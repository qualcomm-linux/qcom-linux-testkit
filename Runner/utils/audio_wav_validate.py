#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
"""Validate WAV structure, duration, negotiated format, and signal activity.

This parser intentionally does not trust RIFF/data sizes. Streaming recorders can
leave placeholder sizes when they are stopped by a timeout. Analysis is clamped
to bytes that actually exist in the file and is bounded/distributed for large
recordings.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import sys
from dataclasses import dataclass
from typing import BinaryIO, Iterable

VALIDATION_SCOPE = "record"


class WavValidationError(Exception):
    """Raised for malformed or unsupported WAV files."""


@dataclass(frozen=True)
class WaveInfo:
    container: str
    format_code: int
    format_name: str
    channels: int
    sample_rate: int
    byte_rate: int
    block_align: int
    bits_per_sample: int
    valid_bits_per_sample: int
    data_offset: int
    declared_data_bytes: int
    available_data_bytes: int
    usable_data_bytes: int
    file_bytes: int

    @property
    def frames(self) -> int:
        return self.usable_data_bytes // self.block_align

    @property
    def duration_seconds(self) -> float:
        if self.sample_rate <= 0:
            return 0.0
        return self.frames / float(self.sample_rate)


@dataclass
class SignalStats:
    samples: int = 0
    nonzero_storage_samples: int = 0
    active_samples: int = 0
    clipped_samples: int = 0
    glitch_candidates: int = 0
    silence_runs: int = 0
    longest_silence_frames: int = 0
    peak: float = 0.0
    sum_values: float = 0.0
    sum_squares: float = 0.0
    distinct: set[object] | None = None
    channel_active_samples: list[int] | None = None
    invalid_float_samples: int = 0

    def __post_init__(self) -> None:
        if self.distinct is None:
            self.distinct = set()

    @property
    def rms(self) -> float:
        if self.samples == 0:
            return 0.0
        return math.sqrt(self.sum_squares / self.samples)

    @property
    def active_ratio(self) -> float:
        if self.samples == 0:
            return 0.0
        return self.active_samples / float(self.samples)

    @property
    def clipped_ratio(self) -> float:
        if self.samples == 0:
            return 0.0
        return self.clipped_samples / float(self.samples)

    @property
    def dc_offset(self) -> float:
        if self.samples == 0:
            return 0.0
        return self.sum_values / float(self.samples)


def _read_exact(handle: BinaryIO, count: int) -> bytes:
    data = handle.read(count)
    if len(data) != count:
        raise WavValidationError(
            f"unexpected-end-of-file: wanted={count} got={len(data)}"
        )
    return data


def _format_name(code: int) -> str:
    return {
        1: "pcm",
        3: "ieee-float",
    }.get(code, f"format-{code}")


def parse_wave(path: str, max_header_bytes: int = 1024 * 1024) -> WaveInfo:
    file_bytes = os.path.getsize(path)
    if file_bytes < 44:
        raise WavValidationError(f"file-too-small:{file_bytes}")

    with open(path, "rb") as handle:
        header = _read_exact(handle, 12)
        container = header[0:4].decode("ascii", errors="replace")
        if container not in {"RIFF", "RF64"}:
            raise WavValidationError(f"unsupported-container:{container}")
        if header[8:12] != b"WAVE":
            raise WavValidationError("missing-WAVE-signature")

        fmt_payload: bytes | None = None
        data_offset: int | None = None
        declared_data_bytes: int | None = None

        while handle.tell() + 8 <= file_bytes:
            if handle.tell() > max_header_bytes:
                raise WavValidationError(
                    f"data-chunk-not-found-within-{max_header_bytes}-bytes"
                )

            chunk_header = _read_exact(handle, 8)
            chunk_id = chunk_header[0:4]
            chunk_size = struct.unpack_from("<I", chunk_header, 4)[0]
            chunk_data_offset = handle.tell()

            if chunk_id == b"fmt ":
                if chunk_size < 16:
                    raise WavValidationError(f"invalid-fmt-size:{chunk_size}")
                readable = min(chunk_size, 128, file_bytes - chunk_data_offset)
                fmt_payload = _read_exact(handle, readable)
                remaining = chunk_size - readable
                if remaining > 0:
                    handle.seek(remaining, os.SEEK_CUR)
            elif chunk_id == b"data":
                data_offset = chunk_data_offset
                declared_data_bytes = chunk_size
                break
            else:
                next_offset = chunk_data_offset + chunk_size
                if next_offset > file_bytes:
                    raise WavValidationError(
                        "truncated-chunk-before-data:"
                        f"id={chunk_id!r} declared={chunk_size}"
                    )
                handle.seek(chunk_size, os.SEEK_CUR)

            if chunk_size & 1:
                if handle.tell() < file_bytes:
                    handle.seek(1, os.SEEK_CUR)

        if fmt_payload is None:
            raise WavValidationError("missing-fmt-chunk")
        if data_offset is None or declared_data_bytes is None:
            raise WavValidationError("missing-data-chunk")

    if len(fmt_payload) < 16:
        raise WavValidationError("truncated-fmt-chunk")

    format_code, channels, sample_rate, byte_rate, block_align, bits = (
        struct.unpack_from("<HHIIHH", fmt_payload, 0)
    )
    valid_bits = bits

    if format_code == 0xFFFE:
        if len(fmt_payload) < 40:
            raise WavValidationError("truncated-extensible-fmt-chunk")
        valid_bits = struct.unpack_from("<H", fmt_payload, 18)[0] or bits
        format_code = struct.unpack_from("<H", fmt_payload, 24)[0]

    if format_code not in {1, 3}:
        raise WavValidationError(f"unsupported-wave-format:{format_code}")
    if channels <= 0 or channels > 64:
        raise WavValidationError(f"invalid-channel-count:{channels}")
    if sample_rate <= 0:
        raise WavValidationError(f"invalid-sample-rate:{sample_rate}")
    if block_align <= 0:
        raise WavValidationError(f"invalid-block-align:{block_align}")
    if block_align % channels != 0:
        raise WavValidationError(
            f"block-align-not-divisible-by-channels:{block_align}/{channels}"
        )
    if byte_rate <= 0:
        raise WavValidationError(f"invalid-byte-rate:{byte_rate}")
    expected_byte_rate = sample_rate * block_align
    if byte_rate != expected_byte_rate:
        raise WavValidationError(
            f"byte-rate-mismatch:{byte_rate}!={expected_byte_rate}"
        )

    bytes_per_sample = block_align // channels
    container_bits = bytes_per_sample * 8
    if bits <= 0 or bits > container_bits:
        raise WavValidationError(
            f"invalid-bits-per-sample:{bits}>{container_bits}"
        )
    if valid_bits <= 0 or valid_bits > container_bits:
        raise WavValidationError(
            f"invalid-valid-bits-per-sample:{valid_bits}>{container_bits}"
        )
    if format_code == 1 and bytes_per_sample not in {1, 2, 3, 4, 8}:
        raise WavValidationError(
            f"unsupported-pcm-container-bytes:{bytes_per_sample}"
        )
    if format_code == 3 and bytes_per_sample not in {4, 8}:
        raise WavValidationError(
            f"unsupported-float-container-bytes:{bytes_per_sample}"
        )

    available_data_bytes = max(0, file_bytes - data_offset)
    if container == "RF64" or declared_data_bytes in {0, 0xFFFFFFFF}:
        usable_data_bytes = available_data_bytes
    else:
        usable_data_bytes = min(declared_data_bytes, available_data_bytes)

    usable_data_bytes -= usable_data_bytes % block_align
    if usable_data_bytes <= 0:
        raise WavValidationError("empty-audio-payload")

    return WaveInfo(
        container=container,
        format_code=format_code,
        format_name=_format_name(format_code),
        channels=channels,
        sample_rate=sample_rate,
        byte_rate=byte_rate,
        block_align=block_align,
        bits_per_sample=bits,
        valid_bits_per_sample=valid_bits,
        data_offset=data_offset,
        declared_data_bytes=declared_data_bytes,
        available_data_bytes=available_data_bytes,
        usable_data_bytes=usable_data_bytes,
        file_bytes=file_bytes,
    )


def _window_ranges(total_bytes: int, limit_bytes: int, align: int) -> list[tuple[int, int]]:
    limit_bytes = max(align, limit_bytes - (limit_bytes % align))
    if total_bytes <= limit_bytes:
        return [(0, total_bytes)]

    window_count = 8
    window_size = max(align, limit_bytes // window_count)
    window_size -= window_size % align
    if window_size <= 0:
        window_size = align

    max_start = total_bytes - window_size
    positions: list[int] = []
    for index in range(window_count):
        raw = round(max_start * index / float(window_count - 1))
        aligned = int(raw) - (int(raw) % align)
        if aligned not in positions:
            positions.append(aligned)

    return [(position, window_size) for position in positions]


def _decode_pcm(sample: bytes, container_bytes: int, valid_bits: int) -> tuple[float, int]:
    if container_bytes == 1:
        raw = sample[0] - 128
        scale = 128.0
    else:
        raw = int.from_bytes(sample, "little", signed=True)
        effective_bits = valid_bits if 1 < valid_bits <= container_bytes * 8 else container_bytes * 8
        scale = float(1 << (effective_bits - 1))

        # WAVE_FORMAT_EXTENSIBLE may store valid bits left-aligned in a larger
        # container. Shift only when the low padding bits are consistently zero.
        padding = container_bytes * 8 - effective_bits
        if padding > 0 and raw % (1 << padding) == 0:
            raw >>= padding

    normalized = max(-1.0, min(1.0, raw / scale))
    return normalized, raw


def _decode_float(sample: bytes, container_bytes: int) -> tuple[float, float]:
    value = struct.unpack("<f" if container_bytes == 4 else "<d", sample)[0]
    return value, value


def analyze_signal(
    path: str,
    info: WaveInfo,
    analyze_bytes: int,
    threshold: float,
    clipping_threshold: float,
    glitch_threshold: float,
    dropout_min_ms: float,
) -> SignalStats:
    stats = SignalStats()
    stats.channel_active_samples = [0] * info.channels
    container_bytes = info.block_align // info.channels
    ranges = _window_ranges(info.usable_data_bytes, analyze_bytes, info.block_align)
    minimum_silence_frames = max(
        1,
        int(info.sample_rate * max(0.0, dropout_min_ms) / 1000.0),
    )

    with open(path, "rb") as handle:
        for relative_offset, length in ranges:
            previous_samples: list[float | None] = [None] * info.channels
            current_silence_frames = 0
            handle.seek(info.data_offset + relative_offset)
            payload = handle.read(length)
            payload = payload[: len(payload) - (len(payload) % info.block_align)]

            for frame_offset in range(0, len(payload), info.block_align):
                frame = payload[frame_offset : frame_offset + info.block_align]
                frame_active = False
                for channel in range(info.channels):
                    start = channel * container_bytes
                    sample = frame[start : start + container_bytes]
                    if any(sample):
                        stats.nonzero_storage_samples += 1

                    if info.format_code == 1:
                        normalized, distinct_value = _decode_pcm(
                            sample, container_bytes, info.valid_bits_per_sample
                        )
                    else:
                        normalized, distinct_value = _decode_float(
                            sample, container_bytes
                        )
                        if not math.isfinite(normalized):
                            stats.invalid_float_samples += 1
                            continue
                        normalized = max(-1.0, min(1.0, normalized))
                        distinct_value = round(float(distinct_value), 10)

                    magnitude = abs(normalized)
                    stats.samples += 1
                    stats.sum_values += normalized
                    stats.sum_squares += normalized * normalized
                    if magnitude > stats.peak:
                        stats.peak = magnitude
                    if magnitude > threshold:
                        stats.active_samples += 1
                        stats.channel_active_samples[channel] += 1
                        frame_active = True
                    if magnitude >= clipping_threshold:
                        stats.clipped_samples += 1
                    if (
                        previous_samples[channel] is not None
                        and abs(normalized - previous_samples[channel]) >= glitch_threshold
                    ):
                        stats.glitch_candidates += 1
                    previous_samples[channel] = normalized
                    if len(stats.distinct) < 256:
                        stats.distinct.add(distinct_value)

                if frame_active:
                    if current_silence_frames >= minimum_silence_frames:
                        stats.silence_runs += 1
                    stats.longest_silence_frames = max(
                        stats.longest_silence_frames,
                        current_silence_frames,
                    )
                    current_silence_frames = 0
                else:
                    current_silence_frames += 1

            if current_silence_frames >= minimum_silence_frames:
                stats.silence_runs += 1
            stats.longest_silence_frames = max(
                stats.longest_silence_frames,
                current_silence_frames,
            )

    return stats


def _dbfs(value: float) -> float:
    if value <= 0.0:
        return float("-inf")
    return 20.0 * math.log10(value)


def _clean(value: object) -> str:
    text = str(value)
    return text.replace(" ", "_").replace("\n", "_")


def emit(status: str, reason: str, info: WaveInfo | None, stats: SignalStats | None, warnings: Iterable[str]) -> None:
    fields: list[tuple[str, object]] = [
        ("status", status),
        ("reason", reason),
    ]

    if info is not None:
        fields.extend(
            [
                ("container", info.container),
                ("format", info.format_name),
                ("channels", info.channels),
                ("rate_hz", info.sample_rate),
                ("bits", info.bits_per_sample),
                ("block_align", info.block_align),
                ("file_bytes", info.file_bytes),
                ("declared_data_bytes", info.declared_data_bytes),
                ("available_data_bytes", info.available_data_bytes),
                ("usable_data_bytes", info.usable_data_bytes),
                ("duration_s", f"{info.duration_seconds:.3f}"),
            ]
        )

    if stats is not None:
        fields.extend(
            [
                ("analyzed_samples", stats.samples),
                ("nonzero_storage_samples", stats.nonzero_storage_samples),
                ("active_samples", stats.active_samples),
                ("active_ratio", f"{stats.active_ratio:.8f}"),
                ("distinct_samples", len(stats.distinct)),
                ("peak_dbfs", f"{_dbfs(stats.peak):.2f}"),
                ("rms_dbfs", f"{_dbfs(stats.rms):.2f}"),
                ("dc_offset", f"{stats.dc_offset:.8f}"),
                ("clipped_samples", stats.clipped_samples),
                ("clipped_ratio", f"{stats.clipped_ratio:.8f}"),
                ("silence_runs", stats.silence_runs),
                (
                    "longest_silence_ms",
                    f"{1000.0 * stats.longest_silence_frames / info.sample_rate:.2f}",
                ),
                ("glitch_candidates", stats.glitch_candidates),
                (
                    "silent_channels",
                    sum(1 for count in stats.channel_active_samples or [] if count == 0),
                ),
                ("invalid_float_samples", stats.invalid_float_samples),
            ]
        )

    warning_list = list(warnings)
    fields.append(("warnings", ",".join(warning_list) if warning_list else "none"))

    legacy_rendered = " ".join(f"{key}={_clean(value)}" for key, value in fields)
    validation_status = "FAIL" if status == "ERROR" else status
    validation_fields = [("status", validation_status), *fields[1:]]
    validation_rendered = " ".join(
        f"{key}={_clean(value)}" for key, value in validation_fields
    )
    print("AUDIO_WAV_VALIDATION " + legacy_rendered)
    print(
        "AUDIO_VALIDATION "
        f"scope={_clean(VALIDATION_SCOPE)} policy=basic-integrity "
        + validation_rendered
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True)
    parser.add_argument("--source-kind", choices=("mic", "null"), default="mic")
    parser.add_argument("--expect-rate", type=int, default=0)
    parser.add_argument("--expect-channels", type=int, default=0)
    parser.add_argument("--expect-bits", type=int, default=0)
    parser.add_argument("--expected-seconds", type=float, default=0.0)
    parser.add_argument("--analyze-bytes", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--min-active-samples", type=int, default=100)
    parser.add_argument("--sample-threshold-lsb", type=float, default=8.0)
    parser.add_argument("--min-distinct-samples", type=int, default=4)
    parser.add_argument("--min-duration-ratio", type=float, default=0.70)
    parser.add_argument("--strict-signal", choices=("0", "1"), default="0")
    parser.add_argument("--min-rms-dbfs", type=float, default=-60.0)
    parser.add_argument("--clipping-threshold", type=float, default=0.999)
    parser.add_argument("--glitch-threshold", type=float, default=0.80)
    parser.add_argument("--dropout-min-ms", type=float, default=50.0)
    parser.add_argument(
        "--validation-scope",
        choices=("record", "playback", "loopback"),
        default="record",
    )
    return parser.parse_args()


def main() -> int:
    global VALIDATION_SCOPE

    args = parse_args()
    VALIDATION_SCOPE = args.validation_scope
    warnings: list[str] = []

    try:
        info = parse_wave(args.file)
    except (OSError, WavValidationError) as error:
        emit("ERROR", str(error), None, None, warnings)
        return 2

    if args.expect_rate > 0 and info.sample_rate != args.expect_rate:
        emit(
            "FAIL",
            f"sample-rate-mismatch:{info.sample_rate}!={args.expect_rate}",
            info,
            None,
            warnings,
        )
        return 1

    if args.expect_channels > 0 and info.channels != args.expect_channels:
        emit(
            "FAIL",
            f"channel-mismatch:{info.channels}!={args.expect_channels}",
            info,
            None,
            warnings,
        )
        return 1

    if args.expect_bits > 0 and info.bits_per_sample != args.expect_bits:
        emit(
            "FAIL",
            f"bits-per-sample-mismatch:{info.bits_per_sample}!={args.expect_bits}",
            info,
            None,
            warnings,
        )
        return 1

    if info.declared_data_bytes == 0 and info.available_data_bytes > 0:
        warnings.append("declared-data-zero-with-payload")
    elif info.declared_data_bytes not in {0xFFFFFFFF, info.available_data_bytes}:
        if info.declared_data_bytes > info.available_data_bytes:
            warnings.append("declared-data-exceeds-file")
        elif info.declared_data_bytes < info.available_data_bytes:
            warnings.append("trailing-bytes-after-data")

    if args.expected_seconds > 0.0:
        minimum_duration = max(0.25, args.expected_seconds * args.min_duration_ratio)
        if info.duration_seconds < minimum_duration:
            emit(
                "FAIL",
                f"duration-too-short:{info.duration_seconds:.3f}<{minimum_duration:.3f}",
                info,
                None,
                warnings,
            )
            return 1

    threshold = max(0.0, args.sample_threshold_lsb / 32768.0)
    try:
        stats = analyze_signal(
            args.file,
            info,
            max(info.block_align, args.analyze_bytes),
            threshold,
            max(0.0, min(1.0, args.clipping_threshold)),
            max(0.0, min(2.0, args.glitch_threshold)),
            max(0.0, args.dropout_min_ms),
        )
    except (OSError, struct.error, ValueError) as error:
        emit("ERROR", f"signal-analysis-failed:{error}", info, None, warnings)
        return 2

    if stats.samples <= 0:
        emit("FAIL", "no-decodable-samples", info, stats, warnings)
        return 1

    if args.source_kind == "null":
        emit("PASS", "valid-null-source-recording", info, stats, warnings)
        return 0

    if stats.nonzero_storage_samples == 0:
        emit("FAIL", "all-zero-audio-payload", info, stats, warnings)
        return 1

    if stats.peak == 0.0:
        emit("FAIL", "digital-silence-all-zero", info, stats, warnings)
        return 1

    if len(stats.distinct) < max(2, args.min_distinct_samples):
        warnings.append("constant-or-near-constant-payload")

    if stats.active_samples < args.min_active_samples:
        warnings.append(
            f"low-active-sample-count:{stats.active_samples}<{args.min_active_samples}"
        )

    if args.strict_signal == "1" and _dbfs(stats.rms) < args.min_rms_dbfs:
        emit(
            "FAIL",
            f"rms-below-strict-threshold:{_dbfs(stats.rms):.2f}<{args.min_rms_dbfs:.2f}",
            info,
            stats,
            warnings,
        )
        return 1

    if _dbfs(stats.rms) < -60.0:
        warnings.append("very-low-rms")
    if stats.clipped_samples > 0:
        warnings.append("clipping-observed")
    if stats.silence_runs > 0:
        warnings.append("digital-silence-runs-observed")
    if abs(stats.dc_offset) >= 0.10:
        warnings.append("large-dc-offset")
    if stats.glitch_candidates > 0:
        warnings.append("large-sample-transitions-observed")
    if any(count == 0 for count in stats.channel_active_samples or []):
        warnings.append("silent-channel-observed")
    if stats.invalid_float_samples > 0:
        warnings.append("invalid-float-samples-observed")

    emit("PASS", "signal-activity-present", info, stats, warnings)
    return 0


if __name__ == "__main__":
    sys.exit(main())
