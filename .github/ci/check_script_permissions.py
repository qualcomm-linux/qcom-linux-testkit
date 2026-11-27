# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Validate Git executable modes without inspecting checkout metadata or chmod state."""

import argparse
import io
import os
import re
import shlex
import subprocess


def git(*arguments, data=None):
    return subprocess.check_output(["git", *arguments], input=data, stderr=subprocess.PIPE)


def annotate(level, message, path=None):
    """Escape untrusted filenames and text for GitHub Actions annotations."""
    def escape(value):
        return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")

    location = ""
    if path is not None:
        location = " file=" + escape(path).replace(":", "%3A").replace(",", "%2C") + ",line=1"
    print(f"::{level}{location}::{escape(message)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("BASE_REVISION", ""),
                        help="Base commit SHA for optional warnings, omitted audits all tracked files")
    base = parser.parse_args().base
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel")).rstrip("\r\n"))
    changed = None
    if base and set(base) != {"0"}:
        if not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", base):
            raise ValueError("The comparison base must be a full Git commit SHA")
        try:
            git("rev-parse", "--verify", base + "^{commit}")
        except subprocess.CalledProcessError:
            annotate("notice", "Comparison commit is unavailable, auditing all tracked executables")
        else:
            # Compare with the index so staged mode changes can also be checked locally.
            changed = set(git("diff", "--cached", "--name-only", "--diff-filter=ACMRT",
                              "--no-renames", "-z", base, "--").split(b"\0"))

    errors = 0
    shell_count = 0
    candidates = []
    for record in git("ls-files", "--stage", "-z").split(b"\0"):
        if not record:
            continue
        metadata, path_bytes = record.split(b"\t", 1)
        mode, object_id, stage = metadata.split()
        path = os.fsdecode(path_bytes)
        if stage != b"0":
            annotate("error", "Resolve the Git index conflict before checking permissions", path)
            errors += 1
            continue
        # Symlinks and submodules have no independently tracked executable bit.
        if mode not in {b"100644", b"100755"}:
            continue
        if path.endswith(".sh"):
            shell_count += 1
            if mode != b"100755":
                annotate("error", "Tracked shell script is not executable. Run "
                         f"git update-index --chmod=+x -- {shlex.quote(path)}", path)
                errors += 1
        elif mode == b"100755" and (changed is None or path_bytes in changed):
            candidates.append((object_id, path))

    # Read committed/staged bytes in one batch, independent of filesystem modes,
    # sparse checkouts, symlink targets and untracked files such as .git/hooks.
    prefixes = {}
    if candidates:
        objects = list(dict.fromkeys(object_id for object_id, path in candidates))
        blobs = io.BytesIO(git("cat-file", "--batch", data=b"\n".join(objects) + b"\n"))
        for expected in objects:
            object_id, kind, size = blobs.readline().split()
            if object_id != expected or kind != b"blob":
                raise ValueError("Cannot read a tracked executable blob")
            prefixes[object_id] = blobs.read(int(size))[:2]
            if blobs.read(1) != b"\n":
                raise ValueError("Invalid Git blob boundary")
    warnings = 0
    for object_id, path in candidates:
        if not prefixes[object_id].startswith(b"#!"):
            annotate("warning", "Executable file is not a shell script and has no shebang. "
                     "If it is data, remove its executable bit with "
                     f"git update-index --chmod=-x -- {shlex.quote(path)}", path)
            warnings += 1

    scope = "all tracked files" if changed is None else "changed tracked files"
    print(f"Checked {shell_count} tracked shell scripts: {errors} errors. "
          f"Optional executable warnings for {scope}: {warnings}.")
    return 1 if errors else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        annotate("error", f"Cannot complete Git permission validation: {error}")
        raise SystemExit(1) from error
