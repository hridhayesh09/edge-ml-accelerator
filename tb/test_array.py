"""Tests for the 8x8 systolic array against the NumPy golden model."""

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from hw_utils import golden_matmul, pack, rand_int8, unpack

RNG = np.random.default_rng(2026)
STATS = {"matrices": 0, "rows": 0}


class ArrayTB:
    def __init__(self, dut):
        self.dut = dut
        self.n = int(dut.N.value)
        self.cycle = 0
        self.outputs = []          # (cycle, row of ints)
        self.first_in_edge = None

    async def start(self):
        dut = self.dut
        Clock(dut.clk, 20, unit="ns", impl="gpi").start()
        dut.w_we.value = 0
        dut.w_addr.value = 0
        dut.w_data.value = 0
        dut.in_valid.value = 0
        dut.a_row.value = 0
        dut.rst.value = 1
        await ClockCycles(dut.clk, 3)
        dut.rst.value = 0
        cocotb.start_soon(self._monitor())
        await RisingEdge(dut.clk)

    async def _monitor(self):
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1
            await ReadOnly()
            # in_valid seen now is what the next edge (cycle + 1) will capture
            if int(self.dut.in_valid.value) and self.first_in_edge is None:
                self.first_in_edge = self.cycle + 1
            if int(self.dut.out_valid.value):
                row = unpack(self.dut.c_row.value, 32, self.n)
                self.outputs.append((self.cycle, row))

    async def load_weights(self, w):
        dut = self.dut
        for i in range(self.n):
            for j in range(self.n):
                dut.w_we.value = 1
                dut.w_addr.value = i * self.n + j
                dut.w_data.value = int(w[i, j]) & 0xFF
                await RisingEdge(dut.clk)
        dut.w_we.value = 0

    async def stream(self, a, bubble_prob=0.0):
        """Feed the rows of a, optionally with idle cycles in between."""
        dut = self.dut
        self.first_in_edge = None
        for row in a:
            while bubble_prob and RNG.random() < bubble_prob:
                dut.in_valid.value = 0
                dut.a_row.value = 0
                await RisingEdge(dut.clk)
            dut.in_valid.value = 1
            dut.a_row.value = pack(row, 8)
            await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        dut.a_row.value = 0

    async def run(self, a, w, bubble_prob=0.0, load=True):
        if load:
            await self.load_weights(w)
        self.outputs.clear()
        await self.stream(a, bubble_prob)
        await ClockCycles(self.dut.clk, 2 * self.n + 4)
        got = np.array([r for _, r in self.outputs], dtype=np.int64).reshape(-1, self.n)
        expect = golden_matmul(a, w)
        assert got.shape == expect.shape, f"expected {expect.shape[0]} rows, got {got.shape[0]}"
        assert np.array_equal(got, expect), f"mismatch:\nA=\n{a}\nW=\n{w}\ngot=\n{got}\nexpected=\n{expect}"
        STATS["matrices"] += 1
        STATS["rows"] += a.shape[0]


@cocotb.test()
async def latency(dut):
    """First result appears exactly 2N-1 cycles after the first input."""
    tb = ArrayTB(dut)
    await tb.start()
    n = tb.n
    a = rand_int8(RNG, (4, n))
    w = rand_int8(RNG, (n, n))
    await tb.run(a, w)
    first_out = tb.outputs[0][0]
    # The input is captured on edge first_in_edge (end of cycle 1). The result
    # is visible right after edge first_in_edge + 2N-2, i.e. during cycle 2N-1.
    latency = first_out - tb.first_in_edge + 1
    assert latency == 2 * n - 1, f"latency {latency} cycles, expected {2 * n - 1}"


@cocotb.test()
async def identity_weights(dut):
    """W = identity, so C must equal A exactly."""
    tb = ArrayTB(dut)
    await tb.start()
    a = rand_int8(RNG, (32, tb.n))
    await tb.run(a, np.eye(tb.n, dtype=np.int8))


@cocotb.test()
async def extreme_values(dut):
    """All -128 (largest positive sum), all 127, and mixed extremes."""
    tb = ArrayTB(dut)
    await tb.start()
    n = tb.n
    await tb.run(rand_int8(RNG, (8, n), "min"), rand_int8(RNG, (n, n), "min"))   # 8 * 16384
    await tb.run(rand_int8(RNG, (8, n), "max"), rand_int8(RNG, (n, n), "min"))   # most negative
    await tb.run(rand_int8(RNG, (8, n), "max"), rand_int8(RNG, (n, n), "max"))
    for _ in range(20):
        await tb.run(rand_int8(RNG, (16, n), "extreme"), rand_int8(RNG, (n, n), "extreme"))


@cocotb.test()
async def random_matrices(dut):
    """1,000 random matrix products with random sizes and data patterns."""
    tb = ArrayTB(dut)
    await tb.start()
    n = tb.n
    modes = ["uniform", "uniform", "extreme", "sparse"]
    for i in range(1000):
        m = int(RNG.integers(1, 65))
        a = rand_int8(RNG, (m, n), modes[i % 4])
        w = rand_int8(RNG, (n, n), modes[(i // 4) % 4])
        await tb.run(a, w)
    dut._log.info(f"array: {STATS['matrices']} matrices, {STATS['rows']} rows verified so far")


@cocotb.test()
async def bubbles_in_stream(dut):
    """Gaps between input rows must not corrupt or reorder results."""
    tb = ArrayTB(dut)
    await tb.start()
    for _ in range(40):
        a = rand_int8(RNG, (int(RNG.integers(1, 33)), tb.n))
        w = rand_int8(RNG, (tb.n, tb.n))
        await tb.run(a, w, bubble_prob=0.4)


@cocotb.test()
async def back_to_back_same_weights(dut):
    """Several activation batches reuse one weight load (weight-stationary)."""
    tb = ArrayTB(dut)
    await tb.start()
    w = rand_int8(RNG, (tb.n, tb.n))
    await tb.load_weights(w)
    for _ in range(20):
        a = rand_int8(RNG, (int(RNG.integers(1, 65)), tb.n))
        await tb.run(a, w, load=False)
    dut._log.info(f"array total: {STATS['matrices']} matrices, {STATS['rows']} rows verified")
