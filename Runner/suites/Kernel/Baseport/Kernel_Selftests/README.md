# Installed kernel selftests

```sh
./run.sh
./run.sh --selftest-dir /kselftest --allowlist ./enabled_tests.list --timeout 300
```

SELFTEST_DIR, ALLOWLIST and TIMEOUT supply defaults for the corresponding CLI
options. Without a directory override, discovery checks /kselftest,
/usr/lib/kselftests and /usr/libexec/kselftests. The supplied allowlist remains the
default, no additional test collections run automatically.

Allowlist lines accept collection, collection:test or collection/test. Blank lines
and comments are ignored. An installed kselftest-list.txt expands collections.
The installed run_kselftest.sh is used for manifest-listed selections. Legacy
installations use run_test.sh for a selected collection, otherwise executable
*test files. Duplicate selections are removed and a collection harness is not
followed by rediscovery of its child binaries. A selected legacy collection harness takes precedence over explicit child
selections in that collection to prevent duplicate execution.

Requires existing test payloads, their runtime dependencies, shell utilities and
setsid for owned-session timeout cleanup. Nothing is installed or downloaded.
The test works without systemd. Missing optional payloads are SKIP. Existing tests
that fail, time out, emit an unexpected TAP/KTAP failure or cannot retain their
output are FAIL. Kselftest exit 4, zero-test plans and all-skipped TAP output are
SKIP. A supported non-TAP executable can PASS with exit zero. Exit failures take
precedence over success text. Catchable interruption fails the suite.

Each selection has a timeout in seconds. The owned process session is terminated
on timeout/completion with bounded TERM/KILL cleanup. A surviving process
retains ownership and makes the selection FAIL, without an unbounded wait.
Payloads run beside their installed fixtures, as required by upstream selftests.
Testkit logs and TMPDIR are under a unique kselftest-run.*
directory in invocation CWD. Upstream payloads may manage their own fixture files.
Kernel_Selftests.res remains beside run.sh for existing publishers. The
per-selection log, status, elapsed time and selection list remain under that run
directory. Use the provided YAML to
publish results even when a functional selection fails.

SPDX-License-Identifier: BSD-3-ClauseCopyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
