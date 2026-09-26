# QNN Net Run Version

Runs `qnn-net-run --version` as a focused Config 2/overlay readiness check and
retains the complete output. The executable is normally supplied by the target
image's `qnn-tools` package.

The suite never adds repositories or installs packages. If `qnn-net-run` is not
present during automatic discovery, the result is SKIP. An invalid explicit
path, timeout, nonzero command status, or empty version output is FAIL.

```sh
# Normal Config 2 validation
./run.sh

# Explicit binary
./run.sh --qnn-net-run /usr/bin/qnn-net-run

# Bounded custom timeout
./run.sh --timeout 20

# Environment equivalents
QNN_NET_RUN_BINARY=/usr/bin/qnn-net-run \
QNN_VERSION_TIMEOUT=20 \
./run.sh
```

Expected results:

- PASS when `qnn-net-run --version` succeeds and prints version evidence.
- SKIP when automatic discovery cannot find `qnn-net-run`.
- FAIL for an invalid explicit binary, timeout, nonzero status, or empty output.

The retained log is stored below
`results/AI_ML_QNN_Net_Run_Version/run-<timestamp>-<pid>/`.
