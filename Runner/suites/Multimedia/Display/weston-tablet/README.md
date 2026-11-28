# weston-tablet

Runs `weston-tablet` under a working Wayland session and validates that the
client exercised the Wayland tablet protocol (`zwp_tablet_v2`).

`weston-tablet` binds `zwp_tablet_manager_v2` and creates a tablet seat so
the compositor can enumerate physical tablet and stylus devices. The test
validates that the protocol binding and seat creation succeeded regardless of
whether physical tablet hardware is attached — the compositor must expose the
tablet manager for the client to start normally.

## What this test validates

- A connected DRM display exists (otherwise SKIP)
- A usable Weston runtime is available (otherwise SKIP)
- `weston-tablet` is present in `PATH`
- The client runs for the configured `DURATION` without an unexpected exit
- Wayland protocol validation passes (when enabled):
  - Generic: `wl_compositor.create_surface` and `wl_surface.commit`
  - Tablet-specific: `zwp_tablet_manager_v2` bound and `zwp_tablet_seat_v2` created

## Parameters (LAVA yaml `params:`)

- `DURATION` (default `30s`)
- `WAIT_SECS` (default `10`) — Weston runtime readiness timeout
- `ALLOW_RELAUNCH` (default `0`) — allow recovery of an existing managed Weston runtime
- `VALIDATE_WAYLAND_PROTO` (default `1`) — capture `WAYLAND_DEBUG=1` output and check protocol evidence
- `VALIDATE_SCREENSHOT` (default `0`) — screenshot-delta validation

## How to run

```sh
cd Runner/suites/Multimedia/Display/weston-tablet
chmod +x run.sh
./run.sh
```

## Logs and results

- `weston-tablet.res` — `weston-tablet PASS/FAIL/SKIP`
- `weston-tablet_run.log` — `WAYLAND_DEBUG` output when protocol validation is enabled
- `weston-tablet_stdout_*.log` — extra logs
