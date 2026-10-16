"""End-to-end tests of the whole design (accel_top) through its UART pins.

The testbench plays the laptop: it sends real UART bytes into uart_rx and
decodes what comes out of uart_tx. It uses host/accel_proto.py, the same
protocol code the real host script uses.

The baud rate is sped up (8 clocks per bit instead of 434) so simulations
finish quickly. Nothing else changes.
"""

import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "host"))
import accel_proto as P  # noqa: E402

from hw_utils import rand_int8  # noqa: E402
from uart_model import UartSink, UartSource  # noqa: E402

CLK_NS = 20
RNG = np.random.default_rng(7)
STATS = {"matmuls": 0, "tiles": 0}


class SystemTB:
    def __init__(self, dut):
        self.dut = dut
        self.bit_ns = int(dut.CLKS_PER_BIT.value) * CLK_NS
        self.src = UartSource(dut.uart_rx, self.bit_ns)
        self.sink = UartSink(dut.uart_tx, self.bit_ns)

    async def start(self):
        Clock(self.dut.clk, CLK_NS, unit="ns", impl="gpi").start()
        self.dut.rst.value = 1
        await ClockCycles(self.dut.clk, 5)
        self.dut.rst.value = 0
        await ClockCycles(self.dut.clk, 5)
        cocotb.start_soon(self.sink.run())

    async def xfer(self, tx, n_rx):
        await self.src.send(tx)
        timeout = self.bit_ns * 12 * (n_rx + 64) + 1_000_000
        return await self.sink.recv(n_rx, timeout_ns=timeout)

    async def run_program(self, gen):
        try:
            tx, n = next(gen)
            while True:
                rx = await self.xfer(tx, n)
                tx, n = gen.send(rx)
        except StopIteration as stop:
            return stop.value

    async def matmul(self, a, w):
        c, st = await self.run_program(P.matmul_program(a, w))
        expect = P.golden_matmul(a, w)
        assert np.array_equal(c, expect), f"mismatch for shape A{a.shape} W{w.shape}"
        STATS["matmuls"] += 1
        STATS["tiles"] += st.tiles
        return c, st


@cocotb.test()
async def ping(dut):
    """PING returns A5, N, MAX_M-1, version."""
    tb = SystemTB(dut)
    await tb.start()
    info = P.dec_ping(await tb.xfer(P.enc_ping(), P.PING_REPLY_LEN))
    assert info == {"n": 8, "max_m": 256, "version": 1}, info


@cocotb.test()
async def unknown_command(dut):
    """An unknown command byte gets EE back, and the core keeps working."""
    tb = SystemTB(dut)
    await tb.start()
    assert await tb.xfer(b"\x00", 1) == bytes([P.RSP_ERR])
    assert await tb.xfer(b"Z", 1) == bytes([P.RSP_ERR])
    P.dec_ping(await tb.xfer(P.enc_ping(), P.PING_REPLY_LEN))


@cocotb.test()
async def single_tile_and_cycle_count(dut):
    """One 8x8 tile. Also pins down the cycle count: M rows take M + 2N cycles."""
    tb = SystemTB(dut)
    await tb.start()
    for m in (1, 2, 16, 64):
        a = rand_int8(RNG, (m, 8))
        w = rand_int8(RNG, (8, 8))
        _, st = await tb.matmul(a, w)
        assert st.per_tile_cycles == [(m, m + 16)], st.per_tile_cycles


@cocotb.test()
async def extreme_values(dut):
    """Largest positive and negative sums, through the full system."""
    tb = SystemTB(dut)
    await tb.start()
    await tb.matmul(rand_int8(RNG, (4, 8), "min"), rand_int8(RNG, (8, 8), "min"))
    await tb.matmul(rand_int8(RNG, (4, 8), "max"), rand_int8(RNG, (8, 8), "min"))
    # accumulate 8 tiles of the largest sum: 8 * 131072
    await tb.matmul(rand_int8(RNG, (3, 64), "min"), rand_int8(RNG, (64, 8), "min"))


@cocotb.test()
async def run_overwrites(dut):
    """RUN replaces the output buffer; it does not add to the old result."""
    tb = SystemTB(dut)
    await tb.start()
    a = rand_int8(RNG, (12, 8))
    w = rand_int8(RNG, (8, 8))
    c1, _ = await tb.matmul(a, w)
    c2, _ = await tb.matmul(a, w)
    assert np.array_equal(c1, c2)


@cocotb.test()
async def tiled_shapes(dut):
    """Matrices bigger than 8x8, including sizes that need padding."""
    tb = SystemTB(dut)
    await tb.start()
    shapes = [(5, 8, 8), (24, 40, 20), (33, 17, 9), (10, 64, 16), (7, 3, 5), (40, 24, 24)]
    for i, (m, k, n) in enumerate(shapes):
        mode = "sparse" if i % 2 else "uniform"
        await tb.matmul(rand_int8(RNG, (m, k), mode), rand_int8(RNG, (k, n), mode))
    for _ in range(4):
        m, k, n = (int(x) for x in RNG.integers(1, 41, size=3))
        await tb.matmul(rand_int8(RNG, (m, k)), rand_int8(RNG, (k, n)))
    dut._log.info(f"system: {STATS['matmuls']} matmuls, {STATS['tiles']} tiles verified so far")


@cocotb.test()
async def full_buffer_and_chunking(dut):
    """M = 256 fills the buffers exactly; M = 300 must be split into 2 chunks."""
    tb = SystemTB(dut)
    await tb.start()
    _, st = await tb.matmul(rand_int8(RNG, (256, 8)), rand_int8(RNG, (8, 8)))
    assert st.per_tile_cycles == [(256, 256 + 16)]
    _, st = await tb.matmul(rand_int8(RNG, (300, 8)), rand_int8(RNG, (8, 8)))
    assert [m for m, _ in st.per_tile_cycles] == [256, 44]
    dut._log.info(f"system total: {STATS['matmuls']} matmuls, {STATS['tiles']} tiles verified")


@cocotb.test()
async def commands_back_to_back(dut):
    """Several commands sent in one burst without waiting for replies."""
    tb = SystemTB(dut)
    await tb.start()
    w = rand_int8(RNG, (8, 8))
    a = rand_int8(RNG, (6, 8))
    burst = P.enc_ping() + P.enc_load_w(w) + P.enc_load_a(a) + P.enc_run() + P.enc_read() + P.enc_ping()
    await tb.src.send(burst)
    n = P.PING_REPLY_LEN + P.RUN_REPLY_LEN + P.read_len(6) + P.PING_REPLY_LEN
    rx = await tb.sink.recv(n, timeout_ns=tb.bit_ns * 12 * (n + 200))
    P.dec_ping(rx[:4])
    P.dec_run(rx[4:9])
    c = P.dec_results(rx[9:9 + P.read_len(6)], 6)
    assert np.array_equal(c, P.golden_matmul(a, w))
    P.dec_ping(rx[-4:])
    await Timer(1, unit="us")
