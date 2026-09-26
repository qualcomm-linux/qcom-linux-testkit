#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Exercise the public Linux DMA-HEAP and DMA-BUF CPU-access UAPI."""

import argparse
import errno
import fcntl
import hashlib
import mmap
import os
import stat
import struct
import sys


IOC_NRBITS = 8
IOC_TYPEBITS = 8
IOC_SIZEBITS = 14
IOC_NRSHIFT = 0
IOC_TYPESHIFT = IOC_NRSHIFT + IOC_NRBITS
IOC_SIZESHIFT = IOC_TYPESHIFT + IOC_TYPEBITS
IOC_DIRSHIFT = IOC_SIZESHIFT + IOC_SIZEBITS
IOC_WRITE = 1
IOC_READ = 2

DMA_HEAP_ALLOCATION_FORMAT = "=QIIQ"
DMA_BUF_SYNC_FORMAT = "=Q"
DMA_HEAP_IOCTL_ALLOC = (
    ((IOC_READ | IOC_WRITE) << IOC_DIRSHIFT)
    | (ord("H") << IOC_TYPESHIFT)
    | (0 << IOC_NRSHIFT)
    | (struct.calcsize(DMA_HEAP_ALLOCATION_FORMAT) << IOC_SIZESHIFT)
)
DMA_BUF_IOCTL_SYNC = (
    (IOC_WRITE << IOC_DIRSHIFT)
    | (ord("b") << IOC_TYPESHIFT)
    | (0 << IOC_NRSHIFT)
    | (struct.calcsize(DMA_BUF_SYNC_FORMAT) << IOC_SIZESHIFT)
)
DMA_BUF_SYNC_READ = 1
DMA_BUF_SYNC_WRITE = 2
DMA_BUF_SYNC_END = 4
MAX_ALLOCATION_BYTES = 16 * 1024 * 1024
PREVIEW_BYTES = 32


# report_value(value)
# Returns VALUE as one printable TSV field with newlines and tabs replaced. It
# emits no output and has no side effects.
def report_value(value):
    return str(value).replace("\r", " ").replace("\n", " ").replace("\t", " ")


# write_report(path, report)
# Replaces PATH with a stable two-column TSV representation of REPORT. It has
# no return value and creates the parent directory when required.
def write_report(path, report):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as report_file:
        report_file.write("key\tvalue\n")
        for key, value in report.items():
            report_file.write(report_value(key) + "\t" + report_value(value) + "\n")


# count_open_fds()
# Returns the number of descriptors visible in /proc/self/fd, or -1 when procfs
# is unavailable. It emits no output and has no persistent side effects.
def count_open_fds():
    try:
        return len(os.listdir("/proc/self/fd"))
    except OSError:
        return -1


# sync_buffer(buffer_fd, flags)
# Issues DMA_BUF_IOCTL_SYNC for BUFFER_FD with one unsigned 64-bit FLAGS value.
# It returns no value, emits no output, and raises OSError on an ioctl failure.
def sync_buffer(buffer_fd, flags):
    request = bytearray(struct.pack(DMA_BUF_SYNC_FORMAT, flags))
    fcntl.ioctl(buffer_fd, DMA_BUF_IOCTL_SYNC, request, True)


# allocate_buffer(heap_fd, length)
# Allocates LENGTH bytes from an open DMA heap and returns the DMA-BUF fd. It
# requests read/write plus close-on-exec access and raises OSError on failure.
def allocate_buffer(heap_fd, length):
    fd_flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
    request = bytearray(
        struct.pack(
            DMA_HEAP_ALLOCATION_FORMAT,
            length,
            0,
            fd_flags,
            0,
        )
    )
    fcntl.ioctl(heap_fd, DMA_HEAP_IOCTL_ALLOC, request, True)
    buffer_fd = struct.unpack(DMA_HEAP_ALLOCATION_FORMAT, request)[1]
    try:
        os.fstat(buffer_fd)
    except OSError as error:
        raise RuntimeError(
            "DMA_HEAP_IOCTL_ALLOC returned an unusable fd: " + str(error)
        ) from error
    return buffer_fd


# verify_closed_fd(buffer_fd)
# Confirms that BUFFER_FD is invalid after close. It returns True only for
# EBADF, emits no output, and has no side effects.
def verify_closed_fd(buffer_fd):
    try:
        os.fstat(buffer_fd)
    except OSError as error:
        return error.errno == errno.EBADF
    return False


# first_mismatch(expected, observed)
# Returns the first differing byte offset, -1 for equal byte strings, or the
# common length when only their lengths differ. It emits no output.
def first_mismatch(expected, observed):
    for offset, values in enumerate(zip(expected, observed)):
        if values[0] != values[1]:
            return offset
    if len(expected) != len(observed):
        return min(len(expected), len(observed))
    return -1


# exercise_heap(heap_path, length, report)
# Opens HEAP_PATH, performs two bounded allocations, validates initial zeroing,
# shared mmap read/write integrity and DMA_BUF_IOCTL_SYNC bracketing, closes and
# verifies every map and fd, and updates REPORT. It returns no value, emits no
# output, and raises RuntimeError when the transaction or cleanup fails.
def exercise_heap(heap_path, length, report):
    baseline_fds = count_open_fds()
    heap_fd = -1
    first_fd = -1
    second_fd = -1
    write_map = None
    read_map = None
    zero_map = None
    active_sync_fd = -1
    active_sync_flags = 0
    operation_error = None
    cleanup_errors = []

    pattern = bytes(((offset * 37 + 11) & 0xFF) for offset in range(length))
    expected_digest = hashlib.sha256(pattern).hexdigest()
    report["pattern_sha256"] = expected_digest
    report["pattern_preview_hex"] = pattern[:PREVIEW_BYTES].hex()
    report["fd_count_before"] = baseline_fds

    try:
        report["phase"] = "open-heap"
        heap_fd = os.open(
            heap_path,
            os.O_RDWR | getattr(os, "O_CLOEXEC", 0),
        )

        report["phase"] = "allocate-first-buffer"
        first_fd = allocate_buffer(heap_fd, length)
        first_fd_flags = fcntl.fcntl(first_fd, fcntl.F_GETFD)
        report["first_fd_cloexec"] = (
            "yes" if first_fd_flags & fcntl.FD_CLOEXEC else "no"
        )
        if report["first_fd_cloexec"] != "yes":
            raise RuntimeError("allocated DMA-BUF fd does not have close-on-exec")

        report["phase"] = "map-first-buffer"
        write_map = mmap.mmap(
            first_fd,
            length,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )

        report["phase"] = "check-initial-zero"
        sync_buffer(first_fd, DMA_BUF_SYNC_READ)
        active_sync_fd = first_fd
        active_sync_flags = DMA_BUF_SYNC_READ
        initially_zero = write_map[:] == bytes(length)
        sync_buffer(first_fd, DMA_BUF_SYNC_READ | DMA_BUF_SYNC_END)
        active_sync_fd = -1
        active_sync_flags = 0
        report["initial_zero"] = "yes" if initially_zero else "no"
        if not initially_zero:
            raise RuntimeError("new DMA-BUF allocation was not zero initialized")

        report["phase"] = "write-pattern"
        sync_buffer(first_fd, DMA_BUF_SYNC_WRITE)
        active_sync_fd = first_fd
        active_sync_flags = DMA_BUF_SYNC_WRITE
        write_map[:] = pattern
        sync_buffer(first_fd, DMA_BUF_SYNC_WRITE | DMA_BUF_SYNC_END)
        active_sync_fd = -1
        active_sync_flags = 0

        report["phase"] = "unmap-written-buffer"
        write_map.close()
        if not write_map.closed:
            raise RuntimeError("first DMA-BUF mapping remained open after close")
        report["write_mapping_closed"] = "yes"
        write_map = None

        report["phase"] = "remap-and-read-pattern"
        read_map = mmap.mmap(
            first_fd,
            length,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        sync_buffer(first_fd, DMA_BUF_SYNC_READ)
        active_sync_fd = first_fd
        active_sync_flags = DMA_BUF_SYNC_READ
        observed = read_map[:]
        sync_buffer(first_fd, DMA_BUF_SYNC_READ | DMA_BUF_SYNC_END)
        active_sync_fd = -1
        active_sync_flags = 0
        observed_digest = hashlib.sha256(observed).hexdigest()
        mismatch_offset = first_mismatch(pattern, observed)
        report["readback_sha256"] = observed_digest
        report["readback_preview_hex"] = observed[:PREVIEW_BYTES].hex()
        report["mismatch_offset"] = mismatch_offset
        if mismatch_offset >= 0:
            raise RuntimeError(
                "DMA-BUF readback mismatch at offset="
                + str(mismatch_offset)
                + " expected_sha256="
                + expected_digest
                + " observed_sha256="
                + observed_digest
            )

        report["phase"] = "unmap-and-close-first-buffer"
        read_map.close()
        if not read_map.closed:
            raise RuntimeError("readback DMA-BUF mapping remained open after close")
        report["read_mapping_closed"] = "yes"
        read_map = None
        closed_first_fd = first_fd
        os.close(first_fd)
        first_fd = -1
        if not verify_closed_fd(closed_first_fd):
            raise RuntimeError("first DMA-BUF fd remained valid after close")
        report["first_fd_closed"] = "yes"

        report["phase"] = "allocate-second-buffer"
        second_fd = allocate_buffer(heap_fd, length)
        zero_map = mmap.mmap(
            second_fd,
            length,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
        )
        sync_buffer(second_fd, DMA_BUF_SYNC_READ)
        active_sync_fd = second_fd
        active_sync_flags = DMA_BUF_SYNC_READ
        second_zero = zero_map[:] == bytes(length)
        sync_buffer(second_fd, DMA_BUF_SYNC_READ | DMA_BUF_SYNC_END)
        active_sync_fd = -1
        active_sync_flags = 0
        report["second_allocation_zero"] = "yes" if second_zero else "no"
        if not second_zero:
            raise RuntimeError("second DMA-BUF allocation was not zero initialized")

        report["phase"] = "release-second-buffer"
        zero_map.close()
        if not zero_map.closed:
            raise RuntimeError("second DMA-BUF mapping remained open after close")
        report["zero_mapping_closed"] = "yes"
        zero_map = None
        closed_second_fd = second_fd
        os.close(second_fd)
        second_fd = -1
        if not verify_closed_fd(closed_second_fd):
            raise RuntimeError("second DMA-BUF fd remained valid after close")
        report["second_fd_closed"] = "yes"

        closed_heap_fd = heap_fd
        os.close(heap_fd)
        heap_fd = -1
        if not verify_closed_fd(closed_heap_fd):
            raise RuntimeError("DMA heap fd remained valid after close")
        report["heap_fd_closed"] = "yes"
        report["phase"] = "transaction-complete"
    except Exception as error:
        operation_error = error
    finally:
        if active_sync_fd >= 0:
            try:
                sync_buffer(active_sync_fd, active_sync_flags | DMA_BUF_SYNC_END)
            except OSError as error:
                cleanup_errors.append("end-active-cpu-access=" + str(error))

        for mapping_name, mapping in (
            ("write-map", write_map),
            ("read-map", read_map),
            ("zero-map", zero_map),
        ):
            if mapping is not None and not mapping.closed:
                try:
                    mapping.close()
                except (BufferError, OSError) as error:
                    cleanup_errors.append(mapping_name + "=" + str(error))
                else:
                    if not mapping.closed:
                        cleanup_errors.append(mapping_name + "=remained-open")

        for fd_name, file_descriptor in (
            ("first-fd", first_fd),
            ("second-fd", second_fd),
            ("heap-fd", heap_fd),
        ):
            if file_descriptor >= 0:
                try:
                    os.close(file_descriptor)
                except OSError as error:
                    cleanup_errors.append(fd_name + "=" + str(error))
                else:
                    if not verify_closed_fd(file_descriptor):
                        cleanup_errors.append(fd_name + "=remained-open")

    final_fds = count_open_fds()
    report["fd_count_after"] = final_fds
    if baseline_fds >= 0 and final_fds >= 0 and baseline_fds != final_fds:
        cleanup_errors.append(
            "descriptor-count-before="
            + str(baseline_fds)
            + "-after="
            + str(final_fds)
        )

    report["cleanup"] = "pass" if not cleanup_errors else "fail"
    if cleanup_errors:
        report["cleanup_errors"] = " | ".join(cleanup_errors)

    if operation_error is not None or cleanup_errors:
        failure_parts = []
        if operation_error is not None:
            failure_parts.append("phase=" + report.get("phase", "unknown"))
            failure_parts.append(str(operation_error))
        failure_parts.extend(cleanup_errors)
        raise RuntimeError(" | ".join(failure_parts))

    report["allocation_bytes"] = length
    report["allocations"] = 2
    report["maps"] = 3
    report["sync_transactions"] = 4


# parse_args(arguments)
# Parses one heap path, allocation size, and report path. It returns an argparse
# namespace, writes usage errors to stderr, and does not inspect the target.
def parse_args(arguments):
    parser = argparse.ArgumentParser(
        description="Exercise one Linux DMA-BUF heap through its public UAPI",
    )
    parser.add_argument("--heap", required=True)
    parser.add_argument("--size", required=True, type=int)
    parser.add_argument("--report", required=True)
    return parser.parse_args(arguments)


# main(arguments)
# Validates arguments, executes one heap transaction, writes its retained TSV,
# and returns 0 for PASS, 1 for a functional failure, or 2 when the requested
# heap device is absent or not a character device. It logs one result marker.
def main(arguments):
    args = parse_args(arguments)
    report = {
        "status": "UNKNOWN",
        "reason": "not-run",
        "heap": args.heap,
        "allocation_bytes": args.size,
        "page_size": mmap.PAGESIZE,
        "alloc_ioctl": hex(DMA_HEAP_IOCTL_ALLOC),
        "sync_ioctl": hex(DMA_BUF_IOCTL_SYNC),
    }

    if (
        args.size <= 0
        or args.size > MAX_ALLOCATION_BYTES
        or args.size % mmap.PAGESIZE != 0
    ):
        report["status"] = "FAIL"
        report["reason"] = "size-outside-safe-page-aligned-range"
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=FAIL"
            + " reason=size-outside-safe-page-aligned-range"
            + " heap="
            + args.heap
            + " size="
            + str(args.size)
            + " page_size="
            + str(mmap.PAGESIZE)
        )
        return 1
    if not os.path.exists(args.heap):
        report["status"] = "SKIP"
        report["reason"] = "heap-device-absent"
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=SKIP reason=heap-device-absent heap="
            + args.heap
        )
        return 2
    if not stat.S_ISCHR(os.stat(args.heap).st_mode):
        report["status"] = "SKIP"
        report["reason"] = "heap-path-not-character-device"
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=SKIP"
            + " reason=heap-path-not-character-device heap="
            + args.heap
        )
        return 2

    try:
        exercise_heap(args.heap, args.size, report)
    except Exception as error:
        reason = report_value(error)
        report["status"] = "FAIL"
        report["reason"] = reason
        write_report(args.report, report)
        print(
            "DMABUF_HEAP_RESULT status=FAIL heap="
            + args.heap
            + " reason="
            + reason.replace(" ", "-")
            + " report="
            + args.report
        )
        return 1

    report["status"] = "PASS"
    report["reason"] = "allocate-map-zero-sync-read-write-release-verified"
    write_report(args.report, report)
    print(
        "DMABUF_HEAP_RESULT status=PASS heap="
        + args.heap
        + " bytes="
        + str(args.size)
        + " allocations=2 maps=3 sync_transactions=4"
        + " released=maps-and-fds"
        + " sha256="
        + report["pattern_sha256"]
        + " preview="
        + report["readback_preview_hex"]
        + " fd_before="
        + str(report["fd_count_before"])
        + " fd_after="
        + str(report["fd_count_after"])
        + " report="
        + args.report
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
