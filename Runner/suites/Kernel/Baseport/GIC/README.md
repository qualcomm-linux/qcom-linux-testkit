# GIC

Validate the arch_timer interrupt path on dynamically discovered online CPUs.
CPU column names are read from /proc/interrupts. Offline CPUs are excluded and
isolated CPUs are skipped by default. Each eligible CPU receives a pinned busy
workload and timer wakeup, avoiding assumptions about idle or tickless counters.
This does not claim to validate every GIC interrupt source.

```sh
cd Runner/suites/Kernel/Baseport/GIC
./run.sh
./run.sh --workload-seconds 2 --retries 2 --timeout 120
# Include isolated CPUs only when this interference is intended:
./run.sh --include-isolated --timeout 120
```

The image must provide taskset, a shell, sleep and base utilities. No runtime
installation or systemd is required. Missing taskset or no eligible CPUs is SKIP.
Invalid counters, failed workloads, exhausted time budget or counters that do
not advance under successful pinned work is FAIL. A real failure is not changed
to SKIP. The default `--timeout auto` budget scales with online CPU count,
workload duration and retries. An explicit positive timeout overrides it.

GIC defaults: GIC_WORKLOAD_SECONDS=2, GIC_RETRIES=2, GIC_TIMEOUT_SECONDS=auto.
Interrupts uses INTERRUPTS_WAIT_TIMEOUT_S=auto as the total budget and uses
INTERRUPTS_POLL_INTERVAL_S=2 as the active workload duration, with two attempts.
CLI values override these environment values.

Evidence is retained under CWD/results/GIC in a unique directory and replayed
to stdout. Results stay next to run.sh as GIC.res for existing LAVA plans.
Owned workload processes are stopped on completion and catchable signals.
