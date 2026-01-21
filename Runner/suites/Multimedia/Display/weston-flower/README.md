# weston-flower

Runs `weston-flower` under a working Wayland session (existing Weston or private Weston started by helpers) and validates that the client actually exercised Wayland.

## What this test validates

- A connected DRM display exists (otherwise SKIP)
- A usable Wayland socket is available (otherwise SKIP)
- GPU acceleration is active when `display_is_cpu_renderer` helper exists (otherwise SKIP)
- `weston-flower` runs for roughly `DURATION`
- Optional:
  - Wayland protocol activity validation using `WAYLAND_DEBUG=1` capture
  - Screenshot delta validation if screenshot tools exist and permissions allow

## Parameters (LAVA yaml `params:`)

- `DURATION` (default `30s`)
- `VALIDATE_WAYLAND_PROTO` (default `1`)
  - When enabled, the script captures `WAYLAND_DEBUG=1` output and checks for `create_surface` and `commit`.
- `VALIDATE_SCREENSHOT` (default `0`)
  - When enabled, tries to capture before and after screenshots and checks for delta.
  - If screenshots are unauthorized or tool is missing, screenshot validation is skipped.

## Logs and results

- `weston-flower.res` contains `weston-flower PASS/FAIL/SKIP`
- `weston-flower_run.log` contains WAYLAND_DEBUG output when protocol validation is enabled
- `weston-flower_stdout_*.log` contains extra logs (including screenshot helper output)
