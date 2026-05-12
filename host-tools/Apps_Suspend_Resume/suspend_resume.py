#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""
Apps_Suspend_Resume host-side validation.

Scope:
  - Validate APPS suspend/resume only.
  - Use /sys/power/suspend_stats as the authoritative result.
  - Use /proc/sys/kernel/random/boot_id to detect accidental reboot.
  - Do not validate XO shutdown.
  - Do not read /sys/kernel/debug/qcom_stats.
  - Use host-side TAC CLI only when a TAC wake method is selected.
  - Keep ADB as an explicit transport only.

Result file format:
  Apps_Suspend_Resume PASS
  Apps_Suspend_Resume FAIL
  Apps_Suspend_Resume SKIP
"""

import argparse
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple


TESTNAME = "Apps_Suspend_Resume"
PASS_RC = 0
FAIL_RC = 1
SKIP_RC = 77


def log(level: str, message: str) -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{level}] {timestamp} - {message}", flush=True)


def log_info(message: str) -> None:
    log("INFO", message)


def log_pass(message: str) -> None:
    log("PASS", message)


def log_warn(message: str) -> None:
    log("WARN", message)


def log_fail(message: str) -> None:
    log("FAIL", message)


def log_skip(message: str) -> None:
    log("SKIP", message)


def write_result(path: str, result: str) -> None:
    with open(path, "w", encoding="utf-8") as res_file:
        res_file.write(f"{TESTNAME} {result}\n")


@dataclass
class CommandResult:
    rc: int
    stdout: str
    stderr: str


class TransportError(RuntimeError):
    pass


class BaseTransport:
    def run(self, command: str, timeout: int = 30) -> CommandResult:
        raise NotImplementedError

    def wait_online(self, timeout: int) -> bool:
        deadline = time.time() + timeout

        while time.time() < deadline:
            result = self.run("true", timeout=10)
            if result.rc == 0:
                return True
            time.sleep(2)

        return False

    def name(self) -> str:
        return self.__class__.__name__


class SSHTransport(BaseTransport):
    def __init__(self, host: str, user: str, port: int) -> None:
        if not host:
            raise TransportError("SSH host is not provided")

        self.host = host
        self.user = user
        self.port = port

    def run(self, command: str, timeout: int = 30) -> CommandResult:
        target = f"{self.user}@{self.host}" if self.user else self.host

        cmd = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            f"ConnectTimeout={max(1, min(timeout, 15))}",
            "-p",
            str(self.port),
            target,
            command,
        ]

        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
            return CommandResult(proc.returncode, proc.stdout, proc.stderr)
        except subprocess.TimeoutExpired as exc:
            return CommandResult(124, exc.stdout or "", exc.stderr or "ssh command timed out")


class ADBTransport(BaseTransport):
    def __init__(self, serial: str = "") -> None:
        self.serial = serial

    def _base_cmd(self) -> List[str]:
        cmd = ["adb"]
        if self.serial:
            cmd.extend(["-s", self.serial])
        return cmd

    def run(self, command: str, timeout: int = 30) -> CommandResult:
        cmd = self._base_cmd()
        cmd.extend(["shell", command])

        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
            return CommandResult(proc.returncode, proc.stdout, proc.stderr)
        except subprocess.TimeoutExpired as exc:
            return CommandResult(124, exc.stdout or "", exc.stderr or "adb command timed out")

    def wait_online(self, timeout: int) -> bool:
        cmd = self._base_cmd()
        cmd.append("wait-for-device")

        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                check=False,
            )
            if proc.returncode != 0:
                return False
        except subprocess.TimeoutExpired:
            return False

        return super().wait_online(timeout)


class SerialTransport(BaseTransport):
    def __init__(self, port: str, baudrate: int) -> None:
        if not port:
            raise TransportError("Serial port is not provided")

        try:
            import serial # type: ignore
        except ImportError as exc:
            raise TransportError("pyserial is not installed on host") from exc

        self.serial_mod = serial
        self.port = port
        self.baudrate = baudrate

    def run(self, command: str, timeout: int = 30) -> CommandResult:
        marker = f"ASR_DONE_{int(time.time() * 1000)}"
        full_command = f"sh -c {shlex.quote(command)}; echo {marker}:$?\n"
        output = ""
        deadline = time.time() + timeout

        try:
            with self.serial_mod.Serial(
                self.port,
                self.baudrate,
                timeout=1,
                write_timeout=5,
            ) as ser:
                ser.write(full_command.encode("utf-8"))
                ser.flush()

                while time.time() < deadline:
                    data = ser.read(4096)
                    if not data:
                        time.sleep(0.2)
                        continue

                    chunk = data.decode("utf-8", errors="replace")
                    output += chunk

                    if marker in output:
                        rc = self._parse_marker_rc(output, marker)
                        return CommandResult(rc, output, "")

            return CommandResult(124, output, "serial command timed out")
        except Exception as exc:
            return CommandResult(1, output, f"serial command failed, {exc}")

    @staticmethod
    def _parse_marker_rc(output: str, marker: str) -> int:
        for line in output.splitlines():
            if line.startswith(f"{marker}:"):
                value = line.split(":", 1)[1].strip()
                try:
                    return int(value)
                except ValueError:
                    return 1

        return 1


def read_text_safely(path: Path, max_bytes: int = 512 * 1024) -> str:
    try:
        with path.open("rb") as handle:
            data = handle.read(max_bytes)
        return data.decode("utf-8", errors="replace")
    except OSError:
        return ""


def extract_tac_serials_from_text(text: str) -> List[str]:
    serials: List[str] = []

    patterns = [
        r"tac-api\.py[^\n\r]*--serial[=\s]+['\"]?([A-Za-z0-9_.:-]+)",
        r"--serial[=\s]+['\"]?([A-Za-z0-9_.:-]+)",
        r"\btac_serial\b\s*[:=]\s*['\"]?([A-Za-z0-9_.:-]+)",
        r"\btac-serial\b\s*[:=]\s*['\"]?([A-Za-z0-9_.:-]+)",
    ]

    for pattern in patterns:
        for match in re.finditer(pattern, text):
            value = match.group(1).strip().strip("'\"")
            if value and value not in serials:
                serials.append(value)

    return serials


def discover_tac_serial_from_env() -> str:
    env_names = [
        "TAC_SERIAL",
        "LAVA_TAC_SERIAL",
        "LAVA_DEVICE_SERIAL",
        "DEVICE_SERIAL",
        "DUT_SERIAL",
    ]

    for name in env_names:
        value = os.getenv(name, "").strip()
        if value:
            log_info(f"Using TAC serial from environment variable, {name}")
            return value

    return ""


def candidate_lava_config_roots() -> List[Path]:
    roots = [
        Path("/etc/lava-dispatcher/devices"),
        Path("/etc/lava-server/dispatcher-config/devices"),
        Path("/etc/lava-dispatcher"),
        Path("/etc/lava-server"),
        Path("/etc/lava-worker"),
    ]

    env_roots = os.getenv("TAC_CONFIG_SEARCH_ROOTS", "").strip()
    if env_roots:
        for item in env_roots.split(":"):
            if item:
                path = Path(item)
                if path not in roots:
                    roots.insert(0, path)

    return roots


def discover_tac_serial_from_lava_config() -> str:
    serial_to_files: Dict[str, List[str]] = {}

    for root in candidate_lava_config_roots():
        if not root.exists():
            continue

        try:
            files = [root] if root.is_file() else list(root.rglob("*"))
        except OSError:
            continue

        for path in files:
            if not path.is_file():
                continue

            suffix = path.suffix.lower()
            if suffix not in (".jinja2", ".j2", ".yaml", ".yml", ".json", ".conf", ".txt"):
                continue

            text = read_text_safely(path)
            if not text:
                continue

            for serial in extract_tac_serials_from_text(text):
                serial_to_files.setdefault(serial, []).append(str(path))

    if len(serial_to_files) == 1:
        serial = next(iter(serial_to_files))
        log_info(f"Discovered TAC serial from LAVA worker config, serial={serial}")
        for source in serial_to_files[serial][:5]:
            log_info(f"TAC serial source, {source}")
        return serial

    if len(serial_to_files) > 1:
        log_fail("Multiple TAC serials discovered from worker config")
        for serial, files in serial_to_files.items():
            log_fail(f"Candidate TAC serial, {serial}, files, {', '.join(files[:3])}")
        log_fail("Set TAC_SERIAL or pass --tac-serial to disambiguate")
        return ""

    return ""


def resolve_tac_serial(cli_serial: str) -> str:
    if cli_serial.strip():
        log_info("Using TAC serial from command line")
        return cli_serial.strip()

    env_serial = discover_tac_serial_from_env()
    if env_serial:
        return env_serial

    config_serial = discover_tac_serial_from_lava_config()
    if config_serial:
        return config_serial

    log_fail("Unable to discover TAC serial from command line, environment, or LAVA worker config")
    return ""


class TacApiCliController:
    def __init__(self, tac_api_bin: str, serial: str) -> None:
        self.tac_api_bin = tac_api_bin
        self.serial = serial

    def available(self) -> Tuple[bool, str]:
        if not self.tac_api_bin:
            return False, "TAC API binary path is not configured"

        if not os.path.exists(self.tac_api_bin):
            return False, f"TAC API binary not found, {self.tac_api_bin}"

        if not os.access(self.tac_api_bin, os.X_OK):
            return False, f"TAC API binary is not executable, {self.tac_api_bin}"

        self.serial = resolve_tac_serial(self.serial)
        if not self.serial:
            return False, "TAC serial could not be resolved"

        return True, f"TAC API CLI available, bin={self.tac_api_bin}, serial={self.serial}"

    def run_command(self, command: str, label: str) -> bool:
        if not command:
            log_fail(f"TAC {label} command is not configured")
            return False

        cmd = [
            self.tac_api_bin,
            "--serial",
            self.serial,
            "--command",
            command,
        ]

        log_info(f"Running TAC {label} command, {' '.join(cmd)}")

        try:
            proc = subprocess.run(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=120,
                check=False,
            )
        except subprocess.TimeoutExpired:
            log_fail(f"TAC {label} command timed out")
            return False
        except OSError as exc:
            log_fail(f"TAC {label} command failed to execute, {exc}")
            return False

        stdout = proc.stdout.strip()
        stderr = proc.stderr.strip()

        if stdout:
            log_info(f"TAC {label} stdout, {stdout}")
        if stderr:
            log_warn(f"TAC {label} stderr, {stderr}")

        if proc.returncode != 0:
            log_fail(f"TAC {label} command failed, rc={proc.returncode}")
            return False

        if "200" in stdout:
            log_pass(f"TAC {label} command completed, HTTP 200 observed")
            return True

        log_pass(f"TAC {label} command completed, rc=0")
        return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Apps suspend/resume host-side validation")

    parser.add_argument("--result-file", default=os.getenv("RESULT_FILE", f"{TESTNAME}.res"))

    parser.add_argument(
        "--transport",
        choices=["auto", "serial", "ssh", "adb"],
        default=os.getenv("TRANSPORT", "auto"),
    )

    parser.add_argument("--serial-port", default=os.getenv("SERIAL_PORT", ""))
    parser.add_argument("--serial-baudrate", type=int, default=int(os.getenv("SERIAL_BAUDRATE", "115200")))

    parser.add_argument("--ssh-host", default=os.getenv("SSH_HOST", ""))
    parser.add_argument("--ssh-user", default=os.getenv("SSH_USER", "root"))
    parser.add_argument("--ssh-port", type=int, default=int(os.getenv("SSH_PORT", "22")))

    parser.add_argument("--adb-serial", default=os.getenv("ADB_SERIAL", ""))
    parser.add_argument(
        "--allow-adb-fallback",
        action="store_true",
        default=os.getenv("ALLOW_ADB_FALLBACK", "0") == "1",
    )

    parser.add_argument(
        "--wake-method",
        choices=["manual", "rtc", "usb-tac", "tac-command", "tac-power-key"],
        default=os.getenv("WAKE_METHOD", "manual"),
    )

    parser.add_argument("--tac-api-bin", default=os.getenv("TAC_API_BIN", "/usr/local/bin/tac-api.py"))
    parser.add_argument("--tac-serial", default=os.getenv("TAC_SERIAL", ""))

    parser.add_argument("--tac-usb-disconnect-command", default=os.getenv("TAC_USB_DISCONNECT_COMMAND", "usbDisconnect"))
    parser.add_argument("--tac-usb-connect-command", default=os.getenv("TAC_USB_CONNECT_COMMAND", "usbConnect"))

    parser.add_argument("--tac-wake-command", default=os.getenv("TAC_WAKE_COMMAND", ""))
    parser.add_argument("--tac-power-key-press-command", default=os.getenv("TAC_POWER_KEY_PRESS_COMMAND", ""))
    parser.add_argument("--tac-power-key-release-command", default=os.getenv("TAC_POWER_KEY_RELEASE_COMMAND", ""))
    parser.add_argument("--tac-wake-hold-ms", type=int, default=int(os.getenv("TAC_WAKE_HOLD_MS", "1000")))

    parser.add_argument("--cycles", type=int, default=int(os.getenv("CYCLES", "1")))
    parser.add_argument("--suspend-delay", type=int, default=int(os.getenv("SUSPEND_DELAY", "10")))
    parser.add_argument("--pre-disconnect-delay", type=int, default=int(os.getenv("PRE_DISCONNECT_DELAY", "1")))
    parser.add_argument("--suspend-window", type=int, default=int(os.getenv("SUSPEND_WINDOW", "10")))
    parser.add_argument("--resume-timeout", type=int, default=int(os.getenv("RESUME_TIMEOUT", "20")))
    parser.add_argument("--post-wake-settle", type=int, default=int(os.getenv("POST_WAKE_SETTLE", "3")))
    parser.add_argument("--command-timeout", type=int, default=int(os.getenv("COMMAND_TIMEOUT", "30")))

    return parser.parse_args()


def choose_transport(args: argparse.Namespace) -> BaseTransport:
    if args.transport == "serial":
        return SerialTransport(args.serial_port, args.serial_baudrate)

    if args.transport == "ssh":
        return SSHTransport(args.ssh_host, args.ssh_user, args.ssh_port)

    if args.transport == "adb":
        return ADBTransport(args.adb_serial)

    if args.serial_port:
        return SerialTransport(args.serial_port, args.serial_baudrate)

    if args.ssh_host:
        return SSHTransport(args.ssh_host, args.ssh_user, args.ssh_port)

    if args.allow_adb_fallback:
        return ADBTransport(args.adb_serial)

    raise TransportError("No command transport configured, provide SERIAL_PORT, SSH_HOST, or use --transport adb")


def read_boot_id(transport: BaseTransport, timeout: int) -> Optional[str]:
    result = transport.run("cat /proc/sys/kernel/random/boot_id 2>/dev/null", timeout=timeout)
    if result.rc != 0:
        log_warn("Unable to read /proc/sys/kernel/random/boot_id")
        return None

    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        log_warn("boot_id output is empty")
        return None

    return lines[-1]


def read_suspend_stats(transport: BaseTransport, timeout: int) -> Optional[Dict[str, int]]:
    script = r"""
if [ -d /sys/power/suspend_stats ]; then
  for key in success fail failed_freeze failed_prepare failed_suspend; do
    if [ -r "/sys/power/suspend_stats/$key" ]; then
      val="$(cat "/sys/power/suspend_stats/$key" 2>/dev/null)"
      printf '%s=%s\n' "$key" "$val"
    fi
  done
elif [ -r /sys/power/suspend_stats ]; then
  sed -n 's/^[[:space:]]*\([^:[:space:]]*\)[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1=\2/p' /sys/power/suspend_stats
else
  exit 1
fi
"""
    result = transport.run(script, timeout=timeout)
    if result.rc != 0:
        log_fail("/sys/power/suspend_stats is not readable")
        return None

    stats: Dict[str, int] = {}
    for line in result.stdout.splitlines():
        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if value.isdigit():
            stats[key] = int(value)

    required = ["success", "fail", "failed_freeze", "failed_prepare", "failed_suspend"]
    missing = [key for key in required if key not in stats]
    if missing:
        log_fail(f"suspend_stats is missing required keys, {', '.join(missing)}")
        log_info(f"raw suspend_stats output, {result.stdout.strip()}")
        return None

    return stats


def format_stats(stats: Dict[str, int]) -> str:
    keys = ["success", "fail", "failed_freeze", "failed_prepare", "failed_suspend"]
    return ", ".join(f"{key}={stats.get(key, 'NA')}" for key in keys)


def validate_stats(before: Dict[str, int], after: Dict[str, int]) -> bool:
    ok = True

    if after["success"] > before["success"]:
        log_pass(f"suspend success count increased, {before['success']} -> {after['success']}")
    else:
        log_fail(f"suspend success count did not increase, before={before['success']}, after={after['success']}")
        ok = False

    for key in ["fail", "failed_freeze", "failed_prepare", "failed_suspend"]:
        if after[key] == before[key]:
            log_pass(f"{key} count did not increase, value={after[key]}")
        else:
            log_fail(f"{key} count increased, before={before[key]}, after={after[key]}")
            ok = False

    return ok


def check_dut_prerequisites(transport: BaseTransport, args: argparse.Namespace) -> bool:
    checks = [
        ("systemctl", "command -v systemctl >/dev/null 2>&1"),
        ("suspend_stats", "[ -d /sys/power/suspend_stats ] || [ -r /sys/power/suspend_stats ]"),
    ]

    if args.wake_method == "rtc":
        checks.append(("rtcwake", "command -v rtcwake >/dev/null 2>&1"))
        checks.append(("rtc0", "[ -e /dev/rtc0 ]"))

    for name, command in checks:
        result = transport.run(command, timeout=args.command_timeout)
        if result.rc != 0:
            log_skip(f"DUT prerequisite missing, {name}")
            return False

        log_pass(f"DUT prerequisite present, {name}")

    state_result = transport.run("cat /sys/power/state 2>/dev/null || true", timeout=args.command_timeout)
    if state_result.stdout.strip():
        log_info(f"/sys/power/state, {state_result.stdout.strip()}")

    return True


def schedule_suspend(transport: BaseTransport, args: argparse.Namespace) -> bool:
    if args.wake_method == "rtc":
        inner = (
            f"sleep {args.suspend_delay} && "
            f"rtcwake -d /dev/rtc0 -m no -s {args.suspend_window} && "
            "systemctl suspend"
        )
    else:
        inner = f"sleep {args.suspend_delay} && systemctl suspend"

    command = (
        "nohup sh -c "
        + shlex.quote(inner)
        + " >/tmp/apps_suspend_resume_suspend.log 2>&1 & echo $!"
    )

    result = transport.run(command, timeout=args.command_timeout)
    if result.rc != 0:
        log_fail("Failed to schedule systemctl suspend on DUT")
        if result.stdout.strip():
            log_info(f"suspend schedule stdout, {result.stdout.strip()}")
        if result.stderr.strip():
            log_info(f"suspend schedule stderr, {result.stderr.strip()}")
        return False

    pid = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "unknown"
    log_info(f"Suspend scheduled on DUT, pid={pid}, delay={args.suspend_delay}s")
    return True


def requires_tac(wake_method: str) -> bool:
    return wake_method in ("usb-tac", "tac-command", "tac-power-key")


def run_tac_wake(args: argparse.Namespace, tac: TacApiCliController) -> bool:
    if args.wake_method == "usb-tac":
        time.sleep(args.pre_disconnect_delay)

        if not tac.run_command(args.tac_usb_disconnect_command, "USB disconnect"):
            return False

        wait_total = args.suspend_delay + args.suspend_window
        log_info(f"Waiting before USB reconnect, {wait_total}s")
        time.sleep(wait_total)

        return tac.run_command(args.tac_usb_connect_command, "USB connect")

    if args.wake_method == "tac-command":
        wait_total = args.suspend_delay + args.suspend_window
        log_info(f"Waiting before TAC wake command, {wait_total}s")
        time.sleep(wait_total)

        return tac.run_command(args.tac_wake_command, "wake")

    if args.wake_method == "tac-power-key":
        wait_total = args.suspend_delay + args.suspend_window
        log_info(f"Waiting before TAC power-key wake, {wait_total}s")
        time.sleep(wait_total)

        if args.tac_wake_hold_ms > 2000:
            log_warn(
                "Power-key hold time is greater than 2000ms, this may trigger long-press behavior, reset, or power-off on some boards"
            )

        if not tac.run_command(args.tac_power_key_press_command, "power-key press"):
            return False

        hold_sec = max(100, args.tac_wake_hold_ms) / 1000.0
        log_info(f"Holding power key for wake, {args.tac_wake_hold_ms}ms")
        time.sleep(hold_sec)

        return tac.run_command(args.tac_power_key_release_command, "power-key release")

    return False


def run_cycle(
    cycle: int,
    transport: BaseTransport,
    tac: Optional[TacApiCliController],
    args: argparse.Namespace,
) -> bool:
    log_info(f"---------------- Cycle {cycle}/{args.cycles} ----------------")

    before_boot_id = read_boot_id(transport, args.command_timeout)
    if before_boot_id:
        log_info(f"Pre-suspend boot_id, {before_boot_id}")

    before_stats = read_suspend_stats(transport, args.command_timeout)
    if before_stats is None:
        return False

    log_info(f"Pre-suspend stats, {format_stats(before_stats)}")

    if not schedule_suspend(transport, args):
        return False

    if requires_tac(args.wake_method):
        if tac is None:
            log_fail("TAC wake method selected but TAC controller is unavailable")
            return False

        if not run_tac_wake(args, tac):
            log_fail("TAC wake operation failed")
            return False

    elif args.wake_method == "rtc":
        wait_total = args.suspend_delay + args.suspend_window
        log_info(f"RTC wake selected, waiting for suspend and wake window, {wait_total}s")
        time.sleep(wait_total)

    else:
        wait_total = args.suspend_delay + args.suspend_window
        log_info(f"Manual wake selected, waiting for external wake action, {wait_total}s")
        time.sleep(wait_total)

    log_info(f"Waiting for DUT command channel to return, timeout {args.resume_timeout}s")
    if not transport.wait_online(args.resume_timeout):
        log_fail(f"DUT did not become reachable within {args.resume_timeout}s after wake")
        return False

    log_pass("DUT command channel is reachable after wake")

    if args.post_wake_settle > 0:
        log_info(f"Waiting post-wake settle time, {args.post_wake_settle}s")
        time.sleep(args.post_wake_settle)

    after_boot_id = read_boot_id(transport, args.command_timeout)
    if before_boot_id and after_boot_id:
        log_info(f"Post-wake boot_id, {after_boot_id}")
        if after_boot_id != before_boot_id:
            log_fail("DUT boot_id changed after wake, device rebooted instead of resuming")
            log_fail("This is not a valid APPS suspend/resume cycle")
            return False

    after_stats = read_suspend_stats(transport, args.command_timeout)
    if after_stats is None:
        return False

    log_info(f"Post-resume stats, {format_stats(after_stats)}")
    return validate_stats(before_stats, after_stats)


def main() -> int:
    args = parse_args()
    result_file = os.path.abspath(args.result_file)

    log_info("-----------------------------------------------------------------------------------------")
    log_info(f"Starting {TESTNAME}")
    log_info(
        "Config, "
        f"transport={args.transport}, wake_method={args.wake_method}, cycles={args.cycles}, "
        f"suspend_delay={args.suspend_delay}, suspend_window={args.suspend_window}, "
        f"resume_timeout={args.resume_timeout}, post_wake_settle={args.post_wake_settle}, "
        f"tac_wake_hold_ms={args.tac_wake_hold_ms}"
    )

    try:
        transport = choose_transport(args)
        log_info(f"Using command transport, {transport.name()}")
    except TransportError as exc:
        log_skip(str(exc))
        write_result(result_file, "SKIP")
        return SKIP_RC

    tac: Optional[TacApiCliController] = None
    if requires_tac(args.wake_method):
        tac = TacApiCliController(args.tac_api_bin, args.tac_serial)
        ok, reason = tac.available()
        if ok:
            log_pass(reason)
        else:
            log_skip(f"TAC wake method selected but TAC is unavailable, {reason}")
            write_result(result_file, "SKIP")
            return SKIP_RC

    if not transport.wait_online(args.resume_timeout):
        log_skip("DUT command transport is not reachable before test")
        write_result(result_file, "SKIP")
        return SKIP_RC

    if not check_dut_prerequisites(transport, args):
        write_result(result_file, "SKIP")
        return SKIP_RC

    all_ok = True

    for cycle in range(1, args.cycles + 1):
        if not run_cycle(cycle, transport, tac, args):
            all_ok = False
            break

    if all_ok:
        log_pass(f"{TESTNAME}, APPS suspend resume validation passed")
        write_result(result_file, "PASS")
        return PASS_RC

    log_fail(f"{TESTNAME}, APPS suspend resume validation failed")
    write_result(result_file, "FAIL")
    return FAIL_RC


if __name__ == "__main__":
    sys.exit(main())
