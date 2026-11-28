# check_ssh_command

Checks that the SSH client discovered through `PATH` is executable and reports
an OpenSSH version. If the selected command is a symbolic link and `readlink` is
available, the test follows the link chain and verifies that it resolves to an
executable. It accepts normal executables and packaging-specific alternatives
layouts. The test runs locally on the DUT.

## What this test checks

The test runs a bounded `ssh -V` invocation and requires OpenSSH version output.
It validates links starting from the PATH-discovered command rather than
assuming a fixed `/usr/bin/ssh` path or a particular alternatives target.

## Requirements

- An OpenSSH client must be installed in the image for this check to PASS.
- `readlink` is used to report and validate symbolic-link chains when available;
  it is not required when the selected SSH command already runs successfully.
- The testkit `Runner` directory, including `init_env` and shared utilities,
  must be kept together.
- The invocation's current directory must be writable for result and log files.

## Run

From this directory:

```sh
./run.sh
```

## Result

The result is written to `check_ssh_command.res`. If the optional SSH client is
not installed, the result is SKIP. The test does not make an SSH network
connection.
