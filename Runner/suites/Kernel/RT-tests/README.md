# Shared RT runtime validation

Existing client arguments and KPI thresholds remain suite-specific. These shared
checks apply to Cyclictest, CyclicDeadline, OSLat, Hackbench, PI_Stress, PMQTest,
PTSEMATest, RTMigrateTest, SSDD, SVSematest, SignalTest and SigwaitTest.

Without a background command or CPU overrides, clients keep their existing
invocation and inherited affinity. No tool installation or systemd is required.
Runtime RT state uses /sys/kernel/realtime then CONFIG_PREEMPT_RT when available.
Unknown RT state is diagnostic, not an automatic functional failure. Clocksource,
timer migration, per-policy governor/limits and idle policy are logged when exposed.

An explicitly supplied background command must remain alive for the measurement.
Use a foreground load command, not one that daemonizes or backgrounds itself.
Startup failure or early completion, including exit zero before measurement ends,
causes FAIL. The load runs in a private session using image-provided setsid.
Owned descendants are terminated after measurement with TERM and then KILL if
needed. Cleanup has a finite wait after each signal. A surviving session causes
FAIL and retains ownership for a later cleanup attempt. Exited zombies do not
count as active workloads. The command is a user-provided shell command, never a parsed log string.
Logs/status remain in a unique rt-background.* directory in invocation CWD.

Optional RT_CPUS and BG_CPUS are Linux CPU lists, such as a single CPU, a range,
or comma-separated entries. They must be online and allowed to the invoking process.
When both are supplied they must be disjoint. BG_CPUS requires a background
command. An absent mask preserves inherited affinity and does not promise CPU
isolation. taskset is required only for explicit masks. Do not combine RT_CPUS
with client-native affinity/SMP options that can override the mask.

Example after selecting suitable CPUs from /proc/self/status on the DUT:

```sh
# Set these to discovered, disjoint CPUs allowed on this DUT.
RT_CPUS="$selected_rt_cpus" BG_CPUS="$selected_load_cpus" ./run.sh \
    --duration 30s --background-cmd 'stress-ng --cpu 1'
```

The example requires stress-ng already supplied in the image. No particular
workload binary is installed automatically. Existing native affinity options
remain available when RT_CPUS is unset. Each suite YAML exposes the two masks.
The LAVA result file remains beside each run.sh. Default measurement directories,
background evidence and temporary files are under invocation CWD.
Explicit --out locations retain the existing interface. Fresh JSON is required
for each invocation so an old report cannot make a rerun pass.
