"""stat_counter unit test: random increments (with long bursts so the count wraps many
times at small W), the output is compared with a reference count after every clock."""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

W = int(os.environ.get("CNT_W", "10"))
CYCLES = int(os.environ.get("CNT_CYCLES", "20000"))
SEED = int(os.environ.get("ITCH_SEED", "1"))


@cocotb.test()
async def counter_random(dut):
    """Exact count every cycle across many wrap-arounds; reset mid-run."""
    rng = random.Random(SEED)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.inc.value = 0
    dut.rst.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    mask = (1 << W) - 1
    ref, wraps, checked = 0, 0, 0
    p_inc = 0.9
    for cyc in range(CYCLES):
        if cyc % 500 == 0:
            p_inc = rng.choice([1.0, 0.95, 0.5, 0.1])
        inc = 1 if rng.random() < p_inc else 0
        rst = 1 if cyc == CYCLES // 2 else 0
        dut.inc.value = inc
        dut.rst.value = rst
        await RisingEdge(dut.clk)
        if rst:
            ref = 0
        elif inc:
            ref = (ref + 1) & mask
            wraps += ref == 0
        await ReadOnly()
        got = int(dut.count.value)
        assert got == ref, f"cycle {cyc}: count={got:#x} expected {ref:#x}"
        checked += 1
        await Timer(1, unit="ns")
    assert wraps >= 3, f"only {wraps} wrap-arounds, test too short for W={W}"
    dut._log.info(f"SUMMARY stat_counter W={W}: PASS cycles={checked} wraps={wraps}")
