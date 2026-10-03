"""Check CPUFreq and thermal integration in each default carrier DTB."""
import subprocess
import sys


def get(blob, node, prop, kind="u"):
    return subprocess.check_output(
        ["fdtget", "-t", kind, blob, node, prop], text=True
    ).strip()


def tree(blob, node="/"):
    result = {}
    props = subprocess.check_output(["fdtget", "-p", blob, node], text=True).split()
    result[node] = {p: get(blob, node, p, "bx") for p in props}
    for child in subprocess.check_output(["fdtget", "-l", blob, node], text=True).split():
        result.update(tree(blob, node.rstrip("/") + "/" + child))
    return result


scaling, = sys.argv[1:]
after = tree(scaling)

cpu = "/cpus/cpu@0"
assert "cpu-supply" not in after[cpu], "must not invent voltage control"
clock_provider, clock_id = get(scaling, cpu, "clocks").split()
assert clock_provider == get(scaling, "/soc/clock-controller@3002000", "phandle")
assert int(clock_id) == 155  # CLK_C906_0 in the pinned clock binding
assert get(scaling, cpu, "#cooling-cells") == "2"
assert get(scaling, cpu, "operating-points-v2") == get(scaling, "/opp-table-cpu", "phandle")
assert get(scaling, "/opp-table-cpu", "compatible", "s") == "operating-points-v2"
opp_nodes = [node for node in after if node.startswith("/opp-table-cpu/opp-")]
rates = []
for node in opp_nodes:
    hi, lo = map(int, get(scaling, node, "opp-hz").split())
    rates.append((hi << 32) | lo)
    assert "opp-microvolt" not in after[node]
    assert get(scaling, node, "clock-latency-ns") == "100000"
assert sorted(rates) == [250000000, 500000000, 1000000000]

# The board picks the CPU PLL rate; the OPPs are integer divisions of it.
# A mismatch would silently mis-report every CPU frequency Linux shows.
clk = "/soc/clock-controller@3002000"
assigned_provider, assigned_id = get(scaling, clk, "assigned-clocks").split()
assert assigned_provider == get(scaling, clk, "phandle")
assert int(assigned_id) == 0  # CLK_MPLL in the pinned clock binding
pll_rate = int(get(scaling, clk, "assigned-clock-rates"))
assert pll_rate == 1000000000
assert max(rates) == pll_rate, "top OPP must be the PLL itself, divided by one"
for rate in rates:
    assert pll_rate % rate == 0, f"{rate} is not an integer division of the PLL"
    assert pll_rate // rate <= 15, "CPU divider field is four bits, one-based"
zone = "/thermal-zones/soc-thermal"
trip = zone + "/trips/cpu-passive"
assert get(scaling, trip, "temperature") == "85000"
assert get(scaling, trip, "hysteresis") == "5000"
assert get(scaling, trip, "type", "s") == "passive"
# Packaged DRAM is limited to 115 C. Check the final carrier DT, including
# overlays, leaves 10 C nominal margin for reboot after passive cooling.
assert get(scaling, zone, "critical-action", "s") == "reboot"
critical = zone + "/trips/soc-crit"
assert get(scaling, critical, "type", "s") == "critical"
critical_temp = int(get(scaling, critical, "temperature"))
assert int(get(scaling, trip, "temperature")) < critical_temp <= 105000
cooling = zone + "/cooling-maps/cpu-map"
assert get(scaling, cooling, "trip") == get(scaling, trip, "phandle")
assert get(scaling, cooling, "cooling-device").split() == [
    get(scaling, cpu, "phandle"), "4294967295", "4294967295"
]
print("Default CPUFreq DT: PLL-derived OPPs and CPU thermal link")
