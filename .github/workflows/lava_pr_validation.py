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
import subprocess
import sys
import time
from urllib.parse import urljoin, urlsplit, urlunsplit
import zipfile

import requests
import yaml

REPOSITORY = "qualcomm-linux/qcom-linux-testkit"
LAVA = "https://lava.infra.foundries.io"
GITHUB = "https://api.github.com"
TERMINAL = {"Finished", "Canceled"}
PRECHECK_STATES = {"PrecheckFailed", "PrecheckSkipped"}


def save_json(path, data):
    """Atomically retain progress so a failed API request cannot truncate it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def digest(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()


def record_failure(folder, stage, failure):
    """Retain a sanitized controller error even before a manifest exists."""
    message = str(failure)
    if isinstance(failure, subprocess.SubprocessError):
        message = "Controller subprocess failed or timed out, check the preceding step output"
    elif isinstance(failure, yaml.YAMLError):
        message = "Invalid YAML in the selected definitions or templates"
    for name in ("GH_TOKEN", "META_QCOM_READ_TOKEN", "LAVATOKEN", "LAVA_OSS_TOKEN", "QLI_S3_TOKEN", "QLI_ARTIFACT_TOKEN"):
        value = os.environ.get(name)
        if value:
            message = message.replace(value, "[redacted]")
    # Signed URLs and URL userinfo must not reach artifacts or PR comments.
    message = re.sub(r"https?://[^\s<>\"']+", "[URL omitted]", message)
    message = " ".join(message.split())[:2000]
    if stage not in {"begin", "start", "preflight", "plans", "prepare", "validate", "cleanup"}:
        return message
    context_path = folder / "context.json"
    context = json.loads(context_path.read_text(encoding="utf-8")) if context_path.is_file() else {}
    if not isinstance(context, dict):
        raise ValueError("Invalid controller context")
    saved = dict(run_id=os.environ.get("VALIDATION_RUN_ID", ""),
                 run_attempt=os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
                 sha=context.get("sha", os.environ.get("PR_REVISION", "")),
                 stage=stage, error=message)
    path = folder / "controller-errors.json"
    errors = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else []
    if not isinstance(errors, list):
        raise ValueError("Invalid controller error evidence")
    errors.append(saved)
    save_json(path, errors)
    return message


class APIError(RuntimeError):
    """Retain HTTP status so definition rejections do not hide service failures."""

    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


class API:
    """Small authenticated REST client with bounded reads and no mutation retries."""

    def __init__(self, base, token, prefix="Bearer"):
        self.base = base
        self.session = requests.Session()
        if token:
            self.session.headers["Authorization"] = f"{prefix} {token}"

    def request(self, method, path, **kwargs):
        url = urljoin(self.base + "/", path)
        if (urlsplit(url).scheme, urlsplit(url).netloc) != (urlsplit(self.base).scheme, urlsplit(self.base).netloc):
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
            raise APIError(message, response.status_code)
        return response

    def get(self, path, **params):
        return self.request("GET", path, params=params).json()

    def pages(self, path, key=None, **params):
        """Support GitHub Link pagination and LAVA next/results pagination."""
        visited = set()
        while path:
            page = urljoin(self.base + "/", path)
            parsed = urlsplit(page)
            if (self.base == LAVA and parsed.scheme == "http" and
                    parsed.netloc == urlsplit(LAVA).netloc):
                # Foundries advertises HTTP next links behind its HTTPS proxy.
                # Request the same page over TLS without relaxing origin checks.
                page = urlunsplit(("https", parsed.netloc, parsed.path, parsed.query, parsed.fragment))
            if page in visited:
                raise RuntimeError("API pagination repeated a page")
            visited.add(page)
            response = self.request("GET", page, params=params)
            data = response.json()
            if isinstance(data, list):
                yield from data
            else:
                yield from data[key or "results"]
            path = response.links.get("next", {}).get("url")
            if isinstance(data, dict) and data.get("next"):
                path = data["next"]
            if path:
                path = urljoin(page, path)
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
    """Bind the PR SHA before waiting for a runner, without executing PR code."""
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
    if previous and previous.get("lava_url") != LAVA:
        raise ValueError("The previous attempt used another LAVA instance, start a new workflow run")
    sha = previous["sha"] if previous else os.environ.get("PR_REVISION") or pr["head"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("revision must be a full lowercase commit SHA")
    if previous and previous["pr"] != int(number):
        raise ValueError("Rerun PR differs from the saved request")
    baseline_input = os.environ.get("INCLUDE_META_QCOM", "true").lower()
    if baseline_input not in {"true", "false"}:
        raise ValueError("include_meta_qcom must be true or false")
    include_meta_qcom = previous.get("include_meta_qcom", True) if previous else baseline_input == "true"
    if not isinstance(include_meta_qcom, bool):
        raise ValueError("Invalid saved meta-qcom test selection")
    comparison = gh.get(f"/repos/{REPOSITORY}/compare/{sha}...{pr['head']['sha']}")
    if comparison.get("status") not in {"identical", "ahead"}:
        raise ValueError("Requested revision is not an ancestor of the current PR head")
    context = dict(pr=int(number), sha=sha, run_id=run_id, run_attempt=attempt, lava_url=LAVA,
                   include_meta_qcom=include_meta_qcom,
                   submit_requested=os.environ.get("SUBMIT_REQUEST", "false") == "true")
    save_json(folder / "context.json", context)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"sha={sha}\ncontext_attempt={attempt}\n")
        output.write(f"include_meta_qcom={str(include_meta_qcom).lower()}\n")
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
    if not artifacts:
        if outcome == "success":
            raise ValueError("No prepared request artifact exists for this validation attempt")
        print("No prepared request artifact is available for collection. Check the preparation logs.")
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
    progress_name = f"lava-progress-{run_id}-{attempt}"
    progress = [artifact for artifact in available if artifact["name"] == progress_name]
    if len(progress) > 1 or any(artifact["expired"] for artifact in progress):
        raise ValueError("The controller progress is ambiguous or expired")
    return dict(run_id=run_id, run_attempt=attempt, artifact_name=artifact_name,
                validation_result=outcome,
                context_artifact=context["name"] if context else "",
                evidence_artifact=evidence_name, evidence_available="true" if evidence else "false",
                progress_artifact=progress_name, progress_available="true" if progress else "false",
                prepared="true" if artifacts else "false")


def lava():
    token = os.environ.get("LAVATOKEN", "")
    if not token:
        raise ValueError("Grant this repository access to the Foundries LAVATOKEN secret used by meta-qcom")
    api = API(LAVA, token, "Token")
    api.username = api.get("/api/v0.2/system/whoami/").get("user")
    if not isinstance(api.username, str) or not api.username or api.username == "AnonymousUser":
        raise ValueError("Foundries did not identify the configured API token owner")
    return api


def artifact_token_name():
    """Validate the non-secret LAVA reference before building any job definitions."""
    name = os.environ.get("LAVA_ARTIFACT_TOKEN_NAME", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise ValueError("Configure FOUNDRIES_ARTIFACT_TOKEN_NAME with the registered Foundries artifact token name")
    return name


def preflight():
    """Check org credentials and token registration without submitting jobs."""
    api = lava()
    print("Foundries authentication succeeded and the job owner was resolved from the API token.")
    if not os.environ.get("LAVA_ARTIFACT_TOKEN_NAME"):
        # The API can return secret values. Retain and print only validated names.
        names = sorted({row["name"] for row in api.pages("/api/v0.2/remote-artifact-tokens/")
                        if isinstance(row.get("name"), str) and
                        re.fullmatch(r"[A-Za-z0-9_-]+", row["name"])})
        print("Registered LAVA artifact token names: " + (", ".join(names) or "none"))
        raise ValueError("Set FOUNDRIES_ARTIFACT_TOKEN_NAME to the token registered for QLI image downloads")
    name = artifact_token_name()
    api.request("HEAD", f"/api/v0.2/remote-artifact-tokens/{name}/")
    print("LAVA artifact token is registered. Download permission is verified when fetching artifacts.")


def job_details(api, job):
    """Normalize ownership from LAVA's saved definition without executing it."""
    fetched = not isinstance(job, dict)
    if not isinstance(job, dict):
        identifier = int(job)
        job = api.get(f"/api/v0.2/jobs/{identifier}/")
        if not isinstance(job, dict) or job.get("id") != identifier:
            raise ValueError("LAVA job detail does not match the requested ID")
    if not isinstance(job.get("metadata"), dict):
        if not fetched and not job.get("original_definition") and not job.get("definition"):
            return job_details(api, job['id'])
        definition = job.get("original_definition") or job.get("definition")
        if isinstance(definition, str) and len(definition.encode("utf-8")) <= 4194304:
            try:
                definition = yaml.safe_load(definition)
            except yaml.YAMLError:
                raise ValueError(f"Invalid saved definition for LAVA job {job['id']}") from None
        if not isinstance(definition, dict) or not isinstance(definition.get("metadata"), dict):
            raise ValueError(f"Ownership metadata unavailable for LAVA job {job['id']}")
        job = job | {"metadata": definition["metadata"]}
    metadata = job["metadata"]
    if any(type(metadata.get(key)) not in (str, int) for key in
           ("testkit-request-key", "testkit-workflow-run")) or (
            "testkit-workflow-attempt" in metadata and
            type(metadata["testkit-workflow-attempt"]) not in (str, int)):
        raise ValueError(f"Invalid ownership metadata for LAVA job {job['id']}")
    return job


def execution_state(folder, manifest):
    """Accept saved job IDs only from this immutable workflow request."""
    identity = dict(run_id=manifest["run_id"], run_attempt=str(manifest.get("run_attempt", "1")),
                    sha=manifest.get("sha", ""), request_digest=digest(manifest))
    path = folder / "execution.json"
    if path.is_file():
        state = json.loads(path.read_text(encoding="utf-8"))
        if all(state.get(key) == value for key, value in identity.items()):
            if (not isinstance(state.get("jobs"), dict) or
                    any(not isinstance(value, dict) for value in state["jobs"].values())):
                raise ValueError("Saved execution jobs must be an object")
            return state
        # Older controllers did not bind execution.json to a request. Recover
        # those jobs through their saved LAVA definitions instead of trusting IDs.
        if "request_digest" in state:
            raise ValueError("Execution evidence does not match the immutable request")
    return identity | dict(jobs={}, error="", started=False)


def matching_jobs(api, entry, include_active=False, known_id=None):
    """Verify every returned row, older servers can ignore query filters."""
    matches = []
    earlier = []
    candidates = ([job_details(api, known_id)] if known_id is not None else
                  api.pages("/api/v0.2/jobs/", description=entry["key"], limit=100))
    for job in candidates:
        if job.get("description") != entry["key"]:
            continue
        if job.get("submitter") != api.username:
            continue
        job = job_details(api, job)
        metadata = job["metadata"]
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
            if known_id is not None:
                raise RuntimeError("Saved job ID belongs to an unsuccessful earlier attempt")
            return []
        rows, evidence = collect_results(api, job, entry)
        if rows and all(not row["errors"] and not row["counts"].get("fail") for row in rows):
            matches.append(job)
    if known_id is not None and not matches:
        raise RuntimeError("Saved LAVA job ID does not match this request or reusable results")
    return matches


def cancel_owned_job(api, job, run_id, wait_seconds=60, run_attempt=None):
    """Cancel only this run's job and optionally confirm its terminal state."""
    if job["state"] in TERMINAL:
        return job
    job = job_details(api, job)
    if (job.get("submitter") != api.username or
            str(job["metadata"].get("testkit-workflow-run")) != run_id or
            (run_attempt is not None and
             str(job["metadata"].get("testkit-workflow-attempt", "1")) != run_attempt)):
        raise RuntimeError(f"Refusing to cancel LAVA job {job['id']} owned by another run or attempt")
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


def definition_validation_error(api, endpoint, payload, expected):
    """Return a definition rejection, while propagating authentication/service failures."""
    try:
        result = api.request("POST", endpoint, json=payload).json()
    except APIError as error:
        if error.status not in {400, 422}:
            raise
        return str(error)
    if result.get("message") != expected:
        return str(result.get("message", "LAVA did not confirm the definition is valid"))
    return ""


def validate_jobs(api, folder, manifest):
    """Check each workload independently against the live authenticated inventory."""
    if manifest.get("lava_url") != LAVA:
        raise ValueError("This request belongs to another LAVA instance, start a new workflow run")
    # HEAD confirms registration without fetching the stored credential.
    api.request("HEAD", f"/api/v0.2/remote-artifact-tokens/{manifest['artifact_token_name']}/")
    paths = {definition["path"] for entry in manifest["jobs"] for definition in entry["definitions"]}
    definition_errors = {}
    for path in sorted(paths):
        try:
            definition = (folder / "source" / path).read_text(encoding="utf-8")
        except FileNotFoundError:
            definition_errors[path] = f"Missing test definition {path}"
            continue
        error = definition_validation_error(api, "/api/v0.2/jobs/validate_testdef/", {
            "definition": definition,
        }, "Test definition valid.")
        if error:
            definition_errors[path] = f"Invalid test definition {path}: {error}"
    # Read the authenticated inventory once. Tags must all match the same
    # device, a global tag definition alone does not make a job schedulable.
    tags = {tag["name"]: tag["id"] for tag in api.pages("/api/v0.2/tags/", limit=100)}
    devices = list(api.pages("/api/v0.2/devices/", limit=100))
    workers = {worker["hostname"]: worker for worker in api.pages("/api/v0.2/workers/", limit=100)}
    scheduling = []
    for entry in manifest["jobs"]:
        definition = (folder / entry["file"]).read_text(encoding="utf-8")
        job = yaml.safe_load(definition)
        if digest(job) != entry["definition_hash"] or job.get("device_type") != entry["device_type"]:
            raise ValueError("Prepared job changed after its manifest was written")
        errors = [definition_errors[item["path"]] for item in entry["definitions"]
                  if item["path"] in definition_errors]
        error = definition_validation_error(api, "/api/v0.2/jobs/validate/", {
            "definition": definition, "strict": True,
        }, "Job valid.")
        if error:
            errors.append(f"Invalid job {entry['file']}: {error}")
        invalid = bool(errors)
        required = set(job.get("tags", []))
        unknown = required - tags.keys()
        boards, eligible = [], []
        for device in devices:
            if device["device_type"] != entry["device_type"]:
                continue
            worker = workers.get(device.get("worker_host"), {})
            available = sorted(name for name, tag_id in tags.items() if tag_id in device.get("tags", []))
            reasons = []
            missing = sorted(required - set(available))
            if missing:
                reasons.append("missing tags " + ", ".join(missing))
            if job.get("device") and device["hostname"] != job["device"]:
                reasons.append(f"requires device {job['device']}")
            if job.get("worker") and device.get("worker_host") != job["worker"]:
                reasons.append(f"requires worker {job['worker']}")
            # Busy devices can serve queued jobs. Do not require an idle device
            # or treat unknown health as failed when LAVA permits health checks.
            if device.get("health") not in {"Good", "Unknown"}:
                reasons.append(f"device health {device.get('health', 'unknown')}")
            if worker.get("state") != "Online" or worker.get("health") != "Active":
                reasons.append(f"worker {device.get('worker_host', 'unknown')} "
                               f"{worker.get('state', 'unknown')}/{worker.get('health', 'unknown')}")
            boards.append(dict(hostname=device["hostname"], tags=available, reasons=reasons,
                               state=device.get("state"), health=device.get("health"),
                               worker=device.get("worker_host")))
            if not reasons:
                eligible.append(device["hostname"])
        if unknown:
            errors.append("Unregistered required tags: " + ", ".join(sorted(unknown)))
        if not boards:
            errors.append(f"No visible boards of device type {entry['device_type']}")
        elif not eligible:
            errors.append("No matching board. " + ". ".join(
                board["hostname"] + ": " + ", ".join(board["reasons"]) for board in boards))
        error = record_failure(folder, "job-precheck", ". ".join(dict.fromkeys(errors)))
        scheduling.append(dict(key=entry["key"], target=result_target(entry), group=entry["group"],
                               file=entry["file"], device_type=entry["device_type"], boards=boards,
                               tags=sorted(required), eligible=eligible, error=error,
                               skip=bool(error) and not invalid))
        if error:
            status = "ERROR" if invalid else "SKIP"
            print(f"{status} {result_target(entry)} ({entry['device_type']}) / "
                  f"{entry['group']}: {error}", flush=True)
    save_json(folder / "scheduling.json", dict(lava_url=LAVA, run_id=manifest["run_id"], jobs=scheduling))
    blocked = sum(bool(job["error"]) for job in scheduling)
    print(f"Pre-checks: ready={len(scheduling) - blocked}, blocked={blocked}. "
          "LAVA still controls permissions, availability and queue allocation.")
    return scheduling


def run_jobs(folder, manifest):
    """Submit every prepared job, then let LAVA schedule devices while tracking completion."""
    if manifest.get("lava_url") != LAVA:
        raise ValueError("This request belongs to another LAVA instance, start a new workflow run")
    state = execution_state(folder, manifest)
    state.update(started=True, error="")
    state_path = folder / "execution.json"
    save_json(state_path, state)
    deadline = time.monotonic() + manifest["request_minutes"] * 60
    pending = list(manifest["jobs"])
    active = {}
    job_fields = ("id", "state", "health", "actual_device", "submit_time", "end_time")
    last_progress = None
    api = None

    def interrupted(signum, frame):
        raise InterruptedError(f"Controller received signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        api = lava()
        prechecks = {item["key"]: item for item in validate_jobs(api, folder, manifest)}
        while pending or active:
            if time.monotonic() >= deadline:
                raise TimeoutError("Validation request deadline expired")
            for key, job in list(active.items()):
                current = api.get(f"/api/v0.2/jobs/{job['id']}/")
                state["jobs"][key] = {field: current.get(field) for field in job_fields}
                if current["state"] in TERMINAL:
                    del active[key]
            while pending:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Validation request deadline expired")
                entry = pending[0]
                known = state["jobs"].get(entry["key"], {})
                matches = matching_jobs(api, entry, include_active=True, known_id=known.get("id"))
                if not matches and known.get("state") in {"Submitting", "Submitted"}:
                    raise RuntimeError("Submission outcome is unknown, recover this request before submitting again")
                if (matches and entry.get("run_attempt") and matches[0]["state"] not in TERMINAL and
                        str(matches[0]["metadata"].get("testkit-workflow-attempt", "1")) != entry["run_attempt"]):
                    # A rerun owns recovery of its earlier attempt for the same
                    # workload. Confirm it stopped before submitting a replacement.
                    previous_attempt = str(matches[0]["metadata"].get("testkit-workflow-attempt", "1"))
                    cancel_owned_job(api, matches[0], manifest["run_id"], run_attempt=previous_attempt)
                    matches = matching_jobs(api, entry)
                if matches:
                    job = matches[0]
                else:
                    error = prechecks[entry["key"]]["error"]
                    if error:
                        status = "PrecheckSkipped" if prechecks[entry["key"]]["skip"] else "PrecheckFailed"
                        state["jobs"][entry["key"]] = {"state": status, "error": error}
                        save_json(state_path, state)
                        pending.pop(0)
                        continue
                    # Mark intent before POST. A timeout is never blindly retried.
                    state["jobs"][entry["key"]] = {"state": "Submitting"}
                    save_json(state_path, state)
                    definition = (folder / entry["file"]).read_text(encoding="utf-8")
                    try:
                        result = api.request("POST", "/api/v0.2/jobs/", json={
                            "definition": definition,
                        }).json()
                        ids = result.get("job_ids", []) if isinstance(result, dict) else []
                        if (not isinstance(ids, list) or len(ids) != 1 or
                                not re.fullmatch(r"[1-9][0-9]*", str(ids[0]))):
                            raise RuntimeError("Expected one non-multinode LAVA job")
                        # Persist the accepted ID before any follow-up network
                        # request, so recovery never depends on a list response.
                        state["jobs"][entry["key"]] = {"id": int(ids[0]), "state": "Submitted"}
                        save_json(state_path, state)
                        matches = matching_jobs(api, entry, known_id=ids[0])
                        if not matches:
                            raise RuntimeError("Submitted LAVA job does not match this request")
                        job = matches[0]
                    except (requests.RequestException, RuntimeError, ValueError) as failure:
                        state["error"] = str(failure)
                        save_json(state_path, state)
                        try:
                            matches = matching_jobs(api, entry, known_id=state["jobs"][entry["key"]].get("id"))
                        except (requests.RequestException, RuntimeError, ValueError) as recovery_error:
                            raise RuntimeError(f"Submission recovery failed: {failure}. {recovery_error}") from None
                        if not matches:
                            raise RuntimeError(
                                f"Submission outcome is unknown, no automatic resubmission. {failure}") from None
                        job = matches[0]
                        state["error"] = ""
                pending.pop(0)
                print(f"{result_target(entry)} {entry['group']}: {LAVA}/scheduler/job/{job['id']}",
                      flush=True)
                state["jobs"][entry["key"]] = {field: job.get(field) for field in job_fields}
                if job["state"] not in TERMINAL:
                    active[entry["key"]] = job
                save_json(state_path, state)
            save_json(state_path, state)
            progress = {}
            for entry in manifest["jobs"]:
                known = state["jobs"].get(entry["key"], {})
                job_state = known.get("state") or "Pending submission"
                category = job_state
                if job_state in {"Submitted", "Scheduling", "Scheduled"}:
                    category = "Queued"
                elif job_state in PRECHECK_STATES:
                    category = "Blocked"
                detail = f"{result_target(entry)} / {entry['group']}: {job_state}"
                if known.get("health"):
                    detail += f"/{known['health']}"
                if known.get("actual_device"):
                    detail += f", device={known['actual_device']}"
                if known.get("id"):
                    detail += f" - {LAVA}/scheduler/job/{known['id']}"
                progress.setdefault(category, []).append(detail)
            if progress != last_progress:
                blocked = sum(job.get("state") in PRECHECK_STATES for job in state["jobs"].values())
                finished = len(manifest["jobs"]) - len(pending) - len(active) - blocked
                print(f"LAVA jobs: total={len(manifest['jobs'])}, finished={finished}, "
                      f"blocked={blocked}, queued_or_running={len(active)}, "
                      f"pending_submission={len(pending)}", flush=True)
                for category, details in progress.items():
                    print(f"  {category} ({len(details)}):", flush=True)
                    for detail in details:
                        print(f"    {detail}", flush=True)
                last_progress = progress
            if pending or active:
                time.sleep(30)
        # Fail the validation job as well as the reporter, so GitHub's failed-job
        # rerun includes hardware execution instead of repeating only reporting.
        executed = 0
        failures = 0
        totals = Counter()
        for entry in manifest["jobs"]:
            if state["jobs"].get(entry["key"], {}).get("state") == "PrecheckSkipped":
                continue
            if state["jobs"].get(entry["key"], {}).get("state") == "PrecheckFailed":
                failures += 1
                print(f"{result_target(entry)} {entry['group']}: pre-check failed, "
                      "see scheduling.json", flush=True)
                continue
            matches = matching_jobs(api, entry, known_id=state["jobs"].get(entry["key"], {}).get("id"))
            if not matches:
                raise RuntimeError(f"LAVA results missing for {result_target(entry)} {entry['group']}")
            rows, evidence = collect_results(api, matches[0], entry)
            issues = [row for row in rows if row["errors"] or row["counts"].get("fail")]
            if not rows or issues:
                failures += 1
                print(f"{result_target(entry)} {entry['group']}: "
                      f"{LAVA}/results/{matches[0]['id']}", flush=True)
                if not rows:
                    print("  No result rows collected", flush=True)
                for row in issues:
                    detail = record_failure(folder, "results", ValueError(
                        f"{row['name']}: " + ", ".join(result_issues(row))))
                    print(f"  {detail}", flush=True)
            for row in rows:
                totals.update(row["counts"])
            executed += sum(row["counts"].get("pass", 0) + row["counts"].get("fail", 0) for row in rows)
        print(f"LAVA jobs finished. Collected testcase results: PASS={totals['pass']}, "
              f"FAIL={totals['fail']}, SKIP={totals['skip']}. "
              f"Jobs needing attention={failures}", flush=True)
        if failures:
            raise RuntimeError(f"LAVA jobs finished with validation issues in {failures} jobs. "
                               "See the per-job results above and diagnostics.md in the results artifact")
        if not executed:
            raise RuntimeError("No executed PASS/FAIL validation across requested tests")
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
            if not known or known.get("state") in TERMINAL | PRECHECK_STATES:
                continue
            try:
                if api is None:
                    raise RuntimeError("LAVA authentication unavailable, cleanup must be recovered")
                matches = matching_jobs(api, entry, known_id=known.get("id"))
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


def result_target(entry):
    """Keep base and overlay results separate while retaining legacy target labels."""
    variant = entry.get("image_variant")
    return f"{entry['target']} ({variant})" if variant else entry["target"]


def unsubmitted_results(entry, error, precheck=False, skip=False):
    """Report named tests that did not run, distinct from observed LAVA results."""
    return [dict(target=result_target(entry), group=entry["group"], coverage=definition["coverage"],
                 name=definition["name"], definition_name=definition["name"], display_name=name,
                 counts={"skip": 1} if skip else {}, job=None, errors=[] if skip else [error],
                 reason=error, precheck=precheck, device_type=entry["device_type"])
            for definition in entry["definitions"]
            for name in definition.get("expected") or [Path(definition["path"]).stem]]


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
        if (definition["coverage"] not in {"Baseline", "Setup"} and
                not counts["pass"] and not counts["fail"]):
            errors.append("No executed PASS/FAIL validation")
        if any(result not in {"pass", "fail", "skip"} for result in counts):
            errors.append("Unexpected result status")
        rows.append(dict(target=result_target(entry), group=entry["group"],
                         coverage=definition["coverage"], name=definition["name"],
                         counts=dict(counts), errors=errors, job=job["id"], tests=cases))
    infrastructure = [case for suite in observed if suite["suite"] == "lava"
                      for case in suite["cases"] if case["result"].lower() == "fail"]
    if job["state"] != "Finished" or job["health"] != "Complete" or infrastructure:
        rows.append(dict(target=result_target(entry), group=entry["group"], coverage="Job",
                         name="Deploy/boot/execution", counts={}, job=job["id"],
                         errors=[f"{job['state']}/{job['health']}"] +
                         [case["name"] for case in infrastructure]))
    return rows, observed


def result_issues(row):
    """Describe failed testcases as well as missing or incomplete validation."""
    issues = list(row["errors"])
    if row["counts"].get("fail"):
        names = sorted({case["name"] for case in row.get("tests", [])
                        if case["result"].lower() == "fail"})
        issues.append("Failed testcases: " + ", ".join(names) if names else
                      f"Failed testcase results: {row['counts']['fail']}")
    if row.get("reason") and row["reason"] not in issues:
        issues.append(row["reason"])
    return issues


def result_matrix(rows, targets, by_group=True, lava_url=LAVA, compact=False):
    """Render the same linked target matrix for job groups and configurations."""
    def cell(value):
        return str(value).replace("|", "&#124;").replace("\n", " ").replace("\r", " ").replace("<", "&lt;")

    group_names = {"pre-merge-basic": "Basic", "pre-merge-audio": "Audio",
                   "pre-merge-bt": "Bluetooth", "pre-merge-camera": "Camera",
                   "pre-merge-display-gfx": "Display/graphics", "pre-merge-gstr-video": "Video (GStreamer)"}
    labels = {}
    mixed = (compact and not by_group and any(row["coverage"] == "Baseline" for row in rows) and
             any(row["coverage"] in {"PR change", "PR addition"} for row in rows))
    sources = {}
    if compact and not by_group:
        for row in rows:
            if row["coverage"] != "Workflow":
                labels.setdefault(row.get("display_name", row["name"]), set()).add(
                    (row["group"], row.get("definition_name", row["name"])))
    grouped = {}
    for row in rows:
        if row["coverage"] == "Workflow":
            continue
        label = row["group"] if by_group else f"{row['group']} / {row['coverage']} / {row['name']}"
        if compact and by_group:
            group, separator, selection = row["group"].partition("-pr-")
            label = group_names.get(group, group)
            if separator:
                label += f" (pr-{selection})"
        if compact and not by_group:
            label = row.get("display_name", row["name"])
            if len(labels[label]) > 1:
                qualifiers = [row.get("definition_name", row["name"]), row["group"]]
                label += " (" + ", ".join(dict.fromkeys(value for value in qualifiers if value != label)) + ")"
            sources.setdefault(label, set()).add("Default" if row["coverage"] == "Baseline" else "PR")
        value = grouped.setdefault((label, row["target"]), {"counts": Counter(), "errors": [], "jobs": set()})
        value["counts"].update(row["counts"])
        value["errors"].extend(row["errors"])
        if row["job"]:
            value["jobs"].add(row["job"])
    title = "Test group" if by_group else "Test" if compact else "Test/configuration"
    if not grouped:
        return ["No functional test results are available."]
    columns = [title] + (["Source"] if mixed else []) + [cell(target) for target in targets]
    lines = ["| " + " | ".join(columns) + " |", "|" + "---|" * len(columns)]
    colors = {"PASS": "🟢", "FAIL": "🔴", "SKIP": "🟡", "ERROR": "🔴", "NOT RUN": "⚪"}
    for label in sorted({label for label, target in grouped}):
        values = [cell(label)]
        if mixed:
            values.append(" / ".join(sorted(sources[label])))
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
            if compact:
                status = f"{colors[status]} {status}"
                if by_group and counts["pass"] and counts["skip"] and not counts["fail"] and not value["errors"]:
                    status += f" / {colors['SKIP']} SKIP"
                links = " ".join(f"[{status}]({lava_url}/results/{job})" for job in sorted(value["jobs"]))
                values.append(links or status)
            else:
                links = " ".join(f"[{status} #{job}]({lava_url}/scheduler/job/{job})"
                                 for job in sorted(value["jobs"]))
                values.append(f"{links or status} {counts['pass']}/{counts['fail']}/{counts['skip']}")
        lines.append("| " + " | ".join(values) + " |")
    return lines


def collect_jobs(folder, manifest):
    """Reconcile owned jobs and retain data for hosted reporting."""
    if not manifest["submit_requested"]:
        print("Preparation only, no LAVA jobs or PR results comment requested.")
        return 0
    if manifest.get("lava_url") != LAVA:
        raise ValueError("Cannot recover OSS jobs through Foundries, use the original OSS workflow revision")
    rows, evidence = [], []
    cleanup_complete = True
    identity = dict(run_id=manifest["run_id"], run_attempt=str(manifest.get("run_attempt", "1")),
                    sha=manifest["sha"], request_digest=digest(manifest))
    state = execution_state(folder, manifest)
    save_json(folder / "results.json", identity | dict(rows=rows, evidence=evidence, cleanup_complete=False))
    api_error = ""
    try:
        api = lava()
    except (requests.RequestException, RuntimeError, ValueError) as error:
        api = None
        api_error = str(error)
    for entry in manifest["jobs"]:
        known = state["jobs"].get(entry["key"], {})
        terminal = known.get("state") in TERMINAL
        try:
            if known.get("state") in PRECHECK_STATES:
                rows.extend(unsubmitted_results(entry, known["error"], precheck=True,
                                                skip=known["state"] == "PrecheckSkipped"))
                continue
            if state.get("started") and not known:
                rows.extend(unsubmitted_results(entry, "Not submitted, controller stopped before this job"))
                continue
            if api is None:
                raise RuntimeError(api_error)
            matches = matching_jobs(api, entry, include_active=True, known_id=known.get("id"))
            if not matches:
                raise RuntimeError("Submission could not be reconciled, remote cleanup is unconfirmed")
            job = matches[0]
            known = {"id": job["id"], "state": job["state"]}
            terminal = job["state"] in TERMINAL
            try:
                job = cancel_owned_job(api, job, manifest["run_id"],
                                       run_attempt=manifest.get("run_attempt", "1"))
            except (requests.RequestException, RuntimeError, ValueError) as error:
                cleanup_complete = False
                rows.append(dict(target=result_target(entry), group=entry["group"], coverage="Job",
                                 name="Cleanup", counts={}, job=job["id"], errors=[str(error)]))
            terminal = job["state"] in TERMINAL
            result, raw = collect_results(api, job, entry)
            if job["state"] not in TERMINAL:
                cleanup_complete = False
            rows.extend(result)
            evidence.append({"job": job["id"], "results": raw})
        except (requests.RequestException, RuntimeError, ValueError) as error:
            if not terminal:
                cleanup_complete = False
            rows.append(dict(target=result_target(entry), group=entry["group"], coverage="Job",
                             name="Collection", counts={}, job=known.get("id"), errors=[str(error)]))
        save_json(folder / "results.json", identity | dict(rows=rows, evidence=evidence, cleanup_complete=False))
    if state.get("error"):
        rows.append(dict(target="All", group="Controller", coverage="Workflow",
                         name="Validation controller", counts={}, job=None, errors=[state["error"]]))
    save_json(folder / "results.json", identity | dict(rows=rows, evidence=evidence, cleanup_complete=cleanup_complete))
    return 0


def finish_jobs(folder, manifest, lifecycle=True):
    """Publish saved results using GitHub only, even when the runner was lost."""
    # Pre-migration requests used OSS and did not record their server.
    lava_url = manifest.get("lava_url", "https://lava-oss.qualcomm.com")
    if lava_url not in {LAVA, "https://lava-oss.qualcomm.com"}:
        raise ValueError("Unknown LAVA instance in saved results")
    folder.mkdir(parents=True, exist_ok=True)
    result_path = folder / "results.json"
    rows, evidence = [], []
    cleanup_complete = not manifest.get("jobs")
    state = execution_state(folder, manifest)
    failure_path = folder / "controller-errors.json"
    controller_errors = []
    if failure_path.is_file():
        controller_errors = json.loads(failure_path.read_text(encoding="utf-8"))
        if not isinstance(controller_errors, list) or any(
                not isinstance(error, dict) or error.get("run_id") != manifest["run_id"] or
                str(error.get("run_attempt")) != str(manifest.get("run_attempt", "1")) or
                error.get("sha") != manifest["sha"] or not isinstance(error.get("error"), str) or
                error.get("stage") not in {"begin", "start", "preflight", "plans", "prepare", "validate", "cleanup"}
                for error in controller_errors):
            raise ValueError("Controller errors do not match this workflow request")
    if result_path.is_file():
        saved = json.loads(result_path.read_text(encoding="utf-8"))
        if (saved.get("run_id") != manifest["run_id"] or saved.get("sha") != manifest["sha"] or
                saved.get("run_attempt") != str(manifest.get("run_attempt", "1")) or
                saved.get("request_digest") != digest(manifest)):
            raise ValueError("Result evidence does not match the immutable request")
        rows, evidence = saved["rows"], saved["evidence"]
        cleanup_complete = saved.get("cleanup_complete") is True
    elif state.get("started"):
        cleanup_complete = all(job.get("state") in TERMINAL | PRECHECK_STATES
                               for job in state["jobs"].values())
    observed = {(row["target"], row["group"], row["name"]) for row in rows}
    if manifest["submit_requested"]:
        for entry in manifest.get("jobs", []):
            missing = [definition for definition in entry["definitions"] if
                       (result_target(entry), entry["group"], definition["name"]) not in observed]
            if not missing:
                continue
            entry = entry | {"definitions": missing}
            known = state["jobs"].get(entry["key"], {})
            if known.get("state") in PRECHECK_STATES:
                rows.extend(unsubmitted_results(entry, known["error"], precheck=True,
                                                skip=known["state"] == "PrecheckSkipped"))
                continue
            if state.get("started") and not known:
                error = "Not submitted, controller stopped before this job"
            elif known.get("state") in TERMINAL:
                error = "Job completed, result collection unavailable"
            else:
                error = "Result collection unavailable, cleanup is unconfirmed"
            rows.extend(row | {"job": known.get("id")} for row in unsubmitted_results(entry, error))
    if state.get("error") and not any(row["coverage"] == "Workflow" and
                                      state["error"] in row["errors"] for row in rows):
        rows.append(dict(target="All", group="Controller", coverage="Workflow", name="Validation controller",
                         counts={}, job=None, errors=[state["error"]]))
    for error in controller_errors:
        rows.append(dict(target="All", group="Controller", coverage="Workflow", name=error["stage"],
                         counts={}, job=None, errors=[f"{error['stage']}: {error['error']}"]))
    outcome = os.environ.get("VALIDATION_RESULT", "")
    if outcome and outcome != "success":
        rows.append(dict(target="All", group="Controller", coverage="Workflow",
                         name="Validation controller", counts={}, job=None,
                         errors=[f"Controller outcome: {outcome}"]))
    executed = any(row["counts"].get("pass") or row["counts"].get("fail") for row in rows)
    failed = (any(row["errors"] or row["counts"].get("fail") for row in rows) or
              not executed or not cleanup_complete)
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
    if manifest.get("include_meta_qcom") is False:
        lines[2] += ", PR tests only"
    if manifest.get("build"):
        lines.append(f"[Nightly {manifest['build']['id']}]({manifest['build']['url']})")
    notices = []
    if not manifest["submit_requested"]:
        lines[3] = "Result: **Preparation only, no hardware validation requested**"
    elif not manifest.get("jobs"):
        notices.append("No hardware jobs were submitted. Validation stopped before a submission request was saved.")
    elif not cleanup_complete:
        notices.append("Cleanup is unconfirmed. Recover jobs using the LAVA PR results workflow.")
    elif not executed:
        notices.append("No tests produced an executed PASS/FAIL result.")
    if pr is None:
        notices.append("PR access is unavailable. Results are retained in this workflow for publication recovery.")
    elif pr["head"]["sha"] != manifest["sha"]:
        notices.append("The PR head has changed. These results apply only to the commit above.")
    lines += notices
    workflow_url = f"https://github.com/{REPOSITORY}/actions/runs/{os.environ.get('GITHUB_RUN_ID', manifest['run_id'])}"
    targets = sorted({result_target(entry) for entry in manifest.get("jobs", [])})
    lines += ["", f"[Workflow and artifacts]({workflow_url})", ""]
    # Keep full diagnostics in the artifact, while the summary shows the verdict.
    diagnostics = []
    for row in rows:
        reasons = result_issues(row)
        if not reasons:
            continue
        label = f"{row['target']} / {row['group']} / {row['name']}"
        if row.get("job"):
            label = f"[{label}]({lava_url}/results/{row['job']})"
        detail = ", ".join(reasons).replace("\n", " ").replace("\r", " ").replace("<", "&lt;")
        diagnostics.append(f"- {label}: {detail[:1000]}")
    if diagnostics:
        (folder / "diagnostics.md").write_text("\n".join(diagnostics) + "\n", encoding="utf-8")
    if any(row["coverage"] == "Workflow" and row["errors"] for row in rows) and not any(
            row["errors"] or row["counts"].get("fail") for row in rows if row["coverage"] != "Workflow"):
        notices.append("Workflow did not complete successfully. See the workflow artifacts.")
        lines += [notices[-1], ""]
    case_rows = []
    for row in rows:
        if not row.get("tests") or row["errors"]:
            case_rows.append(row if not row.get("tests") else row | {
                "counts": {}, "display_name": row["name"] + " (validation)"})
        for case in row.get("tests", []):
            result = case["result"].lower()
            case_rows.append(row | {"name": row["name"] + " / " + case["name"],
                                    "display_name": case["name"], "definition_name": row["name"],
                                    "counts": {result: 1},
                                    "errors": [] if result in {"pass", "fail", "skip"} else ["Unexpected result status"]})
    # A SKIP row already exposes the lack of execution, avoid a duplicate ERROR row.
    summary_rows = [row for row in case_rows if not (
        row.get("tests") and not row["counts"] and row["errors"] == ["No executed PASS/FAIL validation"])]
    functional = {"Baseline", "PR change", "PR addition"}
    test_rows = [row for row in summary_rows if row["coverage"] in functional]
    table_lines = result_matrix(test_rows, targets, by_group=False, lava_url=lava_url, compact=True) + [""]
    # One testcase matrix, followed by concise reasons rather than duplicate
    # group/setup tables. Keep every detailed board rejection in the artifacts.
    prechecks = {}
    for row in rows:
        if row.get("precheck") and row["coverage"] in functional:
            key = (row["target"], row["device_type"], row["reason"])
            prechecks.setdefault(key, set()).add(row.get("display_name", row["name"]))
    if prechecks:
        table_lines += ["Pre-check details:", ""]
        for (target, device_type, reason), tests in prechecks.items():
            detail = f"{target} ({device_type}), {', '.join(sorted(tests))}: {reason}"
            table_lines.append("- " + detail.replace("\n", " ").replace("\r", " ").replace("<", "&lt;"))
        table_lines.append("")
    status_errors = sorted({error for row in rows if row["coverage"] in {"Job", "Workflow", "Setup"}
                            for error in row["errors"]})
    if status_errors:
        table_lines += ["Setup or workflow errors are recorded in diagnostics.md in the workflow artifacts.", ""]
    (folder / "test-results.md").write_text("\n".join(table_lines) + "\n", encoding="utf-8")
    pr_lines = [marker, f"<!-- testkit-lava-attempt:{attempt} -->",
                f"## Test run [workflow]({workflow_url})",
                f"## Test jobs for commit `{manifest['sha']}`", ""]
    if failed or not manifest["submit_requested"]:
        pr_lines += [lines[3], ""]
    if manifest.get("include_meta_qcom") is False:
        pr_lines += ["PR tests only", ""]
    build_label = {"qcom-distro": "meta-qcom-main", "qcom-distro_linux-qcom-6.18": "meta-qcom-lts-6.18"}.get(
        manifest.get("distro"), manifest.get("distro") or "Validation")
    image_type = manifest.get("image_type")
    variants = ("base", "overlay") if image_type == "both" else (
        "overlay" if image_type in {"proprietary", "overlay"} else "base",)
    definitions = {(result_target(entry), entry["group"], definition["name"]):
                   (definition.get("path", definition["name"]), digest(definition.get("params", {})))
                   for entry in manifest.get("jobs", []) for definition in entry.get("definitions", [])}
    for variant in variants:
        variant_targets = {result_target(entry) for entry in manifest.get("jobs", [])
                           if len(variants) == 1 or entry.get("image_variant") == variant}
        counts = Counter()
        unique_tests = set()
        for row in rows:
            if (row["coverage"] in {"Baseline", "PR change", "PR addition"} and
                    row["target"] in variant_targets):
                counts.update(row["counts"])
                definition = definitions.get((row["target"], row["group"], row["name"]),
                                             (row["group"], row["name"]))
                unique_tests.update((*definition, case["name"]) for case in row.get("tests", []))
        label = f"{build_label} ({variant})" if image_type else build_label
        total = counts["pass"] + counts["fail"] + counts["skip"]
        precheck_skips = sum(row["counts"].get("skip", 0) for row in rows
                             if row.get("precheck") and row["coverage"] in functional and
                             row["target"] in variant_targets)
        test_label = "Unique PR tests" if manifest.get("include_meta_qcom") is False else "Unique functional tests"
        count_lines = [f"### {label}", "",
                       f"{test_label}: {len(unique_tests)} | Targets: {len(variant_targets)} | Testcase results: {total}",
                       "",
                       f"Pass: {counts['pass']} | Fail: {counts['fail']} | Skip: {counts['skip']}", ""]
        if precheck_skips:
            count_lines += [f"Includes {precheck_skips} tests skipped before submission due to missing requirements.", ""]
        lines += count_lines
        pr_lines += count_lines
    pr_lines += notices + [""]
    # Keep the same detailed matrices in the workflow and PR comment.
    # Bound both GitHub summaries, retaining every row in the artifact.
    for summary in (lines, pr_lines):
        budget = 60000 - len("\n".join(summary).encode("utf-8"))
        size = 0
        displayed = 0
        for line in table_lines:
            size += len(line.encode("utf-8")) + 1
            if size > budget - 200:
                break
            summary.append(line)
            displayed += 1
        if displayed < len(table_lines):
            summary += ["", "Summary shortened. Download test-results.md from the results artifact for all tests.", ""]
    body = "\n".join(lines).rstrip()
    (folder / "summary.md").write_text(body + "\n", encoding="utf-8")
    pr_body = "\n".join(pr_lines).rstrip()
    (folder / "pr-summary.md").write_text(pr_body + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write(body)
    if not manifest["submit_requested"]:
        return int(outcome not in {"", "success"})
    if publication_error is not None:
        if lifecycle:
            update_check(gh, manifest, "completed", "PR access failed. Results remain in the workflow artifacts.",
                         "failure")
        raise publication_error
    try:
        comments = list(gh.pages(f"/repos/{REPOSITORY}/issues/{manifest['pr']}/comments", per_page=100))
    except (requests.RequestException, RuntimeError, ValueError):
        if lifecycle:
            update_check(gh, manifest, "completed", "PR comments could not be read. Results remain in the workflow artifacts.",
                         "failure")
        raise
    previous = next((comment for comment in comments if marker in comment.get("body", "")
                     and comment["user"]["type"] == "Bot"), None)
    if previous:
        prior_attempt = re.search(r"<!-- testkit-lava-attempt:([1-9][0-9]*) -->", previous["body"])
        if prior_attempt and int(prior_attempt[1]) > int(attempt):
            print("Preserving the PR summary from a newer attempt, older results remain in the artifact")
            return int(failed)
    try:
        if previous:
            gh.request("PATCH", f"/repos/{REPOSITORY}/issues/comments/{previous['id']}", json={"body": pr_body})
        else:
            gh.request("POST", f"/repos/{REPOSITORY}/issues/{manifest['pr']}/comments", json={"body": pr_body})
    except (requests.RequestException, RuntimeError):
        if lifecycle:
            update_check(gh, manifest, "completed", "PR comment publication failed. Results remain in the workflow artifacts.",
                         "failure")
        raise
    conclusion = "cancelled" if outcome == "cancelled" else "timed_out" if outcome == "timed_out" else (
        "failure" if failed or not cleanup_complete else "success")
    if lifecycle:
        update_check(gh, manifest, "completed", body, conclusion)
    print("LAVA results published. Validation verdict: " + ("Needs attention" if failed else "PASS"),
          flush=True)
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["begin", "start", "preflight", "plans", "prepare", "validate", "run", "resolve",
                                            "collect", "publish", "finish", "cleanup"])
    parser.add_argument("--output", type=Path, default=Path("lava-output"))
    args = parser.parse_args()
    try:
        return execute(args)
    except Exception as failure:
        # Unexpected parsing/template errors need the same early-failure evidence.
        # Do not include tracebacks or raw HTTP responses in the published artifact.
        try:
            message = record_failure(args.output, args.command, failure)
        except (OSError, ValueError, TypeError):
            message = f"{args.command} failed ({type(failure).__name__}), controller evidence could not be saved"
        print(f"Validation {args.command} failed: {message}", file=sys.stderr)
        return 1


def execute(args):
    """Run one controller stage, preserving failures at the CLI boundary."""
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
    if args.command == "plans":
        from lava_pr_prepare import resolve_plans
        resolve_plans(args.output)
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
    if args.command == "validate":
        checks = validate_jobs(lava(), args.output, manifest)
        return int(any(item["error"] and not item["skip"] for item in checks))
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
    sys.exit(main())
