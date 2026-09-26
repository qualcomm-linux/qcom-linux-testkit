# DMA-BUF heap functional validation

`DMA_BUF_Heap_Validation` performs a bounded functional transaction through the
public Linux DMA-HEAP and DMA-BUF userspace APIs. It does not stop services,
change device permissions, access the network, install packages, or require a
compiler on the target.

For every selected heap, the repository Python client:

1. Opens the heap and allocates a page-aligned DMA-BUF.
2. Maps it with `MAP_SHARED` for CPU read and write access.
3. Brackets every CPU access with `DMA_BUF_IOCTL_SYNC` START and END requests.
4. Verifies that a new allocation is zero initialized.
5. Writes a deterministic byte pattern, unmaps it, maps the same DMA-BUF again,
   and verifies exact readback plus matching SHA-256 evidence.
6. Verifies mapping closure and DMA-BUF descriptor closure.
7. Allocates a second buffer, checks that it is zero initialized, releases all
   resources, and, when `/proc/self/fd` is available, confirms that the process
   descriptor count returned to its baseline.

This validates allocation, shared mapping, zeroing, CPU data integrity,
synchronization, and release. Device-node presence by itself is never reported
as functional success.

## Heap selection

The default `auto` policy inventories every `/dev/dma_heap/*` entry, but only
operates on these public Linux CPU-mappable heap names:

- `system`
- `system_cc_shared`
- `default_cma_region`
- legacy default-CMA names `reserved`, `linux,cma`, and `default-pool`

Other discovered heaps remain visible in stdout and in `dmabuf_heaps.tsv` with
the classification `product-policy-required`. Vendor, secure, and protected
heaps can intentionally reject CPU access, so there is deliberately no `all`
mode. Use an exact whitespace-separated list only when a product requirement
states that those named heaps are safe for CPU mapping. Commas are not list
separators because they are valid characters in names such as `linux,cma`.

```sh
./run.sh
./run.sh --heaps "system linux,cma"
./run.sh --heaps "qcom,system"
./run.sh --size 131072 --timeout 20
```

`qcom,system` above is an example of an explicit product-policy value, not a
portable default.

| Option | Environment | Default | Purpose |
|---|---|---:|---|
| `--heaps` | `DMABUF_HEAPS` | `auto` | Automatic public-name selection or exact product-policy names |
| `--size` | `DMABUF_ALLOCATION_BYTES` | `65536` | Runtime-page-aligned bytes, at most 16777216 |
| `--timeout` | `DMABUF_TIMEOUT` | `15` | Per-heap watchdog in seconds, at most 300 |

CLI values take precedence over environment values, which take precedence over
defaults. The startup `[DMABUF-POLICY]` line reports every selected value and
its source. At most 64 heaps can be selected, and the selected heap count
multiplied by the per-heap timeout must not exceed the fixed 300-second suite
budget.

## Distribution behavior

The same functional path is used on Yocto, Debian, Ubuntu, CentOS, and RHEL.
The test uses only image-provided components and never invokes `apt`, `dnf`,
`yum`, or `opkg`.

The image must provide Python 3 because the standard-library runner issues the
ioctls directly with `fcntl`, `struct`, and `mmap`. If Python 3 is absent, the
test retains the heap inventory and exits with a clean SKIP. No interpreter,
compiler, kernel selftest, or helper package is installed at runtime.

An exact requested heap that is malformed, absent, or not a character device
is a FAIL. A selected heap that is inaccessible or rejects allocation, mapping,
synchronization, or CPU access is also a FAIL. In automatic mode, absence of
the DMA-HEAP subsystem or absence of a public CPU-mappable heap name is a SKIP,
unless the running kernel explicitly enables the system heap but fails to
expose it.

## Results and evidence

- `PASS`: every selected heap completes the functional transaction and no
  relevant kernel error is found.
- `FAIL`: a declared system heap is absent, explicit selection is invalid, a
  selected transaction fails, data differs, cleanup leaks resources, or a
  relevant kernel error is captured.
- `SKIP`: DMA-HEAP is not applicable, only policy-required heaps are present in
  automatic mode, Python 3 is absent, or kernel-log access is unavailable for
  that health subcheck.

Look for `[DMABUF-POLICY]`, `[DMABUF-DISCOVERY]`, `[DMABUF-HEAP]`,
`[DMABUF-SELECTION]`, `[DMABUF-FUNCTIONAL]`, and `[DMABUF-REPORT]`. The printed
evidence directory retains the complete inventory, selected names, per-heap
stdout and TSV reports, and the shared kernel-log capture. Successful runner
output includes byte count, SHA-256, a bounded hexadecimal preview, mapping and
descriptor release evidence, and descriptor counts before and after.

The implementation follows these public Linux sources:

- `Documentation/userspace-api/dma-buf-heaps.rst`
- `include/uapi/linux/dma-heap.h`
- `include/uapi/linux/dma-buf.h`
- `tools/testing/selftests/dmabuf-heaps/dmabuf-heap.c`
