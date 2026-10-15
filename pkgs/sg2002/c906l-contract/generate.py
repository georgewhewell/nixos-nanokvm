#!/usr/bin/env python3
"""Generate deterministic SG2002 C906L contract bindings.

The input is the resolved, profile-specific JSON produced by lib.nix.  This
script deliberately uses only the Python standard library and never infers
values from generated text.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def strip_documentation(value: Any) -> Any:
    if isinstance(value, list):
        return [strip_documentation(item) for item in value]
    if isinstance(value, dict):
        return {
            key: strip_documentation(item)
            for key, item in value.items()
            if key not in {"description", "spdxLicense"}
        }
    return value


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def macro(name: str) -> str:
    return snake(name).upper().replace("-", "_")


def hex_literal(value: int, width: int = 8) -> str:
    return f"0x{value:0{width}x}"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


SG2002_TIMER_DESCRIPTORS = {
    "timer4": {
        "channel": 4,
        "irq": 55,
        "leaseBit": 0,
        "capabilityBit": 2,
        "failureFlagBit": 2,
        "gateMask": 0x00002000,
        "resetMask": 0x00040000,
        "sourceMask": 0x00000010,
    },
    "timer5": {
        "channel": 5,
        "irq": 56,
        "leaseBit": 1,
        "capabilityBit": 4,
        "failureFlagBit": 8,
        "gateMask": 0x00004000,
        "resetMask": 0x00080000,
        "sourceMask": 0x00000020,
    },
    "timer6": {
        "channel": 6,
        "irq": 57,
        "leaseBit": 2,
        "capabilityBit": 5,
        "failureFlagBit": 9,
        "gateMask": 0x00008000,
        "resetMask": 0x00100000,
        "sourceMask": 0x00000040,
    },
    "timer7": {
        "channel": 7,
        "irq": 58,
        "leaseBit": 3,
        "capabilityBit": 6,
        "failureFlagBit": 10,
        "gateMask": 0x00010000,
        "resetMask": 0x00200000,
        "sourceMask": 0x00000080,
    },
}


def expected_sg2002_timer(name: str, descriptor: dict[str, int]) -> dict[str, Any]:
    channel = descriptor["channel"]
    channel_address = 0x030A0000 + channel * 0x14
    return {
        "kind": "dw-apb-timer-channel",
        "leaseBit": descriptor["leaseBit"],
        "cargoFeature": name,
        "capability": f"{name}SelfTest",
        "failureFlag": f"{name}SelfTestFailed",
        "irq": descriptor["irq"],
        "bank": {
            "address": 0x030A0000,
            "size": 0x00010000,
            "ownership": "shared-bank-exclusive-channel",
            "channel": channel,
        },
        "registers": {
            "load": {"address": channel_address, "access": "read-write"},
            "current": {"address": channel_address + 4, "access": "read-only"},
            "control": {"address": channel_address + 8, "access": "read-write"},
            "eoi": {"address": channel_address + 12, "access": "read-clear"},
            "status": {"address": channel_address + 16, "access": "read-only"},
        },
        "sharedPreconditions": {
            "clockXtalMisc": {
                "address": 0x03002000,
                "mask": 0x00004000,
                "expected": 0x00004000,
                "access": "read-only",
            },
            f"clockTimer{channel}": {
                "address": 0x0300200C,
                "mask": descriptor["gateMask"],
                "expected": descriptor["gateMask"],
                "access": "read-only",
            },
            "resetTimerIp": {
                "address": 0x03003008,
                "mask": 0x00002000,
                "expected": 0x00002000,
                "access": "read-only",
            },
            f"resetTimer{channel}": {
                "address": 0x03003008,
                "mask": descriptor["resetMask"],
                "expected": descriptor["resetMask"],
                "access": "read-only",
            },
            "clockSource": {
                "address": 0x030001A0,
                "mask": descriptor["sourceMask"],
                "expected": 0,
                "access": "read-only",
            },
        },
        "selfTest": {
            "clockHz": 25000000,
            "periodTicks": 2500000,
            "timeoutRtosTicks": 100,
            "rtosTickHz": 200,
        },
        "linuxLease": {
            "policy": "static-exclusive-subresource",
            "mustNotClaimIrq": descriptor["irq"],
            "mustNotAccessChannel": channel,
            "sharedGlobalRegisters": "read-only",
        },
    }


def validate_sg2002_timers(contract: dict[str, Any]) -> None:
    leases = {
        name: lease
        for name, lease in contract["peripheralLeases"].items()
        if name != "picoclawLcd"
    }
    capabilities = contract["abi"]["capabilities"]
    flags = contract["abi"]["flags"]

    require(
        all(name in SG2002_TIMER_DESCRIPTORS for name in leases),
        "resolved contract contains an unsupported peripheral",
    )

    for name, descriptor in SG2002_TIMER_DESCRIPTORS.items():
        capability = f"{name}SelfTest"
        failure_flag = f"{name}SelfTestFailed"
        require(
            capabilities.get(capability, {}).get("bit") == descriptor["capabilityBit"],
            f"{capability} does not use its assigned ABI capability bit",
        )
        require(
            flags.get(failure_flag, {}).get("bit") == descriptor["failureFlagBit"],
            f"{failure_flag} does not use its assigned ABI status-flag bit",
        )

    unique_groups = {
        "lease bits": [timer["leaseBit"] for timer in leases.values()],
        "Cargo features": [timer["cargoFeature"] for timer in leases.values()],
        "capabilities": [timer["capability"] for timer in leases.values()],
        "failure flags": [timer["failureFlag"] for timer in leases.values()],
        "C906L IRQs": [timer["irq"] for timer in leases.values()],
        "timer channels": [timer["bank"]["channel"] for timer in leases.values()],
        "timer registers": [
            register["address"]
            for timer in leases.values()
            for register in timer["registers"].values()
        ],
    }
    for group_name, values in unique_groups.items():
        require(
            len(values) == len(set(values)),
            f"selected peripheral {group_name} are not unique",
        )

    ranges = sorted(
        (
            timer["registers"]["load"]["address"],
            timer["registers"]["status"]["address"] + 4,
        )
        for timer in leases.values()
    )
    require(
        all(left[1] <= right[0] for left, right in zip(ranges, ranges[1:])),
        "selected peripheral timer channel slices overlap",
    )

    for name, timer in leases.items():
        require(
            timer == expected_sg2002_timer(name, SG2002_TIMER_DESCRIPTORS[name]),
            f"{name} does not match the exact SG2002 C906L timer topology",
        )


def validate_picoclaw_lcd(contract: dict[str, Any]) -> None:
    leases = contract["peripheralLeases"]
    require(
        contract["abi"]["capabilities"].get("picoclawLcd", {}).get("bit") == 7,
        "PicoClaw LCD capability must use bit 7",
    )
    require(
        contract["abi"]["flags"].get("picoclawLcdFailed", {}).get("bit") == 11,
        "PicoClaw LCD failure flag must use bit 11",
    )
    if "picoclawLcd" not in leases:
        return
    require(list(leases) == ["picoclawLcd"], "PicoClaw LCD must be selected alone")
    lcd = leases["picoclawLcd"]
    # Freeze physical wiring and framebuffer ownership together. No arbitrary
    # MMIO or weaker ownership contract is accepted merely because it hashes.
    require(
        hashlib.sha256(canonical_json(strip_documentation(lcd))).hexdigest()
        == "0cf1c1b2130feaef12138e6eeb181ae093ef369da3689725fccf065392f41133",
        "PicoClaw LCD does not match the frozen board and framebuffer contract",
    )
    constants = lcd["constants"]
    shared = contract["memory"]["shared"]
    bulk_start = shared["address"] + shared["regions"]["bulk"]["offset"]
    bulk_end = bulk_start + shared["regions"]["bulk"]["size"]
    require(
        constants["ownership0Address"] == bulk_start
        and constants["frameSlot1Address"] + constants["frameSize"] <= bulk_end,
        "PicoClaw framebuffer does not fit the shared bulk region",
    )
    require(
        constants["wifiPowerOwnershipAddress"] % 64 == 0
        and constants["wifiPowerOwnershipAddress"]
        >= constants["ownership1Address"] + constants["ownershipSize"]
        and constants["wifiPowerOwnershipAddress"] + 128 <= constants["frameSlot0Address"],
        "PicoClaw Wi-Fi power records overlap framebuffer ownership or pixels",
    )
    profile = contract["profile"]
    require(
        profile["leaseMask"] == 16
        and profile["profileId"] == 17
        and profile["activationRequired"]
        and profile["manifestFlags"] == 3
        and profile["expectedCapabilities"] == 0x8B
        and profile["dormantCapabilities"] == 0x0B,
        "PicoClaw LCD has an invalid activation identity",
    )


def load_resolved(path: Path, expected_sha256: str) -> tuple[dict[str, Any], bytes]:
    source = path.read_bytes()
    contract = json.loads(source)
    require(isinstance(contract, dict), "resolved contract must be a JSON object")
    require(
        source == canonical_json(contract), "resolved contract JSON is not canonical"
    )
    require(contract.get("schemaVersion") == 1, "unsupported contract schema")
    require(
        contract.get("abi", {}).get("endianness") == "little",
        "ABI is not little-endian",
    )
    require("profile" in contract, "resolved contract has no selected profile")
    require("peripheralLeases" in contract, "resolved contract has no lease set")

    semantic = canonical_json(strip_documentation(contract))
    actual_sha256 = hashlib.sha256(semantic).hexdigest()
    require(
        re.fullmatch(r"[0-9a-f]{64}", expected_sha256) is not None,
        "expected SHA-256 is not 64 lowercase hexadecimal digits",
    )
    require(
        actual_sha256 == expected_sha256,
        f"contract digest mismatch: got {actual_sha256}, expected {expected_sha256}",
    )

    capabilities = contract["abi"]["capabilities"]
    expected_mask = sum(
        1 << capabilities[name]["bit"] for name in contract["profile"]["capabilities"]
    )
    require(
        expected_mask == contract["profile"]["expectedCapabilities"],
        "profile expected-capability mask does not match its named capabilities",
    )
    require(
        sorted(contract["profile"]["peripherals"])
        == sorted(contract["peripheralLeases"]),
        "profile peripheral list and resolved lease set differ",
    )
    require(
        re.fullmatch(r"[a-z][a-z0-9-]*", contract["profile"]["name"]) is not None,
        "profile name cannot be emitted safely",
    )
    require(
        re.fullmatch(r"[A-Za-z0-9._-]+", contract["rpmsg"]["echoService"]["name"])
        is not None,
        "RPMsg service name cannot be emitted safely",
    )
    for group_name, entries in (
        ("states", contract["abi"]["states"]),
        ("services", contract["abi"]["services"]),
        ("opcodes", contract["abi"]["opcodes"]),
        ("capabilities", contract["abi"]["capabilities"]),
        ("flags", contract["abi"]["flags"]),
        ("shared regions", contract["memory"]["shared"]["regions"]),
        ("peripheral leases", contract["peripheralLeases"]),
    ):
        identifiers = [macro(name) for name in entries]
        require(
            len(identifiers) == len(set(identifiers)),
            f"{group_name} contain colliding generated identifiers",
        )
    validate_sg2002_timers(contract)
    validate_picoclaw_lcd(contract)
    return contract, semantic


def c_value(value: int, *, kernel: bool = False, bits: int = 32) -> str:
    width = max(2, bits // 4)
    suffix = "ULL" if kernel and bits == 64 else "U" if kernel else ""
    if kernel:
        return f"{hex_literal(value, width)}{suffix}"
    constructor = "UINT64_C" if bits == 64 else "UINT32_C"
    return f"{constructor}({hex_literal(value, width)})"


def lcd_constants(peripheral: dict[str, Any]) -> dict[str, int]:
    """Flatten the board-specific contract without interpreting its MMIO."""
    constants = {macro(name): value for name, value in peripheral["constants"].items()}
    constants["SERVICE_ADDRESS"] = peripheral["service"]["address"]
    constants["PROTOCOL_VERSION"] = peripheral["service"]["protocolVersion"]
    for name, precondition in peripheral["sharedPreconditions"].items():
        for field in ("address", "mask", "expected"):
            constants[f"PRECONDITION_{macro(name)}_{macro(field)}"] = precondition[
                field
            ]
    return constants


def emit_macros(contract: dict[str, Any], digest: str, *, kernel: bool) -> list[str]:
    abi = contract["abi"]
    soc = contract["soc"]
    mailbox = soc["mailbox"]
    hwspin = mailbox["hardwareSpinlock"]
    hwspin_base = mailbox["address"] + hwspin["registerOffset"]
    hwspin_address = hwspin_base + hwspin["mailboxField"] * hwspin["registerStride"]
    hwspin_token_value_mask = (1 << hwspin["tokenWidth"]) - 1
    mailbox_channel_mask = sum(1 << channel for channel in mailbox["channels"].values())
    memory = contract["memory"]
    rpmsg = contract["rpmsg"]
    profile = contract["profile"]
    prefix = "SG2002_C906L_"
    digest_initializer = (
        "{ " + ", ".join(f"0x{byte:02x}" for byte in bytes.fromhex(digest)) + " }"
    )
    lines = [
        f'#define {prefix}PROFILE_NAME "{profile["name"]}"',
        f'#define {prefix}CONTRACT_SHA256 "{digest}"',
        f"#define {prefix}CONTRACT_SHA256_BYTES {digest_initializer}",
        f"#define {prefix}CONTRACT_EPOCH {contract['contractEpoch']}U",
        f"#define {prefix}ABI_MAJOR {abi['major']}U",
        f"#define {prefix}ABI_MINOR {abi['minor']}U",
        f"#define {prefix}SHMEM_MAGIC {c_value(abi['magic'], kernel=kernel)}",
        f"#define {prefix}MESSAGE_SIZE {abi['message']['size']}U",
        f"#define {prefix}STATUS_SIZE {abi['status']['size']}U",
        f"#define {prefix}CAPABILITY_WIRE_WIDTH {abi['capabilityWireWidth']}U",
        f"#define {prefix}CACHE_LINE_SIZE {soc['cacheLineSize']}U",
        f"#define {prefix}EXPECTED_CAPABILITIES "
        f"{c_value(profile['expectedCapabilities'], kernel=kernel, bits=64)}",
        f"#define {prefix}DORMANT_CAPABILITIES "
        f"{c_value(profile['dormantCapabilities'], kernel=kernel, bits=64)}",
        f"#define {prefix}LEASE_MASK "
        f"{c_value(profile['leaseMask'], kernel=kernel, bits=64)}",
        f"#define {prefix}PROFILE_ID "
        f"{c_value(profile['profileId'], kernel=kernel)}",
        f"#define {prefix}MANIFEST_FLAGS "
        f"{c_value(profile['manifestFlags'], kernel=kernel)}",
        f"#define {prefix}ACTIVATION_REQUIRED "
        f"{1 if profile['activationRequired'] else 0}U",
        f"#define {prefix}DRAM_ADDRESS "
        f"{c_value(soc['dram']['address'], kernel=kernel, bits=64)}",
        f"#define {prefix}DRAM_SIZE "
        f"{c_value(soc['dram']['size'], kernel=kernel, bits=64)}",
        f"#define {prefix}FIRMWARE_ADDRESS "
        f"{c_value(memory['firmware']['address'], kernel=kernel, bits=64)}",
        f"#define {prefix}FIRMWARE_SIZE "
        f"{c_value(memory['firmware']['size'], kernel=kernel, bits=64)}",
        f"#define {prefix}SHMEM_ADDRESS "
        f"{c_value(memory['shared']['address'], kernel=kernel, bits=64)}",
        f"#define {prefix}SHMEM_SIZE "
        f"{c_value(memory['shared']['size'], kernel=kernel, bits=64)}",
    ]

    for name, entry in abi["states"].items():
        lines.append(f"#define {prefix}STATE_{macro(name)} {entry}U")
    for name, entry in abi["services"].items():
        lines.append(f"#define {prefix}SERVICE_{macro(name)} {entry}U")
    for name, entry in abi["opcodes"].items():
        lines.append(
            f"#define {prefix}OP_{macro(name)} {c_value(entry, kernel=kernel)}"
        )
    for name, entry in abi["capabilities"].items():
        lines.append(f"#define {prefix}CAP_{macro(name)} (1ULL << {entry['bit']})")
    for name, entry in abi["flags"].items():
        lines.append(f"#define {prefix}FLAG_{macro(name)} (1U << {entry['bit']})")

    activation = contract["activation"]
    manifest = activation["manifest"]
    request = activation["request"]
    lines.extend(
        [
            f"#define {prefix}LEASE_WIRE_WIDTH {activation['leaseWireWidth']}U",
            f"#define {prefix}MANIFEST_OFFSET "
            f"{c_value(manifest['offset'], kernel=kernel, bits=64)}",
            f"#define {prefix}MANIFEST_ADDRESS "
            f"{c_value(memory['shared']['address'] + manifest['offset'], kernel=kernel, bits=64)}",
            f"#define {prefix}MANIFEST_SIZE {manifest['size']}U",
            f"#define {prefix}MANIFEST_MAGIC "
            f"{c_value(manifest['magic'], kernel=kernel)}",
            f"#define {prefix}MANIFEST_FORMAT_MAJOR {manifest['formatMajor']}U",
            f"#define {prefix}MANIFEST_FORMAT_MINOR {manifest['formatMinor']}U",
            f"#define {prefix}MANIFEST_COMMIT "
            f"{c_value(manifest['commit'], kernel=kernel)}",
            f"#define {prefix}ACTIVATION_REQUEST_OFFSET "
            f"{c_value(request['offset'], kernel=kernel, bits=64)}",
            f"#define {prefix}ACTIVATION_REQUEST_ADDRESS "
            f"{c_value(memory['shared']['address'] + request['offset'], kernel=kernel, bits=64)}",
            f"#define {prefix}ACTIVATION_REQUEST_SIZE {request['size']}U",
            f"#define {prefix}ACTIVATION_REQUEST_MAGIC "
            f"{c_value(request['magic'], kernel=kernel)}",
            f"#define {prefix}ACTIVATION_REQUEST_FORMAT_MAJOR {request['formatMajor']}U",
            f"#define {prefix}ACTIVATION_REQUEST_FORMAT_MINOR {request['formatMinor']}U",
            f"#define {prefix}ACTIVATION_REQUEST_COMMIT "
            f"{c_value(request['commit'], kernel=kernel)}",
            f"#define {prefix}ACTIVATION_RESPONSE_TIMEOUT_MS "
            f"{activation['linuxResponseTimeoutMs']}U",
        ]
    )
    for name, entry in activation["states"].items():
        lines.append(f"#define {prefix}ACTIVATION_STATE_{macro(name)} {entry}U")
    for name, entry in activation["results"].items():
        lines.append(f"#define {prefix}ACTIVATION_RESULT_{macro(name)} {entry}U")
    for name, entry in activation["manifestFlags"].items():
        lines.append(
            f"#define {prefix}MANIFEST_FLAG_{macro(name)} (1U << {entry['bit']})"
        )

    lines.extend(
        [
            f"#define {prefix}MAILBOX_ADDRESS "
            f"{c_value(mailbox['address'], kernel=kernel, bits=64)}",
            f"#define {prefix}MAILBOX_SIZE "
            f"{c_value(mailbox['size'], kernel=kernel, bits=64)}",
            f"#define {prefix}MAILBOX_PAYLOAD_ADDRESS "
            f"{c_value(mailbox['payloadAddress'], kernel=kernel, bits=64)}",
            f"#define {prefix}MAILBOX_SLOT_COUNT {mailbox['slotCount']}U",
            f"#define {prefix}MAILBOX_PROCESSOR_COUNT {mailbox['processorCount']}U",
            f"#define {prefix}MAILBOX_CHANNEL_MASK "
            f"{c_value(mailbox_channel_mask, kernel=kernel)}",
            f"#define {prefix}LINUX_CPU_ID {mailbox['processorIds']['linux']}U",
            f"#define {prefix}RTOS_CPU_ID {mailbox['processorIds']['c906l']}U",
            f"#define {prefix}MAILBOX_LINUX_IRQ {mailbox['interrupts']['linux']}U",
            f"#define {prefix}MAILBOX_C906L_IRQ {mailbox['interrupts']['c906l']}U",
            f"#define {prefix}MAILBOX_HWSPIN_BASE_ADDRESS "
            f"{c_value(hwspin_base, kernel=kernel, bits=64)}",
            f"#define {prefix}MAILBOX_HWSPIN_REGISTER_COUNT "
            f"{hwspin['registerCount']}U",
            f"#define {prefix}MAILBOX_HWSPIN_REGISTER_STRIDE "
            f"{hwspin['registerStride']}U",
            f"#define {prefix}MAILBOX_HWSPIN_ACCESS_WIDTH " f"{hwspin['accessWidth']}U",
            f"#define {prefix}MAILBOX_HWSPIN_FIELD {hwspin['mailboxField']}U",
            f"#define {prefix}MAILBOX_HWSPIN_ADDRESS "
            f"{c_value(hwspin_address, kernel=kernel, bits=64)}",
            f"#define {prefix}MAILBOX_HWSPIN_TOKEN_WIDTH {hwspin['tokenWidth']}U",
            f"#define {prefix}MAILBOX_HWSPIN_LINUX_TOKEN_SHIFT "
            f"{hwspin['linuxTokenShift']}U",
            f"#define {prefix}MAILBOX_HWSPIN_C906L_TOKEN_SHIFT "
            f"{hwspin['c906lTokenShift']}U",
            f"#define {prefix}MAILBOX_HWSPIN_LINUX_TOKEN_MASK "
            f"{c_value(hwspin_token_value_mask << hwspin['linuxTokenShift'], kernel=kernel)}",
            f"#define {prefix}MAILBOX_HWSPIN_C906L_TOKEN_MASK "
            f"{c_value(hwspin_token_value_mask << hwspin['c906lTokenShift'], kernel=kernel)}",
            f"#define {prefix}MAILBOX_HWSPIN_TASK_ACQUIRE_ATTEMPTS "
            f"{hwspin['taskAcquireAttempts']}U",
            f"#define {prefix}MAILBOX_HWSPIN_IRQ_ACQUIRE_ATTEMPTS "
            f"{hwspin['irqAcquireAttempts']}U",
            f"#define {prefix}MAILBOX_HWSPIN_IRQ_CONSECUTIVE_DEFERRAL_LIMIT "
            f"{hwspin['irqConsecutiveDeferralLimit']}U",
        ]
    )
    for name, channel in mailbox["channels"].items():
        lines.append(f"#define {prefix}CHANNEL_{macro(name)} {channel}U")

    for name, region in memory["shared"]["regions"].items():
        stem = prefix + macro(name) + "_REGION"
        address = memory["shared"]["address"] + region["offset"]
        lines.extend(
            [
                f"#define {stem}_OFFSET {c_value(region['offset'], kernel=kernel, bits=64)}",
                f"#define {stem}_ADDRESS {c_value(address, kernel=kernel, bits=64)}",
                f"#define {stem}_SIZE {c_value(region['size'], kernel=kernel, bits=64)}",
            ]
        )

    lines.extend(
        [
            f"#define {prefix}RSC_TABLE_VERSION {rpmsg['resourceTable']['version']}U",
            f"#define {prefix}RSC_TABLE_ENTRIES {rpmsg['resourceTable']['entries']}U",
            f"#define {prefix}RSC_TABLE_ENTRY_OFFSET {rpmsg['resourceTable']['entryOffset']}U",
            f"#define {prefix}RSC_VDEV {rpmsg['resourceTable']['resourceTypeVdev']}U",
            f"#define {prefix}VIRTIO_ID_RPMSG {rpmsg['resourceTable']['virtioDeviceId']}U",
            f"#define {prefix}RSC_VDEV_NOTIFY_ID_INITIAL "
            f"{c_value(rpmsg['resourceTable']['notifyIdInitial'], kernel=kernel)}",
            f"#define {prefix}VIRTIO_RPMSG_FEATURES "
            f"{c_value(rpmsg['resourceTable']['deviceFeatures'], kernel=kernel)}",
            f"#define {prefix}RSC_GUEST_FEATURES_INITIAL "
            f"{c_value(rpmsg['resourceTable']['guestFeaturesInitial'], kernel=kernel)}",
            f"#define {prefix}RSC_CONFIG_LENGTH "
            f"{rpmsg['resourceTable']['configLength']}U",
            f"#define {prefix}RSC_STATUS_INITIAL "
            f"{rpmsg['resourceTable']['statusInitial']}U",
            f"#define {prefix}VIRTIO_DRIVER_OK "
            f"{c_value(rpmsg['resourceTable']['driverOkStatus'], kernel=kernel)}",
            f"#define {prefix}RSC_VRING_COUNT "
            f"{rpmsg['resourceTable']['vringCount']}U",
            f"#define {prefix}VRING_NOTIFY_ID_INITIAL "
            f"{c_value(rpmsg['resourceTable']['vringNotifyIdInitial'], kernel=kernel)}",
            f"#define {prefix}VRING_PHYSICAL_ADDRESS_INITIAL "
            f"{c_value(rpmsg['resourceTable']['vringPhysicalAddressInitial'], kernel=kernel)}",
            f"#define {prefix}RSC_TABLE_SERIALIZED_SIZE "
            f"{rpmsg['resourceTable']['serializedSize']}U",
            f"#define {prefix}VRING_ALIGN {rpmsg['vrings']['alignment']}U",
            f"#define {prefix}VRING_DESCRIPTORS {rpmsg['vrings']['descriptors']}U",
            f"#define {prefix}VRING_DRIVER_BYTES {rpmsg['vrings']['driverBytes']}U",
            f"#define {prefix}VRING_USED_OFFSET {rpmsg['vrings']['usedOffset']}U",
            f"#define {prefix}RPMSG_BUFFER_BYTES {rpmsg['buffers']['bufferSize']}U",
            f"#define {prefix}RPMSG_HEADER_BYTES {rpmsg['buffers']['headerSize']}U",
            f"#define {prefix}RPMSG_PAYLOAD_BYTES {rpmsg['buffers']['payloadSize']}U",
            f"#define {prefix}RPMSG_NS_ADDRESS {rpmsg['nameService']['address']}U",
            f"#define {prefix}RPMSG_NS_CREATE "
            f"{c_value(rpmsg['nameService']['createFlag'], kernel=kernel)}",
            f"#define {prefix}RPMSG_ECHO_ADDRESS "
            f"{c_value(rpmsg['echoService']['address'], kernel=kernel)}",
            f'#define {prefix}RPMSG_SERVICE_NAME "{rpmsg["echoService"]["name"]}"',
        ]
    )
    for name, flag in rpmsg["descriptorFlags"].items():
        lines.append(
            f"#define {prefix}VRING_DESC_F_{macro(name)} "
            f"{c_value(flag, kernel=kernel)}"
        )

    control = soc["coreControl"]
    lines.extend(
        [
            f"#define {prefix}RESET_ADDRESS "
            f"{c_value(control['reset']['address'], kernel=kernel, bits=64)}",
            f"#define {prefix}RESET_MASK (1U << {control['reset']['bit']})",
            f"#define {prefix}SECURITY_ENABLE_ADDRESS "
            f"{c_value(control['securityEnable']['address'], kernel=kernel, bits=64)}",
            f"#define {prefix}SECURITY_ENABLE_MASK "
            f"(1U << {control['securityEnable']['bit']})",
            f"#define {prefix}VECTOR_LOW_ADDRESS "
            f"{c_value(control['vectorLowAddress'], kernel=kernel, bits=64)}",
            f"#define {prefix}VECTOR_HIGH_ADDRESS "
            f"{c_value(control['vectorHighAddress'], kernel=kernel, bits=64)}",
        ]
    )

    for peripheral_name, timer in contract["peripheralLeases"].items():
        if timer["kind"] == "picoclaw-st7789":
            stem = prefix + macro(peripheral_name)
            lines.append(f"#define {prefix}HAVE_{macro(peripheral_name)} 1")
            lines.append(f'#define {stem}_SERVICE_NAME "{timer["service"]["name"]}"')
            for name, value in lcd_constants(timer).items():
                lines.append(f"#define {stem}_{name} {c_value(value, kernel=kernel)}")
            continue
        require(
            timer["kind"] == "dw-apb-timer-channel",
            f"unsupported peripheral kind: {timer['kind']}",
        )
        peripheral_prefix = prefix + macro(peripheral_name)
        lines.append(f"#define {prefix}HAVE_{macro(peripheral_name)} 1")
        lines.extend(
            [
                f"#define {peripheral_prefix}_IRQ {timer['irq']}U",
                f"#define {peripheral_prefix}_BANK_ADDRESS "
                f"{c_value(timer['bank']['address'], kernel=kernel, bits=64)}",
                f"#define {peripheral_prefix}_BANK_SIZE "
                f"{c_value(timer['bank']['size'], kernel=kernel, bits=64)}",
                f"#define {peripheral_prefix}_CLOCK_HZ {timer['selfTest']['clockHz']}U",
                f"#define {peripheral_prefix}_TEST_PERIOD_TICKS "
                f"{timer['selfTest']['periodTicks']}U",
                f"#define {peripheral_prefix}_TEST_TIMEOUT_RTOS_TICKS "
                f"{timer['selfTest']['timeoutRtosTicks']}U",
                f"#define {peripheral_prefix}_RTOS_TICK_HZ "
                f"{timer['selfTest']['rtosTickHz']}U",
            ]
        )
        for name, register in timer["registers"].items():
            lines.append(
                f"#define {peripheral_prefix}_{macro(name)}_ADDRESS "
                f"{c_value(register['address'], kernel=kernel, bits=64)}"
            )
        for name, precondition in timer["sharedPreconditions"].items():
            stem = peripheral_prefix + "_PRECONDITION_" + macro(name)
            lines.extend(
                [
                    f"#define {stem}_ADDRESS "
                    f"{c_value(precondition['address'], kernel=kernel, bits=64)}",
                    f"#define {stem}_MASK {c_value(precondition['mask'], kernel=kernel)}",
                    f"#define {stem}_EXPECTED "
                    f"{c_value(precondition['expected'], kernel=kernel)}",
                ]
            )
    return lines


def render_c_header(contract: dict[str, Any], digest: str, *, kernel: bool) -> str:
    guard = "SG2002_C906L_KERNEL_CONTRACT_H" if kernel else "SG2002_C906L_CONTRACT_H"
    includes = (
        "#include <linux/build_bug.h>\n#include <linux/stddef.h>\n#include <linux/types.h>"
        if kernel
        else "#include <stddef.h>\n#include <stdint.h>"
    )
    types = {
        1: "u8" if kernel else "uint8_t",
        2: "__le16" if kernel else "uint16_t",
        4: "__le32" if kernel else "uint32_t",
        8: "__le64" if kernel else "uint64_t",
    }
    abi = contract["abi"]
    macros = "\n".join(emit_macros(contract, digest, kernel=kernel))
    status_fields = []
    for field in abi["status"]["fields"]:
        name = snake(field["name"])
        status_fields.append(f"\t{types[field['width']]} {name};")
    message_suffix = (
        f" __packed __aligned({abi['message']['alignment']})"
        if kernel
        else f" __attribute__((packed, aligned({abi['message']['alignment']})))"
    )
    status_suffix = (
        f" __packed __aligned({abi['status']['alignment']})"
        if kernel
        else f" __attribute__((packed, aligned({abi['status']['alignment']})))"
    )
    record_suffix = (
        f" __packed __aligned({contract['activation']['manifest']['alignment']})"
        if kernel
        else " __attribute__((packed, aligned(64)))"
    )
    packed_suffix = " __packed" if kernel else " __attribute__((packed))"
    assertion = "static_assert" if kernel else "_Static_assert"
    offset_assertions = "\n".join(
        f'{assertion}(offsetof(struct sg2002_c906l_status, {snake(field["name"])}) '
        f'== {field["offset"]}, "status.{snake(field["name"])} offset");'
        for field in abi["status"]["fields"]
    )
    manifest_offset_assertions = "\n".join(
        f'{assertion}(offsetof(struct sg2002_c906l_manifest, {snake(field["name"])}) '
        f'== {field["offset"]}, "manifest.{snake(field["name"])} offset");'
        for field in contract["activation"]["manifest"]["fields"]
    )
    request_offset_assertions = "\n".join(
        f'{assertion}(offsetof(struct sg2002_c906l_activation_request, {snake(field["name"])}) '
        f'== {field["offset"]}, "activation_request.{snake(field["name"])} offset");'
        for field in contract["activation"]["request"]["fields"]
    )
    return f"""/* SPDX-License-Identifier: MIT */
/* Generated from the canonical SG2002 C906L contract.  Do not edit. */
#ifndef {guard}
#define {guard}

{includes}

{macros}

struct sg2002_c906l_message {{
\t{types[1]} service;
\t{types[1]} opcode;
\t{types[2]} sequence;
\t{types[4]} value;
}}{message_suffix};

struct sg2002_c906l_status {{
{chr(10).join(status_fields)}
}}{status_suffix};

struct sg2002_c906l_manifest {{
\t{types[4]} magic;
\t{types[2]} format_major;
\t{types[2]} format_minor;
\t{types[4]} struct_size;
\t{types[4]} generation;
\t{types[4]} contract_epoch;
\t{types[4]} profile_id;
\t{types[2]} abi_major;
\t{types[2]} abi_minor;
\t{types[2]} capability_width;
\t{types[2]} lease_width;
\t{types[8]} final_capabilities;
\t{types[8]} dormant_capabilities;
\t{types[8]} lease_mask;
\t{types[4]} flags;
\t{types[4]} reserved0;
\t{types[1]} contract_sha256[32];
\t{types[1]} reserved1[28];
\t{types[4]} commit;
}}{record_suffix};

struct sg2002_c906l_activation_request {{
\t{types[4]} magic;
\t{types[2]} format_major;
\t{types[2]} format_minor;
\t{types[4]} struct_size;
\t{types[4]} generation;
\t{types[4]} request_id;
\t{types[4]} contract_epoch;
\t{types[4]} profile_id;
\t{types[4]} abi_version;
\t{types[8]} final_capabilities;
\t{types[8]} lease_mask;
\t{types[1]} contract_sha256[32];
\t{types[1]} reserved[44];
\t{types[4]} commit;
}}{record_suffix};

struct sg2002_c906l_vring_resource {{
\t{types[4]} device_address;
\t{types[4]} align;
\t{types[4]} descriptors;
\t{types[4]} notify_id;
\t{types[4]} physical_address;
}}{packed_suffix};

struct sg2002_c906l_resource_snapshot {{
\t{types[4]} version;
\t{types[4]} entries;
\t{types[4]} reserved[2];
\t{types[4]} offset;
\t{types[4]} resource_type;
\t{types[4]} device_id;
\t{types[4]} notify_id;
\t{types[4]} device_features;
\t{types[4]} guest_features;
\t{types[4]} config_length;
\t{types[1]} status;
\t{types[1]} vring_count;
\t{types[1]} vdev_reserved[2];
\tstruct sg2002_c906l_vring_resource vrings[2];
}}{packed_suffix};

{assertion}(sizeof(struct sg2002_c906l_message) == SG2002_C906L_MESSAGE_SIZE,
\t"C906L mailbox message size");
{assertion}(__alignof__(struct sg2002_c906l_message) == {abi['message']['alignment']},
\t"C906L mailbox message alignment");
{assertion}(sizeof(struct sg2002_c906l_status) == SG2002_C906L_STATUS_SIZE,
\t"C906L status size");
{assertion}(__alignof__(struct sg2002_c906l_status) == {abi['status']['alignment']},
\t"C906L status alignment");
{assertion}(sizeof(struct sg2002_c906l_manifest) == SG2002_C906L_MANIFEST_SIZE,
\t"C906L manifest size");
{assertion}(__alignof__(struct sg2002_c906l_manifest) == {contract['activation']['manifest']['alignment']},
\t"C906L manifest alignment");
{assertion}(sizeof(struct sg2002_c906l_activation_request) ==
\tSG2002_C906L_ACTIVATION_REQUEST_SIZE, "C906L activation request size");
{assertion}(__alignof__(struct sg2002_c906l_activation_request) == {contract['activation']['request']['alignment']},
\t"C906L activation request alignment");
{assertion}(sizeof(struct sg2002_c906l_resource_snapshot) ==
\tSG2002_C906L_RSC_TABLE_SERIALIZED_SIZE, "C906L resource table size");
{offset_assertions}
{manifest_offset_assertions}
{request_offset_assertions}

#endif
"""


def render_rust(contract: dict[str, Any], digest: str) -> str:
    abi = contract["abi"]
    soc = contract["soc"]
    mailbox = soc["mailbox"]
    hwspin = mailbox["hardwareSpinlock"]
    hwspin_base = mailbox["address"] + hwspin["registerOffset"]
    hwspin_address = hwspin_base + hwspin["mailboxField"] * hwspin["registerStride"]
    hwspin_token_value_mask = (1 << hwspin["tokenWidth"]) - 1
    mailbox_channel_mask = sum(1 << channel for channel in mailbox["channels"].values())
    memory = contract["memory"]
    rpmsg = contract["rpmsg"]
    profile = contract["profile"]
    activation = contract["activation"]
    manifest = activation["manifest"]
    request = activation["request"]
    digest_bytes = ", ".join(f"0x{byte:02x}" for byte in bytes.fromhex(digest))
    lines = [
        "// SPDX-License-Identifier: MIT",
        "// Generated from the canonical SG2002 C906L contract.  Do not edit.",
        "",
        f'pub const PROFILE_NAME: &str = "{profile["name"]}";',
        f'pub const CONTRACT_SHA256_HEX: &str = "{digest}";',
        f"pub const CONTRACT_SHA256: [u8; 32] = [{digest_bytes}];",
        f"pub const CONTRACT_EPOCH: u32 = {contract['contractEpoch']};",
        f"pub const ABI_MAJOR: u16 = {abi['major']};",
        f"pub const ABI_MINOR: u16 = {abi['minor']};",
        f"pub const MESSAGE_SIZE: usize = {abi['message']['size']};",
        f"pub const STATUS_SIZE: usize = {abi['status']['size']};",
        f"pub const CAPABILITY_WIRE_WIDTH: u16 = {abi['capabilityWireWidth']};",
        f"pub const SHMEM_MAGIC: u32 = {hex_literal(abi['magic'])};",
        f"pub const EXPECTED_CAPABILITIES: u64 = {hex_literal(profile['expectedCapabilities'], 16)};",
        f"pub const DORMANT_CAPABILITIES: u64 = {hex_literal(profile['dormantCapabilities'], 16)};",
        f"pub const LEASE_MASK: u64 = {hex_literal(profile['leaseMask'], 16)};",
        f"pub const PROFILE_ID: u32 = {hex_literal(profile['profileId'])};",
        f"pub const MANIFEST_FLAGS: u32 = {hex_literal(profile['manifestFlags'])};",
        f"pub const ACTIVATION_REQUIRED: bool = {'true' if profile['activationRequired'] else 'false'};",
        f"pub const CACHE_LINE_SIZE: usize = {soc['cacheLineSize']};",
        f"pub const DRAM_ADDRESS: usize = {hex_literal(soc['dram']['address'])};",
        f"pub const DRAM_SIZE: usize = {hex_literal(soc['dram']['size'])};",
        f"pub const FIRMWARE_ADDRESS: usize = {hex_literal(memory['firmware']['address'])};",
        f"pub const FIRMWARE_SIZE: usize = {hex_literal(memory['firmware']['size'])};",
        f"pub const SHMEM_ADDRESS: usize = {hex_literal(memory['shared']['address'])};",
        f"pub const SHMEM_SIZE: usize = {hex_literal(memory['shared']['size'])};",
    ]
    for name, entry in abi["states"].items():
        lines.append(f"pub const STATE_{macro(name)}: u32 = {entry};")
    for name, entry in abi["services"].items():
        lines.append(f"pub const SERVICE_{macro(name)}: u8 = {entry};")
    for name, entry in abi["opcodes"].items():
        lines.append(f"pub const OP_{macro(name)}: u8 = {hex_literal(entry, 2)};")
    for name, entry in abi["capabilities"].items():
        lines.append(f"pub const CAP_{macro(name)}: u64 = 1 << {entry['bit']};")
    for name, entry in abi["flags"].items():
        lines.append(f"pub const FLAG_{macro(name)}: u32 = 1 << {entry['bit']};")
    lines.extend(
        [
            f"pub const LEASE_WIRE_WIDTH: u16 = {activation['leaseWireWidth']};",
            f"pub const MANIFEST_OFFSET: usize = {hex_literal(manifest['offset'])};",
            f"pub const MANIFEST_ADDRESS: usize = {hex_literal(memory['shared']['address'] + manifest['offset'])};",
            f"pub const MANIFEST_SIZE: usize = {manifest['size']};",
            f"pub const MANIFEST_MAGIC: u32 = {hex_literal(manifest['magic'])};",
            f"pub const MANIFEST_FORMAT_MAJOR: u16 = {manifest['formatMajor']};",
            f"pub const MANIFEST_FORMAT_MINOR: u16 = {manifest['formatMinor']};",
            f"pub const MANIFEST_COMMIT: u32 = {hex_literal(manifest['commit'])};",
            f"pub const ACTIVATION_REQUEST_OFFSET: usize = {hex_literal(request['offset'])};",
            f"pub const ACTIVATION_REQUEST_ADDRESS: usize = {hex_literal(memory['shared']['address'] + request['offset'])};",
            f"pub const ACTIVATION_REQUEST_SIZE: usize = {request['size']};",
            f"pub const ACTIVATION_REQUEST_MAGIC: u32 = {hex_literal(request['magic'])};",
            f"pub const ACTIVATION_REQUEST_FORMAT_MAJOR: u16 = {request['formatMajor']};",
            f"pub const ACTIVATION_REQUEST_FORMAT_MINOR: u16 = {request['formatMinor']};",
            f"pub const ACTIVATION_REQUEST_COMMIT: u32 = {hex_literal(request['commit'])};",
            f"pub const ACTIVATION_RESPONSE_TIMEOUT_MS: u32 = {activation['linuxResponseTimeoutMs']};",
        ]
    )
    for name, entry in activation["states"].items():
        lines.append(f"pub const ACTIVATION_STATE_{macro(name)}: u8 = {entry};")
    for name, entry in activation["results"].items():
        lines.append(f"pub const ACTIVATION_RESULT_{macro(name)}: u32 = {entry};")
    for name, entry in activation["manifestFlags"].items():
        lines.append(
            f"pub const MANIFEST_FLAG_{macro(name)}: u32 = 1 << {entry['bit']};"
        )
    lines.extend(
        [
            f"pub const MAILBOX_ADDRESS: usize = {hex_literal(mailbox['address'])};",
            f"pub const MAILBOX_SIZE: usize = {hex_literal(mailbox['size'])};",
            f"pub const MAILBOX_PAYLOAD_ADDRESS: usize = {hex_literal(mailbox['payloadAddress'])};",
            f"pub const MAILBOX_SLOT_COUNT: usize = {mailbox['slotCount']};",
            f"pub const MAILBOX_PROCESSOR_COUNT: usize = {mailbox['processorCount']};",
            f"pub const MAILBOX_CHANNEL_MASK: u8 = {hex_literal(mailbox_channel_mask, 2)};",
            f"pub const LINUX_CPU_ID: usize = {mailbox['processorIds']['linux']};",
            f"pub const RTOS_CPU_ID: usize = {mailbox['processorIds']['c906l']};",
            f"pub const MAILBOX_LINUX_IRQ: u32 = {mailbox['interrupts']['linux']};",
            f"pub const MAILBOX_C906L_IRQ: u32 = {mailbox['interrupts']['c906l']};",
            f"pub const MAILBOX_HWSPIN_BASE_ADDRESS: usize = {hex_literal(hwspin_base)};",
            f"pub const MAILBOX_HWSPIN_REGISTER_COUNT: usize = {hwspin['registerCount']};",
            f"pub const MAILBOX_HWSPIN_REGISTER_STRIDE: usize = {hwspin['registerStride']};",
            f"pub const MAILBOX_HWSPIN_ACCESS_WIDTH: usize = {hwspin['accessWidth']};",
            f"pub const MAILBOX_HWSPIN_FIELD: usize = {hwspin['mailboxField']};",
            f"pub const MAILBOX_HWSPIN_ADDRESS: usize = {hex_literal(hwspin_address)};",
            f"pub const MAILBOX_HWSPIN_TOKEN_WIDTH: u32 = {hwspin['tokenWidth']};",
            f"pub const MAILBOX_HWSPIN_LINUX_TOKEN_SHIFT: u32 = {hwspin['linuxTokenShift']};",
            f"pub const MAILBOX_HWSPIN_C906L_TOKEN_SHIFT: u32 = {hwspin['c906lTokenShift']};",
            f"pub const MAILBOX_HWSPIN_LINUX_TOKEN_MASK: u16 = {hex_literal(hwspin_token_value_mask << hwspin['linuxTokenShift'], 4)};",
            f"pub const MAILBOX_HWSPIN_C906L_TOKEN_MASK: u16 = {hex_literal(hwspin_token_value_mask << hwspin['c906lTokenShift'], 4)};",
            f"pub const MAILBOX_HWSPIN_TASK_ACQUIRE_ATTEMPTS: u32 = {hwspin['taskAcquireAttempts']};",
            f"pub const MAILBOX_HWSPIN_IRQ_ACQUIRE_ATTEMPTS: u32 = {hwspin['irqAcquireAttempts']};",
            f"pub const MAILBOX_HWSPIN_IRQ_CONSECUTIVE_DEFERRAL_LIMIT: u32 = {hwspin['irqConsecutiveDeferralLimit']};",
        ]
    )
    for name, channel in mailbox["channels"].items():
        lines.append(f"pub const CHANNEL_{macro(name)}: usize = {channel};")
    for name, region in memory["shared"]["regions"].items():
        stem = macro(name) + "_REGION"
        address = memory["shared"]["address"] + region["offset"]
        lines.extend(
            [
                f"pub const {stem}_OFFSET: usize = {hex_literal(region['offset'])};",
                f"pub const {stem}_ADDRESS: usize = {hex_literal(address)};",
                f"pub const {stem}_SIZE: usize = {hex_literal(region['size'])};",
            ]
        )
    for name, flag in rpmsg["descriptorFlags"].items():
        lines.append(
            f"pub const VRING_DESC_F_{macro(name)}: u16 = {hex_literal(flag, 4)};"
        )
    lines.extend(
        [
            f"pub const RSC_TABLE_VERSION: u32 = {rpmsg['resourceTable']['version']};",
            f"pub const RSC_TABLE_ENTRIES: u32 = {rpmsg['resourceTable']['entries']};",
            f"pub const RSC_TABLE_ENTRY_OFFSET: u32 = {rpmsg['resourceTable']['entryOffset']};",
            f"pub const RSC_VDEV: u32 = {rpmsg['resourceTable']['resourceTypeVdev']};",
            f"pub const VIRTIO_ID_RPMSG: u32 = {rpmsg['resourceTable']['virtioDeviceId']};",
            f"pub const VIRTIO_RPMSG_FEATURES: u32 = {hex_literal(rpmsg['resourceTable']['deviceFeatures'])};",
            f"pub const VRING_ALIGN: u32 = {rpmsg['vrings']['alignment']};",
            f"pub const VRING_DESCRIPTORS: usize = {rpmsg['vrings']['descriptors']};",
            f"pub const VRING_DRIVER_BYTES: usize = {rpmsg['vrings']['driverBytes']};",
            f"pub const VRING_USED_OFFSET: usize = {rpmsg['vrings']['usedOffset']};",
            f"pub const RSC_VDEV_NOTIFY_ID_INITIAL: u32 = {hex_literal(rpmsg['resourceTable']['notifyIdInitial'])};",
            f"pub const RSC_GUEST_FEATURES_INITIAL: u32 = {hex_literal(rpmsg['resourceTable']['guestFeaturesInitial'])};",
            f"pub const RSC_CONFIG_LENGTH: u32 = {rpmsg['resourceTable']['configLength']};",
            f"pub const RSC_STATUS_INITIAL: u8 = {rpmsg['resourceTable']['statusInitial']};",
            f"pub const RSC_VRING_COUNT: u8 = {rpmsg['resourceTable']['vringCount']};",
            f"pub const VIRTIO_DRIVER_OK: u8 = {hex_literal(rpmsg['resourceTable']['driverOkStatus'], 2)};",
            f"pub const VRING_NOTIFY_ID_INITIAL: u32 = {hex_literal(rpmsg['resourceTable']['vringNotifyIdInitial'])};",
            f"pub const VRING_PHYSICAL_ADDRESS_INITIAL: u32 = {hex_literal(rpmsg['resourceTable']['vringPhysicalAddressInitial'])};",
            f"pub const RSC_TABLE_SERIALIZED_SIZE: usize = {rpmsg['resourceTable']['serializedSize']};",
            f"pub const RPMSG_BUFFER_BYTES: usize = {rpmsg['buffers']['bufferSize']};",
            f"pub const RPMSG_HEADER_BYTES: usize = {rpmsg['buffers']['headerSize']};",
            f"pub const RPMSG_PAYLOAD_BYTES: usize = {rpmsg['buffers']['payloadSize']};",
            f"pub const RPMSG_NS_ADDRESS: u32 = {rpmsg['nameService']['address']};",
            f"pub const RPMSG_NS_CREATE: u32 = {rpmsg['nameService']['createFlag']};",
            f"pub const RPMSG_ECHO_ADDRESS: u32 = {hex_literal(rpmsg['echoService']['address'])};",
            f'pub const RPMSG_SERVICE_NAME: &[u8] = b"{rpmsg["echoService"]["name"]}";',
            "",
            "#[repr(C, align(8))]",
            "#[derive(Clone, Copy, Debug, Eq, PartialEq)]",
            "pub struct Message {",
            "    pub service: u8,",
            "    pub opcode: u8,",
            "    pub sequence: u16,",
            "    pub value: u32,",
            "}",
            "",
            "#[repr(C, align(64))]",
            "#[derive(Clone, Copy)]",
            "pub struct Status {",
            "    pub magic: u32,",
            "    pub abi_major: u16,",
            "    pub abi_minor: u16,",
            "    pub struct_size: u32,",
            "    pub state: u32,",
            "    pub generation: u32,",
            "    pub flags: u32,",
            "    pub heartbeat: u64,",
            "    pub capabilities: u64,",
            "    pub last_request: u64,",
            "    pub last_response: u64,",
            "    pub activation_state: u8,",
            "    pub activation_error: u8,",
            "    pub activation_attempts: u16,",
            "    pub activation_request_id: u32,",
            "}",
            "",
            "#[repr(C, align(64))]",
            "#[derive(Clone, Copy)]",
            "pub struct Manifest {",
            "    pub magic: u32,",
            "    pub format_major: u16,",
            "    pub format_minor: u16,",
            "    pub struct_size: u32,",
            "    pub generation: u32,",
            "    pub contract_epoch: u32,",
            "    pub profile_id: u32,",
            "    pub abi_major: u16,",
            "    pub abi_minor: u16,",
            "    pub capability_width: u16,",
            "    pub lease_width: u16,",
            "    pub final_capabilities: u64,",
            "    pub dormant_capabilities: u64,",
            "    pub lease_mask: u64,",
            "    pub flags: u32,",
            "    pub reserved0: u32,",
            "    pub contract_sha256: [u8; 32],",
            "    pub reserved1: [u8; 28],",
            "    pub commit: u32,",
            "}",
            "",
            "#[repr(C, align(64))]",
            "#[derive(Clone, Copy)]",
            "pub struct ActivationRequest {",
            "    pub magic: u32,",
            "    pub format_major: u16,",
            "    pub format_minor: u16,",
            "    pub struct_size: u32,",
            "    pub generation: u32,",
            "    pub request_id: u32,",
            "    pub contract_epoch: u32,",
            "    pub profile_id: u32,",
            "    pub abi_version: u32,",
            "    pub final_capabilities: u64,",
            "    pub lease_mask: u64,",
            "    pub contract_sha256: [u8; 32],",
            "    pub reserved: [u8; 44],",
            "    pub commit: u32,",
            "}",
            "",
            "const _: [(); 8] = [(); core::mem::size_of::<Message>()];",
            "const _: [(); 64] = [(); core::mem::size_of::<Status>()];",
            "const _: [(); 64] = [(); core::mem::align_of::<Status>()];",
            "const _: [(); 128] = [(); core::mem::size_of::<Manifest>()];",
            "const _: [(); 64] = [(); core::mem::align_of::<Manifest>()];",
            "const _: [(); 128] = [(); core::mem::size_of::<ActivationRequest>()];",
            "const _: [(); 64] = [(); core::mem::align_of::<ActivationRequest>()];",
        ]
    )
    control = soc["coreControl"]
    lines.extend(
        [
            f"pub const RESET_ADDRESS: usize = {hex_literal(control['reset']['address'])};",
            f"pub const RESET_MASK: u32 = {hex_literal(1 << control['reset']['bit'])};",
            f"pub const SECURITY_ENABLE_ADDRESS: usize = {hex_literal(control['securityEnable']['address'])};",
            f"pub const SECURITY_ENABLE_MASK: u32 = {hex_literal(1 << control['securityEnable']['bit'])};",
            f"pub const VECTOR_LOW_ADDRESS: usize = {hex_literal(control['vectorLowAddress'])};",
            f"pub const VECTOR_HIGH_ADDRESS: usize = {hex_literal(control['vectorHighAddress'])};",
        ]
    )
    for type_name, fields in (
        ("Status", abi["status"]["fields"]),
        ("Manifest", manifest["fields"]),
        ("ActivationRequest", request["fields"]),
    ):
        for field in fields:
            lines.append(
                f"const _: [(); {field['offset']}] = "
                f"[(); core::mem::offset_of!({type_name}, {snake(field['name'])})];"
            )
    for peripheral_name, timer in contract["peripheralLeases"].items():
        if timer["kind"] == "picoclaw-st7789":
            stem = macro(peripheral_name)
            lines.append(f"pub const HAVE_{stem}: bool = true;")
            lines.append(
                f'pub const {stem}_SERVICE_NAME: &str = "{timer["service"]["name"]}";'
            )
            for name, value in lcd_constants(timer).items():
                value_type = "usize" if name.endswith(("ADDRESS", "SIZE")) else "u32"
                lines.append(
                    f"pub const {stem}_{name}: {value_type} = {hex_literal(value)};"
                )
            conditions = timer["sharedPreconditions"].values()
            lines.append(
                f"pub const {stem}_SHARED_PRECONDITIONS: &[(usize, u32, u32)] = &["
            )
            for condition in conditions:
                lines.append(
                    "    ("
                    + ", ".join(
                        hex_literal(condition[field])
                        for field in ("address", "mask", "expected")
                    )
                    + "),"
                )
            lines.append("];")
            continue
        require(
            timer["kind"] == "dw-apb-timer-channel",
            f"unsupported peripheral kind: {timer['kind']}",
        )
        stem = macro(peripheral_name)
        lines.append(f"pub const HAVE_{stem}: bool = true;")
        lines.extend(
            [
                f"pub const {stem}_IRQ: u32 = {timer['irq']};",
                f"pub const {stem}_BANK_ADDRESS: usize = {hex_literal(timer['bank']['address'])};",
                f"pub const {stem}_BANK_SIZE: usize = {hex_literal(timer['bank']['size'])};",
                f"pub const {stem}_CLOCK_HZ: u32 = {timer['selfTest']['clockHz']};",
                f"pub const {stem}_TEST_PERIOD_TICKS: u32 = {timer['selfTest']['periodTicks']};",
                f"pub const {stem}_TEST_TIMEOUT_RTOS_TICKS: u32 = {timer['selfTest']['timeoutRtosTicks']};",
                f"pub const {stem}_RTOS_TICK_HZ: u32 = {timer['selfTest']['rtosTickHz']};",
            ]
        )
        for name, register in timer["registers"].items():
            lines.append(
                f"pub const {stem}_{macro(name)}_ADDRESS: usize = "
                f"{hex_literal(register['address'])};"
            )
        for name, precondition in timer["sharedPreconditions"].items():
            precondition_stem = stem + "_PRECONDITION_" + macro(name)
            lines.extend(
                [
                    f"pub const {precondition_stem}_ADDRESS: usize = "
                    f"{hex_literal(precondition['address'])};",
                    f"pub const {precondition_stem}_MASK: u32 = "
                    f"{hex_literal(precondition['mask'])};",
                    f"pub const {precondition_stem}_EXPECTED: u32 = "
                    f"{hex_literal(precondition['expected'])};",
                ]
            )
    return "\n".join(lines) + "\n"


def render_python(contract: dict[str, Any], digest: str) -> str:
    abi = contract["abi"]
    soc = contract["soc"]
    mailbox = soc["mailbox"]
    hwspin = mailbox["hardwareSpinlock"]
    hwspin_base = mailbox["address"] + hwspin["registerOffset"]
    hwspin_address = hwspin_base + hwspin["mailboxField"] * hwspin["registerStride"]
    hwspin_token_value_mask = (1 << hwspin["tokenWidth"]) - 1
    mailbox_channel_mask = sum(1 << channel for channel in mailbox["channels"].values())
    core_control = soc["coreControl"]
    memory = contract["memory"]
    rpmsg = contract["rpmsg"]
    profile = contract["profile"]
    lines = [
        "# SPDX-License-Identifier: MIT",
        "# Generated from the canonical SG2002 C906L contract.  Do not edit.",
        f'PROFILE_NAME = "{profile["name"]}"',
        f'CONTRACT_SHA256 = "{digest}"',
        f"CONTRACT_EPOCH = {contract['contractEpoch']}",
        f"ABI_MAJOR = {abi['major']}",
        f"ABI_MINOR = {abi['minor']}",
        f"CAPABILITY_WIRE_WIDTH = {abi['capabilityWireWidth']}",
        f"SHMEM_MAGIC = {hex_literal(abi['magic'])}",
        f"MESSAGE_SIZE = {abi['message']['size']}",
        f"STATUS_SIZE = {abi['status']['size']}",
        f"EXPECTED_CAPABILITIES = {hex_literal(profile['expectedCapabilities'])}",
        f"DORMANT_CAPABILITIES = {hex_literal(profile['dormantCapabilities'])}",
        f"LEASE_MASK = {hex_literal(profile['leaseMask'], 16)}",
        f"PROFILE_ID = {hex_literal(profile['profileId'])}",
        f"MANIFEST_FLAGS = {hex_literal(profile['manifestFlags'])}",
        f"ACTIVATION_REQUIRED = {profile['activationRequired']}",
        f"CACHE_LINE_SIZE = {soc['cacheLineSize']}",
        f"DRAM_ADDRESS = {hex_literal(soc['dram']['address'])}",
        f"DRAM_SIZE = {hex_literal(soc['dram']['size'])}",
        f"FIRMWARE_ADDRESS = {hex_literal(memory['firmware']['address'])}",
        f"FIRMWARE_SIZE = {hex_literal(memory['firmware']['size'])}",
        f"SHMEM_ADDRESS = {hex_literal(memory['shared']['address'])}",
        f"SHMEM_SIZE = {hex_literal(memory['shared']['size'])}",
        f"RPMSG_PAYLOAD_SIZE = {rpmsg['buffers']['payloadSize']}",
        f"MAILBOX_ADDRESS = {hex_literal(mailbox['address'])}",
        f"MAILBOX_SIZE = {hex_literal(mailbox['size'])}",
        f"MAILBOX_PAYLOAD_ADDRESS = {hex_literal(mailbox['payloadAddress'])}",
        f"MAILBOX_SLOT_COUNT = {mailbox['slotCount']}",
        f"MAILBOX_PROCESSOR_COUNT = {mailbox['processorCount']}",
        f"MAILBOX_CHANNEL_MASK = {hex_literal(mailbox_channel_mask, 2)}",
        f"MAILBOX_SLOT_SIZE = {mailbox['slotSize']}",
        f"LINUX_CPU_ID = {mailbox['processorIds']['linux']}",
        f"RTOS_CPU_ID = {mailbox['processorIds']['c906l']}",
        f"MAILBOX_LINUX_IRQ = {mailbox['interrupts']['linux']}",
        f"MAILBOX_C906L_IRQ = {mailbox['interrupts']['c906l']}",
        f"MAILBOX_HWSPIN_BASE_ADDRESS = {hex_literal(hwspin_base)}",
        f"MAILBOX_HWSPIN_REGISTER_COUNT = {hwspin['registerCount']}",
        f"MAILBOX_HWSPIN_REGISTER_STRIDE = {hwspin['registerStride']}",
        f"MAILBOX_HWSPIN_ACCESS_WIDTH = {hwspin['accessWidth']}",
        f"MAILBOX_HWSPIN_FIELD = {hwspin['mailboxField']}",
        f"MAILBOX_HWSPIN_ADDRESS = {hex_literal(hwspin_address)}",
        f"MAILBOX_HWSPIN_TOKEN_WIDTH = {hwspin['tokenWidth']}",
        f"MAILBOX_HWSPIN_LINUX_TOKEN_SHIFT = {hwspin['linuxTokenShift']}",
        f"MAILBOX_HWSPIN_C906L_TOKEN_SHIFT = {hwspin['c906lTokenShift']}",
        f"MAILBOX_HWSPIN_LINUX_TOKEN_MASK = {hex_literal(hwspin_token_value_mask << hwspin['linuxTokenShift'], 4)}",
        f"MAILBOX_HWSPIN_C906L_TOKEN_MASK = {hex_literal(hwspin_token_value_mask << hwspin['c906lTokenShift'], 4)}",
        f"MAILBOX_HWSPIN_TASK_ACQUIRE_ATTEMPTS = {hwspin['taskAcquireAttempts']}",
        f"MAILBOX_HWSPIN_IRQ_ACQUIRE_ATTEMPTS = {hwspin['irqAcquireAttempts']}",
        f"MAILBOX_HWSPIN_IRQ_CONSECUTIVE_DEFERRAL_LIMIT = {hwspin['irqConsecutiveDeferralLimit']}",
        f"RESET_ADDRESS = {hex_literal(core_control['reset']['address'])}",
        f"RESET_MASK = {hex_literal(1 << core_control['reset']['bit'])}",
        f"RESET_RELEASED_WHEN_SET = {core_control['reset']['releasedWhenSet']}",
        f"SECURITY_ENABLE_ADDRESS = {hex_literal(core_control['securityEnable']['address'])}",
        f"SECURITY_ENABLE_MASK = {hex_literal(1 << core_control['securityEnable']['bit'])}",
        f"SECURITY_ENABLED_WHEN_SET = {core_control['securityEnable']['enabledWhenSet']}",
        f"VECTOR_LOW_ADDRESS = {hex_literal(core_control['vectorLowAddress'])}",
        f"VECTOR_HIGH_ADDRESS = {hex_literal(core_control['vectorHighAddress'])}",
        f"LEASE_WIRE_WIDTH = {contract['activation']['leaseWireWidth']}",
        f"MANIFEST_OFFSET = {hex_literal(contract['activation']['manifest']['offset'])}",
        f"MANIFEST_ADDRESS = {hex_literal(memory['shared']['address'] + contract['activation']['manifest']['offset'])}",
        f"MANIFEST_SIZE = {contract['activation']['manifest']['size']}",
        f"MANIFEST_MAGIC = {hex_literal(contract['activation']['manifest']['magic'])}",
        f"MANIFEST_FORMAT_MAJOR = {contract['activation']['manifest']['formatMajor']}",
        f"MANIFEST_FORMAT_MINOR = {contract['activation']['manifest']['formatMinor']}",
        f"MANIFEST_COMMIT = {hex_literal(contract['activation']['manifest']['commit'])}",
        f"ACTIVATION_REQUEST_OFFSET = {hex_literal(contract['activation']['request']['offset'])}",
        f"ACTIVATION_REQUEST_ADDRESS = {hex_literal(memory['shared']['address'] + contract['activation']['request']['offset'])}",
        f"ACTIVATION_REQUEST_SIZE = {contract['activation']['request']['size']}",
        f"ACTIVATION_REQUEST_MAGIC = {hex_literal(contract['activation']['request']['magic'])}",
        f"ACTIVATION_REQUEST_FORMAT_MAJOR = {contract['activation']['request']['formatMajor']}",
        f"ACTIVATION_REQUEST_FORMAT_MINOR = {contract['activation']['request']['formatMinor']}",
        f"ACTIVATION_REQUEST_COMMIT = {hex_literal(contract['activation']['request']['commit'])}",
        f"ACTIVATION_RESPONSE_TIMEOUT_MS = {contract['activation']['linuxResponseTimeoutMs']}",
    ]
    for name, entry in abi["states"].items():
        lines.append(f"STATE_{macro(name)} = {entry}")
    for name, entry in abi["services"].items():
        lines.append(f"SERVICE_{macro(name)} = {entry}")
    for name, entry in abi["opcodes"].items():
        lines.append(f"OP_{macro(name)} = {hex_literal(entry, 2)}")
    for name, entry in abi["capabilities"].items():
        lines.append(f"CAP_{macro(name)} = 1 << {entry['bit']}")
    for name, entry in abi["flags"].items():
        lines.append(f"FLAG_{macro(name)} = 1 << {entry['bit']}")
    for name, entry in contract["activation"]["states"].items():
        lines.append(f"ACTIVATION_STATE_{macro(name)} = {entry}")
    for name, entry in contract["activation"]["results"].items():
        lines.append(f"ACTIVATION_RESULT_{macro(name)} = {entry}")
    for name, entry in contract["activation"]["manifestFlags"].items():
        lines.append(f"MANIFEST_FLAG_{macro(name)} = 1 << {entry['bit']}")
    for name, channel in mailbox["channels"].items():
        lines.append(f"CHANNEL_{macro(name)} = {channel}")
    for name, region in memory["shared"]["regions"].items():
        stem = macro(name) + "_REGION"
        lines.append(f"{stem}_OFFSET = {hex_literal(region['offset'])}")
        lines.append(
            f"{stem}_ADDRESS = {hex_literal(memory['shared']['address'] + region['offset'])}"
        )
        lines.append(f"{stem}_SIZE = {hex_literal(region['size'])}")
    for peripheral_name, peripheral in contract["peripheralLeases"].items():
        stem = macro(peripheral_name)
        lines.append(f"HAVE_{stem} = True")
        if peripheral["kind"] == "picoclaw-st7789":
            lines.append(f'{stem}_SERVICE_NAME = "{peripheral["service"]["name"]}"')
            for name, value in lcd_constants(peripheral).items():
                lines.append(f"{stem}_{name} = {hex_literal(value)}")
            continue
        lines.append(f"{stem}_IRQ = {peripheral['irq']}")
        lines.append(
            f"{stem}_BANK_ADDRESS = {hex_literal(peripheral['bank']['address'])}"
        )
        lines.append(f"{stem}_BANK_SIZE = {hex_literal(peripheral['bank']['size'])}")
        lines.append(f"{stem}_CLOCK_HZ = {peripheral['selfTest']['clockHz']}")
        lines.append(
            f"{stem}_TEST_PERIOD_TICKS = {peripheral['selfTest']['periodTicks']}"
        )
        lines.append(
            f"{stem}_TEST_TIMEOUT_RTOS_TICKS = "
            f"{peripheral['selfTest']['timeoutRtosTicks']}"
        )
        lines.append(f"{stem}_RTOS_TICK_HZ = {peripheral['selfTest']['rtosTickHz']}")
        for register_name, register in peripheral["registers"].items():
            lines.append(
                f"{stem}_{macro(register_name)}_ADDRESS = "
                f"{hex_literal(register['address'])}"
            )
        for precondition_name, precondition in peripheral[
            "sharedPreconditions"
        ].items():
            precondition_stem = f"{stem}_PRECONDITION_{macro(precondition_name)}"
            lines.append(
                f"{precondition_stem}_ADDRESS = "
                f"{hex_literal(precondition['address'])}"
            )
            lines.append(
                f"{precondition_stem}_MASK = {hex_literal(precondition['mask'])}"
            )
            lines.append(
                f"{precondition_stem}_EXPECTED = "
                f"{hex_literal(precondition['expected'])}"
            )
    return "\n".join(lines) + "\n"


def linux_dt_lease_resources(
    contract: dict[str, Any],
) -> tuple[list[tuple[str, int, int]], list[tuple[str, int]]]:
    """Return physical MMIO ranges and C906L-local IRQs for the final-DT guard.

    New peripheral kinds should carry explicit ``linuxLease.mmioRanges``.  The
    timer fallback keeps ABI-1.1's already-published contract digest stable
    while deriving the exact 0x14-byte DesignWare channel aperture rather than
    claiming or disabling the shared 64 KiB timer bank.
    """

    ranges: list[tuple[str, int, int]] = []
    irqs: list[tuple[str, int]] = []
    for name in contract["profile"]["peripherals"]:
        peripheral = contract["peripheralLeases"][name]
        linux_lease = peripheral["linuxLease"]
        explicit_ranges = linux_lease.get("mmioRanges")
        if explicit_ranges is not None:
            require(
                isinstance(explicit_ranges, list), f"{name} MMIO ranges are not a list"
            )
            resource_ranges = [
                (entry["address"], entry["size"]) for entry in explicit_ranges
            ]
        elif peripheral["kind"] == "dw-apb-timer-channel":
            channel_size = 0x14
            address = peripheral["bank"]["address"] + (
                peripheral["bank"]["channel"] * channel_size
            )
            resource_ranges = [(address, channel_size)]
            for register_name, register in peripheral["registers"].items():
                require(
                    address <= register["address"] < address + channel_size,
                    f"{name} {register_name} register lies outside its channel lease",
                )
        else:
            raise ValueError(
                f"{name} ({peripheral['kind']}) needs explicit linuxLease.mmioRanges"
            )

        require(resource_ranges, f"{name} has no Linux-excluded MMIO range")
        for address, size in resource_ranges:
            require(isinstance(address, int), f"{name} MMIO address is not an integer")
            require(isinstance(size, int), f"{name} MMIO size is not an integer")
            require(0 <= address < 1 << 64, f"{name} MMIO address does not fit u64")
            require(0 < size < 1 << 64, f"{name} MMIO size does not fit u64")
            require(address + size <= 1 << 64, f"{name} MMIO range exceeds u64")
            ranges.append((name, address, size))

        local_irqs = linux_lease.get("localIrqs")
        if local_irqs is None:
            local_irqs = [peripheral["irq"]]
        for irq in local_irqs:
            require(
                isinstance(irq, int) and 0 <= irq < 1 << 32,
                f"{name} C906L IRQ is invalid",
            )
            irqs.append((name, irq))

    for index, (_name, address, size) in enumerate(ranges):
        for other_name, other_address, other_size in ranges[index + 1 :]:
            require(
                address + size <= other_address
                or other_address + other_size <= address,
                f"C906L MMIO leases overlap near {other_name}",
            )
    return ranges, irqs


def render_dts(contract: dict[str, Any], digest: str) -> str:
    memory = contract["memory"]
    mailbox = contract["soc"]["mailbox"]
    profile = contract["profile"]
    abi_word = contract["abi"]["major"] << 16 | contract["abi"]["minor"]
    digest_cells = " ".join(f"{byte:02x}" for byte in bytes.fromhex(digest))
    lease_property = ""
    lease_resource_properties = ""
    if profile["peripherals"]:
        leases = ", ".join(f'"{name}"' for name in profile["peripherals"])
        lease_property = f"\n\t\tsophgo,leased-peripherals = {leases};"
        mmio_ranges, c906l_irqs = linux_dt_lease_resources(contract)
        range_cells = " ".join(
            f"{hex_literal(address, 16)} {hex_literal(size, 16)}"
            for _owner, address, size in mmio_ranges
        )
        range_owners = ", ".join(f'"{owner}"' for owner, _address, _size in mmio_ranges)
        irq_cells = " ".join(str(irq) for _owner, irq in c906l_irqs)
        irq_owners = ", ".join(f'"{owner}"' for owner, _irq in c906l_irqs)
        lease_resource_properties = f"""
\t\tsophgo,c906l-leased-mmio-ranges = /bits/ 64 <{range_cells}>;
\t\tsophgo,c906l-leased-mmio-range-owners = {range_owners};"""
        if c906l_irqs:
            lease_resource_properties += f"""
\t\tsophgo,c906l-local-irqs = <{irq_cells}>;
\t\tsophgo,c906l-local-irq-owners = {irq_owners};"""
    activation_property = (
        "\n\t\tsophgo,activation-required;" if profile["activationRequired"] else ""
    )
    common_properties = f"""
\t\tsophgo,contract-sha256 = [{digest_cells}];
\t\tsophgo,contract-epoch = <{contract['contractEpoch']}>;
\t\tsophgo,abi-version = <{hex_literal(abi_word)}>;
\t\tsophgo,expected-capabilities = /bits/ 64 <{hex_literal(profile['expectedCapabilities'], 16)}>;
\t\tsophgo,dormant-capabilities = /bits/ 64 <{hex_literal(profile['dormantCapabilities'], 16)}>;
\t\tsophgo,lease-mask = /bits/ 64 <{hex_literal(profile['leaseMask'], 16)}>;
\t\tsophgo,profile-id = <{hex_literal(profile['profileId'])}>;
\t\tsophgo,manifest-flags = <{hex_literal(profile['manifestFlags'])}>;
\t\tsophgo,profile = "{profile['name']}";{activation_property}{lease_property}"""
    return f"""/* SPDX-License-Identifier: (GPL-2.0 OR MIT) */
/* Generated from the canonical SG2002 C906L contract.  Do not edit. */

/ {{
\treserved-memory {{
\t\t#address-cells = <1>;
\t\t#size-cells = <1>;
\t\tranges;

\t\tc906l_firmware: c906l-firmware@{memory['firmware']['address']:x} {{
\t\t\treg = <{hex_literal(memory['firmware']['address'])} {hex_literal(memory['firmware']['size'])}>;
\t\t\tno-map;
\t\t}};

\t\tc906l_shmem: c906l-shmem@{memory['shared']['address']:x} {{
\t\t\treg = <{hex_literal(memory['shared']['address'])} {hex_literal(memory['shared']['size'])}>;
\t\t\tno-map;
\t\t}};
\t}};

\tc906l-control {{
\t\tcompatible = "sophgo,sg2002-c906l-control";
\t\tmboxes = <&mailbox {mailbox['channels']['control']} {mailbox['processorIds']['c906l']}>;
\t\tmbox-names = "control";
\t\tmemory-region = <&c906l_shmem>;{common_properties}{lease_resource_properties}
\t}};

\tc906l-rproc {{
\t\tcompatible = "sophgo,sg2002-c906l-rproc";
\t\tmboxes = <&mailbox {mailbox['channels']['vqKick']} {mailbox['processorIds']['c906l']}>,
\t\t\t  <&mailbox {mailbox['channels']['vqNotify']} {mailbox['processorIds']['c906l']}>;
\t\tmbox-names = "vq-kick", "vq-notify";
\t\tmemory-region = <&c906l_shmem>;{common_properties}
\t}};
}};

&{{/soc}} {{
\tmailbox: mailbox@{mailbox['address']:x} {{
\t\tcompatible = "sophgo,cv1800b-mailbox";
\t\treg = <{hex_literal(mailbox['address'])} {hex_literal(mailbox['size'])}>;
\t\tinterrupts = <{mailbox['interrupts']['linux']} IRQ_TYPE_LEVEL_HIGH>;
\t\t#mbox-cells = <2>;
\t}};
}};
"""


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def generate(contract_path: Path, expected_sha256: str, output: Path) -> None:
    contract, semantic = load_resolved(contract_path, expected_sha256)
    require(not output.exists(), f"output path already exists: {output}")
    output.mkdir(parents=True)

    digest = hashlib.sha256(semantic).hexdigest()
    (output / "share/sg2002-c906l").mkdir(parents=True)
    (output / "share/sg2002-c906l/contract.json").write_bytes(
        contract_path.read_bytes()
    )
    (output / "share/sg2002-c906l/contract.semantic.json").write_bytes(semantic)
    write_text(
        output / "share/sg2002-c906l/contract.sha256",
        f"{digest}  contract.semantic.json\n",
    )
    write_text(
        output / "include/sg2002-c906l-contract.h",
        render_c_header(contract, digest, kernel=False),
    )
    write_text(
        output / "include/sg2002-c906l-kernel-contract.h",
        render_c_header(contract, digest, kernel=True),
    )
    write_text(output / "rust/generated_contract.rs", render_rust(contract, digest))
    write_text(
        output / "python/sg2002_c906l_contract.py", render_python(contract, digest)
    )
    write_text(output / "dts/sg2002-c906l-contract.dtsi", render_dts(contract, digest))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    generate(args.contract, args.sha256, args.output)


if __name__ == "__main__":
    main()
