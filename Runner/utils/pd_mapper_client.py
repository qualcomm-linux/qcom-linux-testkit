#!/usr/bin/env python3
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

"""Query the Qualcomm PD Mapper get-domain-list QMI operation over QRTR."""

import argparse
import hashlib
import json
import socket
import struct
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

try:
    import lzma
except ImportError:
    lzma = None


QMI_REQUEST = 0
QMI_RESPONSE = 2
SERVREG_GET_DOMAIN_LIST = 0x21
QMI_HEADER = struct.Struct("<BHHH")


def emit(status: str, reason: str, **fields: object) -> None:
    """Print one machine-readable final status line without side effects."""
    details = " ".join(f"{key}={value}" for key, value in fields.items())
    print(f"PD_MAPPER_FUNCTIONAL status={status} reason={reason} {details}".rstrip())


def load_registry(list_file: Path) -> Tuple[Dict[str, Set[Tuple[str, int]]], int]:
    """Return registry services mapped to their domain tuples, and the number
    of .xz registries left unread because Python has no lzma."""
    services: Dict[str, Set[Tuple[str, int]]] = {}
    unread = 0
    for raw_path in list_file.read_text(encoding="utf-8").splitlines():
        if not raw_path:
            continue
        path = Path(raw_path)
        opener = open
        if path.name.endswith(".xz"):
            if lzma is None:
                unread += 1
                continue
            opener = lzma.open
        with opener(path, "rt", encoding="utf-8") as stream:
            root = json.load(stream)
        domain_data = root["sr_domain"]
        domain = "/".join(
            (domain_data["soc"], domain_data["domain"], domain_data["subdomain"])
        )
        instance = int(domain_data["qmi_instance_id"])
        for entry in root["sr_service"]:
            service = f'{entry["provider"]}/{entry["service"]}'
            services.setdefault(service, set()).add((domain, instance))
    return services, unread


def parse_tlvs(payload: bytes) -> Dict[int, bytes]:
    """Decode one QMI payload into unique TLVs or raise on malformed input."""
    tlvs: Dict[int, bytes] = {}
    offset = 0
    while offset < len(payload):
        if len(payload) - offset < 3:
            raise ValueError(f"truncated-tlv-header-at-{offset}")
        tlv_type, tlv_length = struct.unpack_from("<BH", payload, offset)
        offset += 3
        end = offset + tlv_length
        if end > len(payload):
            raise ValueError(f"truncated-tlv-value-type-{tlv_type}")
        if tlv_type in tlvs:
            raise ValueError(f"duplicate-tlv-type-{tlv_type}")
        tlvs[tlv_type] = payload[offset:end]
        offset = end
    return tlvs


def decode_domains(value: bytes) -> List[Tuple[str, int]]:
    """Decode a PD Mapper domain-list TLV into domain and instance tuples."""
    if not value:
        raise ValueError("empty-domain-list-tlv")
    count = value[0]
    offset = 1
    domains: List[Tuple[str, int]] = []
    for index in range(count):
        if offset >= len(value):
            raise ValueError(f"truncated-domain-name-length-at-{index}")
        name_length = value[offset]
        offset += 1
        fixed_length = name_length + 9
        if len(value) - offset < fixed_length:
            raise ValueError(f"truncated-domain-entry-at-{index}")
        name_bytes = value[offset : offset + name_length]
        offset += name_length
        instance, service_data_valid, service_data = struct.unpack_from(
            "<IBI", value, offset
        )
        offset += 9
        del service_data_valid, service_data
        domains.append((name_bytes.decode("utf-8"), instance))
    if offset != len(value):
        raise ValueError(f"trailing-domain-list-bytes-{len(value) - offset}")
    return domains


def request_domains(
    client: socket.socket,
    endpoint: Tuple[int, int],
    service: str,
    transaction: int,
    offset: Optional[int],
) -> Tuple[List[Tuple[str, int]], int, bytes, bytes]:
    """Send one bounded QMI page request and return validated response data."""
    service_bytes = service.encode("utf-8")
    if not service_bytes or len(service_bytes) > 256 or b"\0" in service_bytes:
        raise ValueError(f"invalid-service-name-length-{len(service_bytes)}")
    payload = struct.pack("<BH", 1, len(service_bytes)) + service_bytes
    if offset is not None:
        payload += struct.pack("<BHI", 0x10, 4, offset)
    request = QMI_HEADER.pack(
        QMI_REQUEST,
        transaction,
        SERVREG_GET_DOMAIN_LIST,
        len(payload),
    ) + payload
    client.sendto(request, endpoint)
    response, source = client.recvfrom(65536)
    if source[0] != endpoint[0] or source[1] != endpoint[1]:
        raise ValueError(f"response-source-mismatch-{source[0]}-{source[1]}")
    if len(response) < QMI_HEADER.size:
        raise ValueError("short-qmi-response")
    msg_type, response_txn, msg_id, msg_length = QMI_HEADER.unpack_from(response)
    if msg_type != QMI_RESPONSE:
        raise ValueError(f"unexpected-qmi-type-{msg_type}")
    if response_txn != transaction:
        raise ValueError(f"unexpected-transaction-{response_txn}")
    if msg_id != SERVREG_GET_DOMAIN_LIST:
        raise ValueError(f"unexpected-message-id-{msg_id}")
    if msg_length != len(response) - QMI_HEADER.size:
        raise ValueError(
            f"qmi-length-mismatch-{msg_length}-{len(response) - QMI_HEADER.size}"
        )
    tlvs = parse_tlvs(response[QMI_HEADER.size :])
    result = tlvs.get(2)
    if result is None or len(result) != 4:
        raise ValueError("missing-or-invalid-result-tlv")
    qmi_result, qmi_error = struct.unpack("<HH", result)
    if qmi_result != 0 or qmi_error != 0:
        raise RuntimeError(f"qmi-failure-{qmi_result}-{qmi_error}")
    total_value = tlvs.get(0x10)
    if total_value is None or len(total_value) != 2:
        raise ValueError("missing-or-invalid-total-domains-tlv")
    total_domains = struct.unpack("<H", total_value)[0]
    domains = decode_domains(tlvs[0x12]) if 0x12 in tlvs else []
    return domains, total_domains, request, response


def preview(payload: bytes) -> str:
    """Return a bounded hexadecimal packet preview for diagnostic logging."""
    return payload[:32].hex() or "empty"


def query_service(
    client: socket.socket,
    endpoint: Tuple[int, int],
    service: str,
    transaction_start: int,
) -> Tuple[Set[Tuple[str, int]], List[bytes], List[bytes], int]:
    """Query all bounded pages for one service and return domains and packets."""
    observed: Set[Tuple[str, int]] = set()
    request_packets: List[bytes] = []
    response_packets: List[bytes] = []
    offset = 0
    transaction = transaction_start
    total = 0
    while True:
        domains, total, request, response = request_domains(
            client,
            endpoint,
            service,
            transaction,
            offset if offset else None,
        )
        request_packets.append(request)
        response_packets.append(response)
        observed.update(domains)
        if len(observed) >= total:
            break
        if not domains:
            raise ValueError(f"pagination-stalled-offset-{offset}-total-{total}")
        offset += len(domains)
        transaction = (transaction + 1) & 0xFFFF or 1
        if len(request_packets) > 16:
            raise ValueError("pagination-limit-exceeded")
    return observed, request_packets, response_packets, transaction


def main() -> int:
    """Run CLI validation and return 0 for PASS, 1 for FAIL, or 2 for SKIP."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", type=int, required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--registry-list", type=Path, required=True)
    parser.add_argument("--report-file", type=Path, required=True)
    parser.add_argument("--service", default="")
    parser.add_argument(
        "--implementation",
        choices=("kernel", "userspace", "protocol-only"),
        required=True,
    )
    parser.add_argument("--timeout", type=float, required=True)
    args = parser.parse_args()

    family = getattr(socket, "AF_QIPCRTR", 42)

    try:
        services, unread = load_registry(args.registry_list)
    except (OSError, EOFError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        emit("FAIL", "registry-read-or-parse", message=repr(str(error)))
        return 1
    if not services and (args.implementation != "kernel" or args.service):
        emit("SKIP", "no-registry-services")
        return 2

    if args.service and args.service not in services:
        emit(
            "FAIL",
            "selected-service-not-in-registry",
            service=args.service,
            available_services=len(services),
        )
        return 1

    service_source = "override" if args.service else "dynamic-registry"
    candidates = [args.service] if args.service else sorted(services)[:32]
    omitted_candidates = max(len(services) - len(candidates), 0)
    print(
        "PD_MAPPER_SELECTION"
        f" source={service_source} available_services={len(services)}"
        f" candidates={len(candidates)} omitted={omitted_candidates}"
        f" unread_registries={unread}"
        f" registry_list={args.registry_list}"
    )
    endpoint = (args.node, args.port)
    service = ""
    expected: Optional[Set[Tuple[str, int]]] = None
    observed: Set[Tuple[str, int]] = set()
    all_requests: List[bytes] = []
    all_responses: List[bytes] = []
    transaction = 1
    active_service = "none"

    try:
        with socket.socket(family, socket.SOCK_DGRAM) as client:
            client.settimeout(args.timeout)
            for candidate in candidates:
                active_service = candidate
                candidate_domains, requests, responses, transaction = query_service(
                    client, endpoint, candidate, transaction
                )
                all_requests.extend(requests)
                all_responses.extend(responses)
                print(
                    "PD_MAPPER_PROBE"
                    f" service={candidate} source={service_source}"
                    f" observed_domains={len(candidate_domains)}"
                )
                transaction = (transaction + 1) & 0xFFFF or 1
                if candidate_domains:
                    service = candidate
                    expected = services[candidate]
                    observed = candidate_domains
                    break

            if not service and args.implementation == "kernel" and not args.service:
                service = "tms/servreg"
                active_service = service
                service_source = "public-kernel-contract"
                observed, requests, responses, transaction = query_service(
                    client, endpoint, service, transaction
                )
                del transaction
                all_requests.extend(requests)
                all_responses.extend(responses)
                print(
                    "PD_MAPPER_PROBE"
                    f" service={service} source={service_source}"
                    f" observed_domains={len(observed)}"
                )
    except socket.timeout:
        emit(
            "FAIL",
            "response-timeout",
            service=active_service,
            node=args.node,
            port=args.port,
            received_domains=len(observed),
        )
        return 1
    except (OSError, UnicodeDecodeError, ValueError, RuntimeError) as error:
        emit(
            "FAIL",
            "protocol-error",
            service=active_service,
            message=repr(str(error)),
        )
        return 1

    if not service:
        emit(
            "FAIL",
            "no-registry-service-resolved",
            implementation=args.implementation,
            candidates=len(candidates),
        )
        return 1
    if not observed:
        emit(
            "FAIL",
            "empty-domain-list",
            implementation=args.implementation,
            service=service,
            service_source=service_source,
        )
        return 1

    args.report_file.parent.mkdir(parents=True, exist_ok=True)
    with args.report_file.open("w", encoding="utf-8", newline="\n") as report:
        report.write("state\tdomain\tinstance\n")
        expected_for_report = expected or set()
        for domain, instance in sorted(expected_for_report | observed):
            if expected is None:
                state = "observed"
            elif (domain, instance) in expected and (domain, instance) in observed:
                state = "matched"
            elif (domain, instance) in expected:
                state = "missing"
            elif unread:
                state = "unverified"
            else:
                state = "unexpected"
            report.write(f"{state}\t{domain}\t{instance}\n")

    request_data = b"".join(all_requests)
    response_data = b"".join(all_responses)
    print(
        "PD_MAPPER_IO direction=tx"
        f" packets={len(all_requests)} bytes={len(request_data)}"
        f" sha256={hashlib.sha256(request_data).hexdigest()}"
        f" preview_hex={preview(request_data)}"
    )
    print(
        "PD_MAPPER_IO direction=rx"
        f" packets={len(all_responses)} bytes={len(response_data)}"
        f" sha256={hashlib.sha256(response_data).hexdigest()}"
        f" preview_hex={preview(response_data)}"
    )
    # An unread registry may add domains to the service: then only the
    # readable registries' domains can be required.
    if expected is not None and unread and not expected <= observed:
        emit(
            "FAIL",
            "readable-registry-domain-missing",
            service=service,
            service_source=service_source,
            expected_domains=len(expected),
            observed_domains=len(observed),
            unread_registries=unread,
            report=args.report_file,
        )
        return 1
    if expected is not None and not unread and observed != expected:
        emit(
            "FAIL",
            "domain-set-mismatch",
            service=service,
            service_source=service_source,
            expected_domains=len(expected),
            observed_domains=len(observed),
            report=args.report_file,
        )
        return 1

    if expected is None:
        comparison = "nonempty-structural"
    elif unread:
        comparison = "readable-registry-subset"
    else:
        comparison = "exact-registry"
    emit(
        "PASS",
        "domain-list-verified",
        service=service,
        service_source=service_source,
        node=args.node,
        port=args.port,
        domains=len(observed),
        comparison=comparison,
        report=args.report_file,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
