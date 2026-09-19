"""Check the C906 PMU description in the device tree OpenSBI actually reads.

OpenSBI is built around U-Boot's DTB because the SG2002's FSBL passes no
FDT, so this is the only device tree that reaches the SBI PMU event table.
Everything asserted here was measured on a PicoClaw.
"""
import subprocess
import sys

# mhpmcounter(selector + 2), and this SoC implements mhpmcounter3..9 only.
MAX_SELECTOR = 0x07
FIXED_COUNTERS = {0: "mcycle", 2: "minstret"}


def cells(blob, node, prop):
    out = subprocess.check_output(
        ["fdtget", "-t", "u", blob, node, prop], text=True
    )
    return [int(v) for v in out.split()]


def rows(values, width):
    assert len(values) % width == 0, f"property is not {width}-cell rows"
    return [values[i:i + width] for i in range(0, len(values), width)]


blob, = sys.argv[1:]
node = subprocess.check_output(
    ["fdtget", "-l", blob, "/"], text=True
).split()
assert "pmu" in node, "no pmu node: every hardware perf event would be ENOENT"

compat = subprocess.check_output(
    ["fdtget", "-t", "s", blob, "/pmu", "compatible"], text=True
).strip()
assert compat == "riscv,pmu", compat

counters = rows(cells(blob, "/pmu", "riscv,event-to-mhpmcounters"), 3)
events = rows(cells(blob, "/pmu", "riscv,event-to-mhpmevent"), 3)
raw = rows(cells(blob, "/pmu", "riscv,raw-event-to-mhpmcounters"), 5)

# Every programmable event must name exactly one counter, and that counter
# must be one the silicon implements. A bitmap naming mhpmcounter10 or above
# opens successfully and then reads zero forever.
for start, end, bitmap in counters:
    assert start == end, f"event range {start:#x}..{end:#x} is not a single event"
    bits = [b for b in range(64) if bitmap & (1 << b)]
    assert len(bits) == 1, f"event {start:#x} names {len(bits)} counters"
    bit, = bits
    if bit in FIXED_COUNTERS:
        assert start <= 2, (
            f"event {start:#x} claims fixed {FIXED_COUNTERS[bit]}; OpenSBI's "
            "pmu_add_hw_event_map() denies that above SBI_PMU_HW_INSTRUCTIONS"
        )
        continue
    assert 3 <= bit <= MAX_SELECTOR + 2, (
        f"event {start:#x} binds mhpmcounter{bit}, which this SoC does not "
        f"implement (only 3..{MAX_SELECTOR + 2})"
    )

# The fixed counters need no selector, but must still be declared or
# sbi_pmu_event_get_info() refuses to claim them and Linux reports ENOENT.
declared = {start for start, _, _ in counters}
assert 0x00001 in declared, "cpu-cycles not declared; perf would report ENOENT"
assert 0x00002 in declared, "instructions not declared; perf would report ENOENT"
selectors = {start for start, _, _ in events}
assert not (selectors & {0x00001, 0x00002}), "fixed counters take no selector"

# Selectors are the C906 mhpmevent codes, and must land on their own counter.
by_event = {start: bitmap for start, _, bitmap in counters}
for event, hi, selector in events:
    assert hi == 0, f"event {event:#x} selector is not a 32-bit value"
    assert 1 <= selector <= MAX_SELECTOR, (
        f"event {event:#x} uses selector {selector:#x}; only 0x01.."
        f"{MAX_SELECTOR:#04x} have counters on this SoC"
    )
    assert by_event.get(event) == 1 << (selector + 2), (
        f"event {event:#x} selector {selector:#x} must bind mhpmcounter"
        f"{selector + 2}"
    )

for lo_sel, sel, lo_mask, hi_mask, bitmap in raw:
    assert lo_sel == 0 and (lo_mask, hi_mask) == (0xFFFFFFFF, 0xFFFFFFFF)
    assert 1 <= sel <= MAX_SELECTOR, (
        f"raw selector {sel:#x} has no counter on this SoC"
    )
    assert bitmap == 1 << (sel + 2), f"raw selector {sel:#x} binds the wrong counter"

print(
    f"PMU DT: {len(events)} mapped events, {len(raw)} raw selectors, "
    "fixed cycle/instret declared"
)
