# weston-smoke

Runs `weston-smoke` under a working Wayland session (existing Weston or private Weston started by helpers) and validates that the client actually exercised Wayland.

## What this test validates

- A connected DRM display exists (otherwise SKIP)
- A usable Wayland socket is available (otherwise SKIP)
- GPU acceleration is active when `display_is_cpu_renderer` helper exists (otherwise SKIP)
- `weston-smoke` runs for roughly `DURATION`
- Optional:
  - Wayland protocol activity validation using `WAYLAND_DEBUG=1` capture
  - Screenshot delta validation if screenshot tools exist and permissions allow

## Parameters (LAVA yaml `params:`)

- `DURATION` (default `30s`)
- `VALIDATE_WAYLAND_PROTO` (default `1`)
- `VALIDATE_SCREENSHOT` (default `0`)

## Logs and results

- `weston-smoke.res` contains `weston-smoke PASS/FAIL/SKIP`
- `weston-smoke_run.log` contains WAYLAND_DEBUG output when protocol validation is enabled
- `weston-smoke_stdout_*.log` contains extra logs (including screenshot helper output)

