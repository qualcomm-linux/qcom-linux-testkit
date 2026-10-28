# Pre_Suspend_Check

Records the state of the machine before it is suspended, so that
[Resume_Check](../Resume_Check/README.md) can tell afterwards whether a
suspend/resume cycle really happened and whether it introduced any errors.

This test does **not** suspend the machine. Suspend has to be triggered
outside of the LAVA test shell (for example from an interactive action),
because the shell that issues it does not return an exit code.

## Flow

1. Run `Pre_Suspend_Check`.
2. Suspend the machine (e.g. `echo mem > /sys/power/state`, `rtcwake`, ...).
3. Wake it up and run `Resume_Check`.

## What it checks

| Check | Effect on the result |
|---|---|
| `/sys/power/state` exists | FAIL when missing |
| `SLEEP_MODE` offered by `/sys/power/state` (when set) | FAIL when missing |
| `SUSPEND_MODE` offered by `/sys/power/mem_sleep` (when set and not `default`) | FAIL when missing |
| `SLEEP_MODE` able to run `SUSPEND_MODE` (e.g. `freeze` is always s2idle) | FAIL on a conflict |
| Valid options | FAIL on an unknown option, mode or sleep state |
| State file written | FAIL when it cannot be written |
| `boot_id`, `/sys/power/suspend_stats`, kernel log readable | warning only, weakens what Resume_Check can verify |

The recorded state is saved to `/tmp/pre-suspend-state.txt` by default.
`/tmp` is tmpfs on most images, so a reboot discards the baseline.

| Field | Meaning |
|---|---|
| `BOOT_ID` | identifies the running kernel, a reboot changes it |
| `UPTIME` | seconds since boot |
| `SUSPEND_SUCCESS`, `SUSPEND_FAIL` | `/sys/power/suspend_stats` cycle counters |
| `FAILED_<phase>` | one per `/sys/power/suspend_stats/failed_<phase>` counter |
| `DMESG_BOUNDARY` | printk timestamp of the newest kernel log record |

An empty field means the value could not be measured, and Resume_Check
treats it as unavailable rather than zero. `DMESG_BOUNDARY` lets
Resume_Check scan only the records logged after this test, and tell when
the ring buffer has dropped some of them; it is empty when the kernel log
has no timestamps.

## Result

A single result, `Pre_Suspend_Check PASS|FAIL`, is written to
`Pre_Suspend_Check.res`. With `--suspend-mode MODE` the result is named
`Pre_Suspend_Check_MODE` instead, e.g. `Pre_Suspend_Check_s2idle`, so that
the result shows which mode the job tests. Invalid options are reported as a
FAIL under the same name, and the result of an earlier run is removed first.

## Usage

```sh
./run.sh [--state-file PATH] [--sleep-mode mem|freeze|standby|disk] \
         [--suspend-mode default|s2idle|shallow|deep]
```

The same values can be passed through the `STATE_FILE`, `SLEEP_MODE` and
`SUSPEND_MODE` environment variables; command line options take precedence.

## Example LAVA job

The suspend cannot run inside a LAVA test shell, because the shell that
issues it does not return until the machine resumes. The job below starts
it from an interactive test action, in the background, and waits for the
kernel's `PM: suspend entry`. The lab then wakes the board with the
device's `wake_up` user command and gives it time to resume with
`wait_resume`; both have to be defined in the device dictionary (for
example a power button press and a `sleep`). The marker printed once the
write to `/sys/power/state` returns confirms the resume, and the test
shell prompt is restored before Resume_Check runs.

Replace the deploy and boot actions, the device type and the shell prompt
with the ones for your board. `SUSPEND_MODE` selects the variant; the
example uses `s2idle`. For `default`, drop the `grep` check and the write
to `/sys/power/mem_sleep` from the suspend command.

```yaml
device_type: <device-type>
job_name: suspend-resume s2idle
timeouts:
  job:
    minutes: 70
  connection:
    minutes: 2
priority: medium
visibility: public

actions:
# Deploy and boot the image as for any other test job, for example:
- deploy:
    to: <deploy-method>
    # ...
- boot:
    method: <boot-method>
    prompts:
    - root@(.*):[/~]#
    # ...

- test:
    timeout:
      minutes: 5
    definitions:
    - from: git
      name: pre-suspend-check-s2idle
      repository: https://github.com/qualcomm-linux/qcom-linux-testkit
      path: Runner/suites/Kernel/Baseport/Pre_Suspend_Check/Pre_Suspend_Check.yaml
      parameters:
        SUSPEND_MODE: s2idle
      expected:
      - Pre_Suspend_Check_s2idle

# Suspend in the background, five seconds later, so that the console stays
# usable. The console loglevel is raised for the cycle so that the kernel's
# "PM: suspend entry" reaches the console. The arithmetic keeps the echo of
# the command itself from matching the markers.
- test:
    interactive:
    - name: suspend-s2idle
      prompts:
      - 'PM: suspend entry'
      script:
      - name: suspend-s2idle-entry
        command: '(sleep 5; grep -qw s2idle /sys/power/mem_sleep || { echo "lava-suspend-unsupported-$((2 + 1)): $(cat /sys/power/mem_sleep)"; exit; }; read level rest < /proc/sys/kernel/printk; echo 7 > /proc/sys/kernel/printk; sync; echo s2idle > /sys/power/mem_sleep && echo mem > /sys/power/state; ret=$?; echo $level > /proc/sys/kernel/printk; [ $ret = 0 ] && echo "lava-resumed-$((2 + 1))" || echo "lava-suspend-failed-$((2 + 1))") &'
        failures:
        - message: 'lava-suspend-unsupported-3'
          exception: TestError
          error: 's2idle not in /sys/power/mem_sleep'
        - message: 'lava-suspend-failed-3'
          exception: TestError
          error: 'echo mem > /sys/power/state failed'
    timeout:
      minutes: 1

- command:
    name: wait_resume
    timeout:
      minutes: 2
- command:
    name: wake_up
    timeout:
      minutes: 2
- command:
    name: wait_resume
    timeout:
      minutes: 2

# Wait for the resume marker, then hand the test shell its prompt again.
- test:
    interactive:
    - name: resume-s2idle
      prompts:
      - 'lava-resumed-3'
      script:
      - name: resume-s2idle-returned
        command:
        failures:
        - message: 'lava-suspend-failed-3'
          exception: TestError
          error: 'echo mem > /sys/power/state failed'
    - name: shell-s2idle
      prompts:
      - "root@(.*):[/~]#"
      script:
      - name: shell-s2idle-prompt
        command: ''
    timeout:
      minutes: 2

- test:
    timeout:
      minutes: 5
    definitions:
    - from: git
      name: resume-check-s2idle
      repository: https://github.com/qualcomm-linux/qcom-linux-testkit
      path: Runner/suites/Kernel/Baseport/Resume_Check/Resume_Check.yaml
      parameters:
        SUSPEND_MODE: s2idle
      expected:
      - Resume_Check_s2idle
```
