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
import subprocess
import tarfile
from urllib.parse import urlsplit
import zipfile

from jinja2 import Environment, FileSystemLoader, StrictUndefined
import requests
import yaml

import generate_test_inventory_html as inventory
from lava_pr_validation import API, GITHUB, REPOSITORY, digest, github, save_json
from lava_test_plans.utils import compression

ROOT = Path(__file__).resolve().parents[1]


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


def check_download(url):
    """Check exact objects without transferring rootfs images or leaking tokens."""
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.hostname != "qli-prod-artifacts.qualcomm.com":
        raise ValueError("Artifact URL is outside the configured HTTPS artifact service")
    headers = {"QLIAuthorization": os.environ["QLI_ARTIFACT_TOKEN"]}
    with requests.get(url, headers=headers, stream=True, allow_redirects=False,
                      timeout=(15, 60)) as response:
        if response.status_code not in (200, 206):
            raise ValueError(f"Required artifact unavailable: {parsed.path}, HTTP {response.status_code}")
        if "text/html" in response.headers.get("Content-Type", ""):
            raise ValueError(f"Artifact service returned an HTML page: {parsed.path}")


def select_targets(gh, config, distro, requested):
    """Read the real pre-merge list, preserving the source revision and omissions."""
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
    selected = eligible if requested.strip() == "meta-qcom" else list(dict.fromkeys(
        target.strip() for target in requested.split(",")))
    if set(selected) & set(excluded):
        raise ValueError("Targets excluded from Testkit PR validation: " +
                         ", ".join(target for target in selected if target in excluded))
    if not selected or set(selected) - set(eligible):
        raise ValueError(f"Choose enabled Testkit targets from meta-qcom {name}: {', '.join(eligible)}")
    return dict(repository=repository, revision=revision, workflow=config["target_workflow"],
                job=name, kernel=settings.get("kernel"), targets=targets, selected=selected,
                excluded=excluded)


def validate_target_templates(plans, targets, config):
    """Reject missing lab mappings/templates before image or hardware operations."""
    gaps = []
    for target in targets:
        if not config["targets"].get(target):
            gaps.append(f"{target}: OSS device mapping is not confirmed")
        relative = Path("projects/meta-qcom/devices") / target
        if not ((ROOT / "ci/lava-oss" / relative).is_file() or
                (plans / "lava_test_plans" / relative).is_file()):
            gaps.append(f"{target}: device template is absent from the pinned lava-test-plans")
    if gaps:
        raise ValueError("Pre-merge targets cannot be silently omitted. " + ", ".join(gaps))


def select_build(gh, config, targets, distro, override, image_name):
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
            check_download(url)
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
    for path in sorted(path for path in (source / "Runner").rglob("*")
                       if path.suffix in {".yaml", ".yml"}):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict) or not document.get("metadata"):
            continue
        steps = document.get("run", {}).get("steps")
        if not isinstance(steps, list) or not all(isinstance(step, str) for step in steps):
            continue
        relative = path.relative_to(source).as_posix()
        invocations = [owner for owner in owners if any(owner in step for step in steps)]
        local = owning_suite(relative, owners)
        if not invocations and local and any("./run.sh" in step for step in steps):
            invocations = [local]
        definitions[relative] = document
        for owner in invocations:
            by_suite[owner].append(relative)
    return owners, definitions, by_suite


def owning_suite(path, owners):
    return next((owner for owner in owners if path.startswith(owner + "/")), None)


def affected_suites(source, changes, owners, config):
    """Expand associated files and shared dependencies, conservatively on dynamic paths."""
    reasons = defaultdict(set)
    texts = {}
    for path in (source / "Runner").rglob("*"):
        if path.is_file() and path.suffix in {".sh", ".py", ".awk", ".yaml", ".json", ".conf"}:
            texts[path.relative_to(source).as_posix()] = path.read_text(encoding="utf-8", errors="replace")
    for change in changes:
        changed = change["path"]
        if changed.lower().endswith((".md", ".rst")):
            continue
        owner = owning_suite(changed, owners)
        if owner:
            reasons[owner].add(changed)
            continue
        if not changed.startswith("Runner/"):
            continue
        if changed.startswith("Runner/suites/") and not (source / changed).exists():
            continue  # Removed suite. Missing baseline paths are rejected during render.
        pending, visited = [changed], set()
        while pending:
            dependency = pending.pop()
            if dependency in visited:
                continue
            visited.add(dependency)
            consumers = [path for path, text in texts.items()
                         if Path(dependency).name in text and path != dependency]
            consumers.extend(config["associations"].get(dependency, []))
            for consumer in consumers:
                owner = owning_suite(consumer, owners)
                if owner:
                    reasons[owner].add(changed)
                else:
                    pending.append(consumer)
        if not any(changed in paths for paths in reasons.values()):
            # A dynamic shared dependency cannot safely be treated as no impact.
            for owner in owners:
                reasons[owner].add(changed + " (shared scope unresolved)")
    return reasons


def render_baseline(plans, target, context, config):
    templates = plans / "lava_test_plans"
    plan_groups = {path.stem for path in (templates / "testplans/meta-qcom/qcom-distro/pre-merge").glob("*.yaml")}
    if plan_groups != set(config["groups"]):
        raise ValueError("Configured groups must cover the complete pinned meta-qcom PR plan")
    # Pinned LAVA templates produce YAML and shell, HTML escaping corrupts their values.
    # nosemgrep: python.flask.security.xss.audit.direct-use-of-jinja2.direct-use-of-jinja2
    environment = Environment(loader=FileSystemLoader([
        str(ROOT / "ci/lava-oss"), str(templates), str(templates / "testplans"), str(templates / "testcases"),
        str(templates / "devices")]), undefined=StrictUndefined, autoescape=False,
        extensions=["jinja2.ext.loopcontrols"])
    environment.globals["compression"] = compression
    context["device_type"] = f"projects/meta-qcom/devices/{target}"
    device = environment.get_template(context["device_type"]).make_module(context)
    excluded_groups = getattr(device, "EXCLUDED_TESTPLANS", [])
    context["EXCLUDED_TESTS"] = getattr(device, "EXCLUDED_TESTS", [])
    jobs, excluded = {}, []
    for group in config["groups"]:
        if group + ".yaml" in excluded_groups:
            excluded.append(f"{target}/{group}")
            continue
        template = environment.get_template(f"testcases/{group}.yaml")
        namespace = template.make_module(context)
        excluded.extend(f"{target}/{group}/{test['name']}" for test in namespace.all_tests
                        if test["name"] in context["EXCLUDED_TESTS"] or not test.get("include", True))
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


def group_for(suite):
    groups = {"Connectivity/BT/": "pre-merge-bt", "Connectivity/Bluetooth/": "pre-merge-bt",
              "Multimedia/Audio/": "pre-merge-audio", "Multimedia/Graphics/": "pre-merge-display-gfx",
              "Multimedia/Video/": "pre-merge-gstr-video", "Multimedia/Camera/": "pre-merge-camera"}
    if "/Camera_NHX" in suite:
        raise ValueError("Camera_NHX needs an explicit compatible selection and image")
    return next((group for prefix, group in groups.items() if prefix in suite), "pre-merge-basic")


def append_tests(jobs, affected, documents, by_suite, selections, config, source_url):
    manifest = []
    baseline = [(group, definition) for group, job in jobs.items() for definition in entries(job)]
    for suite, reasons in sorted(affected.items()):
        candidates = by_suite.get(suite, [])
        explicit = selections.get(suite)
        changed_yamls = [path for path in candidates if path in reasons]
        if explicit:
            choices = explicit if isinstance(explicit, list) else [explicit]
        else:
            default = f"{suite}/{Path(suite).name}.yaml"
            paths = changed_yamls or ([default] if default in candidates else candidates)
            if len(paths) != 1:
                raise ValueError(f"Select YAML and group for {suite}, candidates: {', '.join(candidates) or 'none'}")
            default_group = next((group for group, old in baseline
                                  if old["path"] == paths[0] and
                                  effective_params(old, documents) ==
                                  effective_params({"path": paths[0]}, documents)), None)
            choices = [{"path": paths[0], "group": default_group or group_for(suite)}]
        for choice in choices:
            path = choice["path"]
            if path not in candidates:
                raise ValueError(f"{path} does not invoke {suite}")
            group = choice["group"]
            if group not in config["groups"]:
                raise ValueError(f"Unknown execution group: {group}")
            if group not in jobs:
                manifest.append(dict(suite=suite, path=path, group=group, reasons=sorted(reasons),
                                     disposition="excluded by target template"))
                continue
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
            definition = dict(path=path, params=params)
            # Do not collapse baseline instances, only avoid equivalent additions.
            equivalent = any(old["path"] == path and old_group == group and
                             effective_params(old, documents) == effective_params(definition, documents)
                             for old_group, old in baseline)
            if equivalent:
                disposition = "covered by baseline"
            else:
                name = "pr-" + Path(path).stem + "-" + digest(choice)[:8]
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
                    raise ValueError("Definition filename must form a valid LAVA name")
                definition.update(name=name, repository=source_url,
                                  **{"from": "url", "strip-components": 1})
                if choice.get("expected"):
                    definition["expected"] = choice["expected"]
                minutes = int(choice.get("minutes", config["addition_minutes"]))
                if not 1 <= minutes <= 120:
                    raise ValueError("Addition timeout must be 1..120 minutes")
                fresh = choice.get("fresh_boot", False)
                steps = " ".join(documents[path]["run"]["steps"]).lower()
                risky = any(word in (path + " " + steps + json.dumps(params)).lower()
                            for word in ("crash", "inject", "unbind", "reboot"))
                if risky and (not explicit or not fresh):
                    raise ValueError(f"{path} needs an explicit fresh_boot selection")
                destination = jobs[group]
                if fresh:
                    unique = group + "-" + name
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
                destination["timeouts"]["job"]["minutes"] += minutes
                disposition = "added with fresh boot" if fresh else "appended"
            manifest.append(dict(suite=suite, path=path, group=group, params=params,
                                 reasons=sorted(reasons), disposition=disposition))
    return manifest


def prepare(folder):
    folder = folder.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    config = json.loads((ROOT / "ci/lava-pr-validation.json").read_text(encoding="utf-8"))
    gh = github()
    number = int(os.environ["PR_NUMBER"])
    pr = gh.get(f"/repos/{REPOSITORY}/pulls/{number}")
    if pr["state"] != "open" or pr["base"]["ref"] != "main":
        raise ValueError("Select an open PR targeting main")
    distro = os.environ.get("IMAGE_DISTRO", "qcom-distro")
    producer = API(GITHUB, os.environ.get("META_QCOM_READ_TOKEN") or os.environ.get("GH_TOKEN", ""))
    target_matrix = select_targets(producer, config, distro, os.environ.get("TARGETS", "meta-qcom"))
    targets = target_matrix["selected"]
    save_json(folder / "target-matrix.json", target_matrix)
    plans = Path(os.environ["LAVA_PLANS_PATH"]).resolve()
    if git(plans, "rev-parse", "HEAD").decode().strip() != config["plans_revision"]:
        raise ValueError("lava-test-plans checkout does not match the trusted pin")
    validate_target_templates(plans, targets, config)
    image_type = os.environ.get("IMAGE_TYPE", "multimedia")
    if image_type not in {"multimedia", "proprietary"}:
        raise ValueError("Choose the multimedia or proprietary image variant")
    image_name = "qcom-multimedia-image" if image_type == "multimedia" else "qcom-multimedia-proprietary-image"
    source, sha, base, changes, repository = snapshot(folder, pr, os.environ.get("PR_REVISION", ""))
    owners, documents, by_suite = catalogue(source)
    affected = affected_suites(source, changes, owners, config)
    selections = config["selections"] | json.loads(os.environ.get("TEST_SELECTIONS", "{}"))
    for suite in selections:
        if suite not in owners:
            raise ValueError(f"Unknown suite in selections: {suite}")
        affected[suite].add("explicit maintainer selection")
    build = select_build(producer, config, targets, distro, os.environ.get("NIGHTLY_RUN_ID", ""), image_name)
    check_download(config["audio_url"])
    run_id = os.environ["VALIDATION_RUN_ID"]
    if not re.fullmatch(r"[1-9][0-9]*", run_id):
        raise ValueError("Invalid workflow run ID")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", os.environ["LAVA_ARTIFACT_TOKEN_NAME"]):
        raise ValueError("Configure the registered OSS artifact token name")
    source_url = f"https://github.com/{repository}/archive/{sha}.tar.gz"
    manifest = dict(pr=number, sha=sha, merge_base=base, repository=repository,
                    distro=distro, image_type=image_type, build=build, run_id=run_id, changes=changes,
                    target_matrix=target_matrix,
                    plans_revision=config["plans_revision"], jobs=[], selections=[], exclusions=[],
                    artifact_token_name=os.environ["LAVA_ARTIFACT_TOKEN_NAME"],
                    submit_requested=os.environ.get("SUBMIT_REQUEST", "false").lower() == "true",
                    request_minutes=config["request_minutes"], max_active_jobs=config["max_active_jobs"])
    (folder / "jobs").mkdir()
    baseline_job_count = 0
    for target in targets:
        context = dict(PROJECT="projects/meta-qcom/", PROJECT_NAME="meta-qcom", OS_INFO="qcom-distro",
                       BUILD_NUMBER=f"testkit-pr-{number}", BUILD_URL=build["prefix"],
                       ROOTFS_URL=build["images"][target], DEVICE_TYPE=target, overlays=[],
                       IMAGE_FILE_NAME=f"{image_name}-{target}.rootfs.qcomflash.tar.gz",
                       AUTO_LOGIN_PASSWORD_PROMPT="Password", AUTO_LOGIN_PASSWORD="oelinux123",
                       AUDIO_CLIPS_BASE_DIR="/home/AudioClips/", AUDIO_CLIPS_URL=config["audio_url"],
                       AUTH_HEADER_NAME="QLIAuthorization", AUTH_HEADER_TOKEN=os.environ["LAVA_ARTIFACT_TOKEN_NAME"],
                       DOCKER_IMAGE_POSTPROCESS=config["postprocess_image"],
                       target_downloads_timeout=40, target_deploy_timeout=20, TARGET_BOOT_TIMEOUT=10,
                       TEST_DEFINITIONS_REPOSITORY=f"https://github.com/{repository}",
                       TEST_DEFINITIONS_REVISION=sha, TEST_DEFINITIONS_REVISION_SHA=sha,
                       PR_NUMBER=str(number), PR_URL=pr["html_url"])
        jobs, excluded = render_baseline(plans, target, context, config)
        baseline_job_count += len(jobs)
        manifest["exclusions"].extend(excluded)
        baseline_ids = {id(definition) for job in jobs.values() for definition in entries(job)}
        for job in jobs.values():
            for definition in entries(job):
                if definition["path"] not in documents:
                    raise ValueError(f"Missing baseline YAML in PR: {definition['path']}")
        selection = append_tests(jobs, affected, documents, by_suite, selections, config, source_url)
        manifest["selections"].extend(dict(target=target, **row) for row in selection)
        for group, job in jobs.items():
            job["device_type"] = config["targets"][target]
            job["timeouts"]["queue"] = {"minutes": config["queue_minutes"]}
            # The OSS flasher invokes QDL. Preserve the project's camera/media
            # postprocessing and supply the existing OSS flash.settings contract.
            for action in job["actions"]:
                deploy = action.get("deploy", {})
                if deploy.get("to") == "qdl":
                    raise ValueError("OSS requires QDL through the flasher action")
                docker = deploy.get("postprocess", {}).get("docker")
                if docker:
                    docker.pop("local", None)
                    docker["steps"] = [
                        f'echo "DEVICE_TYPE={config["targets"][target]}" >> $IMAGE_PATH/flash.settings'
                        if 'echo "DEVICE_TYPE=' in step else
                        step.replace(f"qcom-multimedia-image-{target}", f"{image_name}-{target}")
                        for step in docker["steps"]]
                    docker["steps"].extend([
                        'echo "ROOTFS_IMAGE=rootfs.img" >> $IMAGE_PATH/flash.settings',
                        f'echo "PORT={config["flasher_port"]}" >> $IMAGE_PATH/flash.settings'])
                if "audio" in deploy.get("images", {}):
                    deploy["images"]["audio"]["headers"] = {
                        "QLIAuthorization": os.environ["LAVA_ARTIFACT_TOKEN_NAME"]}
            definitions = entries(job)
            if any(item.get("repository") != source_url for item in definitions):
                raise ValueError("All test definitions must use the exact PR archive")
            # OSS currently fetches definitions with git on the dispatcher.
            # This does not require git in the image or execute PR code here.
            for definition in definitions:
                definition.update({"from": "git", "repository": f"https://github.com/{repository}.git",
                                   "revision": sha})
                definition.pop("strip-components", None)
            key = "testkit-" + digest(dict(sha=sha, repository=repository, build=build["prefix"],
                                          distro=distro, target=target, group=group, job=job))[:32]
            job["job_name"] = key
            job.setdefault("metadata", {}).update({"testkit-request-key": key,
                                                     "testkit-workflow-run": run_id,
                                                     "testkit-sha": sha})
            filename = f"jobs/{target}-{group}.yaml"
            (folder / filename).write_text(yaml.safe_dump(job, sort_keys=False), encoding="utf-8")
            manifest["jobs"].append(dict(file=filename, key=key, target=target, group=group,
                                         device_type=job["device_type"], definition_hash=digest(job),
                                         definitions=[dict(name=item["name"], path=item["path"],
                                                           params=item.get("params", {}), expected=item.get("expected", []),
                                                           coverage="Baseline" if id(item) in baseline_ids else "PR addition")
                                                      for item in definitions]))
    job_limit = baseline_job_count + config["max_additional_jobs"]
    manifest["job_limit"] = job_limit
    save_json(folder / "manifest.json", manifest)
    if len(manifest["jobs"]) > job_limit:
        raise ValueError(f"Prepared {len(manifest['jobs'])} jobs exceeds the {job_limit} job budget")
    print(f"Prepared {len(manifest['jobs'])} jobs for PR #{number} at {sha}. No jobs submitted.")
