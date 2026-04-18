# weston-simple-shm

## Overview

`weston-simple-shm` validates the Wayland shared-memory (`wl_shm`) rendering path using CPU-rendered buffers.

This testcase verifies:

- Weston runtime is healthy and usable
- `weston-simple-shm` launches successfully
- the default format path works
- required explicit formats work
- optional formats can be exercised for additional coverage
- the client remains alive for the configured monitor window
- the client can be stopped cleanly after validation

This test is intended as a low-level compositor sanity check before moving to GPU or EGL-based client validation.

---

## Validation Scope

The testcase covers the following:

1. **Weston runtime validation**
   - uses shared runtime helpers from `lib_display.sh`
   - validates a connected display is present
   - validates Weston runtime is available before launching the client
   - optionally allows runtime relaunch using `--allow-relaunch`

2. **Client availability**
   - checks that `weston-simple-shm` is available on the target

3. **Format-based validation**
   - runs one default case without `-F`
   - runs required explicit format cases
   - runs optional format cases for additional coverage

4. **Startup and monitor window**
   - ensures the client starts successfully
   - ensures the client remains alive for the configured duration

5. **Client log capture**
   - saves per-case client logs
   - prints helpful tail output on failures

---

## Default Format Policy

By default, the testcase uses:

- **Required formats**
  - `default`
  - `xrgb8888`

- **Optional formats**
  - `argb8888`
  - `rgb565`

The testcase passes only if all required format cases pass.

Optional format failures are logged for coverage and debugging, but do not fail the testcase.

---

## Prerequisites

Before running the testcase, ensure that:

- Weston is installed and functional on the target
- a display is connected
- `weston-simple-shm` is available in `PATH`
- the target has the required Wayland runtime environment
- the display stack is already brought up on the system

---

## Test Location

```text
Runner/suites/Multimedia/Graphics/weston-simple-shm/
```

---

## Files

Typical contents of this testcase directory:

```text
run.sh
weston-simple-shm.yaml
README.md
```

---

## How to Run

Run the testcase directly:

```sh
cd Runner/suites/Multimedia/Graphics/weston-simple-shm
chmod +x run.sh
./run.sh
```

Run with Weston relaunch allowed:

```sh
./run.sh --allow-relaunch
```

Run with a custom format set:

```sh
./run.sh \
  --required-formats "default xrgb8888 argb8888" \
  --optional-formats "rgb565"
```

---

## Command Line Options

```text
--allow-relaunch
    Allow Weston runtime relaunch when runtime is unhealthy

--duration SEC
    Keep each weston-simple-shm case running for SEC seconds

--startup-wait SEC
    Wait SEC seconds after launch before startup verdict

--stop-grace SEC
    Grace period after INT before KILL

--required-formats "LIST"
    Space-separated required formats

--optional-formats "LIST"
    Space-separated optional formats

-h, --help
    Show usage
```

---

## Optional Environment Variables

The testcase supports the following optional variables:

- `WAIT_SECS`
  - Weston runtime preparation timeout
  - default: `10`

- `DURATION`
  - monitor time per format case
  - default: `5`

- `STARTUP_WAIT`
  - delay before checking whether the client survived startup
  - default: `3`

- `STOP_GRACE`
  - grace period after sending `SIGINT`
  - default: `3`

- `ALLOW_RELAUNCH`
  - allow runtime relaunch
  - default: `0`

- `REQUIRED_FORMATS`
  - required format cases
  - default: `default xrgb8888`

- `OPTIONAL_FORMATS`
  - optional format cases
  - default: `argb8888 rgb565`

Example:

```sh
WAIT_SECS=10 \
DURATION=5 \
STARTUP_WAIT=3 \
STOP_GRACE=3 \
ALLOW_RELAUNCH=1 \
REQUIRED_FORMATS="default xrgb8888" \
OPTIONAL_FORMATS="argb8888 rgb565" \
./run.sh
```

---

## Expected Result

### PASS
The testcase passes when:

- Weston runtime is healthy
- `weston-simple-shm` is present
- all required format cases launch successfully
- all required format cases remain alive for the configured duration

### FAIL
The testcase fails when any of the following occurs:

- Weston runtime is unavailable
- `weston-simple-shm` exits during startup for a required case
- `weston-simple-shm` exits before the monitor window completes for a required case
- a required format is not supported by the compositor
- a required format is not supported by the client binary

### SKIP
The testcase is skipped when:

- no connected display is detected
- the binary is not present
- help/usage path is explicitly requested

---

## Result File

The testcase writes the result to:

```text
weston-simple-shm.res
```

Possible values:

```text
weston-simple-shm PASS
weston-simple-shm FAIL
weston-simple-shm SKIP
```

The testcase is CI/LAVA friendly and keeps the shell exit path non-blocking after runtime start, while using the `.res` file for PASS/FAIL/SKIP reporting.

---

## Logs

The testcase generates:

- a testcase result file
- a help snapshot log
- per-format client logs
- summary entries in the testcase run log

These logs are useful for debugging:

- startup failures
- compositor format support failures
- early client exits
- shutdown behavior

---

## Notes

- The literal token `default` means the client is run **without** `-F`
- Required and optional format groups are intentionally separated
- Optional formats are useful for broader compositor coverage without introducing unnecessary hard failures
- This testcase is a compositor and shared-memory client validation, not a GPU or EGL benchmark
