# FastCV Module Functional Validation

This suite runs the Qualcomm `fastcv_test` module test using a binary and
matching data folder supplied by the user. These assets are not assumed to be
part of an installable package, root filesystem, or ramdisk.

The suite does not discover `fastcv_test` from `PATH` or download test data.
The operator must sideload both fixture assets and provide their locations
explicitly. On supported general-purpose distributions, the suite installs
missing FastCV runtime packages before executing a valid fixture.

## Required fixture

Provide:

- the path to the executable `fastcv_test` binary; and
- the directory containing the matching FastCV test data, including the
  required `FastCVTestTable.csv` control file.

Absolute paths are recommended because LAVA invokes the suite from its
repository directory. For example:

```sh
./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new
```

If neither path is supplied, the suite skips cleanly and prints the required
options. If only one path is supplied, the suite fails as an incomplete fixture
configuration. Invalid, unreadable, empty, or non-executable fixture paths also
fail once explicitly selected.

The `fastcv_test` executable and test-data directory must come from the same
FastCV release. Warnings such as `Unknown function ... in FastCVTestTable.csv`
usually indicate that the binary and test data do not match.

## Platform prerequisites

On Yocto and other image-managed systems, the suite performs no package-manager
operations. The validation ramdisk or image must already contain the required
FastCV runtime libraries.

On Debian and Ubuntu, the suite checks and installs these missing packages:

```text
qcom-fastcv-binaries libfastcvopt-dev
```

On CentOS Stream 10 and compatible Red Hat Enterprise Linux 10 aarch64 systems,
the suite first installs `epel-release`, then ensures that these two Qualcomm
CentOS 10 repositories are enabled:

```text
https://softwarecenter.qualcomm.com/nexus/rpm/centos/10/os/aarch64/
https://softwarecenter.qualcomm.com/nexus/rpm/centos/10/os/noarch/
```

When neither repository ID is already enabled, the suite creates
`/etc/yum.repos.d/qualcomm-linux.repo` with the
`qualcomm-linux-aarch64` and `qualcomm-linux-noarch` definitions from the RPM
image setup guide. The suite runs the documented metadata cleanup and cache
refresh before it checks and installs:

```text
qcom-fastcv-binaries libfastcvopt-devel
```

No installed package is upgraded. Package recovery needs root privileges,
network access, and working distro repositories only when a required package
or repository is missing. An incomplete pre-existing Qualcomm repository
configuration fails rather than being overwritten. Package preparation failure
is reported as a suite failure. The RPM path also verifies that the `epel`
repository is enabled after installing `epel-release`. Automatic repository
creation is rejected on other CentOS or Red Hat major versions because the
configured repository URLs are specific to version 10. When the complete
FastCV package set is already installed, the suite skips repository setup and
package-manager network operations.

These packages provide the FastCV runtime dependencies, but they do not provide
the `fastcv_test` module runner or its matching test data. Sideload both fixture
assets separately, for example:

```sh
install -d /var/fastcv
install -m 0755 ./fastcv_test /var/fastcv/fastcv_test
tar -xf ./test_data.tar.gz -C /var/fastcv
test -r /var/fastcv/test_data_new/FastCVTestTable.csv
```

Then run the suite. Runtime package recovery happens automatically:

```sh
sudo ./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new
```

`sudo` is needed only when the suite must add a repository or install a missing
package. LAVA target shells commonly already run as root.

## Default coverage

The default command is equivalent to:

```sh
/var/fastcv/fastcv_test /var/fastcv/test_data_new -t 6 -l 10 -m COLORYUV
/var/fastcv/fastcv_test /var/fastcv/test_data_new -t 6 -l 10 -m SCALE
/var/fastcv/fastcv_test /var/fastcv/test_data_new -t 6 -l 10 -m ARITHM
/var/fastcv/fastcv_test /var/fastcv/test_data_new -t 6 -l 10 -m BLUR
/var/fastcv/fastcv_test /var/fastcv/test_data_new -t 6 -l 10 -m TRNS
```

This bounded default covers representative color conversion, scaling,
arithmetic, filtering, and transformation operations on CPU and VENUM. Each
module runs as a separate invocation and must report its exact module PASS plus
both overall FIT PASS markers. Any module or overall FIT FAIL marker fails the
suite.

The complete native matrix remains available explicitly with `--targets 0
--modules all`. That mode enables every backend reported by the binary and
walks its complete module table. It can take substantially longer, and the
suite replays the retained command output after the invocation completes or
reaches its configured timeout.

Supported target selectors are:

| Value | Target requested by `fastcv_test` |
| --- | --- |
| `0` | All targets available to the binary |
| `2` | CPU |
| `4` | VENUM |
| `6` | CPU and VENUM |
| `8` | DSP |

Multiple targets may be supplied as a comma-separated list. Each target is a
separate bounded invocation.

## Focused module coverage

Use `--modules` with one module or a comma-separated module list. Each selected
module runs separately with `-m`. The runner accepts the two output dialects
observed from supported `fastcv_test` builds while retaining fail-closed
validation.

```sh
./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new \
    --targets 6 \
    --loops 10 \
    --modules COLORYUV,SCALE,ARITHM,BLUR,TRNS
```

The full output dialect reports all three summary markers:

```text
FASTCV_TEST, SCALE=>PASS
FIT:(FeatureName=>FASTCV, Overall=>PASS)
FASTCV_PROFILE, FIT:(FeatureName=>FASTCV, Overall=>PASS)
```

Some host-distribution builds emit only profiling records. For that dialect,
the runner requires at least one function-level profile PASS plus the final
profile FIT PASS:

```text
FASTCV_PROFILE, fcvScaleDownBy2u8 :: PASS, ...
FASTCV_PROFILE, FIT:(FeatureName=>FASTCV, Overall=>PASS)
```

Both dialects also require exit status zero and no function, module, profile,
or FIT failure marker. A profile FIT summary by itself is not sufficient.

Module names are validated as alphanumeric identifiers with `_`, `+`, or `-`
characters. The suite does not impose a static allowlist because the
sideloaded binary and data revision own the available module set.

Run one focused module on CPU and VENUM:

```sh
./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new \
    --targets 6 \
    --loops 10 \
    --modules COLORYUV
```

Run one focused module on DSP:

```sh
./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new \
    --targets 8 \
    --loops 10 \
    --modules SCALE
```

Run the complete native target and module matrix only in a suitably sized
scheduled job:

```sh
./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new \
    --targets 0 \
    --modules all \
    --loops 10 \
    --level 10 \
    --timeout 1800
```

## Options and precedence

The wrapper exposes the options that are actually parsed by the supplied
`fastcvTest.cpp` Linux implementation:

| Wrapper option | `fastcv_test` argument | Default and constraints |
| --- | --- | --- |
| `--binary PATH` | executable | Required external fixture path |
| `--data-dir DIR` | first positional argument | Required matching data directory |
| `--targets LIST` | `-t` | Comma-separated `0`, `2`, `4`, `6`, or `8`, default `6` |
| `--modules LIST` | `-m` | `all` or comma-separated modules, default `COLORYUV,SCALE,ARITHM,BLUR,TRNS` |
| `--loops COUNT` | `-l` | Positive integer, default `10` |
| `--level COUNT` | `-L` | Positive integer for all-module runs, default `10` |
| `--timeout SECONDS` | wrapper only | Positive per-invocation bound, default `300` |
| `--function NAME` | `-f` | Optional function, requires exactly one focused module |
| `--operation-mode N` | `-M` | Optional operation-mode bit value `0` through `8` |
| `--operation-tables-only 0\|1` | `-OPT` | Requires a nonzero operation mode |
| `--seed INTEGER` | `-s` | Optional RNG seed, a negative value requests a time-based seed |
| `--no-buffer-pool 0\|1` | `-nbp` | Use ordinary allocations instead of the internal buffer pool |
| `--prealloc-bytes N` | `-psb` | Positive scratch-buffer preallocation size |
| `--opencv 0\|1` | `-o` | Request OpenCV benchmark profiling when supported by the binary build |
| `--unit-only 0\|1` | `-U` | Disable performance profiling |
| `--profile-only 0\|1` | `-P` | Disable unit tests |
| `--exhaustive 0\|1` | `-E` | Enable exhaustive profiling-vector validation |
| `--resolution N` | `-S` | Profiling resolution index `0` through `7` |
| `--qdsp-heap 0\|1` | `-H` | Allocate QDSP test vectors from the ARM heap |
| `--element-alignment 0\|1` | `-AL` | Limit allocation alignment to element size |
| `--cache-flush 0\|1` | `-C` | Request cache flush/invalidate profiling, a no-op in the supplied non-Android source |
| `--without-operation-mode 0\|1` | `-TWOp` | Run the source's additional API checks without calling `fcvSetOperationMode` |

`--unit-only` and `--profile-only` are mutually exclusive.
`--no-buffer-pool` cannot be combined with `--prealloc-bytes`, because the
source applies preallocation only when its internal buffer pool is enabled.
When `--without-operation-mode 1` is selected, the suite also requires the
source's exact success marker for that additional path.

The supplied source rejects more than 14 total process arguments. The wrapper
counts the final argument vector and fails before execution when a requested
combination exceeds that source limit. This means all supported switches are
available, but they cannot all be enabled in one invocation. Split such
coverage across multiple suite executions.

Environment equivalents use the names in the YAML parameters:
`FASTCV_TEST_BINARY`, `FASTCV_TEST_DATA_DIR`, `FASTCV_TEST_TARGETS`,
`FASTCV_TEST_MODULES`, `FASTCV_TEST_LOOPS`, `FASTCV_TEST_LEVEL`,
`FASTCV_TEST_TIMEOUT`, `FASTCV_TEST_FUNCTION`,
`FASTCV_TEST_OPERATION_MODE`, `FASTCV_TEST_OPERATION_TABLES_ONLY`,
`FASTCV_TEST_SEED`, `FASTCV_TEST_NO_BUFFER_POOL`,
`FASTCV_TEST_PREALLOC_BYTES`, `FASTCV_TEST_OPENCV`,
`FASTCV_TEST_UNIT_ONLY`, `FASTCV_TEST_PROFILE_ONLY`,
`FASTCV_TEST_EXHAUSTIVE`, `FASTCV_TEST_RESOLUTION`,
`FASTCV_TEST_QDSP_HEAP`, `FASTCV_TEST_ELEMENT_ALIGNMENT`,
`FASTCV_TEST_CACHE_FLUSH`, and `FASTCV_TEST_WITHOUT_OPERATION_MODE`.
CLI values take precedence.

For example, a focused function run is:

```sh
./run.sh \
    --binary /var/fastcv/fastcv_test \
    --data-dir /var/fastcv/test_data_new \
    --targets 6 \
    --modules SCALE \
    --function fcvScaleDownBy2u8
```

The supplied source prints help for `-p`, `-e`, and `-DF`, but its argument
parser does not implement those switches. The wrapper intentionally does not
advertise them. `-AC` is compiled only for Android and is also outside this
Linux suite's interface.

The full matrix size is the number of targets multiplied by the number of
focused modules. The suite rejects selections above 64 invocations to keep an
accidental selector expansion from consuming an unbounded CI job. Keep large
matrices in an appropriate scheduled job and divide them across executions.

## Results

- **PASS**: every requested invocation exits zero and reports either the full
  module/FIT marker set or function-level profiling PASS evidence with the
  profile FIT summary. Unit-only mode requires the full non-profile marker set.
  Selected function and without-operation-mode evidence is required when
  applicable, and any official FAIL marker fails the invocation.
- **FAIL**: the explicit fixture is incomplete or invalid, configuration is
  malformed, required host-distribution package recovery fails, execution
  fails or times out, a FAIL marker is present, or required PASS markers are
  missing.
- **SKIP**: neither sideloaded asset path is provided. Kernel-log health is a
  separate SKIP if a DSP-capable target was selected but logs are unavailable.

## Evidence

Each run stores evidence below:

```text
results/FastCV_Module_Functional_Validation/run-<timestamp>-<pid>/
```

Evidence includes binary metadata, a complete data-file listing, normalized
target and module selections, one complete log per invocation, and one retained
FastRPC kernel-log snapshot when target `0` or `8` is selected.
