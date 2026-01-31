# weston-scaler

Runs `weston-scaler` as a Wayland client and validates it actually ran in a usable Wayland session.

## What this test validates

1. **Display presence (DRM connector)**  
   If no connected display is detected, the test **SKIPs**.

2. **Wayland availability**  
   Reuses existing Wayland socket if present, otherwise tries to start a private Weston using helpers from `lib_display.sh`.
   If no socket can be found, the test **SKIPs**.

3. **GPU acceleration gating (optional but default behavior)**  
   If CPU/software renderer is detected, the test **SKIPs** (to avoid “false green” on llvmpipe).

4. **Client execution evidence**
   - By default, enables **client-side Wayland protocol validation** using `WAYLAND_DEBUG=1` and checks for
     `wl_compositor.create_surface` + `wl_surface.commit` in the client log.
   - Optionally, can perform **screenshot-delta** validation (before/after) when screenshot tools exist.

## Files

- `run.sh` – main runner (writes `weston-scaler.res` and `weston-scaler_run.log`)
- `weston-scaler.yaml` – LAVA job fragment / example
- `weston-scaler.res` – output result file (generated)

## Parameters (LAVA/job params)

- `DURATION` (default `30s`): how long to run the client
- `VALIDATE_WAYLAND_PROTO` (default `1`): enable `WAYLAND_DEBUG=1` and protocol evidence check
- `VALIDATE_SCREENSHOT` (default `0`): enable screenshot-before/after delta validation

## Expected result semantics

- `PASS` – client ran for expected duration (or timed out) and validations passed
- `FAIL` – client exited too quickly, bad exit code, missing Wayland evidence, or screenshot delta check failed
- `SKIP` – no display, no Wayland socket, or GPU accel not enabled
