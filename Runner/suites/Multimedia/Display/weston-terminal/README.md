# weston-terminal

Runs `weston-terminal` under a working Wayland session and validates that the
client created an XDG-shell toplevel window.

`weston-terminal` is a Wayland terminal emulator that binds `xdg_wm_base` (or
the legacy `xdg_shell`/`wl_shell` on older Weston builds), creates an
`xdg_surface`, and assigns it the `xdg_toplevel` role to produce a decorated
window. This validates that the compositor correctly handles shell surfaces and
toplevel window lifecycle events.

## What this test validates

- A connected DRM display exists (otherwise SKIP)
- A usable Weston runtime is available (otherwise SKIP)
- `weston-terminal` is present in `PATH`
- The client runs for the configured `DURATION` without an unexpected exit
- Wayland protocol validation passes (when enabled):
  - Generic: `wl_compositor.create_surface` and `wl_surface.commit`
  - Terminal-specific: `xdg_wm_base` (or legacy shell) bound and `xdg_toplevel` window created

## Parameters (LAVA yaml `params:`)

- `DURATION` (default `30s`)
- `WAIT_SECS` (default `10`) — Weston runtime readiness timeout
- `ALLOW_RELAUNCH` (default `0`) — allow recovery of an existing managed Weston runtime
- `VALIDATE_WAYLAND_PROTO` (default `1`) — capture `WAYLAND_DEBUG=1` output and check protocol evidence
- `VALIDATE_SCREENSHOT` (default `0`) — screenshot-delta validation

## How to run

```sh
cd Runner/suites/Multimedia/Display/weston-terminal
chmod +x run.sh
./run.sh
```

## Logs and results

- `weston-terminal.res` — `weston-terminal PASS/FAIL/SKIP`
- `weston-terminal_run.log` — `WAYLAND_DEBUG` output when protocol validation is enabled
- `weston-terminal_stdout_*.log` — extra logs
