#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Trusted manual LAVA controller and independent finalizer. Never run PR code here."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys
import time
from urllib.parse import urljoin, urlsplit

import requests
import yaml

REPOSITORY = "qualcomm-linux/qcom-linux-testkit"
LAVA = "https://lava-oss.qualcomm.com"
GITHUB = "https://api.github.com"
TERMINAL = {"Finished", "Canceled"}


def save_json(path, data):
    """Atomically retain progress so a failed API request cannot truncate it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def digest(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


class API:
    """Small authenticated REST client with bounded reads and no mutation retries."""

    def __init__(self, base, token, prefix="Bearer"):
        self.base = base
        self.session = requests.Session()
        if token:
            self.session.headers["Authorization"] = f"{prefix} {token}"

    def request(self, method, path, **kwargs):
        url = urljoin(self.base + "/", path)
        if urlsplit(url).netloc != urlsplit(self.base).netloc:
            raise ValueError("API pagination or request escaped its origin")
        try:
            response = self.session.request(method, url, timeout=(15, 60), **kwargs)
        except requests.RequestException:
            raise RuntimeError(f"{method} {urlsplit(url).path}: connection failed or timed out") from None
        if not response.ok:
            # Do not print response bodies, headers or signed download URLs.
            raise RuntimeError(f"{method} {urlsplit(url).path}: HTTP {response.status_code}")
        return response

    def get(self, path, **params):
        return self.request("GET", path, params=params).json()

    def pages(self, path, key=None, **params):
        """Support GitHub Link pagination and LAVA next/results pagination."""
        while path:
            response = self.request("GET", path, params=params)
            data = response.json()
            if isinstance(data, list):
                yield from data
            else:
                yield from data[key or "results"]
            path = response.links.get("next", {}).get("url")
            if isinstance(data, dict) and data.get("next"):
                path = data["next"]
            params = {}


def github():
    return API(GITHUB, os.environ.get("GH_TOKEN", ""))


def resolve_request():
    """Accept artifacts only from the trusted manual validation workflow on main."""
    run_id = os.environ["VALIDATION_RUN_ID"]
    attempt = os.environ.get("VALIDATION_RUN_ATTEMPT", "")
    if not re.fullmatch(r"[1-9][0-9]{0,19}", run_id) or (
            attempt and not re.fullmatch(r"[1-9][0-9]{0,19}", attempt)):
        raise ValueError("Validation run and attempt must be positive numeric IDs")
    gh = github()
    endpoint = f"/repos/{REPOSITORY}/actions"
    workflow = gh.get(f"{endpoint}/workflows/lava-pr-validation.yml")
    latest = gh.get(f"{endpoint}/runs/{run_id}")
    attempt = attempt or str(latest["run_attempt"])
    same_run = run_id == os.environ.get("GITHUB_RUN_ID")
    if same_run:
        if attempt != os.environ.get("GITHUB_RUN_ATTEMPT"):
            raise ValueError("Automatic results must use the current workflow attempt")
    elif latest["status"] != "completed":
        raise ValueError("Wait for the validation workflow to complete before recovering results")
    run = gh.get(f"{endpoint}/runs/{run_id}/attempts/{attempt}")
    if (run.get("repository", {}).get("full_name") != REPOSITORY or
            run.get("head_repository", {}).get("full_name") != REPOSITORY or
            run.get("workflow_id") != workflow["id"] or
            run.get("path") != ".github/workflows/lava-pr-validation.yml" or
            run.get("event") != "workflow_dispatch" or run.get("head_branch") != "main" or
            str(run.get("id")) != run_id or str(run.get("run_attempt")) != attempt):
        raise ValueError("Results require a main-branch manual LAVA PR validation run in this repository")
    if not same_run and run["status"] != "completed":
        raise ValueError("The requested validation attempt has not completed")
    artifact_name = f"lava-request-{run_id}-{attempt}"
    artifacts = [artifact for artifact in gh.pages(
        f"{endpoint}/runs/{run_id}/artifacts", key="artifacts", per_page=100)
        if artifact["name"] == artifact_name]
    if len(artifacts) > 1 or any(artifact["expired"] for artifact in artifacts):
        raise ValueError("The prepared request artifact is ambiguous or expired")
    if not artifacts:
        if not same_run or os.environ.get("VALIDATION_RESULT") not in {"failure", "cancelled", "skipped"}:
            raise ValueError("No prepared request artifact exists for this validation attempt")
        print("Validation did not complete successfully and no request artifact is available for collection.")
    return dict(run_id=run_id, run_attempt=attempt, artifact_name=artifact_name,
                prepared="true" if artifacts else "false")


def lava():
    api = API(LAVA, os.environ["LAVA_OSS_TOKEN"], "Token")
    if api.get("/api/v0.2/system/whoami/").get("user") != os.environ["LAVA_OSS_USER"]:
        raise ValueError("LAVA_OSS_USER does not match the configured API token owner")
    return api


def matching_jobs(api, entry):
    """Verify every returned row, older servers can ignore query filters."""
    matches = []
    for job in api.pages("/api/v0.2/jobs/", description=entry["key"], limit=100):
        if job.get("description") != entry["key"]:
            continue
        if job.get("submitter") != os.environ["LAVA_OSS_USER"]:
            continue
        metadata = job.get("metadata") or {}
        if metadata.get("testkit-request-key") != entry["key"]:
            raise RuntimeError("Job name collision without matching request metadata")
        matches.append(job)
    if len(matches) > 1:
        raise RuntimeError(f"Multiple LAVA jobs match {entry['key']}, resolve duplicates")
    return matches


def validate_jobs(api, folder, manifest):
    """Validate all jobs before spending a single device slot."""
    # HEAD confirms registration without fetching the stored credential.
    api.request("HEAD", f"/api/v0.2/remote-artifact-tokens/{manifest['artifact_token_name']}/")
    paths = {definition["path"] for entry in manifest["jobs"] for definition in entry["definitions"]}
    for path in sorted(paths):
        result = api.request("POST", "/api/v0.2/jobs/validate_testdef/", json={
            "definition": (folder / "source" / path).read_text(encoding="utf-8"),
        }).json()
        if result.get("message") != "Test definition valid.":
            raise ValueError(f"Invalid test definition {path}: {result.get('message')}")
    for entry in manifest["jobs"]:
        definition = (folder / entry["file"]).read_text(encoding="utf-8")
        if digest(yaml.safe_load(definition)) != entry["definition_hash"]:
            raise ValueError("Prepared job changed after its manifest was written")
        result = api.request("POST", "/api/v0.2/jobs/validate/", json={
            "definition": definition, "strict": True,
        }).json()
        if result.get("message") != "Job valid.":
            raise ValueError(f"Invalid job {entry['file']}: {result.get('message')}")
        api.get(f"/api/v0.2/devicetypes/{entry['device_type']}/")


def run_jobs(folder, manifest):
    """Hold slots until LAVA terminates, including time spent queued."""
    api = lava()
    validate_jobs(api, folder, manifest)
    state = {"jobs": {}, "error": ""}
    state_path = folder / "execution.json"
    deadline = time.monotonic() + manifest["request_minutes"] * 60
    pending = list(manifest["jobs"])
    active = {}

    def interrupted(signum, frame):
        raise InterruptedError(f"Controller received signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        while pending or active:
            if time.monotonic() >= deadline:
                raise TimeoutError("Validation request deadline expired")
            for key, job in list(active.items()):
                current = api.get(f"/api/v0.2/jobs/{job['id']}/")
                state["jobs"][key] = {field: current.get(field) for field in (
                    "id", "state", "health", "actual_device", "submit_time", "end_time")}
                if current["state"] in TERMINAL:
                    del active[key]
            while pending and len(active) < manifest["max_active_jobs"]:
                entry = pending[0]
                matches = matching_jobs(api, entry)
                if matches:
                    job = matches[0]
                else:
                    # A previous workflow's cleanup may still be running.
                    outstanding = [item for item in api.pages(
                        "/api/v0.2/jobs/", end_time__isnull="true", description__startswith="testkit-",
                        submitter__username=os.environ["LAVA_OSS_USER"], limit=100)
                        if item.get("state") not in TERMINAL and
                        item.get("submitter") == os.environ["LAVA_OSS_USER"] and
                        (item.get("metadata") or {}).get("testkit-request-key")]
                    if len(outstanding) >= manifest["max_active_jobs"]:
                        break
                    # Mark intent before POST. A timeout is never blindly retried.
                    state["jobs"][entry["key"]] = {"state": "Submitting"}
                    save_json(state_path, state)
                    definition = (folder / entry["file"]).read_text(encoding="utf-8")
                    try:
                        result = api.request("POST", "/api/v0.2/jobs/", json={
                            "definition": definition,
                        }).json()
                        ids = result.get("job_ids", [])
                        if len(ids) != 1:
                            raise RuntimeError("Expected one non-multinode LAVA job")
                        job = api.get(f"/api/v0.2/jobs/{ids[0]}/")
                    except (requests.RequestException, RuntimeError):
                        matches = matching_jobs(api, entry)
                        if not matches:
                            raise RuntimeError(
                                "Submission outcome is unknown, no automatic resubmission") from None
                        job = matches[0]
                pending.pop(0)
                print(f"{entry['target']} {entry['group']}: {LAVA}/scheduler/job/{job['id']}",
                      flush=True)
                state["jobs"][entry["key"]] = {"id": job["id"], "state": job["state"]}
                if job["state"] not in TERMINAL:
                    active[entry["key"]] = job
                save_json(state_path, state)
            save_json(state_path, state)
            if pending or active:
                time.sleep(30)
    except (Exception, KeyboardInterrupt) as error:
        state["error"] = str(error)
        save_json(state_path, state)
        raise
    finally:
        # The results job or manual recovery also reconciles remote records if this
        # process or its runner disappears before recording a submitted ID.
        for job in active.values():
            if str((job.get("metadata") or {}).get("testkit-workflow-run")) == manifest["run_id"]:
                try:
                    api.request("POST", f"/api/v0.2/jobs/{job['id']}/cancel/")
                except (requests.RequestException, RuntimeError):
                    print(f"Job {job['id']} still needs finalizer cancellation", file=sys.stderr)


def collect_results(api, job, entry):
    """Count functional results, retaining infrastructure and missing evidence."""
    observed = []
    for suite in api.pages(f"/api/v0.2/jobs/{job['id']}/suites/", limit=100):
        cases = list(api.pages(
            f"/api/v0.2/jobs/{job['id']}/suites/{suite['id']}/tests/", limit=100))
        observed.append({"suite": suite["name"], "cases": cases})
    rows = []
    for definition in entry["definitions"]:
        # LAVA prefixes definition names with the test action ordinal.
        candidates = [suite for suite in observed if
                      suite["suite"] == definition["name"] or
                      suite["suite"].endswith("_" + definition["name"])]
        cases = [case for suite in candidates for case in suite["cases"]]
        counts = Counter(case["result"].lower() for case in cases)
        missing = sorted(set(definition.get("expected", [])) -
                         {case["name"] for case in cases})
        errors = []
        if not cases:
            errors.append("No results")
        if len(candidates) > 1:
            errors.append("Ambiguous result suites")
        if missing:
            errors.append("Missing: " + ", ".join(missing))
        if not counts["pass"] and not counts["fail"]:
            errors.append("No executed PASS/FAIL validation")
        if any(result not in {"pass", "fail", "skip"} for result in counts):
            errors.append("Unexpected result status")
        rows.append(dict(target=entry["target"], group=entry["group"],
                         coverage=definition["coverage"], name=definition["name"],
                         counts=dict(counts), errors=errors, job=job["id"]))
    infrastructure = [case for suite in observed if suite["suite"] == "lava"
                      for case in suite["cases"] if case["result"].lower() == "fail"]
    if job["state"] != "Finished" or job["health"] != "Complete" or infrastructure:
        rows.append(dict(target=entry["target"], group=entry["group"], coverage="Job",
                         name="Deploy/boot/execution", counts={}, job=job["id"],
                         errors=[f"{job['state']}/{job['health']}"] +
                         [case["name"] for case in infrastructure]))
    return rows, observed


def finish_jobs(folder, manifest):
    """Reconcile and cancel only this run's jobs, then publish one result comment."""
    if not manifest["submit_requested"]:
        print("Preparation only, no LAVA jobs or PR results comment requested.")
        return 0
    api = lava()
    rows, evidence = [], []
    for entry in manifest["jobs"]:
        try:
            matches = matching_jobs(api, entry)
            if not matches:
                raise RuntimeError("Not submitted or submission could not be reconciled")
            job = matches[0]
            owned = str((job.get("metadata") or {}).get("testkit-workflow-run")) == manifest["run_id"]
            if job["state"] not in TERMINAL and owned:
                api.request("POST", f"/api/v0.2/jobs/{job['id']}/cancel/")
                job = api.get(f"/api/v0.2/jobs/{job['id']}/")
            result, raw = collect_results(api, job, entry)
            rows.extend(result)
            evidence.append({"job": job["id"], "results": raw})
        except (requests.RequestException, RuntimeError, ValueError) as error:
            rows.append(dict(target=entry["target"], group=entry["group"], coverage="Job",
                             name="Collection", counts={}, job=None, errors=[str(error)]))
    save_json(folder / "results.json", {"rows": rows, "evidence": evidence})
    failed = any(row["errors"] or row["counts"].get("fail") for row in rows) or not rows
    gh = github()
    pr = gh.get(f"/repos/{REPOSITORY}/pulls/{manifest['pr']}")
    marker = f"<!-- testkit-lava:{manifest['run_id']} -->"
    lines = [marker, f"LAVA validation for `{manifest['sha']}`",
             f"Images: [meta-qcom {manifest['build']['id']}]({manifest['build']['url']}), "
             f"`{manifest['distro']}`, `{manifest['image_type']}`, producer `{manifest['build']['prefix'].rstrip('/').rsplit('/', 1)[-1]}`.",
             "Result: **Needs attention**" if failed else "Result: **PASS**"]
    if pr["head"]["sha"] != manifest["sha"]:
        lines.append("The PR head has changed. These results apply only to the commit above.")
    if manifest.get("target_matrix"):
        matrix = manifest["target_matrix"]
        matrix_url = f"https://github.com/{matrix['repository']}/blob/{matrix['revision']}/{matrix['workflow']}"
        lines.append(f"Targets: {len(matrix['selected'])}/{len(matrix['targets'])} from "
                     f"[meta-qcom {matrix['job']}]({matrix_url}).")
        if matrix.get("excluded"):
            lines.append("Configured target exclusions: " + ", ".join(matrix["excluded"]) + ".")
    if manifest.get("exclusions"):
        lines.append("Template exclusions: " + ", ".join(manifest["exclusions"]) + ".")
    lines += ["", "| Target | Coverage | Test/configuration | PASS | FAIL | SKIP | Missing/Error | LAVA |",
              "|---|---|---|---:|---:|---:|---|---|"]
    header = list(lines)

    def cell(value):
        return str(value).replace("|", "&#124;").replace("\n", " ").replace("<", "&lt;")

    for row in rows:
        counts = row["counts"]
        link = f"[{row['job']}]({LAVA}/scheduler/job/{row['job']})" if row["job"] else "—"
        lines.append("| " + " | ".join([
            cell(row["target"]), cell(row["coverage"]), cell(row["name"]),
            str(counts.get("pass", 0)), str(counts.get("fail", 0)), str(counts.get("skip", 0)),
            cell(", ".join(row["errors"])) or "—", link]) + " |")
    workflow_url = f"https://github.com/{REPOSITORY}/actions/runs/{os.environ.get('GITHUB_RUN_ID', manifest['run_id'])}"
    request_url = f"https://github.com/{REPOSITORY}/actions/runs/{manifest['run_id']}"
    lines += ["", f"[Selection manifest]({request_url}), [complete results]({workflow_url}). "
              "LAVA setup bookkeeping is excluded from functional counts."]
    body = "\n".join(lines)
    (folder / "summary.md").write_text(body + "\n", encoding="utf-8")
    if len(body) > 60000:
        grouped = {}
        for row in rows:
            key = (row["target"], row["coverage"], row["group"], row["job"])
            aggregate = grouped.setdefault(key, {"counts": Counter(), "errors": 0})
            aggregate["counts"].update(row["counts"])
            aggregate["errors"] += bool(row["errors"])
        for (target, coverage, group, job_id), aggregate in grouped.items():
            counts = aggregate["counts"]
            link = f"[{job_id}]({LAVA}/scheduler/job/{job_id})" if job_id else "—"
            header.append("| " + " | ".join([
                cell(target), cell(coverage), cell(group), str(counts["pass"]),
                str(counts["fail"]), str(counts["skip"]), str(aggregate["errors"]), link]) + " |")
        body = "\n".join(header) + f"\n\n[Complete per-test table]({workflow_url}) in the results artifact."
    comments = list(gh.pages(f"/repos/{REPOSITORY}/issues/{manifest['pr']}/comments", per_page=100))
    previous = next((comment for comment in comments if marker in comment.get("body", "")
                     and comment["user"]["type"] == "Bot"), None)
    if previous:
        gh.request("PATCH", f"/repos/{REPOSITORY}/issues/comments/{previous['id']}", json={"body": body})
    else:
        gh.request("POST", f"/repos/{REPOSITORY}/issues/{manifest['pr']}/comments", json={"body": body})
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write(body)
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "run", "resolve", "finish"])
    parser.add_argument("--output", type=Path, default=Path("lava-output"))
    args = parser.parse_args()
    if args.command == "resolve":
        request = resolve_request()
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            for name, value in request.items():
                stream.write(f"{name}={value}\n")
        return 0
    if args.command == "prepare":
        from lava_pr_prepare import prepare
        prepare(args.output)
        return 0
    manifest = json.loads((args.output / "manifest.json").read_text(encoding="utf-8"))
    if manifest["run_id"] != os.environ["VALIDATION_RUN_ID"]:
        raise ValueError("Manifest belongs to another workflow run")
    if args.command == "run":
        run_jobs(args.output, manifest)
        return 0
    return finish_jobs(args.output, manifest)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, requests.RequestException, OSError) as failure:
        print(f"Validation stopped: {failure}", file=sys.stderr)
        sys.exit(1)
