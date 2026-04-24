# Weston_Runtime_Preflight

## Overview

`Weston_Runtime_Preflight` validates Weston and Wayland runtime health before any Weston client-level display or graphics tests are executed.

This testcase is a **runtime gate only**. It does **not** launch `weston-simple-shm`, `weston-simple-egl`, or any other Weston client application.

The goal is to catch real Weston bring-up issues early, such as:

- `weston.service` in failed state
- `weston.socket` active but compositor process not running
- missing or inconsistent Wayland runtime state
- broken systemd-managed Weston recovery on target
- runtime directory / socket issues for the configured Weston service user

Client-level validation must be handled separately:

- `weston-simple-shm` should be the first client-level blocker
- `weston-simple-egl` should be the EGL-specific blocker after that

---

## Behavior

### Default mode

```sh
./run.sh

This is the strict runtime health check.

In this mode, the testcase:

checks DRM/display connectivity

captures display snapshot and modetest diagnostics

checks weston.service and weston.socket state

inspects Weston service runtime context

checks whether a Weston compositor process is actually running

validates discovered Wayland runtime information

optionally collects EGL pipeline diagnostics


This mode does not attempt to restart or recover Weston.

If Weston runtime is unhealthy, the testcase reports FAIL.

Typical examples that cause FAIL in default mode:

weston.service is failed

no Weston process is running

runtime state is inconsistent

Wayland runtime cannot be validated



---

Relaunch mode

./run.sh --allow-relaunch

This mode enables an explicit recovery attempt for a broken systemd-managed Weston runtime.

In this mode, if Weston runtime is unhealthy, the testcase may:

stop weston.socket

stop weston.service

reset failed systemd state

restart the systemd-managed Weston runtime

re-check Weston service state, runtime directory, Wayland socket, and compositor process


If Weston is already healthy, relaunch is not performed and the test logs:

Relaunch not required, Weston already running


If recovery succeeds, the testcase reports PASS.

If recovery does not restore a healthy Weston runtime, the testcase reports FAIL.


---

PASS / FAIL / SKIP semantics

PASS

Reported when:

a connected display is available

Weston runtime is healthy

Wayland runtime discovery succeeds

optional EGL diagnostics do not block runtime success


FAIL

Reported when:

weston.service is failed or unhealthy in strict mode

no Weston compositor process is running

systemd-managed relaunch fails to recover Weston

runtime validation fails after cleanup/restart attempt

runtime remains inconsistent after recovery


SKIP

Reported when:

no usable connected display is present for the test


This testcase should not hide runtime issues behind SKIP when a display is present and Weston is expected to work.


---

What this test validates

connected display presence

DRM / connector snapshot

modetest capture for debug

weston.service state

weston.socket state

Weston service user / UID context

preferred runtime directory for Weston service user

existence of Wayland runtime directory

existence of Wayland socket when applicable

actual Weston compositor process presence

adopted Wayland environment used for reproduction

optional EGL pipeline diagnostics for debug visibility



---

What this test does not validate

This testcase does not validate:

Weston client rendering correctness

shared-memory client rendering

EGL window rendering

repeated client launch / kill lifecycle

graphics functional behavior beyond runtime diagnostics


Those must be covered by separate tests such as:

weston-simple-shm

weston-simple-egl



---

Runtime model notes

This test performs dynamic runtime inspection and does not hardcode a single runtime path.

It can log context such as:

Weston service user

Weston service UID

preferred runtime directory, for example /run/user/1000

discovered runtime socket

current XDG_RUNTIME_DIR

current WAYLAND_DISPLAY


This helps distinguish between:

service-level failure

runtime directory creation failure

socket creation failure

compositor process failure

environment mismatch



---

Parameters

The testcase supports the following controls through environment variables and CLI.

Environment variables

WAIT_SECS

default: 10

time to wait for runtime readiness checks


VALIDATE_EGLINFO

default: 1

when enabled, collects EGL pipeline diagnostics for debugging

this is diagnostic and not intended to be the primary runtime gate



CLI option

--allow-relaunch

default: disabled

enables cleanup and restart attempt for systemd-managed Weston runtime




---

Example usage

Strict mode:

./run.sh

Recovery mode:

./run.sh --allow-relaunch

With custom wait time:

WAIT_SECS=15 ./run.sh

With EGL diagnostics disabled:

VALIDATE_EGLINFO=0 ./run.sh

Strict mode with diagnostics disabled:

WAIT_SECS=15 VALIDATE_EGLINFO=0 ./run.sh

Recovery mode with custom wait:

WAIT_SECS=15 ./run.sh --allow-relaunch


---

Result files

The testcase writes:

Weston_Runtime_Preflight.res

Weston_Runtime_Preflight_run.log


Possible result values:

Weston_Runtime_Preflight PASS

Weston_Runtime_Preflight FAIL

Weston_Runtime_Preflight SKIP

---

Recommended execution order

Recommended gate order:
1. Weston_Runtime_Preflight

2. weston-simple-shm

3. weston-simple-egl

This ordering ensures runtime failures are caught before client-level failures are investigated.
