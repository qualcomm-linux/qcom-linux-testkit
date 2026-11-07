# Remoteproc validation

`remoteproc` is the unified passive health test for all registered remote
processors. It replaces the separate PIL remoteproc smoke test because both
tests inspected the same runtime remoteproc state.

The suite validates required sysfs attributes, accepts valid `running`,
`attached`, and non-autoboot `offline` states, rejects `crashed` states,
records the bound driver, checks image-provided firmware when it is exposed,
and captures relevant remoteproc and Qualcomm PAS kernel errors.

The test does not start, stop, or reset a remote processor. SMP2P remains a
separate suite because it validates SMEM edge configuration, doorbell routing,
interrupt registration, and the `qcom_smp2p` driver.

Invoke `./run.sh` from this directory or its absolute path from Runner.
`remoteproc.res` is always written beside `run.sh`, including PASS, FAIL and
SKIP paths. Logs are retained under `$PWD/results/remoteproc/run-*/` and kernel
errors are printed to stdout. Missing runtime instances skip cleanly. The test
uses the image's existing tools on Yocto, Debian, Ubuntu, CentOS and ramdisk.
Missing inventory tools skip before runtime inspection.
