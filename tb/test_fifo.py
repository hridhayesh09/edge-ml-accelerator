"""Tests for sync_fifo against a Python model (collections.deque)."""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge


async def setup(dut):
    Clock(dut.clk, 20, unit="ns", impl="gpi").start()
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.din.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 3)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def random_push_pop(dut):
    """20,000 cycles of random pushes and pops checked against a deque."""
    await setup(dut)
    depth = int(dut.DEPTH.value)
    model = deque()
    for cycle in range(20000):
        # Vary the push/pop bias so the FIFO spends time both full and empty
        phase = (cycle // 2000) % 3
        p_wr = [0.8, 0.5, 0.2][phase]
        wr = random.random() < p_wr
        rd = random.random() < (1 - p_wr)
        val = random.randrange(256)

        await ReadOnly()
        empty = int(dut.empty.value)
        full = int(dut.full.value)
        assert empty == (len(model) == 0), f"empty flag wrong at cycle {cycle}"
        assert full == (len(model) == depth), f"full flag wrong at cycle {cycle}"
        if not empty:
            assert int(dut.dout.value) == model[0], f"dout wrong at cycle {cycle}"

        await RisingEdge(dut.clk)
        dut.wr_en.value = int(wr)
        dut.rd_en.value = int(rd)
        dut.din.value = val
        # The model applies the same rules as the hardware at the next edge
        do_rd = rd and len(model) > 0
        do_wr = wr and len(model) < depth
        await RisingEdge(dut.clk)
        dut.wr_en.value = 0
        dut.rd_en.value = 0
        if do_rd:
            model.popleft()
        if do_wr:
            model.append(val)


@cocotb.test()
async def fill_and_drain(dut):
    """Fill to exactly DEPTH, confirm full, then drain in order."""
    await setup(dut)
    depth = int(dut.DEPTH.value)
    data = [random.randrange(256) for _ in range(depth + 5)]
    for v in data:
        dut.wr_en.value = 1
        dut.din.value = v
        await RisingEdge(dut.clk)
    dut.wr_en.value = 0
    await ReadOnly()
    assert int(dut.full.value) == 1
    out = []
    await RisingEdge(dut.clk)
    while True:
        await ReadOnly()
        if int(dut.empty.value):
            break
        out.append(int(dut.dout.value))
        await RisingEdge(dut.clk)
        dut.rd_en.value = 1
        await RisingEdge(dut.clk)
        dut.rd_en.value = 0
    assert out == data[:depth], "writes past full should be dropped, order kept"
