# Docker_Info

Validates selected Docker daemon settings on the DUT by running `docker info` locally.

## What this test checks

The test verifies that `docker info` reports:

- **Storage Driver:** `vfs`, `overlay2`, or `overlayfs`
- **Default Runtime:** `runc`
- **Init Binary:** `docker-init`
- **Docker Root Dir:** `/var/lib/docker`

The storage-driver alternatives allow for the values observed on different images. Keep this list aligned with the platform requirements.

## Requirements

- The Docker CLI must be installed on the DUT.
- The Docker daemon must be running and accessible to the user running the test.
- `grep` must be available on the DUT.
- The testkit `Runner` directory, including `init_env` and shared utilities, must be kept together.
- The test directory must be writable so the result file and logs can be saved.

## Validation method

The test runs `docker info` with a 30-second deadline, retains and logs its
output, and checks the four fields listed above. It fails if the command fails,
times out, or a required field is absent or has an unaccepted value.

## Result semantics

- **PASS** when `docker info` succeeds and all four fields match the expected values.
- **FAIL** when Docker is unavailable, the daemon cannot be queried, or any required field does not match.

## Output

The test writes its result to:

```text
docker_info.res
```

The LAVA result ID remains `docker_info`. Run directly from the repository
root with:

```sh
cd Runner/suites/System/Docker_Info
./run.sh
```
