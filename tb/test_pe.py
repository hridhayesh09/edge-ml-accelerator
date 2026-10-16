"""Tests for a single processing element."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from hw_utils import to_signed


async def setup(dut):
    Clock(dut.clk, 20, unit="ns", impl="gpi").start()
    dut.w_we.value = 0
    dut.w_in.value = 0
    dut.a_in.value = 0
    dut.p_in.value = 0
    await ClockCycles(dut.clk, 2)


async def load_weight(dut, w):
    dut.w_we.value = 1
    dut.w_in.value = w & 0xFF
    await RisingEdge(dut.clk)
    dut.w_we.value = 0


async def check(dut, a, w, p):
    dut.a_in.value = a & 0xFF
    dut.p_in.value = p & 0xFFFFFFFF
    await RisingEdge(dut.clk)
    await ReadOnly()
    expect = to_signed(p + a * w, 32)
    got_p = to_signed(int(dut.p_out.value), 32)
    got_a = to_signed(int(dut.a_out.value), 8)
    assert got_p == expect, f"a={a} w={w} p={p}: p_out={got_p}, expected {expect}"
    assert got_a == a, f"a_out={got_a}, expected {a}"
    await RisingEdge(dut.clk)


@cocotb.test()
async def corner_cases(dut):
    """Every pair of extreme int8 values, with extreme partial sums."""
    await setup(dut)
    corners = [-128, -127, -1, 0, 1, 126, 127]
    psums = [0, 1, -1, 2**31 - 1, -(2**31), 123456, -654321]
    for w in corners:
        await load_weight(dut, w)
        for a in corners:
            for p in psums:
                await check(dut, a, w, p)


@cocotb.test()
async def random_values(dut):
    """5,000 random activation / weight / partial-sum combinations."""
    await setup(dut)
    for i in range(5000):
        if i % 50 == 0:
            w = random.randint(-128, 127)
            await load_weight(dut, w)
        a = random.randint(-128, 127)
        p = random.randint(-(2**31), 2**31 - 1)
        await check(dut, a, w, p)


@cocotb.test()
async def weight_holds(dut):
    """The weight only changes when w_we is high."""
    await setup(dut)
    await load_weight(dut, 5)
    dut.w_in.value = 99   # present a different value without w_we
    for _ in range(10):
        await check(dut, 3, 5, 0)
