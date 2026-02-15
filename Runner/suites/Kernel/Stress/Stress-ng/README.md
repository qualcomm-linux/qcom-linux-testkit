Scheduler/Stress Validation — stress-ng Runner

This README explains how to use the stress-ng–based validation script (run.sh) we wrote to exercise CPU, memory, I/O, and scheduler paths on embedded Linux systems (Yocto, Debian/Ubuntu, RT & non-RT kernels, NUMA/non-NUMA). It also covers how to get stress-ng onto your target (cross-compile or sideload).

---

What this test does

Launches stress-ng stressors sized to the current machine (online CPUs, RAM, and free disk) so we don’t overcommit tiny embedded boards.

Affines worker threads to every online CPU to make scheduler regressions obvious.

Applies fail criteria (max latency, OOM, I/O errors, stressor non-zero exits); returns non-zero exit code on failure for CI.

Saves a short summary and optional detailed logs; runs a dmesg scan via your functestlib.sh.

---

Requirements

stress-ng binary on the target

Standard tools: awk, grep, sed, cut, tr, sleep, date, head, getconf

(Optional) taskset, numactl for CPU pinning/NUMA; dd for I/O prechecks

Your test framework’s init_env and functestlib.sh (already handled by run.sh)

The runner reuses helpers from your existing functestlib.sh:

check_dependencies

find_test_case_by_name

log_info, log_warn, log_pass, log_fail, log_skip, log_error

scan_dmesg_errors

---

Getting stress-ng

Project: https://github.com/ColinIanKing/stress-ng

A) Native install (Debian/Ubuntu)

sudo apt-get update
sudo apt-get install -y stress-ng

B) Cross-compile (Yocto)

Add to your image or build it as an SDK tool:

In your layer, ensure stress-ng is available (meta-openembedded has a recipe in meta-oe on many branches).

Add to image:

IMAGE_INSTALL:append = " stress-ng"

Rebuild image / SDK:

bitbake core-image-minimal

C) Cross-compile (generic cmake/make)

On your host:

git clone https://github.com/ColinIanKing/stress-ng.git
cd stress-ng
make CROSS_COMPILE=aarch64-linux-gnu-  # or your triplet
# artifact is src/stress-ng

Copy the binary to your target (see “Sideload” below).

D) Android / BusyBox targets (sideload)

Push a statically linked stress-ng:

adb push stress-ng /usr/local/bin/
adb shell chmod 755 /usr/local/bin/stress-ng

Or with SSH:

scp stress-ng root@TARGET:/usr/local/bin/
ssh root@TARGET chmod 755 /usr/local/bin/stress-ng

---

run.sh quick start

From the test case directory (the script finds its own path via find_test_case_by_name):

./run.sh

By default, it:

Detects online CPUs, total RAM, and free disk.

Picks safe defaults: worker threads == online CPUs, memory workers sized to a small percentage of RAM, I/O workers sized to free space.

Runs for a sane duration (e.g., 5–10 minutes configurable).

Fails on stressor non-zero exit, OOM, major I/O error, or dmesg anomalies.

## Usage

```
Usage: ./run.sh [--p1 <sec>] [--p2 <sec>] [--mem-frac <pct>] [--disk-frac <pct>]
                [--cpu-list <list>] [--temp-limit <degC>] [--stressng "<args>"]
                [--repeat <N>] [--help]
```

### Options

| Option              | Description |
|---------------------|-------------|
| `--p1 <sec>`        | Phase 1 duration in seconds (default: 60) |
| `--p2 <sec>`        | Phase 2 duration in seconds (default: 60) |
| `--mem-frac <pct>`  | Percentage of total memory per worker (default: 15) |
| `--disk-frac <pct>` | Percentage of free disk space per worker (default: 5) |
| `--cpu-list <list>` | Comma-separated list or range of CPUs to stress |
| `--temp-limit <degC>` | Maximum temperature threshold |
| `--stressng "<args>"` | Additional arguments passed to stress-ng |
| `--repeat <N>`      | Repeat the entire test sequence N times (default: 1) |
| `--help`            | Show this help message and exit |

> Exact flags may differ slightly depending on your final script; the examples below assume the version we discussed (auto-sizing, affinity, fail criteria, reuse of functestlib.sh).

---

Example invocations

1) Quick CPU & memory smoke (auto sizing, 5 min)

./run.sh --duration 300 --stressors cpu,vm

2) Full platform shake (CPU+VM+I/O; pinned per-CPU)

./run.sh --duration 600 --stressors cpu,vm,io --logs

3) Limit footprint on small RAM systems

./run.sh --duration 180 --stressors vm --mem-pct 5

4) Pin workers to a subset of CPUs

./run.sh --cpu-list 0-3 --duration 240 --stressors cpu

5) Exercise only I/O with conservative disk usage

./run.sh --stressors io --disk-pct 3 --duration 120

6) Mixed with latency guardrail (if cyclic path is enabled)

./run.sh --stressors cpu,vm --max-latency-us 500 --duration 300

7) Run with default phases, repeated 3 times

./run.sh --repeat 3

8) Run on specific CPUs with temperature limit

./run.sh --cpu-list 0-3 --temp-limit 80

9) Run memory-intensive workload for 90 seconds per phase

./run.sh --mem-frac 30 --p1 90 --p2 90

10) Run stress-ng with a custom workload twice

./run.sh --repeat 2 --stressng "--cpu 4 --timeout 30 --verify"

---

What the script checks/fails on

stressor exit codes (any non-zero → FAIL)

Killed by OOM or ENOMEM patterns in stress-ng output → FAIL

I/O failures (EIO, read/write errors) → FAIL

dmesg anomalies via scan_dmesg_errors → WARN/FAIL as configured

(Optional) latency threshold if you also run a small cyclic step

Exit code:

0 = PASS (no failures, at least one stressor ran)

1 = FAIL (functional failure or threshold exceeded)

2 = SKIP (dependencies missing)

Artifacts:

stress-ng-summary.log (always)

stress-ng-*.log files (with --logs)

*.res result file for your harness

---

Sizing & affinity logic (how it stays safe)

CPU workers: ≤ online CPUs (default: one worker per online CPU)

Memory workers: uses a small percentage of total RAM (cap per worker), adjustable via --mem-pct

I/O workers: uses a small percentage of free disk (cap per worker), adjustable via --disk-pct

Affinity: default is on (each worker pinned to a specific online CPU); disable with --no-affine

NUMA: if numactl exists, the script prefers local node binding where appropriate; otherwise it simply CPU-affines.

---

Building stress-ng into your products

Yocto (image integration)

Add to your image recipe or local.conf:

IMAGE_INSTALL:append = " stress-ng"

Rebuild and flash your image.

Debian/Ubuntu rootfs

Bake into your rootfs recipe or install at first boot with a provisioning script:

apt-get update && apt-get install -y stress-ng

Sideload in CI

For CI smoke on development hardware:

scp stress-ng root@TARGET:/usr/local/bin/
ssh root@TARGET chmod 755 /usr/local/bin/stress-ng

---

Cross-compiling notes & tips

On ARM64 build hosts with Linaro/GCC toolchains:

make CROSS_COMPILE=aarch64-linux-gnu-
file src/stress-ng   # confirm aarch64 ELF

Prefer static if your target is minimal:

make static

Validate dependencies: run src/stress-ng --version on the host and then on the target after copy.

---

Troubleshooting

“stress-ng: command not found”
Not on PATH. Install natively, or place it in /usr/local/bin and chmod +x.

Out-of-memory or system lockups
Lower --mem-pct, shorten --duration, drop io on small/flash media.

I/O errors / read-only filesystems
Switch to a writable mount (e.g., /tmp) or adjust --disk-pct down to 1–2%.

High kernel latency on PREEMPT_RT
Start with CPU-only tests, then introduce memory/I/O slowly; use --max-latency-us to gate.

BusyBox environments
Ensure the script’s dependencies exist (the runner checks and SKIPs otherwise). You can pre-install missed tools or adjust the stress mix.

---

Security & safety

This script is destructive only in its I/O scratch area (e.g., under /tmp/stress-ng-io); it won’t touch other files.

It will refuse to over-allocate RAM/disk beyond configured caps.

Still, run on development hardware or staging boards when possible.

---

License

The test runner: BSD-3-Clause (Qualcomm Technologies, Inc. and/or its subsidiaries).

stress-ng is licensed upstream by its author; see its repository for details.

---

Appendix: Useful stress-ng commands (manual)

See available stressors:

stress-ng --class cpu --sequential 1 --metrics-brief --timeout 10

Run with maximum stress on all classes (dangerous on small boards):

stress-ng --aggressive --all 1 --timeout 60

Only memory:

stress-ng --vm 4 --vm-bytes 5% --vm-keep --timeout 120
