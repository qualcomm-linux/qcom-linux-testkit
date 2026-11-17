#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Trusted manual LAVA controller and independent finalizer. Never run PR code here."""

import argparse
from collections import Counter
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sys
import time
from urllib.parse import urljoin, urlsplit
import zipfile

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
        attempts = 3 if method in {"GET", "HEAD"} else 1
        for attempt in range(attempts):
            try:
                response = self.session.request(method, url, timeout=(15, 60), **kwargs)
            except requests.RequestException:
                if attempt + 1 == attempts:
                    raise RuntimeError(f"{method} {urlsplit(url).path}: connection failed or timed out") from None
            else:
                if response.status_code not in {429, 500, 502, 503, 504} or attempt + 1 == attempts:
                    break
                response.close()
            time.sleep(2 ** attempt)
        if not response.ok:
            # Do not print response bodies, headers or signed download URLs.
            message = f"{method} {urlsplit(url).path}: HTTP {response.status_code}"
            if (self.base == GITHUB and response.status_code == 403 and method in {"POST", "PATCH"} and
                    re.fullmatch(r"/repos/[^/]+/[^/]+/issues/(?:[0-9]+/comments|comments/[0-9]+)",
                                 urlsplit(url).path)):
                message += (". PR comment access denied. Check pull-requests: write in the calling and "
                            "reusable workflows, and repository policy.")
            raise RuntimeError(message)
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


def previous_request(gh, run_id, attempt, kind="request", filename="manifest.json"):
    """Freeze reruns to the most recent immutable request from this workflow run."""
    if int(attempt) == 1:
        return {}
    endpoint = f"/repos/{REPOSITORY}/actions"
    candidates = []
    for artifact in gh.pages(f"{endpoint}/runs/{run_id}/artifacts", "artifacts", per_page=100):
        match = re.fullmatch(rf"lava-{kind}-{re.escape(run_id)}-([1-9][0-9]*)", artifact["name"])
        if match and int(match[1]) < int(attempt):
            candidates.append((int(match[1]), artifact))
    if not candidates:
        # Submission cannot start before the immutable request upload succeeds.
        return {}
    latest = max(number for number, artifact in candidates)
    selected = [artifact for number, artifact in candidates if number == latest]
    if len(selected) != 1 or selected[0]["expired"]:
        raise ValueError("The previous request is ambiguous or expired, use a new manual validation run")
    response = gh.request("GET", f"{endpoint}/artifacts/{selected[0]['id']}/zip")
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        if archive.namelist().count(filename) != 1 or archive.getinfo(filename).file_size > 4194304:
            raise ValueError("Invalid previous request manifest")
        request = json.loads(archive.read(filename))
    if (str(request["run_id"]) != run_id or
            str(request.get("run_attempt", "1")) != str(latest)):
        raise ValueError("Previous request does not belong to this workflow attempt")
    return request


def update_check(gh, context, status, summary, conclusion=None):
    """Maintain one check per attempt, without overwriting newer validation."""
    if not context["submit_requested"]:
        return
    prefix = f"testkit-lava:{context['run_id']}:"
    matches = [check for check in gh.pages(
        f"/repos/{REPOSITORY}/commits/{context['sha']}/check-runs", "check_runs", per_page=100, filter="all")
        if check.get("name") == "LAVA PR validation" and
        check.get("app", {}).get("slug") == "github-actions" and
        str(check.get("external_id", "")).startswith(prefix)]
    for check in matches:
        previous = check["external_id"].removeprefix(prefix)
        if not previous.isdigit():
            raise ValueError("Invalid lifecycle check attempt")
        if int(previous) > int(context["run_attempt"]):
            return
    matches = [check for check in matches if check["external_id"] == prefix + str(context["run_attempt"])]
    if len(matches) > 1:
        raise ValueError("Multiple lifecycle checks belong to this validation attempt")
    payload = dict(name="LAVA PR validation", status=status,
                   external_id=prefix + str(context["run_attempt"]),
                   details_url=f"https://github.com/{REPOSITORY}/actions/runs/{context['run_id']}",
                   output=dict(title="LAVA PR validation", summary=summary[:60000]))
    if conclusion:
        payload["conclusion"] = conclusion
    if matches:
        gh.request("PATCH", f"/repos/{REPOSITORY}/check-runs/{matches[0]['id']}", json=payload)
    else:
        gh.request("POST", f"/repos/{REPOSITORY}/check-runs",
                   json=payload | {"head_sha": context["sha"]})


def begin_request(folder):
    """Bind the PR SHA before waiting for an OSS runner, without executing PR code."""
    gh = github()
    run_id = os.environ["VALIDATION_RUN_ID"]
    attempt = os.environ["GITHUB_RUN_ATTEMPT"]
    number = os.environ["PR_NUMBER"]
    if any(not re.fullmatch(r"[1-9][0-9]{0,19}", value) for value in (run_id, attempt, number)):
        raise ValueError("Invalid run, attempt or PR number")
    pr = gh.get(f"/repos/{REPOSITORY}/pulls/{number}")
    if pr["state"] != "open" or pr["base"]["ref"] != "main":
        raise ValueError("Select an open PR targeting main")
    previous = previous_request(gh, run_id, attempt) or previous_request(
        gh, run_id, attempt, "context", "context.json")
    sha = previous["sha"] if previous else os.environ.get("PR_REVISION") or pr["head"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("revision must be a full lowercase commit SHA")
    if previous and previous["pr"] != int(number):
        raise ValueError("Rerun PR differs from the saved request")
    comparison = gh.get(f"/repos/{REPOSITORY}/compare/{sha}...{pr['head']['sha']}")
    if comparison.get("status") not in {"identical", "ahead"}:
        raise ValueError("Requested revision is not an ancestor of the current PR head")
    context = dict(pr=int(number), sha=sha, run_id=run_id, run_attempt=attempt,
                   submit_requested=os.environ.get("SUBMIT_REQUEST", "false") == "true")
    save_json(folder / "context.json", context)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"sha={sha}\ncontext_attempt={attempt}\n")
    update_check(gh, context, "queued", "Waiting for a runner to prepare and submit the selected LAVA tests.")


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
        if int(attempt) > int(os.environ["GITHUB_RUN_ATTEMPT"]):
            raise ValueError("Automatic results cannot use a future workflow attempt")
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
    if (not same_run or attempt != os.environ.get("GITHUB_RUN_ATTEMPT")) and run["status"] != "completed":
        raise ValueError("The requested validation attempt has not completed")
    artifact_name = f"lava-request-{run_id}-{attempt}"
    available = list(gh.pages(f"{endpoint}/runs/{run_id}/artifacts", key="artifacts", per_page=100))
    artifacts = [artifact for artifact in available if artifact["name"] == artifact_name]
    if len(artifacts) > 1 or any(artifact["expired"] for artifact in artifacts):
        raise ValueError("The prepared request artifact is ambiguous or expired")
    if not artifacts:
        if not same_run or os.environ.get("VALIDATION_RESULT") not in {"failure", "cancelled", "skipped"}:
            raise ValueError("No prepared request artifact exists for this validation attempt")
        print("Validation did not complete successfully and no request artifact is available for collection.")
    outcome = os.environ.get("VALIDATION_RESULT")
    if not same_run:
        # A failed publication also fails the workflow. Recover the validator's
        # own outcome so reporting errors do not become hardware failures.
        validators = [job for job in gh.pages(
            f"{endpoint}/runs/{run_id}/attempts/{attempt}/jobs", key="jobs", per_page=100)
            if job.get("name") == "validate" and str(job.get("run_id")) == run_id
            and str(job.get("run_attempt")) == attempt]
        if len(validators) != 1 or validators[0].get("status") != "completed":
            raise ValueError("The completed validation job could not be identified for this attempt")
        outcome = validators[0].get("conclusion")
    if outcome not in {"success", "failure", "cancelled", "skipped", "timed_out",
                       "neutral", "action_required", "stale", "startup_failure"}:
        raise ValueError("The validation controller outcome is not available")
    contexts = []
    for artifact in available:
        match = re.fullmatch(rf"lava-context-{run_id}-([1-9][0-9]*)", artifact["name"])
        if match and int(match[1]) <= int(attempt):
            contexts.append((int(match[1]), artifact))
    context = max(contexts, key=lambda value: value[0])[1] if contexts else None
    if context and (context["expired"] or sum(a["name"] == context["name"] for a in available) != 1):
        raise ValueError("The request context is ambiguous or expired")
    evidence_name = f"lava-evidence-{run_id}-{attempt}"
    evidence = [artifact for artifact in available if artifact["name"] == evidence_name]
    if len(evidence) > 1 or any(artifact["expired"] for artifact in evidence):
        raise ValueError("The collected evidence is ambiguous or expired")
    return dict(run_id=run_id, run_attempt=attempt, artifact_name=artifact_name,
                validation_result=outcome,
                context_artifact=context["name"] if context else "",
                evidence_artifact=evidence_name, evidence_available="true" if evidence else "false",
                prepared="true" if artifacts else "false")


def lava():
    token = os.environ.get("LAVA_OSS_TOKEN", "")
    user = os.environ.get("LAVA_OSS_USER", "")
    if not token or not user:
        raise ValueError("Configure LAVA_OSS_USER and LAVA_OSS_TOKEN for this repository")
    api = API(LAVA, token, "Token")
    if api.get("/api/v0.2/system/whoami/").get("user") != user:
        raise ValueError("LAVA_OSS_USER does not match the configured API token owner")
    return api


def artifact_token_name():
    """Validate the non-secret LAVA reference before building any job definitions."""
    name = os.environ.get("LAVA_ARTIFACT_TOKEN_NAME", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise ValueError("Configure LAVA_ARTIFACT_TOKEN_NAME with the registered OSS artifact token name")
    return name


def preflight():
    """Check org credentials and token registration without submitting jobs."""
    api = lava()
    print("LAVA authentication succeeded and the configured account matches.")
    if not os.environ.get("LAVA_ARTIFACT_TOKEN_NAME"):
        # The API can return secret values. Retain and print only validated names.
        names = sorted({row["name"] for row in api.pages("/api/v0.2/remote-artifact-tokens/")
                        if isinstance(row.get("name"), str) and
                        re.fullmatch(r"[A-Za-z0-9_-]+", row["name"])})
        print("Registered LAVA artifact token names: " + (", ".join(names) or "none"))
        raise ValueError("Set LAVA_ARTIFACT_TOKEN_NAME to the token registered for QLI image downloads")
    name = artifact_token_name()
    api.request("HEAD", f"/api/v0.2/remote-artifact-tokens/{name}/")
    print("LAVA artifact token is registered. Download permission is verified when fetching artifacts.")


def matching_jobs(api, entry, include_active=False):
    """Verify every returned row, older servers can ignore query filters."""
    matches = []
    earlier = []
    for job in api.pages("/api/v0.2/jobs/", description=entry["key"], limit=100):
        if job.get("description") != entry["key"]:
            continue
        if job.get("submitter") != os.environ["LAVA_OSS_USER"]:
            continue
        metadata = job.get("metadata") or {}
        if metadata.get("testkit-request-key") != entry["key"]:
            raise RuntimeError("Job name collision without matching request metadata")
        if entry.get("run_attempt"):
            if str(metadata.get("testkit-workflow-run")) != entry["run_id"]:
                continue
            attempt = str(metadata.get("testkit-workflow-attempt", "1"))
            if not re.fullmatch(r"[1-9][0-9]*", attempt):
                raise RuntimeError("Matching LAVA job has invalid workflow attempt metadata")
            if int(attempt) < int(entry["run_attempt"]):
                earlier.append((int(attempt), job))
                continue
            if attempt != entry["run_attempt"]:
                continue
        matches.append(job)
    if len(matches) > 1:
        raise RuntimeError(f"Multiple LAVA jobs match {entry['key']}, resolve duplicates")
    if not matches and earlier:
        latest = max(attempt for attempt, job in earlier)
        candidates = [job for attempt, job in earlier if attempt == latest]
        if len(candidates) != 1:
            raise RuntimeError("Multiple LAVA jobs match the earlier workflow attempt")
        job = candidates[0]
        if job["state"] not in TERMINAL:
            if include_active:
                return [job]
            raise RuntimeError(f"Earlier attempt job {job['id']} is still active, recover its cleanup first")
        if job["state"] != "Finished" or job.get("health") != "Complete":
            return []
        rows, evidence = collect_results(api, job, entry)
        if rows and all(not row["errors"] and not row["counts"].get("fail") for row in rows):
            matches.append(job)
    return matches


def cancel_owned_job(api, job, run_id, wait_seconds=60, run_attempt=None):
    """Cancel only this run's job and optionally confirm its terminal state."""
    if (job["state"] in TERMINAL or job.get("submitter") != os.environ["LAVA_OSS_USER"] or
            str((job.get("metadata") or {}).get("testkit-workflow-run")) != run_id or
            (run_attempt is not None and
             str((job.get("metadata") or {}).get("testkit-workflow-attempt", "1")) != run_attempt)):
        return job
    error = ""
    try:
        api.request("POST", f"/api/v0.2/jobs/{job['id']}/cancel/")
    except (requests.RequestException, RuntimeError) as failure:
        # A lost response can still mean cancellation was accepted. Read back
        # the job state before deciding, never submit another job here.
        error = str(failure)
    if not wait_seconds:
        if error:
            raise RuntimeError(error)
        return job
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            current = api.get(f"/api/v0.2/jobs/{job['id']}/")
            if current["state"] in TERMINAL:
                return current
        except (requests.RequestException, RuntimeError) as failure:
            error = str(failure)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            detail = f", {error}" if error else ""
            raise RuntimeError(f"Cancellation not confirmed for LAVA job {job['id']}{detail}")
        time.sleep(min(5, remaining))


def cleanup_workspace(folder):
    """Remove disposable snapshots only, keeping request and result evidence."""
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()
    folder = folder.absolute()
    if folder != workspace / "lava-output" or folder.resolve() != folder:
        raise ValueError("Cleanup requires the lava-output directory in GITHUB_WORKSPACE")
    for name in ("source", "source.git"):
        path = folder / name
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            if not path.is_dir() or not path.resolve().is_relative_to(folder):
                raise ValueError(f"Refusing cleanup outside the generated snapshot: {name}")
            shutil.rmtree(path)
        print(f"Temporary snapshot cleared: {name}")


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
                matches = matching_jobs(api, entry, include_active=True)
                if (matches and entry.get("run_attempt") and matches[0]["state"] not in TERMINAL and
                        str(matches[0]["metadata"].get("testkit-workflow-attempt", "1")) != entry["run_attempt"]):
                    # A rerun owns recovery of its earlier attempt for the same
                    # workload. Confirm it stopped before spending another slot.
                    previous_attempt = str(matches[0]["metadata"].get("testkit-workflow-attempt", "1"))
                    cancel_owned_job(api, matches[0], manifest["run_id"], run_attempt=previous_attempt)
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
        # Fail the validation job as well as the reporter, so GitHub's failed-job
        # rerun includes hardware execution instead of repeating only reporting.
        for entry in manifest["jobs"]:
            matches = matching_jobs(api, entry)
            if not matches:
                raise RuntimeError(f"LAVA results missing for {entry['target']} {entry['group']}")
            rows, evidence = collect_results(api, matches[0], entry)
            if not rows or any(row["errors"] or row["counts"].get("fail") for row in rows):
                raise RuntimeError(f"LAVA validation failed for {entry['target']} {entry['group']}")
    except (Exception, KeyboardInterrupt) as error:
        state["error"] = str(error)
        save_json(state_path, state)
        raise
    finally:
        # Include a POST accepted before its response/job ID could be saved.
        # Finalization confirms cancellation and can recover after runner loss.
        cleanup = {}
        for entry in manifest["jobs"]:
            known = state["jobs"].get(entry["key"])
            if not known or known.get("state") in TERMINAL:
                continue
            try:
                matches = matching_jobs(api, entry)
                if not matches:
                    raise RuntimeError("No job found for the attempted submission, finalizer must reconcile")
                job = cancel_owned_job(api, matches[0], manifest["run_id"], wait_seconds=0,
                                       run_attempt=manifest.get("run_attempt", "1"))
                cleanup[entry["key"]] = {"id": job["id"], "state": job["state"]}
            except (requests.RequestException, RuntimeError, ValueError) as failure:
                cleanup[entry["key"]] = {"error": str(failure)}
                print(f"Finalizer cleanup required for {entry['key']}: {failure}", file=sys.stderr)
        if cleanup:
            state["cleanup"] = cleanup
            try:
                save_json(state_path, state)
            except OSError:
                print("Could not save cleanup progress, recover using the immutable request", file=sys.stderr)


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
                         counts=dict(counts), errors=errors, job=job["id"], tests=cases))
    infrastructure = [case for suite in observed if suite["suite"] == "lava"
                      for case in suite["cases"] if case["result"].lower() == "fail"]
    if job["state"] != "Finished" or job["health"] != "Complete" or infrastructure:
        rows.append(dict(target=entry["target"], group=entry["group"], coverage="Job",
                         name="Deploy/boot/execution", counts={}, job=job["id"],
                         errors=[f"{job['state']}/{job['health']}"] +
                         [case["name"] for case in infrastructure]))
    return rows, observed


def result_matrix(rows, targets, by_group=True):
    """Render the same linked target matrix for job groups and configurations."""
    def cell(value):
        return str(value).replace("|", "&#124;").replace("\n", " ").replace("\r", " ").replace("<", "&lt;")

    grouped = {}
    for row in rows:
        if row["coverage"] == "Workflow":
            continue
        label = row["group"] if by_group else f"{row['group']} / {row['coverage']} / {row['name']}"
        value = grouped.setdefault((label, row["target"]), {"counts": Counter(), "errors": [], "jobs": set()})
        value["counts"].update(row["counts"])
        value["errors"].extend(row["errors"])
        if row["job"]:
            value["jobs"].add(row["job"])
    title = "Test group" if by_group else "Test/configuration"
    lines = ["| " + " | ".join([title] + [cell(target) for target in targets]) + " |",
             "|" + "---|" * (len(targets) + 1)]
    for label in sorted({label for label, target in grouped}):
        values = [cell(label)]
        for target in targets:
            value = grouped.get((label, target))
            if value is None:
                values.append("Not scheduled")
                continue
            counts = value["counts"]
            if counts["fail"]:
                status = "FAIL"
            elif value["errors"]:
                status = ("SKIP" if counts["skip"] and not counts["pass"] and
                          set(value["errors"]) == {"No executed PASS/FAIL validation"} else "ERROR")
            else:
                status = "PASS" if counts["pass"] else "SKIP" if counts["skip"] else "NOT RUN"
            links = " ".join(f"[{status} #{job}]({LAVA}/scheduler/job/{job})" for job in sorted(value["jobs"]))
            values.append(f"{links or status} {counts['pass']}/{counts['fail']}/{counts['skip']}")
        lines.append("| " + " | ".join(values) + " |")
    return lines


def collect_jobs(folder, manifest):
    """Reconcile owned jobs on the OSS runner and retain data for hosted reporting."""
    if not manifest["submit_requested"]:
        print("Preparation only, no LAVA jobs or PR results comment requested.")
        return 0
    rows, evidence = [], []
    cleanup_complete = True
    identity = dict(run_id=manifest["run_id"], run_attempt=str(manifest.get("run_attempt", "1")),
                    sha=manifest["sha"], request_digest=digest(manifest))
    save_json(folder / "results.json", identity | dict(rows=rows, evidence=evidence, cleanup_complete=False))
    api = lava()
    for entry in manifest["jobs"]:
        try:
            matches = matching_jobs(api, entry)
            if not matches:
                raise RuntimeError("Not submitted or submission could not be reconciled")
            job = matches[0]
            try:
                job = cancel_owned_job(api, job, manifest["run_id"],
                                       run_attempt=manifest.get("run_attempt", "1"))
            except (requests.RequestException, RuntimeError) as error:
                cleanup_complete = False
                rows.append(dict(target=entry["target"], group=entry["group"], coverage="Job",
                                 name="Cleanup", counts={}, job=job["id"], errors=[str(error)]))
            result, raw = collect_results(api, job, entry)
            if job["state"] not in TERMINAL:
                cleanup_complete = False
            rows.extend(result)
            evidence.append({"job": job["id"], "results": raw})
        except (requests.RequestException, RuntimeError, ValueError) as error:
            cleanup_complete = False
            rows.append(dict(target=entry["target"], group=entry["group"], coverage="Job",
                             name="Collection", counts={}, job=None, errors=[str(error)]))
        save_json(folder / "results.json", identity | dict(rows=rows, evidence=evidence, cleanup_complete=False))
    save_json(folder / "results.json", identity | dict(rows=rows, evidence=evidence, cleanup_complete=cleanup_complete))
    return 0


def finish_jobs(folder, manifest, lifecycle=True):
    """Publish saved results using GitHub only, even when the OSS runner was lost."""
    folder.mkdir(parents=True, exist_ok=True)
    result_path = folder / "results.json"
    rows, evidence = [], []
    cleanup_complete = False
    if result_path.is_file():
        saved = json.loads(result_path.read_text(encoding="utf-8"))
        if (saved.get("run_id") != manifest["run_id"] or saved.get("sha") != manifest["sha"] or
                saved.get("run_attempt") != str(manifest.get("run_attempt", "1")) or
                saved.get("request_digest") != digest(manifest)):
            raise ValueError("Result evidence does not match the immutable request")
        rows, evidence = saved["rows"], saved["evidence"]
        cleanup_complete = saved.get("cleanup_complete") is True
    observed = {(row["target"], row["group"]) for row in rows}
    if manifest["submit_requested"]:
        rows.extend(dict(target=entry["target"], group=entry["group"], coverage="Job", name="Collection",
                         counts={}, job=None, errors=["Result collection unavailable, cleanup is unconfirmed"])
                    for entry in manifest.get("jobs", []) if (entry["target"], entry["group"]) not in observed)
    outcome = os.environ.get("VALIDATION_RESULT", "")
    if outcome and outcome != "success":
        rows.append(dict(target="All", group="Controller", coverage="Workflow",
                         name="Validation controller", counts={}, job=None,
                         errors=[f"Controller outcome: {outcome}"]))
    failed = (any(row["errors"] or row["counts"].get("fail") for row in rows) or
              not rows or not cleanup_complete)
    gh = github()
    publication_error = None
    try:
        pr = gh.get(f"/repos/{REPOSITORY}/pulls/{manifest['pr']}")
    except (requests.RequestException, RuntimeError, ValueError) as error:
        publication_error = error
        pr = None
    marker = f"<!-- testkit-lava:{manifest['run_id']} -->"
    attempt = str(manifest.get("run_attempt", "1"))
    lines = [marker, f"<!-- testkit-lava-attempt:{attempt} -->",
             f"LAVA validation for `{manifest['sha']}`, attempt {attempt}",
             "Result: **Needs attention**" if failed else "Result: **PASS**"]
    if manifest.get("build"):
        lines.append(f"Images: [meta-qcom {manifest['build']['id']}]({manifest['build']['url']}), "
                     f"`{manifest['distro']}`, `{manifest['image_type']}`, "
                     f"producer `{manifest['build']['prefix'].rstrip('/').rsplit('/', 1)[-1]}`.")
    if not manifest["submit_requested"]:
        lines[3] = "Result: **Preparation only, no hardware validation requested**"
    elif not cleanup_complete:
        lines.append("Cleanup is unconfirmed. Use the LAVA PR results workflow with this run and attempt "
                     "to recover remote jobs and results. No hardware PASS is claimed without evidence.")
    if pr is None:
        lines.append("PR access is unavailable. Results are retained in this workflow for publication recovery.")
    elif pr["head"]["sha"] != manifest["sha"]:
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
    if manifest.get("baseline_helpers"):
        helpers = sorted({entry["path"] for entry in manifest["baseline_helpers"]})
        lines.append("Shared-helper coverage assigned to the mandatory baseline: " + ", ".join(helpers) + ".")
    workflow_url = f"https://github.com/{REPOSITORY}/actions/runs/{os.environ.get('GITHUB_RUN_ID', manifest['run_id'])}"
    request_url = f"https://github.com/{REPOSITORY}/actions/runs/{manifest['run_id']}"
    totals = Counter()
    for row in rows:
        totals.update(row["counts"])
    targets = sorted({entry["target"] for entry in manifest.get("jobs", [])})
    lines += ["", f"[Workflow run]({workflow_url}) · [Validation request]({request_url})",
              f"PASS: {totals['pass']} | FAIL: {totals['fail']} | SKIP: {totals['skip']}",
              "Counts in each cell are PASS/FAIL/SKIP. SKIP is not completed validation.", ""]
    lines += result_matrix(rows, targets)
    controller_errors = [error for row in rows if row["coverage"] == "Workflow" for error in row["errors"]]
    if controller_errors:
        lines += ["", "Workflow: " + ", ".join(controller_errors)]
    lines += ["", f"[Complete testcase matrix and evidence]({workflow_url}) are in the results artifact. "
              "The matrix includes baseline tests and PR additions. LAVA setup bookkeeping is excluded."]
    case_rows = []
    for row in rows:
        if not row.get("tests") or row["errors"]:
            case_rows.append(row if not row.get("tests") else row | {"counts": {}})
        for case in row.get("tests", []):
            result = case["result"].lower()
            case_rows.append(row | {"name": row["name"] + " / " + case["name"],
                                    "counts": {result: 1},
                                    "errors": [] if result in {"pass", "fail", "skip"} else ["Unexpected result status"]})
    test_lines = result_matrix(case_rows, targets, by_group=False)
    (folder / "test-results.md").write_text("\n".join(test_lines) + "\n", encoding="utf-8")
    lines += ["", "<details>", "<summary>Testcase results by target</summary>", ""]
    # Keep both summaries identical within GitHub's comment limit. The artifact
    # always retains every row when a large result matrix needs a preview.
    size = len("\n".join(lines).encode("utf-8"))
    displayed = 0
    for line in test_lines:
        size += len(line.encode("utf-8")) + 1
        if size > 60000:
            break
        lines.append(line)
        displayed += 1
    if displayed < len(test_lines):
        lines += ["", f"Showing {max(0, displayed - 2)} of {len(test_lines) - 2} rows. "
                  "Download test-results.md from the results artifact for the complete matrix."]
    lines += ["", "</details>"]
    body = "\n".join(lines)
    (folder / "summary.md").write_text(body + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write(body)
    if not manifest["submit_requested"]:
        return int(outcome not in {"", "success"})
    if publication_error is not None:
        raise publication_error
    comments = list(gh.pages(f"/repos/{REPOSITORY}/issues/{manifest['pr']}/comments", per_page=100))
    previous = next((comment for comment in comments if marker in comment.get("body", "")
                     and comment["user"]["type"] == "Bot"), None)
    if previous:
        prior_attempt = re.search(r"<!-- testkit-lava-attempt:([1-9][0-9]*) -->", previous["body"])
        if prior_attempt and int(prior_attempt[1]) > int(attempt):
            print("Preserving the PR summary from a newer attempt, older results remain in the artifact")
            return int(failed)
    try:
        if previous:
            gh.request("PATCH", f"/repos/{REPOSITORY}/issues/comments/{previous['id']}", json={"body": body})
        else:
            gh.request("POST", f"/repos/{REPOSITORY}/issues/{manifest['pr']}/comments", json={"body": body})
    except (requests.RequestException, RuntimeError):
        if lifecycle:
            update_check(gh, manifest, "completed", "PR comment publication failed. Results remain in the workflow artifacts.",
                         "failure")
        raise
    conclusion = "cancelled" if outcome == "cancelled" else "timed_out" if outcome == "timed_out" else (
        "failure" if failed or not cleanup_complete else "success")
    if lifecycle:
        update_check(gh, manifest, "completed", body, conclusion)
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["begin", "start", "preflight", "prepare", "run", "resolve",
                                            "collect", "publish", "finish", "cleanup"])
    parser.add_argument("--output", type=Path, default=Path("lava-output"))
    args = parser.parse_args()
    if args.command == "begin":
        begin_request(args.output)
        return 0
    if args.command == "cleanup":
        cleanup_workspace(args.output)
        return 0
    if args.command == "preflight":
        preflight()
        return 0
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
    path = args.output / "manifest.json"
    if not path.is_file() and args.command in {"start", "publish"}:
        path = args.output / "context.json"
    if path.is_file():
        manifest = json.loads(path.read_text(encoding="utf-8"))
    elif args.command == "publish":
        number = os.environ.get("VALIDATION_PR", "")
        sha = os.environ.get("VALIDATION_SHA", "")
        if not re.fullmatch(r"[1-9][0-9]*", number) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            message = "Validation stopped before request metadata was saved. No functional results are available.\n"
            args.output.mkdir(parents=True, exist_ok=True)
            (args.output / "summary.md").write_text(message, encoding="utf-8")
            if os.environ.get("GITHUB_STEP_SUMMARY"):
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
                    summary.write(message)
            return 1
        manifest = dict(pr=int(number), sha=sha, run_id=os.environ["VALIDATION_RUN_ID"],
                        submit_requested=os.environ.get("SUBMIT_REQUEST") == "true")
    else:
        raise ValueError("Prepared request is missing")
    if path.name == "context.json" or "run_attempt" not in manifest:
        manifest["run_attempt"] = os.environ.get("VALIDATION_RUN_ATTEMPT", os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    if manifest["run_id"] != os.environ["VALIDATION_RUN_ID"]:
        raise ValueError("Manifest belongs to another workflow run")
    for entry in manifest.get("jobs", []):
        entry.setdefault("run_id", manifest["run_id"])
        entry.setdefault("run_attempt", str(manifest.get("run_attempt", "1")))
    if args.command == "run":
        run_jobs(args.output, manifest)
        return 0
    if args.command == "start":
        update_check(github(), manifest, "in_progress", "The validation runner is preparing the LAVA request.")
        return 0
    if args.command == "collect":
        return collect_jobs(args.output, manifest)
    if args.command == "finish":
        # Preserve the earlier combined CLI until consumers move to the split
        # collect/publish steps and grant the hosted publisher checks:write.
        collect_jobs(args.output, manifest)
        return finish_jobs(args.output, manifest, lifecycle=False)
    return finish_jobs(args.output, manifest)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, requests.RequestException, OSError) as failure:
        print(f"Validation stopped: {failure}", file=sys.stderr)
        sys.exit(1)
