"""End-to-end tests of the whole design (accel_top) through its UART pins.

The testbench plays the laptop: it sends real UART bytes into uart_rx and
decodes what comes out of uart_tx. It uses host/accel_proto.py, the same
protocol code the real host script uses.

The baud rate is sped up (8 clocks per bit instead of 25) so simulations
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
        self.timeout_ns = int(dut.RX_TIMEOUT.value) * CLK_NS
        self.src = UartSource(dut.uart_rx, self.bit_ns)
        self.sink = UartSink(dut.uart_tx, self.bit_ns)
        self.faults = {}      # transfer number -> ("corrupt" | "drop", byte index)
        self.transfers = 0

    async def start(self):
        Clock(self.dut.clk, CLK_NS, unit="ns", impl="gpi").start()
        self.dut.demo_active.value = 0       # the standalone demo isn't used here
        self.dut.demo_empty.value = 1
        self.dut.demo_data.value = 0
        self.dut.rst.value = 1
        await ClockCycles(self.dut.clk, 5)
        self.dut.rst.value = 0
        await ClockCycles(self.dut.clk, 5)
        cocotb.start_soon(self.sink.run())
        P.set_array_size(int(self.dut.N.value))   # this build's array size

    async def xfer(self, tx, n_rx):
        self.transfers += 1
        fault = self.faults.pop(self.transfers, None)
        if fault:                                   # simulate a bad serial link
            kind, idx = fault
            tx = bytearray(tx)
            if kind == "corrupt":
                tx[idx] ^= 0x10
            else:
                del tx[idx]
            tx = bytes(tx)
        await self.src.send(tx)
        timeout = self.bit_ns * 12 * (n_rx + 64) + 1_000_000
        return await self.sink.recv(n_rx, timeout_ns=timeout)

    async def resync(self):
        """Same steps as the real driver: wait out the board's stall timeout,
        drop anything half-received, and check that PING works."""
        for _ in range(50):
            # wait until the line has been quiet for a while (the board may be
            # busy answering garbage it took for commands)
            self.sink.queue.clear()
            await Timer(2 * self.timeout_ns + 100 * self.bit_ns, unit="ns")
            if self.sink.queue:
                continue
            await self.src.send(P.enc_ping())
            try:
                rx = await self.sink.recv(P.PING_REPLY_LEN, timeout_ns=self.bit_ns * 200)
                P.dec_ping(rx)
                return
            except (TimeoutError, ValueError):
                continue
        raise TimeoutError("could not resync with the board")

    async def run_program(self, gen):
        """Drives the protocol generator with the same recovery as accel_driver."""
        try:
            tx, n = next(gen)
            while True:
                if tx is P.RESYNC:
                    await self.resync()
                    tx, n = gen.send(b"")
                    continue
                try:
                    rx = await self.xfer(tx, n)
                except TimeoutError:
                    await self.resync()
                    tx, n = gen.throw(P.RetryTile())
                    continue
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
    assert info == {"n": int(dut.N.value), "max_m": 256, "version": P.PROTOCOL_VERSION}, info


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
    """One N x N tile. Also pins down the cycle count: M rows take M + 2N cycles."""
    tb = SystemTB(dut)
    await tb.start()
    for m in (1, 2, 16, 64):
        a = rand_int8(RNG, (m, P.N))
        w = rand_int8(RNG, (P.N, P.N))
        _, st = await tb.matmul(a, w)
        assert st.per_tile_cycles == [(m, m + 2 * P.N)], st.per_tile_cycles


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
    a = rand_int8(RNG, (12, P.N))
    w = rand_int8(RNG, (P.N, P.N))
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
    _, st = await tb.matmul(rand_int8(RNG, (256, P.N)), rand_int8(RNG, (P.N, P.N)))
    assert st.per_tile_cycles == [(256, 256 + 2 * P.N)]
    _, st = await tb.matmul(rand_int8(RNG, (300, P.N)), rand_int8(RNG, (P.N, P.N)))
    assert [m for m, _ in st.per_tile_cycles] == [256, 44]
    dut._log.info(f"system total: {STATS['matmuls']} matmuls, {STATS['tiles']} tiles verified")


@cocotb.test()
async def commands_back_to_back(dut):
    """Several commands sent in one burst without waiting for replies."""
    tb = SystemTB(dut)
    await tb.start()
    w = rand_int8(RNG, (P.N, P.N))
    a = rand_int8(RNG, (6, P.N))
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


@cocotb.test()
async def bad_checksum_refuses_run(dut):
    """A corrupted LOAD makes RUN_ACC reply EC without touching the output buffer."""
    tb = SystemTB(dut)
    await tb.start()
    w1, a1 = rand_int8(RNG, (P.N, P.N)), rand_int8(RNG, (5, P.N))
    w2, a2 = rand_int8(RNG, (P.N, P.N)), rand_int8(RNG, (5, P.N))
    P.dec_run(await tb.xfer(P.enc_load_w(w1) + P.enc_load_a(a1) + P.enc_run(), P.RUN_REPLY_LEN))

    bad_w = bytearray(P.enc_load_w(w2))
    bad_w[10] ^= 0x01                               # one flipped bit in a weight
    rx = await tb.xfer(bytes(bad_w) + P.enc_load_a(a2) + P.enc_run(accumulate=True),
                       P.RUN_REPLY_LEN)
    assert rx == bytes([P.RSP_BAD, 0, 0, 0, 0]), rx.hex()

    c = P.dec_results(await tb.xfer(P.enc_read(), P.read_len(5)), 5)
    assert np.array_equal(c, P.golden_matmul(a1, w1)), "refused RUN_ACC changed the output"


@cocotb.test()
async def lost_byte_times_out(dut):
    """A LOAD missing a byte must not hang the board: it times out, PING works,
    and the next tile computes correctly."""
    tb = SystemTB(dut)
    await tb.start()
    w, a = rand_int8(RNG, (P.N, P.N)), rand_int8(RNG, (4, P.N))
    short = P.enc_load_a(a)[:-2]                    # lose the last data byte and the checksum
    await tb.src.send(P.enc_load_w(w) + short)
    await Timer(2 * tb.timeout_ns, unit="ns")
    assert len(tb.sink.queue) == 0
    P.dec_ping(await tb.xfer(P.enc_ping(), P.PING_REPLY_LEN))
    await tb.matmul(a, w)


@cocotb.test()
async def link_errors_recovered(dut):
    """Full host recovery path: corrupted and dropped bytes in the middle of a
    tiled matmul, the host resyncs and retries, and the answer is still exact."""
    tb = SystemTB(dut)
    await tb.start()
    a, w = rand_int8(RNG, (20, 32)), rand_int8(RNG, (32, 16))
    # 4 K-slices x 2 output tiles; each output tile = 4 tile uploads + 1 READ.
    #   transfer 2  (tile 0, k=1): corrupt a weight      -> EC reply, retry tile 0 (3..7)
    #   transfer 9  (tile 1, k=1): drop an activation    -> board times out, retry tile 1 (13..17)
    #   transfer 14 (tile 1, k=1): corrupt the command   -> garbage reply, retry tile 1 (18..22)
    tb.faults = {2: ("corrupt", 30), 9: ("drop", 100), 14: ("corrupt", 0)}
    _, st = await tb.matmul(a, w)
    assert st.retries == 3, st.retries


# ---------------------------------------------------------------------------
# On-chip MNIST (INFER)
# ---------------------------------------------------------------------------

def mnist_reference(images):
    from mnist_common import int8_forward, numpy_int_matmul
    q = dict(np.load(Path(__file__).resolve().parent.parent / "host" / "mnist_int8.npz"))
    pred, _, logits = int8_forward(images, q, numpy_int_matmul)
    return pred, logits


def make_images(b, seed):
    """Digit-like test images without downloading MNIST: random strokes."""
    rng = np.random.default_rng(seed)
    img = np.zeros((b, 784), dtype=np.uint8)
    for i in range(b):
        mask = rng.random(784) < rng.uniform(0.1, 0.3)
        img[i, mask] = rng.integers(64, 256, size=int(mask.sum()))
    return img


@cocotb.test()
async def infer_matches_numpy(dut):
    """The whole network on chip: digits and all 10 logits per image match the
    NumPy INT8 reference bit for bit, and the cycle count matches the formula."""
    tb = SystemTB(dut)
    await tb.start()
    edge = np.zeros((2, 784), dtype=np.uint8)
    edge[1, :] = np.arange(784) % 255 + 1            # no zero pixels at all
    cases = [(make_images(1, 1), False), (make_images(5, 2), True),
             (edge, True), (make_images(3, 4), False)]   # raw and compressed INFER
    for images, compress in cases:
        b = images.shape[0]
        digits, logits, st = await tb.run_program(
            P.infer_program(images, with_logits=True, compress=compress))
        ref_pred, ref_logits = mnist_reference(images)
        assert np.array_equal(logits, ref_logits), f"logits differ:\n{logits}\n{ref_logits}"
        assert np.array_equal(digits, ref_pred), (digits, ref_pred)
        assert st["compute_cycles"] == P.infer_cycles(b), (st["compute_cycles"], P.infer_cycles(b))
        dut._log.info(f"INFER B={b} compressed={compress}: digits {digits.tolist()}, "
                      f"{st['compute_cycles']} cycles, {st['bytes_sent']} bytes sent")


@cocotb.test()
async def infer_bad_checksum_then_matmul(dut):
    """A corrupted INFER replies EC; afterwards the shared array still does a
    correct INFER and a correct UART matmul (the two modes don't interfere)."""
    tb = SystemTB(dut)
    await tb.start()
    images = make_images(2, 3)
    bad = bytearray(P.enc_infer(images))
    bad[100] ^= 0x01
    rx = await tb.xfer(bytes(bad), P.infer_reply_len(2))
    assert rx[0] == P.RSP_BAD and P.checksum(rx[:-1]) == rx[-1], rx.hex()
    digits, _, _ = await tb.run_program(P.infer_program(images))
    assert np.array_equal(digits, mnist_reference(images)[0])
    await tb.matmul(rand_int8(RNG, (9, 24)), rand_int8(RNG, (24, 16)))
