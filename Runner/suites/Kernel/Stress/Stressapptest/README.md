# Stressapptest Validation

This test validates system stability using [stressapptest](https://github.com/stressapptest/stressapptest).

## Overview

`stressapptest` is a stress-testing tool for CPU, memory, disk and networking, widely used in reliability testing for servers and embedded systems.

This wrapper script adds:

- **Cgroup-aware** memory sizing with safety guards
- **Safe** and **Strict** modes
- Post-run **dmesg** scanning (toggleable)
- Auto detection for CPUs / memory / mounts / IP
- Optional **auto** setup for disk and network tests
- Looping with per-loop and aggregate **JSON** summaries
- CPU pinning via **taskset** (if available) or **cpuset cgroups** (root, when supported)

## Prerequisites

- `stressapptest` must be installed and available in `PATH`.

Optional tools (the wrapper works without them, but features degrade gracefully):

- `taskset` (if present, used for CPU pinning)
- Writable **cpuset** cgroups (kernel feature; used for pinning when `taskset` is absent)
- `df` (for auto disk selection), `ip`/`hostname` (for auto network)
- `getconf`/**`nproc`** (or `/proc/cpuinfo`) for CPU counting

Build from source (typical host):
```bash
git clone https://github.com/stressapptest/stressapptest.git
cd stressapptest
./configure
make
sudo make install

Yocto image:

IMAGE_INSTALL:append = " stressapptest"

Side-load:

scp stressapptest user@target:/usr/local/bin/

Usage

./run.sh [options]

Options forwarded to stressapptest

(These map 1:1 to stressapptest flags.)

-M <MB> : Memory to test (default: auto; see memory sizing below)

-s <seconds> : Duration (default: 300; safe mode: 120)

-m <threads> : Memory copy threads (default: online CPUs; safe: ~half, up to 4)

-W : More CPU-stressful memory copy

-n <ipaddr> : Network client thread to <ipaddr>

--listen : Listen thread (for networking)

-f <filename> : Disk thread using <filename>

-F : Use libc memcpy

-l <logfile> : Log file (default: ./Stressapptest.log)

-v <level> : Verbosity 0–20 (default: 8)


Wrapper-specific options

--safe : Conservative sizing and CPU subset

--dry-run : Print the command that would run and exit

--strict : Fail run if severe dmesg issues are detected

--auto-net[=primary|loopback] : Start local listener and set -n automatically
(default mode: primary; falls back to loopback if no primary IP)

--auto-disk : Pick a writable mount and create a tempfile for -f

--auto : Shorthand for --auto-net --auto-disk


Memory sizing knobs (cgroup-aware)

--mem-pct=<P> : Percent of available RAM to use (default 60; safe: 35)

--mem-headroom-mb=<MB> : Keep this many MB free (default 256; safe: 512)

--mem-cap-mb=<MB> : Hard upper cap on -M

--require-mem-mb=<MB> : Refuse to run if computed target < MB


Control & reporting

--loops=<N> : Repeat test N times (default 1)

--loop-delay=<S> : Sleep S seconds between loops (default 0)

--json=<file> : Write line-delimited JSON per loop + final aggregate


> You can also supply most of these via environment variables (e.g. SAFE=1, MEM_CAP_MB=256, JSON_OUT=summary.json, LOOPS=3).



Examples

Run for 60s using auto sizing:

./run.sh -s 60

Safer profile (shorter, fewer threads, more headroom):

./run.sh --safe

Low-memory guard (refuse to run < 512 MB):

./run.sh --require-mem-mb=512

Cap memory and add extra headroom:

./run.sh --mem-cap-mb=256 --mem-headroom-mb=512

Multiple loops with JSON summary (and strict dmesg checks):

./run.sh --loops=5 --loop-delay=10 --json=summary.json --strict

Auto network + auto disk:

./run.sh --auto

Dry run (show exact command that would execute):

./run.sh --dry-run

CPU usage & pinning

The wrapper starts one stressapptest process with -m <threads> (defaults to online CPUs).
Those workers are threads—not separate processes—so ps typically shows a single process.

Pinning behavior:

1. If taskset exists → the process is pinned to the CPU list (logged as CPU pinning method: taskset (...)).


2. Else, if cpuset cgroups are available (and writable) → the wrapper confines the process to that CPU list
(logged as CPU pinning method: cgroup cpuset (...)).


3. Else → runs unpinned (logged as CPU pinning method: none).




How to verify

Count threads:

PID=$(pidof stressapptest)
grep '^Threads:' /proc/$PID/status
# or
ls -1 /proc/$PID/task | wc -l

See allowed CPUs:

PID=$(pidof stressapptest)
awk '/Cpus_allowed_list/ {print $2}' /proc/$PID/status

Check cpuset cgroup (if used):

cat /proc/$(pidof stressapptest)/cgroup
# then inspect matching cpuset.cpus file under /sys/fs/cgroup/...

Memory sizing (how it’s computed)

1. Determine available memory (prefer cgroup limit/usage if present; otherwise MemAvailable).


2. Take available * mem_pct (default 60%; --safe uses 35%).


3. Reserve headroom (--mem-headroom-mb; default 256 MB; safe: 512 MB).


4. Apply hard cap (--mem-cap-mb) if set.


5. Clamp to sane floor (≥ 16 MB) and not above “available minus headroom”.


6. If --require-mem-mb=N and computed < N, the run aborts.


The final value is passed to stressapptest as -M.

Output

Result: ./Stressapptest.res → PASS or FAIL

Log file: ./Stressapptest.log

If --json is used: line-delimited JSON entries per loop and a final aggregate.


Notes

By default you’ll see one stressapptest process; workers are threads (use /proc/$PID/task to list them).

Auto disk selection avoids RO/system mounts and picks the largest free writable mount for -f.

Auto network starts a local listen thread and chooses a primary IP (falling back to loopback).

---

License

The test runner: BSD-3-Clause (Qualcomm Technologies, Inc. and/or its subsidiaries).
stressapptest is licensed by its upstream author; see its repository for details.
