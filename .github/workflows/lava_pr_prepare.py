# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Resolve immutable inputs and reuse meta-qcom's templates without executing PR code."""

from collections import defaultdict
from copy import deepcopy
import base64
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import tarfile
import time
from urllib.parse import quote, urljoin, urlsplit
import zipfile

import requests
import yaml

ROOT = Path(__file__).resolve().parents[2]
IMAGE_DISTROS = {"meta-qcom-main": "qcom-distro", "meta-qcom-lts-6.18": "qcom-distro_linux-qcom-6.18",
                 "qcom-distro": "qcom-distro", "qcom-distro_linux-qcom-6.18": "qcom-distro_linux-qcom-6.18"}
# Reuse the trusted repository's inventory parser, independent of the launch directory.
sys.path.insert(1, str(ROOT / "scripts"))

import generate_test_inventory_html as inventory
from lava_pr_validation import API, GITHUB, LAVA, REPOSITORY, artifact_token_name, digest, github, lava, previous_request, save_json


def git(directory, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(directory), *arguments], timeout=180,
        env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1"))


def snapshot(folder, pr, requested):
    """Use git objects as data, never checkout hooks, submodules or PR executables."""
    repository = pr["head"]["repo"]["full_name"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid PR repository")
    sha = requested or pr["head"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("revision must be a full lowercase commit SHA")
    bare = folder / "source.git"
    bare.mkdir()
    git(bare, "init", "--bare")
    git(bare, "fetch", "--no-tags", f"https://github.com/{REPOSITORY}.git", pr["base"]["sha"])
    git(bare, "fetch", "--no-tags", f"https://github.com/{repository}.git", pr["head"]["sha"])
    git(bare, "merge-base", "--is-ancestor", sha, pr["head"]["sha"])
    base = git(bare, "merge-base", pr["base"]["sha"], sha).decode().strip()
    fields = git(bare, "diff", "--name-status", "-z", "--find-renames", base, sha).decode().split("\0")
    changed = []
    while fields and fields[0]:
        status = fields.pop(0)
        path = fields.pop(0)
        changed.append({"status": status, "path": path})
        if status.startswith(("R", "C")):
            changed.append({"status": status, "path": fields.pop(0)})
    destination = folder / "source"
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(git(bare, "archive", sha))) as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Unsafe path in PR archive")
            # No symlink traversal, executable installation or git filters.
            if not member.isfile():
                continue
            if member.size > 16 * 1024 * 1024:
                raise ValueError(f"Oversized PR file: {path}")
            target = destination.joinpath(*path.parts)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError("PR archive path escaped the snapshot directory")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.extractfile(member).read())
    return destination, sha, base, changed, repository


def check_download(url, access=None):
    """Check artifact access before allocating hardware, without retaining secrets."""
    parsed = urlsplit(url)
    public = (parsed.hostname == "github.com" and
              parsed.path.startswith(f"/{REPOSITORY}/releases/download/"))
    if (parsed.scheme != "https" or parsed.username or parsed.password or
            parsed.port not in {None, 443} or parsed.fragment or
            (parsed.hostname != "qli-prod-artifacts.qualcomm.com" and not public)):
        raise ValueError("Artifact URL is outside the configured HTTPS artifact service")
    access = {} if access is None else access
    headers = {}
    if not public:
        if "qli_token" not in access:
            token = os.environ.get("QLI_S3_TOKEN") or os.environ.get("QLI_ARTIFACT_TOKEN", "")
            if not token:
                # This endpoint returns only the authenticated user's token.
                # Use it in memory for preflight, never in a manifest or job YAML.
                record = lava().get(f"/api/v0.2/remote-artifact-tokens/{artifact_token_name()}/")
                token = record.get("token")
            access["qli_token"] = token
        if not isinstance(access["qli_token"], str) or not access["qli_token"] or any(
                char in access["qli_token"] for char in "\r\n"):
            raise ValueError("QLI artifact authentication is unavailable")
        headers["QLIAuthorization"] = access["qli_token"]
    origin = parsed.hostname
    # The QLI gateway exposes both the object URL and its /download/ route.
    object_path = parsed.path[9:] if parsed.path.startswith("/download/") else parsed.path
    bucket, separator, object_key = object_path.lstrip("/").partition("/")
    cdn_host = None
    visited = set()
    deadline = time.monotonic() + 120
    for redirect in range(5):
        if url in visited:
            raise ValueError(f"Artifact redirect loop: {parsed.path}")
        visited.add(url)
        try:
            for attempt in range(3):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError(f"Artifact access deadline expired: {parsed.path}")
                try:
                    response = requests.get(url, headers=headers, stream=True, allow_redirects=False,
                                            timeout=(min(15, remaining), min(45, remaining)))
                except requests.RequestException:
                    if attempt == 2:
                        raise
                else:
                    if response.status_code not in {429, 500, 502, 503, 504} or attempt == 2:
                        break
                    response.close()
                time.sleep(min(2 ** attempt, max(0, deadline - time.monotonic())))
            with response:
                if response.status_code in {301, 302, 303, 307, 308}:
                    location = response.headers.get("Location", "")
                    if not location or any(ord(char) < 33 for char in location):
                        raise ValueError(f"Artifact redirect has no valid Location: {parsed.path}")
                    destination_url = urljoin(url, location)
                    destination = urlsplit(destination_url)
                    if (destination.scheme != "https" or destination.username or destination.password or
                            destination.port not in {None, 443} or destination.fragment):
                        raise ValueError(f"Artifact redirect requires a plain HTTPS destination: {parsed.path}")
                    if public:
                        if destination.hostname not in {
                                "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}:
                            raise ValueError("Audio release redirect left the public GitHub artifact hosts")
                    else:
                        # QLI can serve an object through S3 or CloudFront. Trust
                        # the gateway's CDN choice, never a host chosen by a CDN.
                        endpoint = r"s3(?:[.-](?:dualstack\.)?[a-z0-9-]+)?\.amazonaws\.com"
                        virtual = re.fullmatch(re.escape(bucket) + r"\." + endpoint, destination.hostname or "")
                        path_style = re.fullmatch(endpoint, destination.hostname or "")
                        cloudfront = re.fullmatch(r"[a-z0-9-]+\.cloudfront\.net", destination.hostname or "")
                        same_origin = (destination.hostname == origin and
                                       destination.path in {object_path, "/download" + object_path})
                        same_s3 = ((virtual and destination.path == "/" + object_key) or
                                   (path_style and destination.path == object_path))
                        same_cdn = (cloudfront and destination.path in {object_path, "/" + object_key} and
                                    (urlsplit(url).hostname == origin or destination.hostname == cdn_host))
                        if not separator or not (same_origin or same_s3 or same_cdn):
                            raise ValueError(f"Artifact redirect left the configured object: {parsed.path}, "
                                             f"destination host {destination.hostname or 'missing'}")
                        if same_cdn:
                            cdn_host = destination.hostname
                        if destination.hostname != origin:
                            # The redirected URL carries any required signature.
                            # Never forward QLI credentials outside its gateway.
                            headers = {}
                    # Once credentials are removed, a later redirect cannot add them back.
                    print(f"Artifact redirect HTTP {response.status_code}: {urlsplit(url).hostname} -> {destination.hostname}")
                    url = destination_url
                    continue
                if response.status_code not in (200, 206):
                    if response.status_code in (401, 403):
                        raise RuntimeError(f"Artifact access denied: {parsed.path}, HTTP {response.status_code}")
                    raise ValueError(f"Required artifact unavailable: {parsed.path}, HTTP {response.status_code}")
                if "text/html" in response.headers.get("Content-Type", "").lower():
                    raise ValueError(f"Artifact service returned an HTML page: {parsed.path}")
                if not next(response.iter_content(chunk_size=1), b""):
                    raise ValueError(f"Artifact service returned an empty file: {parsed.path}")
                print(f"Artifact access verified: {parsed.path}")
                return
        except requests.RequestException:
            raise RuntimeError(f"Artifact access check failed for {parsed.path}, connection or TLS error") from None
    raise ValueError(f"Too many redirects checking artifact: {parsed.path}")


def select_targets(gh, config, distro, requested):
    """Resolve machines or configured device types against the selected pre-merge list."""
    repository = config["artifact_repository"]
    revision = gh.get(f"/repos/{repository}/commits/{config['target_ref']}")["sha"]
    response = gh.get(f"/repos/{repository}/contents/{config['target_workflow']}", ref=revision)
    document = yaml.safe_load(base64.b64decode(response["content"]).decode("utf-8"))
    matches = []
    for name, job in document["jobs"].items():
        settings = job.get("with", {})
        profile = settings.get("distro_name", "") + settings.get("distro_suffix", "")
        if profile == distro and settings.get("devices_premerge"):
            matches.append((name, settings))
    if len(matches) != 1:
        raise ValueError(f"Expected one enabled meta-qcom pre-merge profile for {distro}")
    name, settings = matches[0]
    targets = [target.strip() for target in settings["devices_premerge"].split(",")]
    if (len(targets) != len(set(targets)) or
            any(not re.fullmatch(r"[a-z0-9][a-z0-9-]*", target) for target in targets)):
        raise ValueError("meta-qcom devices_premerge must contain unique literal machine names")
    excluded = [target for target in targets if target in config.get("excluded_targets", [])]
    eligible = [target for target in targets if target not in excluded]
    selected = []
    invalid = []
    if requested.strip() == "meta-qcom":
        selected = eligible
    else:
        supplied = [target.strip() for target in requested.split(",") if target.strip()]
        for target in dict.fromkeys(supplied):
            if target not in targets:
                machines = [machine for machine in targets if config["targets"].get(machine) == target]
                if len(machines) > 1:
                    raise ValueError(f"Foundries device type {target} maps to multiple machines: "
                                     f"{', '.join(machines)}. Select an explicit machine name.")
                if not machines:
                    invalid.append(target)
                    continue
                print(f"Resolved Foundries device type {target} to meta-qcom machine {machines[0]}")
                target = machines[0]
            if target not in selected:
                selected.append(target)
    if set(selected) & set(excluded):
        raise ValueError("Targets excluded from Testkit PR validation: " +
                         ", ".join(target for target in selected if target in excluded))
    if invalid or not selected:
        reason = f"Targets not enabled for {name}: {', '.join(invalid)}." if invalid else "No targets selected."
        raise ValueError(f"{reason} Use meta-qcom or choose machine names from: {', '.join(eligible)}. "
                         "Configured Foundries device types are also accepted.")
    plans_ref = settings.get("lava_test_plans_ref")
    # Follow the selected profile's declared pin, including the prepare-env
    # output used by meta-qcom. Never evaluate arbitrary workflow expressions.
    for lookup in range(4):
        if not isinstance(plans_ref, str):
            break
        env_ref = re.fullmatch(r"\$\{\{\s*env\.([A-Za-z0-9_-]+)\s*\}\}", plans_ref)
        output_ref = re.fullmatch(r"\$\{\{\s*needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}", plans_ref)
        if env_ref:
            plans_ref = document.get("env", {}).get(env_ref[1])
        elif output_ref:
            plans_ref = document["jobs"].get(output_ref[1], {}).get("outputs", {}).get(output_ref[2])
        else:
            break
    if not isinstance(plans_ref, str) or not re.fullmatch(r"[A-Za-z0-9_./-]+", plans_ref):
        raise ValueError(f"meta-qcom {name} must resolve lava_test_plans_ref to a literal commit, tag or branch")
    plans_revision = gh.get("/repos/qualcomm-linux/lava-test-plans/commits/" + quote(plans_ref, safe=""))["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", plans_revision):
        raise ValueError("meta-qcom lava-test-plans reference did not resolve to a commit")
    return dict(repository=repository, revision=revision, workflow=config["target_workflow"],
                plans_ref=plans_ref, plans_revision=plans_revision,
                job=name, kernel=settings.get("kernel"), targets=targets, selected=selected,
                excluded=excluded)


def resolve_plans(folder):
    """Freeze meta-qcom's target list and template pin before installing its renderer."""
    config = json.loads((ROOT / ".github/ci/lava-pr-validation.json").read_text(encoding="utf-8"))
    previous = previous_request(github(), os.environ["VALIDATION_RUN_ID"], os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    if previous:
        target_matrix = dict(previous["target_matrix"], plans_revision=previous["plans_revision"])
    else:
        distro_choice = os.environ.get("IMAGE_DISTRO", "meta-qcom-main")
        if distro_choice not in IMAGE_DISTROS:
            raise ValueError("Choose meta-qcom-main or meta-qcom-lts-6.18")
        distro = IMAGE_DISTROS[distro_choice]
        producer = API(GITHUB, os.environ.get("META_QCOM_READ_TOKEN") or os.environ.get("GH_TOKEN", ""))
        target_matrix = select_targets(producer, config, distro, os.environ.get("TARGETS", "meta-qcom"))
    revision = target_matrix["plans_revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid saved lava-test-plans commit")
    save_json(folder / "target-matrix.json", target_matrix)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"plans_revision={revision}\n")
    print(f"meta-qcom {target_matrix['revision']} selects lava-test-plans {revision}")


def validate_target_templates(plans, targets, config):
    """Reject missing lab mappings/templates before image or hardware operations."""
    gaps = []
    for target in targets:
        if not config["targets"].get(target):
            gaps.append(f"{target}: Foundries device mapping is not confirmed")
        relative = Path("projects/meta-qcom/devices") / target
        if not (plans / "lava_test_plans" / relative).is_file():
            gaps.append(f"{target}: device template is absent from the pinned lava-test-plans")
    if gaps:
        raise ValueError("Pre-merge targets cannot be silently omitted. " + ", ".join(gaps))


def select_build(gh, config, targets, distro, override, image_name, access=None):
    repository = config["artifact_repository"]
    endpoint = f"/repos/{repository}/actions"
    if override:
        runs = [gh.get(f"{endpoint}/runs/{int(override)}")]
    else:
        runs = []
        for workflow in config["artifact_workflows"]:
            runs.extend(gh.get(f"{endpoint}/workflows/{workflow}/runs",
                               branch="master", status="success", per_page=30)["workflow_runs"])
        runs.sort(key=lambda run: run["created_at"], reverse=True)
    reasons = []
    for run in runs:
        if (run["status"] != "completed" or run["conclusion"] != "success" or
                run["head_branch"] != "master" or
                Path(run["path"]).name not in config["artifact_workflows"]):
            continue
        artifacts = list(gh.pages(f"{endpoint}/runs/{run['id']}/artifacts", "artifacts", per_page=100))
        names = {artifact["name"]: artifact for artifact in artifacts if not artifact["expired"]}
        prefixes = set()
        urls = {}
        try:
            for target in targets:
                name = f"build-url_{target}_{distro}"
                if name not in names:
                    raise ValueError(f"Missing {name}")
                artifact = names[name]
                if artifact["size_in_bytes"] > 1024 * 1024:
                    raise ValueError("Oversized build URL artifact")
                response = gh.request("GET", f"{endpoint}/artifacts/{artifact['id']}/zip")
                with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
                    if name not in archive.namelist() or archive.getinfo(name).file_size > 4096:
                        raise ValueError(f"Invalid build URL artifact: {name}")
                    prefix = archive.read(name).decode().strip().rstrip("/") + "/"
                pattern = re.escape(config["artifact_prefix"]) + str(run["id"]) + r"-[1-9][0-9]*/"
                if not re.fullmatch(pattern, prefix):
                    raise ValueError("Build manifest does not belong to the selected producer run")
                prefixes.add(prefix)
                urls[target] = prefix + f"{distro}/{target}/{image_name}-{target}.rootfs.qcomflash.tar.gz"
            if len(prefixes) != 1:
                raise ValueError("Targets refer to different producer attempts")
        except (ValueError, zipfile.BadZipFile) as error:
            reasons.append(f"{run['id']}: {error}")
            continue
        # Missing published images are an error, not a silent downgrade to an older build.
        for url in urls.values():
            check_download(url, access)
        return dict(id=run["id"], url=run["html_url"], sha=run["head_sha"],
                    prefix=prefixes.pop(), images=urls)
    raise ValueError("No recent successful published build covers all targets, supply an explicit run ID. " +
                     ", ".join(reasons[:6]))


def catalogue(source):
    """Reuse the inventory's suite ownership and index actual YAML invocations."""
    inventory.REPO_ROOT = source
    inventory.BASE = source / "Runner/suites"
    owners = sorted([row["Suite Path"] for row in inventory.discover_tests()], key=len, reverse=True)
    definitions, by_suite = {}, defaultdict(list)
    for path in sorted(path for path in (source / "Runner/suites").rglob("*")
                       if path.suffix in {".yaml", ".yml"}):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict) or not document.get("metadata"):
            continue
        steps = document.get("run", {}).get("steps")
        if not isinstance(steps, list) or not steps or not all(isinstance(step, str) for step in steps):
            continue
        relative = path.relative_to(source).as_posix()
        # Suite-local definitions belong to their runner directory. Do not
        # infer ownership from shell spelling, parameters or result publishers.
        local = owning_suite(relative, owners)
        definitions[relative] = document
        if local:
            by_suite[local].append(relative)
    return owners, definitions, by_suite


def owning_suite(path, owners):
    return next((owner for owner in owners if path.startswith(owner + "/")), None)


def named_suites(test_names, by_suite):
    """Resolve literal suite/YAML names in the PR snapshot without executing it."""
    if not isinstance(test_names, str):
        raise ValueError("test_names must be a comma-separated string")
    selected = defaultdict(set)
    if not test_names.strip():
        return selected
    names = [name.strip() for name in re.split(r"[,\n]", test_names) if name.strip()]
    if not names:
        raise ValueError("test_names must contain at least one suite or YAML name")
    aliases = defaultdict(set)
    for suite, paths in by_suite.items():
        suite_name = PurePosixPath(suite).name
        defaults = [path for path in paths if PurePosixPath(path).stem == suite_name]
        # Without a default, accept a sole YAML or report all choices as ambiguous.
        for path in defaults or paths:
            for alias in (suite, suite_name):
                aliases[alias.casefold()].add((suite, path))
        for path in paths:
            for alias in (path, PurePosixPath(path).name, PurePosixPath(path).stem):
                aliases[alias.casefold()].add((suite, path))
    for name in dict.fromkeys(names):
        matches = aliases.get(name.casefold(), set())
        if not matches:
            raise ValueError(f"Unknown test name: {name}. Use a suite name or YAML filename from the PR revision.")
        if len(matches) != 1:
            candidates = ", ".join(sorted(path for suite, path in matches))
            raise ValueError(f"Ambiguous test name: {name}. Select a YAML path: {candidates}")
        suite, path = next(iter(matches))
        selected[suite].add(path)
    return selected


def affected_suites(changes, owners, config):
    """Select direct suite changes and explicitly configured file associations."""
    reasons = defaultdict(set)
    for change in changes:
        changed = change["path"]
        if changed.lower().endswith((".md", ".rst")):
            continue
        owner = owning_suite(changed, owners)
        if owner:
            reasons[owner].add(changed)
            continue
        # Sourcing a shared library does not establish which of its functions
        # a suite exercises. Regression coverage is opted into through the
        # meta-qcom checkbox, explicit selections or trusted associations.
        pending, visited = [changed], set()
        while pending:
            dependency = pending.pop()
            if dependency in visited:
                continue
            visited.add(dependency)
            for consumer in config["associations"].get(dependency, []):
                owner = consumer if consumer in owners else owning_suite(consumer, owners)
                if owner:
                    reasons[owner].add(changed)
                elif consumer in config["associations"]:
                    pending.append(consumer)
                else:
                    raise ValueError(f"Configured association for {changed} has no suite: {consumer}")
        if changed in config["associations"] and not any(changed in paths for paths in reasons.values()):
            raise ValueError(f"Configured associations for {changed} select no suite")
    return reasons


def render_baseline(plans, target, context, config):
    # Resolution runs before the selected plan's Python dependencies are installed.
    from jinja2 import Environment, FileSystemLoader, StrictUndefined
    from lava_test_plans.utils import compression

    templates = plans / "lava_test_plans"
    plan_groups = {path.stem for path in (templates / "testplans/meta-qcom/qcom-distro/pre-merge").glob("*.yaml")}
    if plan_groups != set(config["groups"]):
        raise ValueError("meta-qcom pre-merge groups changed, review the controller's supported groups. "
                         f"Plan: {', '.join(sorted(plan_groups)) or 'none'}. "
                         f"Controller: {', '.join(config['groups'])}")
    # Pinned LAVA templates produce YAML and shell, HTML escaping corrupts their values.
    environment = Environment(  # nosemgrep: python.flask.security.xss.audit.direct-use-of-jinja2.direct-use-of-jinja2
        loader=FileSystemLoader([
            str(templates), str(templates / "testplans"),
            str(templates / "testcases"), str(templates / "devices")]),
        undefined=StrictUndefined,
        autoescape=False,
        extensions=["jinja2.ext.loopcontrols"])
    environment.globals["compression"] = compression
    context["device_type"] = f"projects/meta-qcom/devices/{target}"
    device = environment.get_template(context["device_type"]).make_module(context)
    excluded_groups = getattr(device, "EXCLUDED_TESTPLANS", [])
    context["EXCLUDED_TESTS"] = getattr(device, "EXCLUDED_TESTS", [])
    jobs, excluded = {}, []
    context["excluded_definitions"] = []
    for group in config["groups"]:
        template = environment.get_template(f"testcases/{group}.yaml")
        namespace = template.make_module(context)
        if not isinstance(getattr(namespace, "all_tests", None), list):
            raise ValueError(f"meta-qcom {group} must declare its test definitions in all_tests")
        context["excluded_definitions"].extend((group, test) for test in namespace.all_tests
            if group + ".yaml" in excluded_groups or test["name"] in context["EXCLUDED_TESTS"] or not test.get("include", True))
        if group + ".yaml" in excluded_groups:
            excluded.append(f"{target}/{group}")
            continue
        excluded.extend(f"{target}/{group}/{test['name']}" for test in namespace.all_tests
                        if test["name"] in context["EXCLUDED_TESTS"] or not test.get("include", True))
        if not any(test["name"] not in context["EXCLUDED_TESTS"] and test.get("include", True)
                   for test in namespace.all_tests):
            excluded.append(f"{target}/{group} (no eligible definitions)")
            continue
        # This output is parsed as a LAVA job, never served as HTML.
        # nosemgrep: python.flask.security.xss.audit.direct-use-of-jinja2.direct-use-of-jinja2
        job = yaml.safe_load(template.render(context))
        if not any(action.get("test", {}).get("definitions") for action in job["actions"]):
            raise ValueError(f"Mandatory group {group} rendered no tests")
        jobs[group] = job
    return jobs, excluded


def entries(job):
    return [definition for action in job["actions"]
            for definition in action.get("test", {}).get("definitions", [])]


def effective_params(definition, documents):
    defaults = documents[definition["path"]].get("params") or {}
    return {key: "" if value is None else str(value)
            for key, value in (defaults | definition.get("params", {})).items()}


def invokes_helper(document, helper):
    """Recognize direct run.steps calls, excluding comments and printed filenames."""
    for step in document["run"]["steps"]:
        tokens = shlex.shlex(step, posix=True, punctuation_chars=";&|")
        tokens.whitespace_split = True
        command = True
        for token in tokens:
            if token and all(character in ";&|" for character in token):
                command = True
            elif command:
                if token in {"if", "then", "else", "do", "!", "command", "exec", "sh", "bash"}:
                    continue
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
                    continue
                if PurePosixPath(token).name == PurePosixPath(helper).name:
                    return True
                command = False
    return False


def group_for(suite):
    groups = {"Connectivity/BT/": "pre-merge-bt", "Connectivity/Bluetooth/": "pre-merge-bt",
              "Multimedia/Audio/": "pre-merge-audio", "Multimedia/Graphics/": "pre-merge-display-gfx",
              "Multimedia/Display/": "pre-merge-display-gfx",
              "Multimedia/Video/": "pre-merge-gstr-video", "Multimedia/Camera/": "pre-merge-camera"}
    return next((group for prefix, group in groups.items() if prefix in suite), "pre-merge-basic")


def append_tests(jobs, affected, documents, by_suite, selections, config, source_url, source=None,
                 include_meta_qcom=True, excluded_definitions=()):
    manifest = []
    selected = set()
    baseline = [(group, definition) for group, job in jobs.items() for definition in entries(job)]
    owners = sorted(set(by_suite) | set(affected), key=len, reverse=True)
    for suite, reasons in sorted(affected.items()):
        candidates = by_suite.get(suite, [])
        explicit = selections.get(suite)
        if suite in selections and (not isinstance(explicit, (dict, list)) or not explicit):
            raise ValueError(f"Selection for {suite} must be an object or a nonempty list of objects")
        runtime_changed = any(reason not in candidates for reason in reasons)
        changed_yamls = [path for path in candidates if path in reasons]
        covered = [(group, old) for group, old in baseline if owning_suite(old["path"], owners) == suite]
        for group, old in covered:
            if old["path"] not in documents:
                raise ValueError(f"Missing selected baseline YAML in PR: {old['path']}")
        # A runner or associated asset change keeps every eligible configuration
        # of the selected suite, including existing parameter variants.
        if not explicit and covered and runtime_changed:
            for group, old in covered:
                selected.add(id(old))
                manifest.append(dict(suite=suite, path=old["path"], group=group,
                                     params=old.get("params", {}), execution_group=group,
                                     definitions=[old["name"]], reasons=sorted(reasons),
                                     disposition="covered by baseline" if include_meta_qcom else "selected from baseline"))
            changed_yamls = [path for path in changed_yamls if not any(old["path"] == path for group, old in covered)]
            if not changed_yamls:
                continue
        if not explicit and "/Camera_NHX" in suite:
            raise ValueError("Camera_NHX needs an explicit compatible selection and image")
        if explicit:
            choices = explicit if isinstance(explicit, list) else [explicit]
        else:
            default = f"{suite}/{Path(suite).name}.yaml"
            paths = changed_yamls or ([default] if default in candidates else candidates)
            if not paths or (not changed_yamls and len(paths) != 1):
                raise ValueError(f"Select YAML and group for {suite}, candidates: {', '.join(candidates) or 'none'}")
            choices = []
            for path in paths:
                instances = [(group, old) for group, old in covered if old["path"] == path]
                if not instances:
                    instances = [(group, old) for group, old in excluded_definitions if old["path"] == path]
                if instances:
                    choices.extend(dict(path=path, group=group, params=old.get("params", {}))
                                   for group, old in instances)
                else:
                    choices.append({"path": path, "group": group_for(suite)})
        for choice in choices:
            if not isinstance(choice, dict) or not all(isinstance(choice.get(key), str) for key in ("path", "group")):
                raise ValueError(f"Selection for {suite} must specify path and group")
            path = choice["path"]
            if path not in candidates:
                raise ValueError(f"{path} does not invoke {suite}")
            group = choice["group"]
            if group not in config["groups"]:
                raise ValueError(f"Unknown execution group: {group}")
            params = choice.get("params", {})
            if not isinstance(params, dict) or set(params) - set(documents[path].get("params") or {}):
                raise ValueError(f"Unknown YAML parameters for {path}")
            if any(isinstance(value, (dict, list)) for value in params.values()):
                raise ValueError(f"YAML parameters must be scalar values for {path}")
            if "fresh_boot" in choice and not isinstance(choice["fresh_boot"], bool):
                raise ValueError("fresh_boot must be a JSON boolean")
            if "expected" in choice and (not isinstance(choice["expected"], list) or
                                         not all(isinstance(name, str) and name for name in choice["expected"])):
                raise ValueError("expected must be a list of result names")
            tags = choice.get("tags", [])
            if (not isinstance(tags, list) or
                    not all(isinstance(tag, str) and tag.strip() == tag and tag for tag in tags)):
                raise ValueError("tags must be a list of nonempty LAVA tag names")
            definition = dict(path=path, params=params)
            # The same YAML may be eligible in one group/configuration and
            # excluded in another. Do not turn an exclusion into a new addition.
            excluded = any(old_group == group and old["path"] == path and
                           effective_params(old, documents) == effective_params(definition, documents)
                           for old_group, old in excluded_definitions)
            if group not in jobs or excluded:
                manifest.append(dict(suite=suite, path=path, group=group, reasons=sorted(reasons),
                                     disposition="excluded by target template"))
                continue
            required_group = group_for(suite)
            required_tags = set(jobs.get(required_group, {}).get("tags", []))
            if required_tags - (set(jobs[group].get("tags", [])) | set(tags)):
                raise ValueError(f"{path} requires the device tags from {required_group}: "
                                 f"{', '.join(sorted(required_tags))}. Select that group or retain its tags.")
            execution_group = group
            # Do not collapse baseline instances, only avoid equivalent additions.
            equivalent = [old for old_group, old in baseline if old["path"] == path and old_group == group and
                          effective_params(old, documents) == effective_params(definition, documents)]
            if equivalent and not choice.get("fresh_boot", False):
                selected.update(id(old) for old in equivalent)
                selected_names = [old["name"] for old in equivalent]
                disposition = "covered by baseline" if include_meta_qcom else "selected from baseline"
            else:
                name = "pr-" + Path(path).stem + "-" + digest(choice)[:8]
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
                    raise ValueError("Definition filename must form a valid LAVA name")
                definition.update(name=name, repository=source_url,
                                  **{"from": "url", "strip-components": 1})
                selected_names = [name]
                if choice.get("expected"):
                    definition["expected"] = choice["expected"]
                minutes = int(choice.get("minutes", config["addition_minutes"]))
                if not 1 <= minutes <= 120:
                    raise ValueError("Addition timeout must be 1..120 minutes")
                fresh = choice.get("fresh_boot", False)
                steps = " ".join(documents[path]["run"]["steps"]).lower()
                risky = any(word in (path + " " + steps + json.dumps(effective_params(definition, documents))).lower()
                            for word in ("crash", "inject", "unbind", "reboot"))
                if risky and source is not None and path in config.get("passive_definitions", []):
                    # Only the reviewed definition and runner from the trusted
                    # controller may bypass a name-based false alarm. A PR edit
                    # or parameter override still needs explicit isolation.
                    trusted_path = ROOT / path
                    runner = Path(suite) / "run.sh"
                    if trusted_path.is_file() and (ROOT / runner).is_file() and (source / runner).is_file():
                        trusted = yaml.safe_load(trusted_path.read_text(encoding="utf-8"))
                        if (documents[path] == trusted and
                                (source / runner).read_bytes() == (ROOT / runner).read_bytes() and
                                effective_params(definition, documents) ==
                                effective_params({"path": path}, {path: trusted})):
                            risky = False
                if risky and (not explicit or not fresh):
                    raise ValueError(f"{path} needs an explicit fresh_boot selection")
                destination = jobs[group]
                if fresh:
                    unique = group + "-" + name
                    execution_group = unique
                    if unique in jobs:
                        raise ValueError(f"Duplicate fresh-boot selection: {path}")
                    destination = deepcopy(jobs[group])
                    destination["actions"] = [action for action in destination["actions"] if "test" not in action]
                    # Preserve required Weston setup on a fresh graphics boot.
                    setup = [deepcopy(item) for old_group, item in baseline if old_group == group
                             and "Weston_Runtime_Preflight" in item["path"]]
                    if setup:
                        destination["actions"].append({"test": {"timeout": {"minutes": 10}, "definitions": setup}})
                    jobs[unique] = destination
                destination["actions"].append({"test": {"timeout": {"minutes": minutes},
                                                         "definitions": [definition]}})
                selected.add(id(definition))
                destination["timeouts"]["job"]["minutes"] += minutes
                disposition = "added with fresh boot" if fresh else "appended"
            if tags:
                destination = jobs[execution_group]
                # Selection tags add requirements, never replace template tags.
                destination["tags"] = sorted(set(destination.get("tags", [])) | set(tags))
            manifest.append(dict(suite=suite, path=path, group=group, params=params,
                                 execution_group=execution_group, definitions=selected_names,
                                 reasons=sorted(reasons), disposition=disposition))
    if not include_meta_qcom:
        for group in list(jobs):
            job = jobs[group]
            if not any(id(item) in selected for item in entries(job)):
                del jobs[group]
                continue
            actions = []
            for action in job["actions"]:
                test = action.get("test", {})
                if "definitions" in test:
                    # Keep only selected tests and the existing graphics setup.
                    test["definitions"] = [item for item in test["definitions"] if id(item) in selected or
                                           "Weston_Runtime_Preflight" in item["path"]]
                    if not test["definitions"]:
                        continue
                actions.append(action)
            job["actions"] = actions
    return manifest


def prepare(folder):
    token_name = artifact_token_name()
    run_id = os.environ["VALIDATION_RUN_ID"]
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[1-9][0-9]*", attempt):
        raise ValueError("Invalid workflow run or attempt ID")
    folder = folder.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    config = json.loads((ROOT / ".github/ci/lava-pr-validation.json").read_text(encoding="utf-8"))
    gh = github()
    previous = previous_request(gh, run_id, attempt)
    if previous and previous.get("lava_url") != LAVA:
        raise ValueError("The previous attempt used another LAVA instance, start a new workflow run")
    if previous and previous.get("selection_policy") != "direct-suites":
        raise ValueError("The saved request uses an older test-selection policy, start a new manual validation run")
    baseline_input = os.environ.get("INCLUDE_META_QCOM", "true").lower()
    if baseline_input not in {"true", "false"}:
        raise ValueError("include_meta_qcom must be true or false")
    include_meta_qcom = previous.get("include_meta_qcom", True) if previous else baseline_input == "true"
    if not isinstance(include_meta_qcom, bool):
        raise ValueError("Invalid saved meta-qcom test selection")
    number = int(os.environ["PR_NUMBER"])
    pr = gh.get(f"/repos/{REPOSITORY}/pulls/{number}")
    if pr["state"] != "open" or pr["base"]["ref"] != "main":
        raise ValueError("Select an open PR targeting main")
    distro_choice = os.environ.get("IMAGE_DISTRO", "meta-qcom-main")
    if distro_choice not in IMAGE_DISTROS:
        raise ValueError("Choose meta-qcom-main or meta-qcom-lts-6.18")
    distro = IMAGE_DISTROS[distro_choice]
    producer = API(GITHUB, os.environ.get("META_QCOM_READ_TOKEN") or os.environ.get("GH_TOKEN", ""))
    target_matrix = json.loads((folder / "target-matrix.json").read_text(encoding="utf-8"))
    targets = target_matrix["selected"]
    plans_revision = target_matrix["plans_revision"]
    plans = Path(os.environ["LAVA_PLANS_PATH"]).resolve()
    if git(plans, "rev-parse", "HEAD").decode().strip() != plans_revision:
        raise ValueError("lava-test-plans checkout does not match the resolved meta-qcom pin")
    validate_target_templates(plans, targets, config)
    # Keep historical names in saved requests so older reruns select the same artifact.
    image_variants = {"base": "multimedia", "overlay": "proprietary",
                      "multimedia": "multimedia", "proprietary": "proprietary", "both": "both"}
    image_choice = os.environ.get("IMAGE_TYPE", "base")
    if image_choice not in image_variants:
        raise ValueError("Choose the base or overlay multimedia image, or both")
    image_type = image_variants[image_choice]
    if previous and (previous["pr"] != number or previous["distro"] != distro or
                     previous["image_type"] != image_type or
                     previous["plans_revision"] != plans_revision):
        raise ValueError("Rerun inputs differ from the saved request, use a new manual validation run")
    variants = {"base": "qcom-multimedia-image", "overlay": "qcom-multimedia-proprietary-image"}
    if image_type != "both":
        variant = "base" if image_type == "multimedia" else "overlay"
        variants = {variant: variants[variant]}
    image_name = next(iter(variants.values()))
    source, sha, base, changes, repository = snapshot(
        folder, pr, previous["sha"] if previous else os.environ.get("PR_REVISION", ""))
    if previous:
        if repository != previous["repository"]:
            raise ValueError("The PR source repository changed, use a new manual validation run")
        base, changes = previous["merge_base"], previous["changes"]
    owners, documents, by_suite = catalogue(source)
    test_names = previous.get("test_names", "") if previous else os.environ.get("TEST_NAMES", "")
    named = named_suites(test_names, by_suite)
    affected = named if named else affected_suites(changes, owners, config)
    requested_selections = json.loads(os.environ.get("TEST_SELECTIONS", "{}"))
    if not isinstance(requested_selections, dict):
        raise ValueError("TEST_SELECTIONS must map suite directories to selections")
    selections = config["selections"] | requested_selections
    overlap = set(named) & set(selections)
    if overlap:
        raise ValueError("Suites appear in both test_names and selections: " + ", ".join(sorted(overlap)) +
                         ". Use selections alone for those suites to specify parameters, tags or fresh_boot.")
    for suite in selections:
        if suite not in owners:
            raise ValueError(f"Unknown suite in selections: {suite}")
        affected[suite].add("explicit maintainer selection")
    if not include_meta_qcom and not affected:
        raise ValueError("No PR suites selected. PR-only runs use direct suite changes or explicit selections, "
                         "not automatic shared-library consumers. Provide test_names or selections, "
                         "or enable include_meta_qcom.")
    access = {}
    if previous and not all(previous.get(key) for key in ("audio_url", "audio_sha256")):
        raise ValueError("The earlier request did not pin its audio asset, use a new manual validation run")
    audio_url = previous["audio_url"] if previous else config["audio_url"]
    audio_sha256 = previous["audio_sha256"] if previous else config["audio_sha256"]
    if not re.fullmatch(r"[0-9a-f]{64}", audio_sha256):
        raise ValueError("Configure the published AudioClips SHA256")
    check_download(audio_url, access)
    if previous:
        build = previous["build"]
    else:
        build = select_build(producer, config, targets, distro, os.environ.get("NIGHTLY_RUN_ID", ""), image_name, access)
        if image_type == "both":
            # Both images must come from the same successful producer attempt.
            build["overlay_images"] = {target: build["prefix"] +
                                       f"{distro}/{target}/{variants['overlay']}-{target}.rootfs.qcomflash.tar.gz"
                                       for target in targets}
    overlay_images = build.get("overlay_images", {}) if image_type == "both" else {}
    if image_type == "both" and set(overlay_images) != set(targets):
        raise ValueError("Saved request does not contain both images for every selected target")
    for url in [*(build["images"].values() if previous else []), *overlay_images.values()]:
        check_download(url, access)
    image_urls = [*build["images"].values(), *overlay_images.values()]
    if os.environ.get("QLI_S3_TOKEN") or os.environ.get("QLI_ARTIFACT_TOKEN"):
        # GitHub and the dispatcher can use different registered credentials.
        # A successful controller probe alone cannot prove LAVA can fetch images.
        record = lava().get(f"/api/v0.2/remote-artifact-tokens/{token_name}/")
        dispatcher_access = {"qli_token": record.get("token")}
        if dispatcher_access["qli_token"] != access.get("qli_token"):
            for url in [audio_url, *image_urls]:
                if urlsplit(url).hostname == "qli-prod-artifacts.qualcomm.com":
                    check_download(url, dispatcher_access)
    source_url = f"https://github.com/{repository}/archive/{sha}.tar.gz"
    manifest = dict(pr=number, sha=sha, merge_base=base, repository=repository,
                    distro=distro, image_type=image_type, build=build, run_id=run_id,
                    run_attempt=attempt, changes=changes, lava_url=LAVA,
                    include_meta_qcom=include_meta_qcom,
                    selection_policy="direct-suites",
                    test_names=test_names,
                    target_matrix=target_matrix,
                    plans_revision=plans_revision, jobs=[], selections=[], exclusions=[],
                    baseline_helpers=[],
                    audio_url=audio_url, audio_sha256=audio_sha256,
                    artifact_token_name=token_name,
                    artifact_verification="controller",
                    submit_requested=os.environ.get("SUBMIT_REQUEST", "false").lower() == "true",
                    request_minutes=config["request_minutes"])
    (folder / "jobs").mkdir()
    baseline_job_count = 0
    for target, variant in ((target, variant) for target in targets for variant in variants):
        image_name = variants[variant]
        rootfs_url = (overlay_images if image_type == "both" and variant == "overlay" else build["images"])[target]
        variant_fields = {"image_variant": variant} if image_type == "both" else {}
        context = dict(PROJECT="projects/meta-qcom/", PROJECT_NAME="meta-qcom", OS_INFO="qcom-distro",
                       LAVA_JOB_PRIORITY=50,  # Match meta-qcom's CI queue priority.
                       BUILD_NUMBER=f"testkit-pr-{number}", BUILD_URL=build["prefix"],
                       ROOTFS_URL=rootfs_url, DEVICE_TYPE=target, overlays=[],
                       IMAGE_FILE_NAME=f"{image_name}-{target}.rootfs.qcomflash.tar.gz",
                       AUTO_LOGIN_PASSWORD_PROMPT="Password", AUTO_LOGIN_PASSWORD="oelinux123",
                       AUDIO_CLIPS_BASE_DIR="/home/AudioClips/", AUDIO_CLIPS_URL=audio_url,
                       AUTH_HEADER_NAME="QLIAuthorization", AUTH_HEADER_TOKEN=token_name,
                       DOCKER_IMAGE_POSTPROCESS=config["postprocess_image"],
                       target_downloads_timeout=40, target_deploy_timeout=20, TARGET_BOOT_TIMEOUT=10,
                       TEST_DEFINITIONS_REPOSITORY=f"https://github.com/{repository}",
                       TEST_DEFINITIONS_REVISION=sha, TEST_DEFINITIONS_REVISION_SHA=sha,
                       PR_NUMBER=str(number), PR_URL=pr["html_url"])
        jobs, excluded = render_baseline(plans, target, context, config)
        if include_meta_qcom:
            baseline_job_count += len(jobs)
        manifest["exclusions"].extend(f"{variant}: {item}" if image_type == "both" else item for item in excluded)
        baseline_ids = {id(definition) for job in jobs.values() for definition in entries(job)}
        if include_meta_qcom:
            for job in jobs.values():
                for definition in entries(job):
                    if definition["path"] not in documents:
                        raise ValueError(f"Missing baseline YAML in PR: {definition['path']}")
        selection = append_tests(jobs, affected, documents, by_suite, selections, config, source_url, source,
                                 include_meta_qcom=include_meta_qcom,
                                 excluded_definitions=context["excluded_definitions"])
        pr_definitions = {(row["execution_group"], name) for row in selection
                          for name in row.get("definitions", [])}
        if not include_meta_qcom:
            baseline_job_count += sum(group in config["groups"] for group in jobs)
            for job in jobs.values():
                for definition in entries(job):
                    if definition["path"] not in documents:
                        raise ValueError(f"Missing selected YAML in PR: {definition['path']}")
        for changed in sorted({change["path"] for change in changes} & set(config.get("baseline_helpers", []))):
            if not jobs:
                continue
            coverage = sorted({definition["path"] for job in jobs.values() for definition in entries(job)
                               if (not include_meta_qcom or id(definition) in baseline_ids) and
                               invokes_helper(documents[definition["path"]], changed)})
            if not (source / changed).is_file() or not coverage:
                raise ValueError(f"{changed} has no selected test coverage on {target}. "
                                 "Enable include_meta_qcom or select suites that invoke it.")
            manifest["baseline_helpers"].append(dict(target=target, path=changed, definitions=coverage, **variant_fields))
        manifest["selections"].extend(dict(target=target, **variant_fields, **row) for row in selection)
        for group, job in jobs.items():
            if job["device_type"] != config["targets"][target]:
                raise ValueError(f"{target}: Foundries device type differs from the pinned template")
            job["timeouts"]["queue"] = {"minutes": config["queue_minutes"]}
            # Retain native meta-qcom deployment, flashing stages and device setup.
            for action in job["actions"]:
                deploy = action.get("deploy", {})
                if "audio" in deploy.get("images", {}):
                    audio = deploy["images"]["audio"]
                    audio["sha256sum"] = audio_sha256
                    if urlsplit(audio_url).hostname == "qli-prod-artifacts.qualcomm.com":
                        audio["headers"] = {"QLIAuthorization": token_name}
                    else:
                        audio.pop("headers", None)
            definitions = entries(job)
            if any(item.get("repository") != source_url for item in definitions):
                raise ValueError("All test definitions must use the exact PR archive")
            # Fetch definitions with git on the dispatcher.
            # This does not require git in the image or execute PR code here.
            for definition in definitions:
                definition.update({"from": "git", "repository": f"https://github.com/{repository}.git",
                                   "revision": sha})
                definition.pop("strip-components", None)
            key = "testkit-" + digest(dict(lava_url=LAVA, run_id=run_id, sha=sha, repository=repository, build=build["prefix"],
                                          distro=distro, target=target, group=group, job=job))[:32]
            job["job_name"] = key
            job.setdefault("metadata", {}).update({"testkit-request-key": key,
                                                     "testkit-workflow-run": run_id,
                                                     "testkit-workflow-attempt": attempt,
                                                     "testkit-sha": sha})
            filename = f"jobs/{target}-{group}.yaml"
            if image_type == "both":
                filename = f"jobs/{target}-{variant}-{group}.yaml"
            (folder / filename).write_text(yaml.safe_dump(job, sort_keys=False), encoding="utf-8")
            result_definitions = []
            for item in definitions:
                coverage = "Baseline" if include_meta_qcom and id(item) in baseline_ids else "Setup"
                if (group, item["name"]) in pr_definitions:
                    coverage = "PR change" if id(item) in baseline_ids else "PR addition"
                result_definitions.append(dict(name=item["name"], path=item["path"],
                                               params=item.get("params", {}), expected=item.get("expected", []),
                                               coverage=coverage))
            manifest["jobs"].append(dict(file=filename, key=key, target=target, group=group,
                                         **variant_fields,
                                         run_id=run_id, run_attempt=attempt,
                                         device_type=job["device_type"], definition_hash=digest(job),
                                          definitions=result_definitions))
    job_limit = baseline_job_count + config["max_additional_jobs"]
    manifest["job_limit"] = job_limit
    save_json(folder / "manifest.json", manifest)
    if not manifest["jobs"]:
        raise ValueError("No runnable PR tests for the selected targets. Check exclusions or provide suite selections.")
    if len(manifest["jobs"]) > job_limit:
        raise ValueError(f"Prepared {len(manifest['jobs'])} jobs exceeds the {job_limit} job budget")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"request_attempt={attempt}\n")
    print(f"Prepared {len(manifest['jobs'])} jobs for PR #{number} at {sha}. No jobs submitted.")
