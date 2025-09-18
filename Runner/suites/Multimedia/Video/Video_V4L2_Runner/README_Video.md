# Iris V4L2 Video Test Scripts for Qualcomm Linux (Yocto)

**Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.**  
**SPDX-License-Identifier: BSD-3-Clause-Clear**

---

## Overview

These scripts automate validation of video **encoding** and **decoding** on Qualcomm Linux platforms running a Yocto-based rootfs.
They drive the public `iris_v4l2_test` app: <https://github.com/quic/v4l-video-test-app>.

The suite includes a **reboot-free video stack switcher** (upstream ↔ downstream), a **Kodiak (QCS6490/RB3gen2) firmware swap flow**, and robust **pre-flight checks** (rootfs size, network bootstrap, module sanity, device nodes).

---

## What’s New (since 2025‑10‑03)

- **Network stabilization delay (post-connect)**  
  After an interface comes up (DHCP/DNS), the runner now sleeps for a short grace period before the first TLS download to avoid immediate failures.
  - Env knob: `NET_STABILIZE_SLEEP` (default **5** seconds).

- **Downloader timeouts & retries (BusyBox‑friendly)**  
  Clip bundle downloads honor BusyBox wget timeouts/retries and perform a final TLS‑lenient attempt when the clock is not yet sane.
  - Env knobs: `WGET_TIMEOUT_SECS` (default **120**), `WGET_TRIES` (default **2**).

- **SKIP instead of FAIL when offline**  
  If the network is unreachable (or time is invalid for TLS) *and* required media clips are missing, **decode** cases are *SKIPPED* rather than failed. Encode cases continue to run.

- **App launch & inter‑test pacing**  
  To reduce flakiness from back‑to‑back runs, the runner adds small sleeps **before** launching `iris_v4l2_test` and **between** tests.
  - Env knobs: `VIDEO_APP_LAUNCH_SLEEP` (default **1** second), `VIDEO_INTER_TEST_SLEEP` (default **1** second).

- **Module operations: gentle waits & retries**  
  Module unload/load and blacklist scrubbing paths include short sleeps and a retry pass (`modprobe -r` retry with a small delay, 1s delays around remoteproc/module reloads). No new CLI needed.

- **CLI parity**  
  `--stack both` is supported to run the suite twice in one invocation (BASE/upstream pass then OVERLAY/downstream pass).

- **NEW (opt‑in) custom module sources**  
  You can now point the runner at alternative module locations without disturbing the default flow. If you **do nothing**, behavior is unchanged.  
  - `--ko-dir DIR[:DIR2:...]` — search these dir(s) for `.ko*` files when resolving modules.  
  - `--ko-tree ROOT` — use `modprobe -d ROOT` (expects `ROOT/lib/modules/$(uname -r)`).  
  - `--ko-tar FILE.tar[.gz|.xz|.zst]` — unpack once under `/run/iris_mods/$KVER`; auto-derives a `--ko-tree` or `--ko-dir`.  
  - `--ko-prefer-custom` — prefer custom sources before the system tree.  
  - The loader now logs **path resolution** and **load method** lines, e.g.:  
    - `resolve-path: qcom_iris via KO_DIRS => /data/kos/qcom_iris.ko`  
    - `load-path: modprobe(system): qcom_iris` / `load-path: insmod: /tmp/qcom_iris.ko`

---

## Features

- Pure **V4L2** driver-level tests using `iris_v4l2_test`
- **Encode** (YUV → H.264/H.265) and **Decode** (H.264/H.265/VP9 → YUV)
- **Yocto**-friendly, POSIX shell with BusyBox-safe paths
- Parse & run multiple JSON configs, auto-detect **encode/decode**
- **Auto-fetch** missing input clips (retries, BusyBox `wget` compatible)
- **Rootfs size guard** (auto‑resize) **before** fetching assets
- **Network bootstrap** (Ethernet → Wi‑Fi via `nmcli`/`wpa_supplicant`) when needed for downloads
- Timeout, repeat, dry-run, JUnit XML, dmesg triage
- **Stack switcher**: upstream ↔ downstream without reboot
- **Kodiak firmware live swap** with backup/restore helpers
- **udev refresh + prune** of stale device nodes
- **Waits/retries/sleeps** integrated across networking, downloads, module ops, and app launches (see next section)
- **(Opt‑in)** custom module sources with **non-exported** CLI flags (`--ko-*`); defaults remain untouched

---

## Stability waits, retries & timeouts (defaults & overrides)

These are **environment variables** (not user‑visible CLI flags) so your LAVA job YAML can stay minimal. All are **optional**—defaults are sane.

| Env Var | Default | Purpose |
|---|---:|---|
| `NET_STABILIZE_SLEEP` | `5` | Sleep (seconds) after link/IP assignment before first download. Applied also when already online, to debounce DNS/routes. |
| `WGET_TIMEOUT_SECS` | `120` | BusyBox wget timeout per attempt when fetching the clip bundle. |
| `WGET_TRIES` | `2` | BusyBox wget retry count for clip bundle. |
| `VIDEO_APP_LAUNCH_SLEEP` | `1` | Sleep (seconds) right before launching `iris_v4l2_test` for each case. |
| `VIDEO_INTER_TEST_SLEEP` | `1` | Sleep (seconds) between cases to allow device/udev to settle. |

> Notes  
> - If download **stalls** or the system clock is invalid for TLS, the runner re-checks network health and treats it as **offline** → decode cases **SKIP** (not FAIL).  
> - Module management includes small internal waits (e.g., `modprobe -r` retry after 200ms, 1s delays around remoteproc/module reloads). These are built‑in, no extra env required.

---

## Directory Layout

```bash
Runner/
├── suites/
│   └── Multimedia/
│       └── Video/
│           ├── README_Video.md
│           └── Video_V4L2_Runner/
│               ├── h264Decoder.json
│               ├── h265Decoder.json
│               ├── vp9Decoder.json
│               ├── h264Encoder.json
│               ├── h265Encoder.json
│               └── run.sh
└── utils/
    ├── functestlib.sh
    └── lib_video.sh
```

---

## Quick Start

```bash
git clone <this-repo>
cd <this-repo>

# Copy to target
scp -r Runner user@<target_ip>:<target_path>
ssh user@<target_ip>

cd <target_path>/Runner
./run-test.sh Video_V4L2_Runner
```

> Results land under: `Runner/suites/Multimedia/Video/Video_V4L2_Runner/`

---

## Runner CLI (run.sh)

| Option | Description |
|---|---|
| `--config path.json` | Run a specific config file |
| `--dir DIR` | Directory to search for configs |
| `--pattern GLOB` | Filter configs by glob pattern |
| `--extract-input-clips true|false` | Auto-fetch missing clips (default: `true`) |
| `--timeout S` | Timeout per test (default: `60`) |
| `--strict` | Treat dmesg warnings as failures |
| `--no-dmesg` | Disable dmesg scanning |
| `--max N` | Run at most `N` tests |
| `--stop-on-fail` | Abort suite on first failure |
| `--loglevel N` | Log level passed to `iris_v4l2_test` |
| `--repeat N` | Repeat each test `N` times |
| `--repeat-delay S` | Delay between repeats |
| `--repeat-policy all|any` | PASS if all runs pass, or any run passes |
| `--junit FILE` | Write JUnit XML |
| `--dry-run` | Print commands only |
| `--verbose` | Verbose runner logs |
| `--app /path/to/iris_v4l2_test` | Override test app path |
| `--stack auto|upstream|downstream|base|overlay|up|down|both` | Select target stack (use `both` for BASE→OVERLAY two-pass) |
| `--platform lemans|monaco|kodiak` | Force platform (else auto-detect) |
| `--downstream-fw PATH` | **Kodiak**: path to DS firmware (e.g. `vpu20_1v.mbn`) |
| `--ko-dir DIR[:DIR2:...]` | *(Opt‑in)* Additional directories to search for `.ko*` files during resolution |
| `--ko-tree ROOT` | *(Opt‑in)* Use `modprobe -d ROOT` (expects `ROOT/lib/modules/$(uname -r)`) |
| `--ko-tar FILE.tar[.gz|.xz|.zst]` | *(Opt‑in)* Unpack once into `/run/iris_mods/$KVER`; auto-derives `--ko-tree` or `--ko-dir` |
| `--ko-prefer-custom` | *(Opt‑in)* Prefer custom module sources (KO_DIRS/KO_TREE) before system |

> **Default remains unchanged.** If you omit all `--ko-*` flags, the runner uses the system module tree and `modinfo`/`modprobe` resolution only.

---

## Pre‑Flight: Rootfs Size & Network

### Auto‑resize before downloads
The runner calls `ensure_rootfs_min_size 2` **before** any download. If `/` is on `/dev/disk/by-partlabel/rootfs` and total size is below ~2 GiB, it executes:
```sh
resize2fs /dev/disk/by-partlabel/rootfs
```

### Network bootstrap (if offline)
If the target is offline when a clip bundle is needed:

1. Tries Ethernet DHCP (safe retries)
2. If **Wi‑Fi creds** are available, tries:
   - `nmcli dev wifi connect "<ssid>" password "<pass>" ifname <iface>`  
     If NetworkManager complains about missing key‑mgmt, it auto‑falls back to:  
     ```sh
     nmcli con add type wifi ifname <iface> con-name auto-<ssid> ssid "<ssid>" \
       wifi-sec.key-mgmt wpa-psk wifi-sec.psk "<pass>"
     nmcli con up auto-<ssid>
     ```
   - If still offline, uses `wpa_supplicant + udhcpc`

After connectivity, a **debounce wait** is applied:
```sh
# Default 5s (override via NET_STABILIZE_SLEEP)
sleep "${NET_STABILIZE_SLEEP:-5}"
```

**Provide credentials via:**
```sh
export SSID="WIFI_SSID"
export PASSWORD="WIFI_PASSWORD"
# or create ./ssid_list.txt with:  WIFI_SSID WIFI_PASSWORD
```

When network remains unreachable and clips are missing, **decode cases are SKIPPED** (not failed).

---

## Stack Selection & Validation

- **lemans/monaco**
  - **Upstream**: `qcom_iris` + `iris_vpu`
  - **Downstream**: `iris_vpu` only (and *no* `qcom_iris`)

- **kodiak**
  - **Upstream**: `venus_core`, `venus_dec`, `venus_enc`
  - **Downstream**: `iris_vpu`

The runner:
1. Prints **pre/post** module snapshots and any runtime/persistent modprobe blocks
2. Switches stacks without reboot (uses runtime blacklists under `/run/modprobe.d`)
3. **Refreshes** `/dev/video*` & `/dev/media*` with udev and **prunes** stale nodes
4. Applies small **waits/retries** around unload/load and de‑blacklist/blacklist paths

---

## Kodiak Firmware Flows

### Downstream (custom blob)
When `--stack downstream` and you pass `--downstream-fw /path/to/vpu20_1v.mbn`:
1. The blob is copied to: `/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn`
2. Previous image is backed up to: `/opt/video-fw-backups/vpu20_p1_gen2.mbn.<timestamp>.bak`
3. Runner tries **remoteproc restart**, then **module reload**, then **unbind/bind** (with short waits between steps)

### Upstream (restore a backup before switch)
When `--stack upstream` on **kodiak**, the runner tries to **restore a known‑good backup** to `/lib/firmware/qcom/vpu/vpu20_p1_gen2.mbn` **before** switching:
- Search order:
  1. `$VIDEO_FW_BACKUP_DIR` (default `/opt/video-fw-backups`), newest `vpu20_p1_gen2.mbn.*.bak`
  2. Legacy `/opt` patterns (e.g., `vpu20_p1_gen2.mbn.*.bak`)
- Then it attempts **remoteproc restart**; falls back as needed (with 1s waits).

**Tip:** If you maintain backups under a custom path:
```sh
export VIDEO_FW_BACKUP_DIR=/opt
./run.sh --platform kodiak --stack upstream
```

---

## Examples

### Minimal: run all configs with sane defaults
```sh
./run.sh
```

### Use `both` to run BASE then OVERLAY in one job
```sh
./run.sh --stack both
```

### Force downstream on lemans/monaco
```sh
./run.sh --stack downstream
```

### Force upstream on lemans/monaco
```sh
./run.sh --stack upstream
```

### Kodiak: downstream with custom firmware (live swap)
```sh
./run.sh --platform kodiak --stack downstream --downstream-fw /data/fw/vpu20_1v.mbn
```

### Kodiak: upstream with automatic backup restore
```sh
./run.sh --platform kodiak --stack upstream
# optionally pin the backup directory
VIDEO_FW_BACKUP_DIR=/opt ./run.sh --platform kodiak --stack upstream
```

### Ensure Wi‑Fi is used for downloads (if needed)
```sh
export SSID="WIFI_SSID"
export PASSWORD="WIFI_PASSWORD"
./run.sh --extract-input-clips true
```

### Use a specific app binary
```sh
./run.sh --app /data/vendor/iris_test_app/iris_v4l2_test --stack upstream
```

### Run only H.265 decode
```sh
./run.sh --pattern '*h265*Decoder.json'
```

### Override waits/timeouts (optional)
```sh
# Debounce network right after IP assignment
export NET_STABILIZE_SLEEP=8

# BusyBox wget tuning
export WGET_TIMEOUT_SECS=180
export WGET_TRIES=3

# Pacing iris app & tests
export VIDEO_APP_LAUNCH_SLEEP=2
export VIDEO_INTER_TEST_SLEEP=3

./run.sh --stack upstream
```

### (Opt‑in) Use custom module sources
**Default behavior is unchanged.** Only use these when you want to test modules from a non-system location.

#### Use a prepared tree (modprobe -d)
```sh
./run.sh --ko-tree /opt/custom-kmods --stack upstream
```

#### Search one or more directories of loose .ko files
```sh
./run.sh --ko-dir /data/kos:/mnt/usb/venus_kos --stack downstream
```

#### Prefer custom before system
```sh
./run.sh --ko-dir /sdcard/kos --ko-prefer-custom --stack upstream
```

#### Unpack a tarball of modules and auto-wire paths
```sh
./run.sh --ko-tar /sdcard/iris_kmods_${KVER}.tar.xz --stack upstream
# The runner unpacks into /run/iris_mods/$KVER and derives --ko-tree or --ko-dir.
```

> While resolving and loading modules, the runner logs lines like:
> - `resolve-path: venus_core via KO_TREE => /run/iris_mods/6.9.0/lib/modules/6.9.0/venus_core.ko`  
> - `load-path: insmod: /data/kos/qcom_iris.ko` or `load-path: modprobe(system): qcom_iris`

---

## Troubleshooting

- **“No backup firmware found” on kodiak upstream switch**  
  Ensure your backups exist under `/opt/video-fw-backups` **or** legacy `/opt` with a name like `vpu20_p1_gen2.mbn.<timestamp>.bak`, or set `VIDEO_FW_BACKUP_DIR`.

- **Upstream/Downstream mismatch**  
  Check the **pre/post module snapshots**; the runner will explicitly log which modules are present/absent.

- **No `/dev/video*`**  
  The runner triggers udev and prunes stale nodes; verify udev is available and rules are active.

- **Download fails**  
  Ensure time is sane (TLS), network is reachable, and provide Wi‑Fi creds via env or `ssid_list.txt`. The downloader uses BusyBox‑compatible flags with retries and a final TLS‑lenient attempt if needed. When the network remains unreachable, the runner **SKIPs** decode cases.

---

