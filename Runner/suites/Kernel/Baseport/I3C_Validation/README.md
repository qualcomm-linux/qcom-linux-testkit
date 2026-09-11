# I3C validation

The Qualcomm Linux interface guide states that current I3C sensor use cases
run through aDSP, SLPI, or SDC firmware and do not expose a Linux I3C use case.
`I3C_Validation` therefore does not claim that a healthy sensor
subsystem proves the physical I3C transport.

The suite checks direct Linux evidence when a future or custom image exposes
it through runtime DT, `/sys/bus/i3c`, or `/sys/class/i3c-master`. I3C masters
are correlated with their parent controller driver, while I3C peripheral
devices require their own direct driver binding. It also records ADSP, SLPI,
SSC, or sensor remoteproc state as explicitly indirect diagnostic evidence.

## Run

```sh
cd Runner/suites/Kernel/Baseport/I3C_Validation
./run.sh
```

## Result policy

- `PASS`: direct Linux-visible I3C objects exist and are bound consistently.
- `FAIL`: Linux declares or exposes I3C objects that are missing or unbound.
- `SKIP`: no direct Linux I3C interface exists. Running firmware or sensors
  remain indirect evidence and do not convert this result to `PASS`.

## Diagnostics

The suite emits bounded direct-I3C and indirect remoteproc evidence to stdout.
Temporary evidence is removed when the run finishes.

Reference: [Qualcomm Linux I3C guide](https://docs.qualcomm.com/doc/80-70023-8/topic/i3c.html)
