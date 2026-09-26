#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
"""Validate an I2C-backed EEPROM through its kernel-managed sysfs interface."""

import argparse
import errno
import glob
import hashlib
import os
from pathlib import Path
import re
import signal
import sys
from typing import Dict, List, NoReturn, Optional, Tuple


EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_SKIP = 2
EXIT_INVALID = 3
OPEN_CLOEXEC = getattr(os, "O_CLOEXEC", 0)


class SkipTest(Exception):
    """Raised when the requested runtime environment is unavailable."""


class InvalidConfiguration(Exception):
    """Raised when a user-provided option is invalid."""


class ValidationFailure(Exception):
    """Raised when an operation fails in an available environment."""


class RunnerArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(EXIT_INVALID, f"{self.prog}: error: {message}\n")


def parse_integer(value: str) -> int:
    try:
        return int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError(
            f"expected a decimal or hexadecimal integer, got {value!r}"
        ) from error


def parse_args() -> argparse.Namespace:
    parser = RunnerArgumentParser(
        description=(
            "Discover an I2C-backed EEPROM and perform a read-only probe or "
            "an explicitly authorized write/read/restore integrity check"
        )
    )
    parser.add_argument(
        "--mode", choices=("discover", "probe", "integrity"), required=True
    )
    parser.add_argument("--device", default="auto")
    parser.add_argument("--offset", type=parse_integer)
    parser.add_argument("--length", type=parse_integer)
    parser.add_argument("--report", required=True)
    parser.add_argument(
        "--sysfs-root",
        default=os.environ.get("I2C_SYSFS_ROOT", "/sys"),
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def write_report(path: str, values: Dict[str, object]) -> None:
    report_path = Path(path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    with report_path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("key\tvalue\n")
        for key, value in values.items():
            rendered = str(value).replace("\t", " ").replace("\n", " ")
            stream.write(f"{key}\t{rendered}\n")


def finish(
    exit_code: int,
    status: str,
    reason: str,
    report_path: str,
    values: Optional[Dict[str, object]] = None,
) -> NoReturn:
    report = {
        "status": status,
        "reason": reason,
    }
    if values:
        report.update(values)
    write_report(report_path, report)

    summary = [
        "I2C_EEPROM_RESULT",
        f"status={status}",
        f"reason={reason}",
    ]
    for key in (
        "candidate_count",
        "candidates",
        "device",
        "source",
        "adapter",
        "address",
        "driver",
        "size_bytes",
        "offset",
        "length",
        "original_sha256",
        "test_sha256",
        "restored_sha256",
        "restoration",
    ):
        if key in report:
            summary.append(f"{key}={report[key]}")
    summary.append(f"report={report_path}")
    print(" ".join(summary))
    raise SystemExit(exit_code)


def candidate_evidence_paths(path: Path) -> List[Path]:
    device_link = path.parent / "device"
    evidence = [path, Path(os.path.realpath(path))]
    if device_link.exists():
        evidence.append(Path(os.path.realpath(device_link)))
    return evidence


def discover_i2c_client_id(path: Path) -> str:
    for evidence_path in candidate_evidence_paths(path):
        for part in reversed(evidence_path.parts):
            if re.fullmatch(r"\d+-[0-9a-fA-F]{4}", part):
                return part
    return ""


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def is_i2c_backed_nvmem(path: Path) -> bool:
    if discover_i2c_client_id(path):
        return True
    evidence = " ".join(str(item) for item in candidate_evidence_paths(path))
    return re.search(r"(?:^|[/\\])i2c-\d+(?:[/\\]|$)", evidence) is not None


def is_eeprom_nvmem(path: Path) -> bool:
    nvmem_type = read_text(path.parent / "type")
    return not nvmem_type or nvmem_type.lower() == "eeprom"


def discover_candidates(sysfs_root: str) -> List[Tuple[str, str]]:
    root = Path(sysfs_root)
    candidates: List[Tuple[str, str]] = []
    seen = set()

    def add_candidate(raw_path: str, source: str) -> None:
        path = Path(raw_path)
        client_id = discover_i2c_client_id(path)
        identity = f"client:{client_id}" if client_id else os.path.realpath(raw_path)
        if identity in seen or not os.path.isfile(raw_path):
            return
        seen.add(identity)
        candidates.append((raw_path, source))

    direct_pattern = str(root / "bus" / "i2c" / "devices" / "*" / "eeprom")
    for raw_path in sorted(glob.glob(direct_pattern)):
        add_candidate(raw_path, "i2c-eeprom-sysfs")

    nvmem_pattern = str(root / "bus" / "nvmem" / "devices" / "*" / "nvmem")
    for raw_path in sorted(glob.glob(nvmem_pattern)):
        path = Path(raw_path)
        if not is_i2c_backed_nvmem(path):
            continue
        if not is_eeprom_nvmem(path):
            continue
        add_candidate(raw_path, "i2c-nvmem-sysfs")

    return candidates


def select_device(
    requested: str, candidates: List[Tuple[str, str]]
) -> Tuple[str, str]:
    if requested != "auto":
        selected = os.path.realpath(requested)
        if not os.path.isfile(selected):
            raise SkipTest("requested-eeprom-device-unavailable")
        selected_path = Path(requested)
        if selected_path.name == "eeprom" and discover_i2c_client_id(selected_path):
            return requested, "i2c-eeprom-sysfs"
        if (
            selected_path.name == "nvmem"
            and is_i2c_backed_nvmem(selected_path)
            and is_eeprom_nvmem(selected_path)
        ):
            return requested, "i2c-nvmem-sysfs"
        raise SkipTest("requested-device-is-not-an-i2c-eeprom")

    if not candidates:
        raise SkipTest("no-i2c-eeprom-sysfs-device")
    if len(candidates) != 1:
        raise SkipTest("multiple-i2c-eeprom-devices-require-selection")
    path, source = candidates[0]
    return path, source


def discover_size(path: str) -> int:
    stat_size = os.stat(path).st_size
    if stat_size > 0:
        return stat_size

    parent = Path(path).parent
    for size_path in (parent / "size", parent.parent / "size"):
        raw_size = read_text(size_path)
        if not raw_size:
            continue
        try:
            size = int(raw_size, 0)
        except ValueError:
            continue
        if size > 0:
            return size

    raise SkipTest("eeprom-size-unavailable")


def discover_i2c_identity(path: str) -> Tuple[str, str, str]:
    path_object = Path(path)
    evidence_paths = candidate_evidence_paths(path_object)
    client_id = discover_i2c_client_id(path_object)

    adapter = "unknown"
    address = "unknown"
    driver = "unknown"
    if client_id:
        adapter, encoded_address = client_id.split("-", 1)
        address = f"0x{int(encoded_address, 16):02x}"
        client_path = Path(path).parent
        if client_path.name != client_id:
            for evidence_path in evidence_paths:
                for parent in (evidence_path, *evidence_path.parents):
                    if parent.name == client_id:
                        client_path = parent
                        break
                if client_path.name == client_id:
                    break
        driver_link = client_path / "driver"
        if driver_link.exists():
            driver = Path(os.path.realpath(driver_link)).name

    return adapter, address, driver


def read_exact(fd: int, offset: int, length: int) -> bytes:
    chunks: List[bytes] = []
    remaining = length
    position = offset
    while remaining:
        if hasattr(os, "pread"):
            chunk = os.pread(fd, remaining, position)
        else:
            os.lseek(fd, position, os.SEEK_SET)
            chunk = os.read(fd, remaining)
        if not chunk:
            raise ValidationFailure("short-read")
        chunks.append(chunk)
        position += len(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def write_exact(fd: int, offset: int, payload: bytes) -> None:
    written = 0
    while written < len(payload):
        if hasattr(os, "pwrite"):
            count = os.pwrite(fd, payload[written:], offset + written)
        else:
            os.lseek(fd, offset + written, os.SEEK_SET)
            count = os.write(fd, payload[written:])
        if count <= 0:
            raise ValidationFailure("short-write")
        written += count


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def validate_region(args: argparse.Namespace, size: int) -> Tuple[int, int]:
    if args.mode == "integrity" and (args.offset is None or args.length is None):
        raise InvalidConfiguration("integrity-mode-requires-offset-and-length")
    if (args.offset is None) != (args.length is None):
        raise InvalidConfiguration("offset-and-length-must-be-specified-together")

    if args.offset is None:
        return 0, size
    if args.offset < 0:
        raise InvalidConfiguration("offset-must-be-non-negative")
    if args.length is None or args.length <= 0:
        raise InvalidConfiguration("length-must-be-positive")
    if args.offset + args.length > size:
        raise InvalidConfiguration("requested-range-exceeds-eeprom-size")
    return args.offset, args.length


def install_signal_handlers() -> None:
    def interrupt(signum: int, _frame: object) -> None:
        raise InterruptedError(f"signal-{signum}")

    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)


def main() -> int:
    args = parse_args()
    base_report: Dict[str, object] = {
        "mode": args.mode,
        "requested_device": args.device,
        "sysfs_root": args.sysfs_root,
    }

    try:
        candidates = discover_candidates(args.sysfs_root)
        candidate_paths = [path for path, _source in candidates]
        base_report.update(
            {
                "candidate_count": len(candidate_paths),
                "candidates": ",".join(candidate_paths),
            }
        )
        device, source = select_device(args.device, candidates)
        size = discover_size(device)
        offset, length = validate_region(args, size)
        adapter, address, driver = discover_i2c_identity(device)
        base_report.update(
            {
                "device": device,
                "source": source,
                "adapter": adapter,
                "address": address,
                "driver": driver,
                "size_bytes": size,
                "offset": offset,
                "length": length,
            }
        )

        if args.mode == "discover":
            finish(
                EXIT_PASS,
                "PASS",
                "dynamic-eeprom-discovery-complete",
                args.report,
                base_report,
            )

        if args.mode == "probe":
            try:
                fd = os.open(device, os.O_RDONLY | OPEN_CLOEXEC)
            except OSError as error:
                raise SkipTest(f"eeprom-open-unavailable-{error.errno}") from error
            try:
                payload = read_exact(fd, offset, length)
            except (OSError, ValidationFailure) as error:
                raise SkipTest("eeprom-read-unavailable") from error
            finally:
                os.close(fd)

            base_report["original_sha256"] = digest(payload)
            finish(
                EXIT_PASS,
                "PASS",
                "dynamic-eeprom-read-verified",
                args.report,
                base_report,
            )

        try:
            fd = os.open(device, os.O_RDWR | OPEN_CLOEXEC)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EPERM, errno.EROFS):
                raise SkipTest("selected-eeprom-is-not-writable") from error
            raise SkipTest(f"eeprom-open-unavailable-{error.errno}") from error

        original = b""
        test_pattern = b""
        restoration = "not-required"
        write_attempted = False
        validation_error: Optional[Exception] = None
        try:
            original = read_exact(fd, offset, length)
        except (OSError, ValidationFailure) as error:
            os.close(fd)
            raise SkipTest("selected-eeprom-range-is-not-readable") from error

        try:
            test_pattern = bytes(value ^ 0xFF for value in original)
            write_attempted = True
            write_exact(fd, offset, test_pattern)
            observed = read_exact(fd, offset, length)
            if observed != test_pattern:
                raise ValidationFailure("test-pattern-readback-mismatch")
        except (OSError, ValidationFailure, InterruptedError) as error:
            validation_error = error
        finally:
            if write_attempted:
                try:
                    write_exact(fd, offset, original)
                    restored = read_exact(fd, offset, length)
                    if restored != original:
                        restoration = "verification-failed"
                    else:
                        restoration = "verified"
                        base_report["restored_sha256"] = digest(restored)
                except (OSError, ValidationFailure, InterruptedError):
                    restoration = "failed"
            os.close(fd)

        base_report.update(
            {
                "original_sha256": digest(original),
                "test_sha256": digest(test_pattern),
                "restoration": restoration,
            }
        )
        if restoration != "verified":
            raise ValidationFailure(f"eeprom-restoration-{restoration}")
        if validation_error is not None:
            raise ValidationFailure(type(validation_error).__name__) from validation_error

        finish(
            EXIT_PASS,
            "PASS",
            "write-read-restore-verified",
            args.report,
            base_report,
        )
    except SkipTest as error:
        finish(EXIT_SKIP, "SKIP", str(error), args.report, base_report)
    except InvalidConfiguration as error:
        finish(EXIT_INVALID, "FAIL", str(error), args.report, base_report)
    except (OSError, ValidationFailure) as error:
        finish(EXIT_FAIL, "FAIL", str(error), args.report, base_report)


if __name__ == "__main__":
    install_signal_handlers()
    main()
