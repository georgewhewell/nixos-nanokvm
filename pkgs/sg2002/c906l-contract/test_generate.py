#!/usr/bin/env python3
"""Focused host tests for deterministic C906L contract generation."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import struct
import tempfile
import unittest
from pathlib import Path


def load_generator(path: Path):
    spec = importlib.util.spec_from_file_location("c906l_contract_generator", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load generator from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ContractGenerationTests(unittest.TestCase):
    generator_path: Path
    profile_arguments: list[tuple[str, Path, str]]

    @classmethod
    def setUpClass(cls) -> None:
        cls.generator = load_generator(cls.generator_path)
        cls.profiles = {}
        for name, path, digest in cls.profile_arguments:
            contract, semantic = cls.generator.load_resolved(path, digest)
            if name in cls.profiles:
                raise RuntimeError(f"duplicate profile argument: {name}")
            cls.profiles[name] = (path, digest, contract, semantic)
        cls.base_path, cls.base_sha256, cls.base, cls.base_semantic = cls.profiles[
            "base"
        ]
        (
            cls.timer4_path,
            cls.timer4_sha256,
            cls.timer4,
            cls.timer4_semantic,
        ) = cls.profiles["timer4"]
        cls.timer_profiles = {
            name: cls.profiles[name]
            for name in ("timer4", "timer5", "timer6", "timer7")
        }

    def generate(self, contract: Path, digest: str, output: Path) -> None:
        self.generator.generate(contract, digest, output)

    @staticmethod
    def tree_bytes(root: Path) -> dict[str, bytes]:
        return {
            str(path.relative_to(root)): path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_file()
        }

    def load_modified(self, contract: dict, root: Path) -> None:
        path = root / "modified.json"
        encoded = self.generator.canonical_json(contract)
        path.write_bytes(encoded)
        digest = hashlib.sha256(
            self.generator.canonical_json(self.generator.strip_documentation(contract))
        ).hexdigest()
        self.generator.load_resolved(path, digest)

    def combined_timer4_timer5(self) -> dict:
        contract = copy.deepcopy(self.timer4)
        contract["profile"] = {
            "name": "custom-timer4-timer5",
            "peripherals": ["timer4", "timer5"],
            "capabilities": [
                "mailbox",
                "rpmsg",
                "shmemHeartbeat",
                "timer4SelfTest",
                "timer5SelfTest",
            ],
            "activationRequired": True,
            "dormantCapabilities": 0x0B,
            "expectedCapabilities": 0x1F,
            "leaseMask": 3,
            "manifestFlags": 3,
            "profileId": 4,
        }
        contract["peripheralLeases"]["timer5"] = copy.deepcopy(
            self.profiles["timer5"][2]["peripheralLeases"]["timer5"]
        )
        return contract

    def test_profiles_have_exact_current_capabilities(self) -> None:
        self.assertEqual(self.base["profile"]["name"], "base")
        self.assertEqual(self.base["profile"]["expectedCapabilities"], 0x0B)
        self.assertEqual(self.base["profile"]["dormantCapabilities"], 0x0B)
        self.assertEqual(self.base["profile"]["leaseMask"], 0)
        self.assertEqual(self.base["profile"]["profileId"], 1)
        self.assertFalse(self.base["profile"]["activationRequired"])
        self.assertEqual(self.base["profile"]["peripherals"], [])
        self.assertEqual(self.timer4["profile"]["name"], "timer4")
        self.assertEqual(self.timer4["profile"]["expectedCapabilities"], 0x0F)
        self.assertEqual(self.timer4["profile"]["dormantCapabilities"], 0x0B)
        self.assertEqual(self.timer4["profile"]["leaseMask"], 1)
        self.assertEqual(self.timer4["profile"]["profileId"], 2)
        self.assertTrue(self.timer4["profile"]["activationRequired"])
        self.assertEqual(self.timer4["profile"]["peripherals"], ["timer4"])
        self.assertNotEqual(self.base_sha256, self.timer4_sha256)
        expected = {
            "timer4": (0x0F, 1, 2),
            "timer5": (0x1B, 2, 3),
            "timer6": (0x2B, 4, 5),
            "timer7": (0x4B, 8, 9),
        }
        for name, (_path, digest, contract, _semantic) in self.timer_profiles.items():
            with self.subTest(profile=name):
                capabilities, lease_mask, profile_id = expected[name]
                self.assertEqual(contract["profile"]["name"], name)
                self.assertEqual(
                    contract["profile"]["expectedCapabilities"], capabilities
                )
                self.assertEqual(contract["profile"]["dormantCapabilities"], 0x0B)
                self.assertEqual(contract["profile"]["leaseMask"], lease_mask)
                self.assertEqual(contract["profile"]["profileId"], profile_id)
                self.assertTrue(contract["profile"]["activationRequired"])
                self.assertEqual(contract["profile"]["peripherals"], [name])
                self.assertNotEqual(self.base_sha256, digest)

    def test_digest_is_over_semantic_canonical_json(self) -> None:
        for name, (_path, digest, _contract, semantic) in self.profiles.items():
            with self.subTest(profile=name):
                self.assertEqual(hashlib.sha256(semantic).hexdigest(), digest)
        documented = dict(self.base)
        documented["spdxLicense"] = "documentation-only change"
        self.assertEqual(
            self.generator.canonical_json(
                self.generator.strip_documentation(documented)
            ),
            self.base_semantic,
        )

    def test_shared_memory_is_exactly_partitioned(self) -> None:
        shared = self.base["memory"]["shared"]
        cursor = 0
        for region in sorted(
            shared["regions"].values(), key=lambda item: item["offset"]
        ):
            self.assertEqual(region["offset"], cursor)
            self.assertEqual(region["offset"] % 4096, 0)
            self.assertEqual(region["size"] % 4096, 0)
            cursor += region["size"]
        self.assertEqual(cursor, shared["size"])
        self.assertEqual(shared["address"] + shared["size"], 0x90000000)

    def test_vring_directions_match_linux_rpmsg(self) -> None:
        vrings = self.base["rpmsg"]["vrings"]
        self.assertEqual(vrings["deviceToDriverRegion"], "rpmsgVring0")
        self.assertEqual(vrings["driverToDeviceRegion"], "rpmsgVring1")

    def test_mailbox_hardware_spinlock_matches_vendor_protocol(self) -> None:
        mailbox = self.base["soc"]["mailbox"]
        hwspin = mailbox["hardwareSpinlock"]
        base = mailbox["address"] + hwspin["registerOffset"]
        register = base + hwspin["mailboxField"] * hwspin["registerStride"]
        self.assertEqual(base, 0x019000C0)
        self.assertEqual(register, 0x019000D0)
        self.assertEqual(hwspin["registerCount"], 8)
        self.assertEqual(hwspin["registerStride"], 4)
        self.assertEqual(hwspin["accessWidth"], 2)
        self.assertEqual(hwspin["mailboxField"], 4)
        self.assertEqual(mailbox["processorCount"], 4)
        self.assertEqual(hwspin["tokenWidth"], 8)
        self.assertEqual(hwspin["linuxTokenShift"], 0)
        self.assertEqual(hwspin["c906lTokenShift"], 8)
        self.assertGreater(hwspin["taskAcquireAttempts"], 0)
        self.assertGreater(hwspin["irqAcquireAttempts"], 0)
        self.assertEqual(hwspin["irqConsecutiveDeferralLimit"], 16)
        self.assertLessEqual(
            hwspin["irqAcquireAttempts"], hwspin["taskAcquireAttempts"]
        )

    def test_wire_layout_fixtures_are_exact(self) -> None:
        message = struct.pack("<BBHI", 1, 3, 0x1234, 0x89ABCDEF)
        self.assertEqual(message, bytes.fromhex("01 03 34 12 ef cd ab 89"))
        self.assertEqual(len(message), self.base["abi"]["message"]["size"])

        status = struct.pack(
            "<IHHIIIIQQQQBBHI",
            0x4D564B4E,
            1,
            0,
            64,
            2,
            7,
            0,
            11,
            0x0B,
            0x1122334455667788,
            0x8877665544332211,
            1,
            0,
            0,
            0,
        )
        self.assertEqual(len(status), self.base["abi"]["status"]["size"])
        for field in self.base["abi"]["status"]["fields"]:
            self.assertLessEqual(field["offset"] + field["width"], len(status))

        manifest = struct.pack(
            "<IHHIIIIHHHHQQQII32s28sI",
            0x31434B4E,
            1,
            0,
            128,
            7,
            2,
            2,
            1,
            1,
            64,
            32,
            0x0F,
            0x0B,
            1,
            3,
            0,
            bytes.fromhex(self.timer4_sha256),
            bytes(28),
            0x54494D43,
        )
        self.assertEqual(len(manifest), 128)

        activation = struct.pack(
            "<IHHIIIIIIQQ32s44sI",
            0x31414B4E,
            1,
            0,
            128,
            7,
            0x12345678,
            2,
            2,
            0x00010001,
            0x0F,
            1,
            bytes.fromhex(self.timer4_sha256),
            bytes(44),
            0x314B4341,
        )
        self.assertEqual(len(activation), 128)

        resource_snapshot_format = "<" + "I" * 11 + "B" * 4 + "I" * 10
        self.assertEqual(
            struct.calcsize(resource_snapshot_format),
            self.base["rpmsg"]["resourceTable"]["serializedSize"],
        )

    def test_generation_is_byte_deterministic(self) -> None:
        for name, (path, digest, _contract, _semantic) in self.profiles.items():
            with self.subTest(profile=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                first = root / "first"
                second = root / "second"
                self.generate(path, digest, first)
                self.generate(path, digest, second)
                self.assertEqual(self.tree_bytes(first), self.tree_bytes(second))

    def test_generated_bindings_carry_profile_and_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "out"
            self.generate(self.base_path, self.base_sha256, output)
            generated = self.tree_bytes(output)
            self.assertEqual(
                generated["share/sg2002-c906l/contract.json"],
                self.base_path.read_bytes(),
            )
            header = generated["include/sg2002-c906l-contract.h"].decode()
            self.assertIn(
                "SG2002_C906L_EXPECTED_CAPABILITIES UINT64_C(0x000000000000000b)",
                header,
            )
            self.assertIn("SG2002_C906L_RPMSG_PAYLOAD_BYTES 496U", header)
            self.assertNotIn("SG2002_C906L_HAVE_TIMER4", header)
            self.assertIn("SG2002_C906L_STATUS_SIZE 64U", header)
            self.assertIn("SG2002_C906L_ABI_MINOR 1U", header)
            self.assertIn("SG2002_C906L_CAPABILITY_WIRE_WIDTH 64U", header)
            self.assertIn("SG2002_C906L_MAILBOX_PROCESSOR_COUNT 4U", header)
            self.assertIn(
                "SG2002_C906L_MAILBOX_CHANNEL_MASK UINT32_C(0x00000007)",
                header,
            )
            self.assertIn(
                "SG2002_C906L_MAILBOX_HWSPIN_ADDRESS " "UINT64_C(0x00000000019000d0)",
                header,
            )
            self.assertIn(
                "SG2002_C906L_MAILBOX_HWSPIN_C906L_TOKEN_MASK " "UINT32_C(0x0000ff00)",
                header,
            )
            self.assertIn("SG2002_C906L_CONTRACT_EPOCH 2U", header)
            self.assertIn("SG2002_C906L_MANIFEST_SIZE 128U", header)
            self.assertIn("SG2002_C906L_ACTIVATION_REQUEST_SIZE 128U", header)
            self.assertIn("__attribute__((packed, aligned(8)))", header)
            self.assertIn("__attribute__((packed, aligned(64)))", header)
            self.assertIn(
                "SG2002_C906L_STATUS_REGION_SIZE UINT64_C(0x0000000000001000)",
                header,
            )
            rust = generated["rust/generated_contract.rs"].decode()
            self.assertIn('pub const PROFILE_NAME: &str = "base";', rust)
            self.assertIn("pub const PROFILE_ID: u32 = 0x00000001;", rust)
            self.assertIn("pub const ACTIVATION_REQUIRED: bool = false;", rust)
            self.assertIn("pub const RPMSG_PAYLOAD_BYTES: usize = 496;", rust)
            self.assertIn("pub const RSC_TABLE_VERSION: u32 = 1;", rust)
            self.assertIn("pub const RSC_TABLE_ENTRIES: u32 = 1;", rust)
            self.assertIn("pub const RSC_TABLE_ENTRY_OFFSET: u32 = 20;", rust)
            self.assertIn("pub const RSC_VDEV: u32 = 3;", rust)
            self.assertIn("pub const VIRTIO_ID_RPMSG: u32 = 7;", rust)
            self.assertIn("pub const VIRTIO_RPMSG_FEATURES: u32 = 0x00000001;", rust)
            self.assertIn("pub const RSC_TABLE_SERIALIZED_SIZE: usize = 88;", rust)
            self.assertIn("pub const MAILBOX_C906L_IRQ: u32 = 61;", rust)
            self.assertIn("pub const MAILBOX_PROCESSOR_COUNT: usize = 4;", rust)
            self.assertIn("pub const MAILBOX_CHANNEL_MASK: u8 = 0x07;", rust)
            self.assertIn(
                "pub const MAILBOX_HWSPIN_IRQ_CONSECUTIVE_DEFERRAL_LIMIT: u32 = 16;",
                rust,
            )
            self.assertIn("pub const MAILBOX_HWSPIN_ADDRESS: usize = 0x019000d0;", rust)
            self.assertIn(
                "pub const MAILBOX_HWSPIN_C906L_TOKEN_MASK: u16 = 0xff00;", rust
            )
            self.assertIn("pub const RESET_ADDRESS: usize = 0x03003024;", rust)
            dts = generated["dts/sg2002-c906l-contract.dtsi"].decode()
            self.assertIn("mboxes = <&mailbox 0 2>;", dts)
            self.assertIn("/bits/ 64 <0x000000000000000b>", dts)
            self.assertIn("sophgo,profile-id = <0x00000001>;", dts)
            self.assertIn("sophgo,manifest-flags = <0x00000002>;", dts)
            self.assertNotIn("sophgo,activation-required;", dts)
            self.assertNotIn("sophgo,c906l-leased-mmio-ranges", dts)
            self.assertNotIn("sophgo,c906l-local-irqs", dts)
            self.assertIn(self.base_sha256[:16], dts.replace(" ", ""))
            python = generated["python/sg2002_c906l_contract.py"].decode()
            compile(python, "sg2002_c906l_contract.py", "exec")
            self.assertIn("CAPABILITY_WIRE_WIDTH = 64", python)
            self.assertIn("MAILBOX_HWSPIN_IRQ_CONSECUTIVE_DEFERRAL_LIMIT = 16", python)
            self.assertIn("MAILBOX_HWSPIN_FIELD = 4", python)
            self.assertIn("MAILBOX_PROCESSOR_COUNT = 4", python)
            self.assertIn("MAILBOX_CHANNEL_MASK = 0x07", python)
            self.assertIn("MAILBOX_HWSPIN_ADDRESS = 0x019000d0", python)
            self.assertIn("MANIFEST_SIZE = 128", python)

    def test_generated_constant_names_are_unique(self) -> None:
        for name, (path, digest, _contract, _semantic) in self.profiles.items():
            with self.subTest(profile=name), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "out"
                self.generate(path, digest, output)
                header = (output / "include/sg2002-c906l-contract.h").read_text()
                definitions = [
                    line.split()[1]
                    for line in header.splitlines()
                    if line.startswith("#define SG2002_C906L_")
                ]
                self.assertEqual(len(definitions), len(set(definitions)))
                rust = (output / "rust/generated_contract.rs").read_text()
                constants = [
                    line.split()[2].rstrip(":")
                    for line in rust.splitlines()
                    if line.startswith("pub const ")
                ]
                self.assertEqual(len(constants), len(set(constants)))

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "timer4"
            self.generate(self.timer4_path, self.timer4_sha256, output)
            header = (output / "include/sg2002-c906l-contract.h").read_text()
            self.assertIn("SG2002_C906L_HAVE_TIMER4 1", header)
            dts = (output / "dts/sg2002-c906l-contract.dtsi").read_text()
            self.assertIn(
                "sophgo,c906l-leased-mmio-ranges = /bits/ 64 "
                "<0x00000000030a0050 0x0000000000000014>;",
                dts,
            )
            self.assertIn('sophgo,c906l-leased-mmio-range-owners = "timer4";', dts)
            self.assertIn("sophgo,c906l-local-irqs = <55>;", dts)
            self.assertIn('sophgo,c906l-local-irq-owners = "timer4";', dts)

    def test_timer4_dt_lease_is_exact_channel_not_shared_bank(self) -> None:
        ranges, irqs = self.generator.linux_dt_lease_resources(self.timer4)
        self.assertEqual(ranges, [("timer4", 0x030A0050, 0x14)])
        self.assertEqual(irqs, [("timer4", 55)])

    def test_all_c906l_timer_bindings_are_exact(self) -> None:
        expected = {
            "timer4": (
                55,
                0x030A0050,
                0x030A0054,
                0x030A0058,
                0x030A005C,
                0x030A0060,
                0x2000,
                0x040000,
                0x10,
            ),
            "timer5": (
                56,
                0x030A0064,
                0x030A0068,
                0x030A006C,
                0x030A0070,
                0x030A0074,
                0x4000,
                0x080000,
                0x20,
            ),
            "timer6": (
                57,
                0x030A0078,
                0x030A007C,
                0x030A0080,
                0x030A0084,
                0x030A0088,
                0x8000,
                0x100000,
                0x40,
            ),
            "timer7": (
                58,
                0x030A008C,
                0x030A0090,
                0x030A0094,
                0x030A0098,
                0x030A009C,
                0x10000,
                0x200000,
                0x80,
            ),
        }
        for name, values in expected.items():
            irq, load, current, control, eoi, status, gate, reset, source = values
            path, digest, _contract, _semantic = self.timer_profiles[name]
            stem = name.upper()
            with self.subTest(profile=name), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "out"
                self.generate(path, digest, output)
                header = (output / "include/sg2002-c906l-contract.h").read_text()
                rust = (output / "rust/generated_contract.rs").read_text()
                python = (output / "python/sg2002_c906l_contract.py").read_text()
                dts = (output / "dts/sg2002-c906l-contract.dtsi").read_text()
                self.assertIn(f"SG2002_C906L_HAVE_{stem} 1", header)
                self.assertIn(f"SG2002_C906L_{stem}_IRQ {irq}U", header)
                for register, address in (
                    ("LOAD", load),
                    ("CURRENT", current),
                    ("CONTROL", control),
                    ("EOI", eoi),
                    ("STATUS", status),
                ):
                    self.assertIn(
                        f"SG2002_C906L_{stem}_{register}_ADDRESS "
                        f"UINT64_C(0x{address:016x})",
                        header,
                    )
                    self.assertIn(
                        f"pub const {stem}_{register}_ADDRESS: usize = "
                        f"0x{address:08x};",
                        rust,
                    )
                    self.assertIn(
                        f"{stem}_{register}_ADDRESS = 0x{address:08x}", python
                    )
                channel = name.removeprefix("timer")
                for precondition, mask in (
                    (f"CLOCK_TIMER{channel}", gate),
                    (f"RESET_TIMER{channel}", reset),
                    ("CLOCK_SOURCE", source),
                ):
                    self.assertIn(
                        f"SG2002_C906L_{stem}_PRECONDITION_{precondition}_MASK "
                        f"UINT32_C(0x{mask:08x})",
                        header,
                    )
                    self.assertIn(
                        f"pub const {stem}_PRECONDITION_{precondition}_MASK: u32 = "
                        f"0x{mask:08x};",
                        rust,
                    )
                    self.assertIn(
                        f"{stem}_PRECONDITION_{precondition}_MASK = 0x{mask:08x}",
                        python,
                    )
                self.assertNotIn("030a00a4", header.lower())
                self.assertNotIn("030a00a4", rust.lower())
                self.assertNotIn("030a00a4", python.lower())
                self.assertIn(f"HAVE_{stem} = True", python)
                self.assertIn(f'"{name}"', dts)

    def test_lcd_spi_clock_meets_panel_write_timing(self) -> None:
        constants = self.profiles["picoclaw-lcd"][2]["peripheralLeases"][
            "picoclawLcd"
        ]["constants"]
        clock, divider = constants["spiClockHz"], constants["spiDivider"]
        self.assertGreater(clock, 0)
        self.assertGreaterEqual(divider, 2)
        self.assertEqual(divider % 2, 0)
        # ST7789V v1.3, section 7.4.3: write period >= 66 ns;
        # SCL high and low >= 15 ns. Use integer products, without rounding
        # a too-fast clock down to an apparently acceptable frequency.
        self.assertGreaterEqual(divider * 1_000_000_000, clock * 66)
        self.assertGreaterEqual(divider * 1_000_000_000, clock * 2 * 15)

    def test_lcd_layout_and_generated_bindings(self) -> None:
        path, digest, contract, _semantic = self.profiles["picoclaw-lcd"]
        lcd = contract["peripheralLeases"]["picoclawLcd"]
        constants = lcd["constants"]
        self.assertEqual(contract["profile"]["expectedCapabilities"], 0x8B)
        self.assertEqual(contract["profile"]["leaseMask"], 16)
        self.assertEqual(contract["profile"]["profileId"], 17)
        self.assertEqual(constants["frameSize"], 240 * 240 * 2)
        self.assertEqual(
            constants["frameSlot1Address"] - constants["frameSlot0Address"], 0x1D000
        )
        self.assertEqual(
            constants["ownership1Address"] - constants["ownership0Address"], 128
        )
        self.assertEqual(
            constants["frameSlot0Address"] - constants["ownership0Address"], 4096
        )
        self.assertEqual(constants["frameSlot0Address"] % 4096, 0)
        self.assertLess(
            constants["ownership1Address"] + 128, constants["frameSlot0Address"]
        )
        self.assertEqual(lcd["framebuffer"]["version"], 3)
        self.assertEqual(lcd["framebuffer"]["pixelFormat"], "RGB565LE")
        for name in ("request", "completion"):
            fields = lcd["framebuffer"][name]["fields"]
            self.assertEqual(sum(field["width"] for field in fields), 64)
            self.assertEqual(
                fields[-1], {"name": "commitSequence", "offset": 60, "width": 4}
            )
        self.assertEqual(lcd["linuxLease"]["localIrqs"], [])
        self.assertEqual(len(lcd["sharedPreconditions"]), 14)
        # The backlight pad is muxed to PWM_7 and owned by Linux, so its mux is
        # deliberately not a precondition of the lease.
        self.assertNotIn("backlightMux", lcd["sharedPreconditions"])
        self.assertEqual(constants["wifiPowerPin"], 26)
        self.assertEqual(constants["wifiPowerOwnershipAddress"], 0x8FF50100)
        self.assertEqual(constants["wifiPowerOwnershipAddress"] % 64, 0)
        self.assertGreaterEqual(
            constants["wifiPowerOwnershipAddress"], constants["ownership1Address"] + 128
        )
        self.assertLessEqual(
            constants["wifiPowerOwnershipAddress"] + 128, constants["frameSlot0Address"]
        )
        self.assertTrue(
            all(
                value["access"] == "read-only"
                for value in lcd["sharedPreconditions"].values()
            )
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "out"
            self.generate(path, digest, output)
            generated = self.tree_bytes(output)
            header = generated["include/sg2002-c906l-contract.h"].decode()
            rust = generated["rust/generated_contract.rs"].decode()
            dts = generated["dts/sg2002-c906l-contract.dtsi"].decode()
            self.assertIn(
                "SG2002_C906L_PICOCLAW_LCD_FRAME_SLOT0_ADDRESS UINT32_C(0x8ff51000)",
                header,
            )
            self.assertIn(
                "SG2002_C906L_PICOCLAW_LCD_REQUEST_MAGIC UINT32_C(0x3146424c)", header
            )
            self.assertIn(
                "pub const PICOCLAW_LCD_SHARED_PRECONDITIONS: &[(usize, u32, u32)]",
                rust,
            )
            self.assertIn(
                "pub const PICOCLAW_LCD_FRAME_SLOT1_ADDRESS: usize = 0x8ff6e000;", rust
            )
            self.assertIn(
                'sophgo,c906l-leased-mmio-range-owners = "picoclawLcd", "picoclawLcd";',
                dts,
            )
            self.assertNotIn("sophgo,c906l-local-irqs", dts)
            self.assertIn("0x0000000004190000 0x0000000000010000", dts)
            self.assertIn("0x0000000003020000 0x0000000000001000", dts)
            self.assertIn("SG2002_C906L_RPMSG_ECHO_ADDRESS", header)

    def test_lcd_ephy_preconditions_cover_documented_control_bits_only(self) -> None:
        # Official SG2002_PINOUT.xlsx, sheet "6. 如何把 MIPI Audio ETH 切入GPIO",
        # cell B27 specifies [10:9 2:1] for BOTH ETH RX/TX input/output enables:
        # https://github.com/sophgo/sophgo-hardware/blob/12d2bc6976400e6d40389f3faaff40f4326b63c2/SG200X/04_SG2002/04_SG2002_PINOUT.xlsx
        # Workbook SHA256: a20e1d2f02b0350a333ff16538cc59c13372b88c8a96f9737a3ef4f5ff57c148
        # Other bits are outside that instruction; do not infer RO/status
        # semantics for them from the observed live values alone.
        contract = self.profiles["picoclaw-lcd"][2]
        conditions = contract["peripheralLeases"]["picoclawLcd"]["sharedPreconditions"]
        for name, address in (("ephyRx", 0x03009074), ("ephyTx", 0x03009070)):
            with self.subTest(precondition=name):
                condition = conditions[name]
                self.assertEqual(
                    condition,
                    {
                        "address": address,
                        "mask": 0x606,
                        "expected": 0x606,
                        "access": "read-only",
                    },
                )
                mask, expected = condition["mask"], condition["expected"]
                for observed in (0x606, 0x1606, 0x1616, 0xFFFFFFFF):
                    self.assertEqual(observed & mask, expected)
                for bit in range(32):
                    observed = expected ^ (1 << bit)
                    if bit in (1, 2, 9, 10):
                        self.assertNotEqual(observed & mask, expected)
                    else:
                        self.assertEqual(observed & mask, expected)
                # Check the emitted firmware and Linux validators see this mask.
                macros = "\n".join(
                    self.generator.emit_macros(
                        contract, self.profiles["picoclaw-lcd"][1], kernel=False
                    )
                )
                self.assertIn(
                    f"PICOCLAW_LCD_PRECONDITION_{self.generator.macro(name)}_MASK UINT32_C(0x00000606)",
                    macros,
                )

    def test_lcd_weakened_contract_is_rejected(self) -> None:
        mutations = [
            lambda lcd: lcd["constants"].update(frameSlot0Address=0x8FF00000),
            lambda lcd: lcd["constants"].update(spiAddress=0x04180000),
            lambda lcd: lcd["constants"].update(spiDivider=4),
            lambda lcd: lcd["constants"].update(dcPin=29),
            lambda lcd: lcd["constants"].update(wifiPowerPin=27),
            lambda lcd: lcd["constants"].update(wifiPowerOwnershipAddress=0x8FF50080),
            lambda lcd: lcd["wifiPower"].update(runtimeRebind=True),
            lambda lcd: lcd["sharedPreconditions"].pop("wifiPowerMux"),
            lambda lcd: lcd["constants"].update(requestMagic=0),
            lambda lcd: lcd["sharedPreconditions"]["spiMosiMux"].update(
                access="read-write"
            ),
            lambda lcd: lcd["sharedPreconditions"].pop("ephyRoute"),
            lambda lcd: lcd["sharedPreconditions"]["ephyRx"].update(mask=0x206),
            lambda lcd: lcd["sharedPreconditions"]["ephyTx"].update(expected=0x602),
            lambda lcd: lcd["linuxLease"]["mmioRanges"].pop(),
            lambda lcd: lcd["framebuffer"]["request"]["fields"][-1].update(offset=56),
            lambda lcd: lcd["service"].update(address=0x400),
        ]
        for mutation in mutations:
            contract = copy.deepcopy(self.profiles["picoclaw-lcd"][2])
            mutation(contract["peripheralLeases"]["picoclawLcd"])
            with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
                ValueError, "frozen board and framebuffer contract"
            ):
                self.load_modified(contract, Path(temporary))

    def test_lcd_mixed_lease_and_out_of_bounds_bulk_are_rejected(self) -> None:
        contract = copy.deepcopy(self.profiles["picoclaw-lcd"][2])
        contract["peripheralLeases"]["timer4"] = copy.deepcopy(
            self.timer4["peripheralLeases"]["timer4"]
        )
        contract["profile"]["peripherals"].append("timer4")
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
            ValueError, "must be selected alone"
        ):
            self.load_modified(contract, Path(temporary))
        contract = copy.deepcopy(self.profiles["picoclaw-lcd"][2])
        contract["memory"]["shared"]["regions"]["bulk"]["size"] = 4096
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
            ValueError, "does not fit"
        ):
            self.load_modified(contract, Path(temporary))

    def test_wrong_sg2002_timer_mapping_is_rejected(self) -> None:
        contract = copy.deepcopy(self.profiles["timer5"][2])
        contract["peripheralLeases"]["timer5"]["registers"]["load"]["address"] += 2
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
            ValueError, "exact SG2002 C906L timer topology"
        ):
            self.load_modified(contract, Path(temporary))

    def test_duplicate_timer_irq_is_rejected(self) -> None:
        contract = self.combined_timer4_timer5()
        contract["peripheralLeases"]["timer5"]["irq"] = 55
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
            ValueError, "C906L IRQs are not unique"
        ):
            self.load_modified(contract, Path(temporary))

    def test_overlapping_timer_slice_is_rejected(self) -> None:
        contract = self.combined_timer4_timer5()
        timer4_registers = contract["peripheralLeases"]["timer4"]["registers"]
        contract["peripheralLeases"]["timer5"]["registers"] = copy.deepcopy(
            timer4_registers
        )
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(
            ValueError, "timer registers are not unique"
        ):
            self.load_modified(contract, Path(temporary))

    def test_wrong_digest_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "contract digest mismatch"):
            self.generator.load_resolved(self.base_path, "0" * 64)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", required=True, type=Path)
    parser.add_argument(
        "--profile",
        action="append",
        nargs=3,
        required=True,
        metavar=("NAME", "PATH", "SHA256"),
    )
    args = parser.parse_args()

    ContractGenerationTests.generator_path = args.generator
    ContractGenerationTests.profile_arguments = [
        (name, Path(path), digest) for name, path, digest in args.profile
    ]
    unittest.main(argv=[__file__])


if __name__ == "__main__":
    main()
