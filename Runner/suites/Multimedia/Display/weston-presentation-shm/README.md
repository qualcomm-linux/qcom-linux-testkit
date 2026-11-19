# weston-presentation-shm

Runs `weston-presentation-shm` under a working Wayland session (existing Weston or private Weston started by helpers) and validates that the client actually exercised Wayland.

`weston-presentation-shm` is a CPU-rendered SHM client that exercises the Wayland presentation-time protocol (`wp_presentation`). It submits frames using `wl_shm` buffers and uses presentation feedback events to verify that the compositor honours precise frame timing and presentation timestamps. This validates the compositor's support for the `wp_presentation` extension, which is required for latency-sensitive and frame-synchronised display applications.

On CentOS, the shared dependency path provides `weston`, `weston-demo`, `seatd`, and `egl-utils`. With `--allow-relaunch`, the test starts `seatd.service` when needed, launches Weston on the selected DRM device, and adopts the generated Wayland socket.

## What this test validates

- A connected DRM display exists (otherwise SKIP)
- A usable Wayland socket is available (otherwise SKIP)
- `weston-presentation-shm` runs for roughly `DURATION`
- Optional:
  - Wayland protocol activity validation using `WAYLAND_DEBUG=1` capture
  - Screenshot delta validation if screenshot tools exist and permissions allow

## Parameters (LAVA yaml `params:`)

- `DURATION` (default `30s`)
- `WAIT_SECS` (default `10`)
  - Weston runtime readiness timeout in seconds.
- `ALLOW_RELAUNCH` (default `0`)
  - When set to `1`, allows recovery of an existing managed Weston runtime.
- `VALIDATE_WAYLAND_PROTO` (default `1`)
  - When enabled, the script captures `WAYLAND_DEBUG=1` output and checks for `create_surface` and `commit`.
- `VALIDATE_SCREENSHOT` (default `0`)
  - When enabled, tries to capture before and after screenshots and checks for delta.
  - If screenshots are unauthorized or tool is missing, screenshot validation is skipped.

## Command line options

```text
--auto                    Reuse and validate the active graphics stack (default)
--base                    Require the active MSM/freedreno base stack
--overlay                 Require the active KGSL/Adreno overlay stack
--wait-secs N             Weston readiness timeout (default: 10)
--allow-relaunch          Allow recovery of an existing managed Weston runtime
--no-allow-relaunch       Do not allow managed Weston recovery (default)
--validate-wayland-proto  Require Wayland protocol evidence (default)
--no-validate-wayland-proto
--validate-screenshot     Enable screenshot-delta validation
--no-validate-screenshot  Disable screenshot-delta validation (default)
-h, --help                Show usage
```

## How to run

```sh
cd Runner/suites/Multimedia/Display/weston-presentation-shm
chmod +x run.sh
./run.sh
```

Run with Weston relaunch allowed:

```sh
./run.sh --allow-relaunch
```

Run requiring the base graphics stack:

```sh
./run.sh --base
```

## Expected result

### PASS

- A connected display is detected
- A usable Weston runtime is available
- `weston-presentation-shm` is present in `PATH`
- The client runs for the configured `DURATION` without an unexpected exit
- Wayland protocol validation passes (when enabled)

### FAIL

- `weston-presentation-shm` exits unexpectedly before `DURATION` elapses
- `weston-presentation-shm` exits too quickly (within 1 second of launch)
- Wayland protocol validation finds no protocol activity
- Screenshot delta validation finds no visible change (when enabled)

### SKIP

- No connected display is detected
- No usable Weston runtime is available
- `weston-presentation-shm` binary is not present in `PATH`

## Logs and results

- `weston-presentation-shm.res` contains `weston-presentation-shm PASS/FAIL/SKIP`
- `weston-presentation-shm_run.log` contains `WAYLAND_DEBUG` output when protocol validation is enabled
- `weston-presentation-shm_stdout_*.log` contains extra logs (including screenshot helper output)
