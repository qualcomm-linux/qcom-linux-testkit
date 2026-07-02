# Memory_Map Performance Test

`Memory_Map` collects a Yocto/Linux memory snapshot from the target and prints a final memory component report to stdout. It is designed to run directly from the target serial shell or from an automation environment such as LAVA without requiring Ubuntu-only tools like `procrank` or `dmabuf_dump`.

The test uses only standard Linux interfaces where possible:

- `/proc/meminfo`
- `/proc/iomem`
- `/proc/*/smaps_rollup`
- `/proc/vmstat`, `/proc/zoneinfo`, `/proc/slabinfo`, `/proc/vmallocinfo`
- `/sys/kernel/debug/*` when debugfs is available
- `/sys/class/kgsl/*` when KGSL is available
- `/sys/block/zram*/mm_stat` when zram is available
- Device tree reserved-memory nodes, when present

---

## Quick start

From the Memory_Map suite directory on the target:

```sh
cd /tmp/Runner/suites/Performance/Memory_Map
./run.sh
```

A normal run prints progress messages while collection is happening, dumps selected debug summaries to stdout, and ends with a compact memory component table plus PASS/FAIL status.

Example final stdout table:

```text
------------------------------------------------------------
Mem Component (in MB)                Qualcomm Technologies, Inc. Robotics RB3gen2
------------------------------------------------------------
NHLOS                                593.96
Kernel Static                        214.01
Apps + Framework                     776.95
Free Mem                             4559.09
------------------------------------------------------------
MemTotal                             5336.04
System RAM                           5550.04
Slab                                 131.32
PageTables                           7.82
KernelStack                          6.15
VmallocUsed                          51.35
CMA Used                             0.00
Swap Used                            0.00
------------------------------------------------------------
```

Generated artifacts are stored under:

```text
./logs_Memory_Map/
```

The run is expected to end with:

```text
[PASS] ... Memory_Map: PASS
```

If the test cannot collect required memory information such as `/proc/meminfo`, it exits FAIL.

---

## Current run behavior

The current `run.sh` flow performs the following high-level steps:

1. Creates the output directory, usually `./logs_Memory_Map`.
2. Prints run configuration such as output directory, collection delay, and top process count.
3. Optionally prepares debugfs access.
4. Collects platform, boot, `/proc`, `/sys`, and debugfs memory artifacts.
5. Builds `memory_summary.txt` from `/proc/meminfo`.
6. Scans `/proc/*/smaps_rollup` for process memory accounting.
7. Generates summaries for reserved memory, DMA-BUF, zram, and KGSL.
8. Writes `memory_component_summary.txt`.
9. Prints selected artifacts and the final memory component summary to stdout.
10. Emits PASS/FAIL result.

The progress messages are intentionally printed before slower steps, especially the process memory scan, so users can see that the test is still active.

---

## Common usage

### Default run

```sh
./run.sh
```

Use this for normal collection and stdout reporting.

### Capture stdout to a file

```sh
./run.sh | tee Memory_Map_stdout.log
```

This is useful for local debugging or attaching the run output to a bug report.

### Inspect generated logs

```sh
ls -lh logs_Memory_Map
cat logs_Memory_Map/memory_component_summary.txt
cat logs_Memory_Map/memory_summary.txt
cat logs_Memory_Map/process_top_pss.txt
```

### Re-run after clearing old logs

```sh
rm -rf logs_Memory_Map Memory_Map_stdout_*.log
./run.sh
```

### Check command-line help

If the suite wrapper exposes command-line options, use:

```sh
./run.sh --help
```

Typical parameters controlled by the wrapper are:

- output directory
- collection delay
- top process count
- debugfs mount behavior
- verbose artifact printing

The library function behind the wrapper is:

```sh
perf_mem_collect_all <out_dir> <delay_secs> <top_process_count> <mount_debugfs> <verbose>
```

---

## What is collected

### Platform and boot context

| File | Purpose |
|---|---|
| `uname.txt` | Kernel and machine information from `uname -a` |
| `date.txt` | UTC timestamp at collection time |
| `proc_version.txt` | Kernel version string from `/proc/version` |
| `cmdline.txt` | Kernel boot command line |
| `cpuinfo.txt` | CPU information |
| `config.txt` | Kernel config from `/proc/config.gz`, if available |
| `uptime.txt` | Current uptime |

### Core memory snapshots

| File | Purpose |
|---|---|
| `meminfo.txt` | Raw `/proc/meminfo` |
| `memory_summary.txt` | Parsed memory key/value summary |
| `free.txt` | Output of `free` |
| `vmstat.txt` | Raw `/proc/vmstat` |
| `vmstat_cmd.txt` | Output of `vmstat` |
| `zoneinfo.txt` | Raw `/proc/zoneinfo` |
| `pagetypeinfo.txt` | Raw `/proc/pagetypeinfo` |
| `buddyinfo.txt` | Raw `/proc/buddyinfo` |
| `slabinfo.txt` | Raw `/proc/slabinfo` |
| `vmallocinfo.txt` | Raw `/proc/vmallocinfo` |
| `iomem.txt` | Raw `/proc/iomem`; used for System RAM calculation |
| `modules.txt` | Raw `/proc/modules` |
| `lsmod.txt` | Output of `lsmod`, if available |

### Process memory

| File | Purpose |
|---|---|
| `process_smaps_availability.txt` | Counts processes with readable `smaps_rollup` |
| `process_mem.tsv` | Per-process PSS/RSS/swap/thread summary |
| `process_top_pss.txt` | Top processes sorted by PSS |
| `ps_A.txt` | Output of `ps -A` |
| `ps_eT.txt` | Output of `ps -eT` |

### Reserved memory, DMA-BUF, zram, KGSL, debug

| File | Purpose |
|---|---|
| `reserved_memory_dt.tsv` | Device tree reserved-memory nodes |
| `memblock_reserved.txt` | Kernel debugfs memblock reserved regions, if available |
| `dma_buf_bufinfo.txt` | Raw DMA-BUF debugfs bufinfo, if available |
| `dmabuf_fd_owners.tsv` | Best-effort DMA-BUF file descriptor owners from `/proc/*/fd` |
| `dmabuf_summary.txt` | DMA-BUF availability and owner summary |
| `zram_summary.tsv` | zram accounting from `/sys/block/zram*/mm_stat` |
| `kgsl_summary.txt` | KGSL memory/debug information, if available |
| `ion_heap_system.txt` | Legacy ION heap debugfs information, if available |
| `tracing_buffer_total_size_kb.txt` | ftrace buffer size, if available |
| `mem_bank_state.txt` | Memory bank online/offline states |
| `dmesg.txt` | Kernel log captured during the run |
| `manifest.tsv` | Artifact name, size, and path index |

---

## Final report files

### `memory_component_summary.txt`

This is the main human-readable report. It is also printed to stdout at the end of the run.

It contains:

- NHLOS
- Kernel Static
- Apps + Framework
- Free Mem
- MemTotal
- System RAM
- Slab
- PageTables
- KernelStack
- VmallocUsed
- CMA Used
- Swap Used

### `memory_summary.txt`

This is a parsed key/value summary from `/proc/meminfo`. Example keys:

```text
MemTotal_kB=5464100
MemFree_kB=3824288
MemAvailable_kB=4668504
UsedApprox_kB=795596
Slab_kB=134476
PageTables_kB=8008
KernelStack_kB=6296
VmallocUsed_kB=52584
CmaUsed_kB=0
SwapUsed_kB=0
```

### `manifest.tsv`

This file lists every generated artifact, its byte size, and its path. It is useful when checking whether a debug file was collected or empty.

Example:

```text
meminfo    1448    ./logs_Memory_Map/meminfo.txt
iomem      10916   ./logs_Memory_Map/iomem.txt
memory_component_summary  848  ./logs_Memory_Map/memory_component_summary.txt
```

---

## Memory formulas used in the report

All final report values are printed in MB. Raw Linux counters are normally collected in kB and converted as:

```text
MB = kB / 1024
```

### 1. Total Linux memory, shown as `System RAM`

`System RAM` is calculated from `/proc/iomem` by summing every address range named `System RAM`.

Formula per range:

```text
range_size_bytes = end_address - start_address + 1
range_size_kB    = range_size_bytes / 1024
```

Total:

```text
System RAM = sum(all /proc/iomem "System RAM" ranges)
```

Example:

```text
83600000-839fffff : System RAM
```

```text
0x839fffff - 0x83600000 + 1 = 4194304 bytes = 4096 kB = 4 MB
```

### 2. Installed Total RAM

For the NHLOS calculation, the test resolves installed RAM by rounding the observed Linux memory up to a standard DRAM bucket. This is needed because Linux-visible memory is lower than the physical installed DRAM.

For example, when the platform has approximately 6 GB installed RAM:

```text
Installed Total RAM = 6144 MB
```

The installed total may differ by platform and memory configuration.

### 3. NHLOS / Non-Linux memory

NHLOS is calculated using the documented memory-map method:

```text
NHLOS = Installed Total RAM - System RAM
```

Where:

- `Installed Total RAM` is the physical DRAM size used for the platform.
- `System RAM` is the total Linux memory from `/proc/iomem`.

Example from the current run:

```text
Installed Total RAM = 6144.00 MB
System RAM          = 5550.04 MB
NHLOS               = 6144.00 - 5550.04 = 593.96 MB
```

NHLOS can vary between builds because the Linux System RAM ranges in `/proc/iomem` can change with DTB, kernel, firmware, bootloader, or memory reservation changes.

### 4. Kernel Static

Kernel Static is calculated using:

```text
Kernel Static = System RAM - MemTotal
```

Where:

- `System RAM` comes from `/proc/iomem`.
- `MemTotal` comes from `/proc/meminfo`.

Example from the current run:

```text
System RAM = 5550.04 MB
MemTotal   = 5336.04 MB
Kernel Static = 5550.04 - 5336.04 = 214.00 MB
```

This represents memory visible to Linux as System RAM but not available as normal allocatable memory in `MemTotal`.

### 5. Apps + Framework

Apps + Framework is calculated as the approximate used Linux memory:

```text
Apps + Framework = MemTotal - MemAvailable
```

The same value is written in `memory_summary.txt` as:

```text
UsedApprox_kB = MemTotal_kB - MemAvailable_kB
```

Example:

```text
MemTotal     = 5336.04 MB
MemAvailable = 4559.09 MB
Apps + Framework = 776.95 MB
```

This is a practical after-boot used-memory value. It includes userspace and framework memory plus other used Linux memory that is not currently available.

### 6. Free Mem

Free Mem uses `MemAvailable` rather than `MemFree`:

```text
Free Mem = MemAvailable
```

`MemAvailable` is preferred because it estimates memory available for new workloads without swapping, including reclaimable cache.

### 7. Slab

```text
Slab = Slab_kB from /proc/meminfo
```

### 8. PageTables

```text
PageTables = PageTables_kB from /proc/meminfo
```

### 9. KernelStack

```text
KernelStack = KernelStack_kB from /proc/meminfo
```

### 10. VmallocUsed

```text
VmallocUsed = VmallocUsed_kB from /proc/meminfo
```

### 11. CMA Used

```text
CMA Used = CmaTotal - CmaFree
```

If the kernel does not expose CMA counters, this may print `0.00`.

### 12. Swap Used

```text
Swap Used = SwapTotal - SwapFree
```

---

## Why NHLOS may not match older internal snapshots

NHLOS is calculated from the live board memory map. If `/proc/iomem` changes, NHLOS changes.

For example:

```text
NHLOS = Installed Total RAM - System RAM
```

If installed RAM is 6144 MB:

```text
System RAM = 5550.04 MB  -> NHLOS = 593.96 MB
System RAM = 5520.12 MB  -> NHLOS = 623.88 MB
```

So a difference of about 30 MB in `/proc/iomem` System RAM directly creates a 30 MB difference in NHLOS.

Common causes:

- Different DTB or reserved-memory layout
- Different kernel configuration
- Firmware or bootloader changes
- Different memory carveouts
- Different platform SKU or RAM population
- Updated boot image or board support package

To compare against an internal report, compare these files first:

```sh
cat logs_Memory_Map/iomem.txt | grep "System RAM"
cat logs_Memory_Map/meminfo.txt | grep MemTotal
cat logs_Memory_Map/memory_component_summary.txt
```

---

## Debugging guide

### NHLOS looks different from expected

Check:

```sh
grep "System RAM" logs_Memory_Map/iomem.txt
cat logs_Memory_Map/memory_component_summary.txt
```

Then calculate manually:

```text
NHLOS = Installed Total RAM - summed System RAM from /proc/iomem
```

### Kernel Static is zero or wrong

Kernel Static depends on `/proc/iomem` parsing. If `System RAM` is `0.00`, inspect:

```sh
cat logs_Memory_Map/iomem.txt
grep "System RAM" logs_Memory_Map/iomem.txt
```

Expected formula:

```text
Kernel Static = System RAM - MemTotal
```

If `/proc/iomem` is missing, hidden, unreadable, or format-changed, Kernel Static cannot be calculated correctly.

### Apps + Framework is higher than top process sum

This is expected. The final report uses:

```text
Apps + Framework = MemTotal - MemAvailable
```

The top process list is only a debug view of process PSS and does not necessarily equal the full used-memory approximation.

### DMA-BUF summary is empty

Check whether debugfs is mounted and whether the kernel exposes DMA-BUF bufinfo:

```sh
mount | grep debugfs
ls -l /sys/kernel/debug/dma_buf/bufinfo
cat logs_Memory_Map/dmabuf_summary.txt
```

Even if `dma_buf_bufinfo.txt` is unavailable, the test still tries to collect best-effort DMA-BUF FD owners from `/proc/*/fd`.

### KGSL summary is unavailable

KGSL is platform and kernel dependent. Check:

```sh
ls -l /sys/class/kgsl/kgsl
cat logs_Memory_Map/kgsl_summary.txt
```

If KGSL is not present, the test records `kgsl_available=no` and continues.

---

## PASS / FAIL behavior

The test is primarily a collection and reporting test.

Current expected behavior:

- PASS when required artifacts such as `/proc/meminfo` are collected and summary generation completes.
- FAIL when required memory collection fails, for example `meminfo.txt` is missing or empty.
- Optional artifacts can be missing without failing the test.

Examples of optional artifacts:

- debugfs memblock reserved data
- DMA-BUF debugfs data
- ION heap data
- KGSL data
- zram data

---

## Using results in automation

For automation systems, the most useful outputs are:

```text
stdout final memory component summary
logs_Memory_Map/memory_component_summary.txt
logs_Memory_Map/memory_summary.txt
logs_Memory_Map/manifest.tsv
logs_Memory_Map/process_top_pss.txt
logs_Memory_Map/iomem.txt
```

Recommended parsing target:

```sh
cat logs_Memory_Map/memory_component_summary.txt
```

Recommended debug bundle:

```sh
tar czf Memory_Map_logs.tgz logs_Memory_Map Memory_Map_stdout_*.log 2>/dev/null || \
tar czf Memory_Map_logs.tgz logs_Memory_Map
```

---

## Limitations

- This test does not require `procrank` or `dmabuf_dump`.
- Per-process memory uses `/proc/*/smaps_rollup`; if access is restricted, process accounting may be partial.
- DMA-BUF, KGSL, ION, and memblock details depend on debugfs/sysfs availability.
- NHLOS is calculated from the current live memory map, so values can differ between builds and DTBs.
- The final report is intended for after-boot snapshot comparison, not continuous memory leak tracking.

---

## Suggested comparison workflow

Run the test on the baseline build and the candidate build:

```sh
./run.sh
cp -r logs_Memory_Map logs_Memory_Map_baseline

# Boot candidate build, then:
./run.sh
cp -r logs_Memory_Map logs_Memory_Map_candidate
```

Compare the final reports:

```sh
diff -u \
  logs_Memory_Map_baseline/memory_component_summary.txt \
  logs_Memory_Map_candidate/memory_component_summary.txt
```

Compare raw memory maps if NHLOS or Kernel Static changed:

```sh
diff -u \
  logs_Memory_Map_baseline/iomem.txt \
  logs_Memory_Map_candidate/iomem.txt
```

Compare process memory if Apps + Framework changed:

```sh
diff -u \
  logs_Memory_Map_baseline/process_top_pss.txt \
  logs_Memory_Map_candidate/process_top_pss.txt
```

---

## Summary

`Memory_Map` provides a lightweight target-side memory report for Qualcomm Linux platforms. It collects raw evidence, prints a concise debug-friendly stdout report, and uses documented memory formulas:

```text
NHLOS          = Installed Total RAM - System RAM from /proc/iomem
Kernel Static  = System RAM from /proc/iomem - MemTotal from /proc/meminfo
Apps+Framework = MemTotal - MemAvailable
Free Mem       = MemAvailable
```

These formulas make the report easy to validate from the generated logs and easy to compare across builds.

