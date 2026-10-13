#!/usr/bin/env python3
"""Reject Linux device-tree nodes which claim C906L-leased MMIO.

The generated C906L control node carries physical address/size pairs as four
32-bit cells (address high/low, size high/low).  This checker deliberately
does not compare ``interrupts`` properties: the C906L interrupt namespace is
not the Linux PLIC interrupt namespace even where the numeric values happen
to match.

Only the Python standard library is used so this remains a small, native build
check rather than a target-side dependency.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Sequence


CONTROL_COMPATIBLE = "sophgo,sg2002-c906l-control"
LEASE_MASK_PROPERTY = "sophgo,lease-mask"
LEASE_NAMES_PROPERTY = "sophgo,leased-peripherals"
LEASE_RANGES_PROPERTY = "sophgo,c906l-leased-mmio-ranges"
LEASE_RANGE_OWNERS_PROPERTY = "sophgo,c906l-leased-mmio-range-owners"
C906L_IRQS_PROPERTY = "sophgo,c906l-local-irqs"
C906L_IRQ_OWNERS_PROPERTY = "sophgo,c906l-local-irq-owners"
U64_LIMIT = 1 << 64


class LeaseGuardError(ValueError):
    """The final flattened device tree cannot prove exclusive ownership."""


@dataclass(frozen=True)
class Token:
    kind: str
    value: str


@dataclass
class Node:
    name: str
    parent: Node | None
    properties: dict[str, list[Token]] = field(default_factory=dict)
    children: list[Node] = field(default_factory=list)

    @property
    def path(self) -> str:
        if self.parent is None:
            return "/"
        prefix = self.parent.path.rstrip("/")
        return f"{prefix}/{self.name}"


@dataclass(frozen=True)
class Range:
    address: int
    size: int

    @property
    def end(self) -> int:
        return self.address + self.size

    def overlaps(self, other: Range) -> bool:
        return self.address < other.end and other.address < self.end


def tokenize(source: str) -> list[Token]:
    """Tokenize the deterministic DTS emitted by dtc.

    This is intentionally a DTS parser, not a line-oriented regular
    expression: dtc may wrap cell lists and string lists across lines.
    """

    tokens: list[Token] = []
    index = 0
    while index < len(source):
        character = source[index]
        if character.isspace():
            index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = len(source) if newline < 0 else newline + 1
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                raise LeaseGuardError("unterminated DTS block comment")
            index = end + 2
            continue
        if character == '"':
            index += 1
            value: list[str] = []
            while index < len(source) and source[index] != '"':
                if source[index] == "\\":
                    index += 1
                    if index >= len(source):
                        raise LeaseGuardError("unterminated DTS string escape")
                    escapes = {"n": "\n", "r": "\r", "t": "\t"}
                    value.append(escapes.get(source[index], source[index]))
                else:
                    value.append(source[index])
                index += 1
            if index >= len(source):
                raise LeaseGuardError("unterminated DTS string")
            index += 1
            tokens.append(Token("string", "".join(value)))
            continue
        if character in "{}=;<>[]:":
            tokens.append(Token("symbol", character))
            index += 1
            continue
        start = index
        while (
            index < len(source)
            and not source[index].isspace()
            and source[index] not in '"{}=;<>[]:'
        ):
            if source.startswith("//", index) or source.startswith("/*", index):
                break
            index += 1
        if index == start:
            raise LeaseGuardError(f"cannot tokenize DTS at byte {index}")
        tokens.append(Token("atom", source[start:index]))
    return tokens


class Parser:
    def __init__(self, tokens: Sequence[Token]):
        self.tokens = tokens
        self.index = 0

    def peek(self, value: str | None = None, offset: int = 0) -> bool:
        location = self.index + offset
        if location >= len(self.tokens):
            return False
        return value is None or self.tokens[location].value == value

    def take(self, value: str | None = None) -> Token:
        if self.index >= len(self.tokens):
            raise LeaseGuardError("unexpected end of DTS")
        token = self.tokens[self.index]
        if value is not None and token.value != value:
            raise LeaseGuardError(
                f"expected {value!r}, found {token.value!r} in flattened DTS"
            )
        self.index += 1
        return token

    def parse(self) -> Node:
        while not (self.peek("/") and self.peek("{", 1)):
            if not self.peek():
                raise LeaseGuardError("flattened DTS has no root node")
            self.index += 1
        self.take("/")
        root = self.parse_node("/", None)
        if self.index != len(self.tokens):
            raise LeaseGuardError("unexpected data follows the flattened DTS root")
        return root

    def parse_node(self, name: str, parent: Node | None) -> Node:
        self.take("{")
        node = Node(name=name, parent=parent)
        while not self.peek("}"):
            if not self.peek():
                raise LeaseGuardError(f"unterminated node {node.path}")

            # Labels are normally absent after DTB decompilation, but accept
            # them so fixture/source-mode checks use the same parser.
            if self.peek(":", 1):
                self.take()
                self.take(":")

            name_token = self.take()
            if name_token.kind != "atom":
                raise LeaseGuardError(
                    f"unexpected token {name_token.value!r} in {node.path}"
                )
            if self.peek("{"):
                node.children.append(self.parse_node(name_token.value, node))
                continue

            property_name = name_token.value
            if property_name in node.properties:
                raise LeaseGuardError(
                    f"duplicate property {property_name!r} in {node.path}"
                )
            if self.peek(";"):
                self.take(";")
                node.properties[property_name] = []
                continue
            self.take("=")
            value: list[Token] = []
            while not self.peek(";"):
                value.append(self.take())
            self.take(";")
            node.properties[property_name] = value

        self.take("}")
        self.take(";")
        return node


def parse_dts(source: str) -> Node:
    return Parser(tokenize(source)).parse()


def walk(node: Node) -> Iterator[Node]:
    yield node
    for child in node.children:
        yield from walk(child)


def string_values(tokens: Sequence[Token]) -> list[str]:
    return [token.value for token in tokens if token.kind == "string"]


def cell_values(tokens: Sequence[Token], property_description: str) -> list[int]:
    values: list[int] = []
    angle_depth = 0
    for token in tokens:
        if token.value == "<":
            angle_depth += 1
            continue
        if token.value == ">":
            angle_depth -= 1
            if angle_depth < 0:
                raise LeaseGuardError(f"unbalanced cells in {property_description}")
            continue
        if angle_depth and token.kind == "atom":
            atom = token.value.rstrip(",")
            try:
                value = int(atom, 0)
            except ValueError as error:
                raise LeaseGuardError(
                    f"non-numeric cell {atom!r} in {property_description}"
                ) from error
            if not 0 <= value < (1 << 32):
                raise LeaseGuardError(
                    f"cell {atom!r} is outside u32 in {property_description}"
                )
            values.append(value)
    if angle_depth != 0:
        raise LeaseGuardError(f"unbalanced cells in {property_description}")
    return values


def cells_to_integer(cells: Sequence[int]) -> int:
    value = 0
    for cell in cells:
        value = value << 32 | cell
    return value


def inherited_cells(node: Node, property_name: str, default: int) -> int:
    tokens = node.properties.get(property_name)
    if tokens is None:
        return default
    cells = cell_values(tokens, f"{node.path}:{property_name}")
    if len(cells) != 1 or cells[0] > 4:
        raise LeaseGuardError(
            f"{node.path}:{property_name} must contain one cell in range 0..4"
        )
    return cells[0]


def node_enabled(node: Node) -> bool:
    current: Node | None = node
    while current is not None:
        if "status" in current.properties:
            values = string_values(current.properties["status"])
            if len(values) != 1:
                raise LeaseGuardError(f"{current.path}:status is not one string")
            if values[0] not in {"ok", "okay"}:
                return False
        current = current.parent
    return True


def decode_reg(node: Node) -> list[Range]:
    if node.parent is None or "reg" not in node.properties:
        return []
    address_cells = inherited_cells(node.parent, "#address-cells", 2)
    size_cells = inherited_cells(node.parent, "#size-cells", 1)
    if size_cells == 0:
        # I2C, MDIO, CPU, GPIO-port, and similar children use reg as a
        # logical selector, not an MMIO resource.
        return []
    width = address_cells + size_cells
    if address_cells == 0 or width == 0:
        raise LeaseGuardError(f"{node.path}:reg has no address cells")
    cells = cell_values(node.properties["reg"], f"{node.path}:reg")
    if len(cells) % width:
        raise LeaseGuardError(
            f"{node.path}:reg has {len(cells)} cells, expected tuples of {width}"
        )
    resources: list[Range] = []
    for offset in range(0, len(cells), width):
        address = cells_to_integer(cells[offset : offset + address_cells])
        size = cells_to_integer(cells[offset + address_cells : offset + width])
        if size == 0:
            continue
        if address >= U64_LIMIT or size >= U64_LIMIT or address + size > U64_LIMIT:
            raise LeaseGuardError(f"{node.path}:reg range exceeds 64 bits")
        resources.append(Range(address, size))
    return resources


def translate_one(resource: Range, bus: Node) -> Range | None:
    """Translate one child-bus resource into the bus parent's address space."""

    if bus.parent is None:
        return resource
    ranges_tokens = bus.properties.get("ranges")
    if ranges_tokens is None:
        # With no ranges property there is no defined child-to-parent mapping.
        # Such child resources are covered by their enabled parent controller's
        # own reg aperture, which is checked independently.
        return None
    cells = cell_values(ranges_tokens, f"{bus.path}:ranges")
    if not cells:
        return resource

    child_address_cells = inherited_cells(bus, "#address-cells", 2)
    parent_address_cells = inherited_cells(bus.parent, "#address-cells", 2)
    size_cells = inherited_cells(bus, "#size-cells", 1)
    width = child_address_cells + parent_address_cells + size_cells
    if child_address_cells == 0 or size_cells == 0 or len(cells) % width:
        raise LeaseGuardError(
            f"{bus.path}:ranges has {len(cells)} cells, expected tuples of {width}"
        )

    for offset in range(0, len(cells), width):
        child = cells_to_integer(cells[offset : offset + child_address_cells])
        parent_offset = offset + child_address_cells
        parent = cells_to_integer(
            cells[parent_offset : parent_offset + parent_address_cells]
        )
        size = cells_to_integer(
            cells[parent_offset + parent_address_cells : offset + width]
        )
        if size == 0 or child + size > U64_LIMIT or parent + size > U64_LIMIT:
            raise LeaseGuardError(f"{bus.path}:ranges contains an invalid range")
        if child <= resource.address and resource.end <= child + size:
            translated = parent + resource.address - child
            if translated + resource.size > U64_LIMIT:
                raise LeaseGuardError(f"{bus.path}:ranges translation exceeds 64 bits")
            return Range(translated, resource.size)
    return None


def enclosing_controller(bus: Node) -> bool:
    """Whether bus, or a container reached without ranges, has its own reg."""

    current = bus
    while current.parent is not None and "ranges" not in current.properties:
        if decode_reg(current):
            return True
        current = current.parent
    return False


def physical_resource(resource: Range, node: Node) -> Range | None:
    current = resource
    if node.parent is None:
        raise LeaseGuardError(f"{node.path} unexpectedly has no parent bus")
    bus = node.parent
    while bus.parent is not None:
        translated = translate_one(current, bus)
        if translated is None:
            if enclosing_controller(bus):
                # A controller without ranges does not define translation for
                # child selectors/windows, including those in reg-less
                # containers such as nvmem-layout.  Its own enabled aperture
                # is the enclosing Linux claim and is checked separately.
                return None
            raise LeaseGuardError(
                f"cannot translate enabled node {node.path} MMIO through {bus.path}"
            )
        current = translated
        bus = bus.parent
    return current


def lease_metadata(root: Node) -> tuple[Node, list[Range]]:
    controls = [
        node
        for node in walk(root)
        if CONTROL_COMPATIBLE in string_values(node.properties.get("compatible", []))
    ]
    if len(controls) != 1:
        raise LeaseGuardError(
            f"final DT must contain exactly one {CONTROL_COMPATIBLE!r} node; "
            f"found {len(controls)}"
        )
    control = controls[0]
    mask_cells = cell_values(
        control.properties.get(LEASE_MASK_PROPERTY, []),
        f"{control.path}:{LEASE_MASK_PROPERTY}",
    )
    if not mask_cells or len(mask_cells) > 2:
        raise LeaseGuardError(
            f"{control.path}:{LEASE_MASK_PROPERTY} must be a one- or two-cell integer"
        )
    lease_mask = cells_to_integer(mask_cells)
    names = string_values(control.properties.get(LEASE_NAMES_PROPERTY, []))
    range_cells = cell_values(
        control.properties.get(LEASE_RANGES_PROPERTY, []),
        f"{control.path}:{LEASE_RANGES_PROPERTY}",
    )
    range_owners = string_values(
        control.properties.get(LEASE_RANGE_OWNERS_PROPERTY, [])
    )
    irqs = cell_values(
        control.properties.get(C906L_IRQS_PROPERTY, []),
        f"{control.path}:{C906L_IRQS_PROPERTY}",
    )
    irq_owners = string_values(control.properties.get(C906L_IRQ_OWNERS_PROPERTY, []))

    if lease_mask == 0:
        if names or range_cells or range_owners or irqs or irq_owners:
            raise LeaseGuardError(
                f"{control.path} has lease resource metadata with a zero lease mask"
            )
        return control, []

    if len(names) != lease_mask.bit_count() or len(names) != len(set(names)):
        raise LeaseGuardError(
            f"{control.path} peripheral names do not match the lease-mask bits"
        )
    if len(range_cells) == 0 or len(range_cells) % 4:
        raise LeaseGuardError(
            f"{control.path}:{LEASE_RANGES_PROPERTY} must contain address/size u64 pairs"
        )
    if len(range_owners) != len(range_cells) // 4:
        raise LeaseGuardError(
            f"{control.path}:{LEASE_RANGE_OWNERS_PROPERTY} must identify every MMIO range"
        )
    if set(range_owners) != set(names):
        raise LeaseGuardError(
            f"{control.path}:{LEASE_RANGE_OWNERS_PROPERTY} must cover every leased peripheral"
        )
    if len(irq_owners) != len(irqs) or not set(irq_owners).issubset(names):
        raise LeaseGuardError(
            f"{control.path}:{C906L_IRQ_OWNERS_PROPERTY} must identify every C906L-local IRQ"
        )

    ranges: list[Range] = []
    for offset in range(0, len(range_cells), 4):
        address = cells_to_integer(range_cells[offset : offset + 2])
        size = cells_to_integer(range_cells[offset + 2 : offset + 4])
        if size == 0 or address + size > U64_LIMIT:
            raise LeaseGuardError(
                f"{control.path}:{LEASE_RANGES_PROPERTY} contains an invalid range"
            )
        item = Range(address, size)
        if any(item.overlaps(existing) for existing in ranges):
            raise LeaseGuardError(
                f"{control.path}:{LEASE_RANGES_PROPERTY} contains overlapping ranges"
            )
        ranges.append(item)
    return control, ranges


def verify_tree(root: Node) -> None:
    control, leases = lease_metadata(root)
    if not leases:
        return

    for node in walk(root):
        if node is control or not node_enabled(node) or node.parent is None:
            continue
        for resource in decode_reg(node):
            physical = physical_resource(resource, node)
            if physical is None:
                continue
            for lease in leases:
                if physical.overlaps(lease):
                    raise LeaseGuardError(
                        f"enabled Linux node {node.path} MMIO "
                        f"[0x{physical.address:x},0x{physical.end:x}) overlaps "
                        f"C906L lease [0x{lease.address:x},0x{lease.end:x})"
                    )


def verify_dts(source: str) -> None:
    verify_tree(parse_dts(source))


def verify_dtb(dtb: Path, dtc: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="c906l-dt-lease-guard-") as temporary:
        flattened = Path(temporary) / "final.dts"
        try:
            with flattened.open("wb") as output:
                subprocess.run(
                    [str(dtc), "-q", "-I", "dtb", "-O", "dts", str(dtb)],
                    check=True,
                    stdout=output,
                )
        except (OSError, subprocess.CalledProcessError) as error:
            raise LeaseGuardError(
                f"could not decompile final DTB {dtb}: {error}"
            ) from error
        verify_dts(flattened.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dtb", required=True, type=Path)
    parser.add_argument("--dtc", required=True, type=Path)
    args = parser.parse_args()
    try:
        verify_dtb(args.dtb, args.dtc)
    except LeaseGuardError as error:
        print(f"C906L DT lease guard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
