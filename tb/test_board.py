"""Smoke test of the exact board build (de10lite_top) at the real 2,000,000 baud.

Uses the real board baud rate (25 clocks per bit),
so it only does a PING and one small matrix multiply.
"""

import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, Timer

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "host"))
import accel_proto as P  # noqa: E402

from uart_model import UartSink, UartSource  # noqa: E402

BIT_NS = 500             # 1 / 2,000,000 baud


def wait_ns(n_bytes):
    """Time to receive n bytes (10 bits each) plus generous slack."""
    return BIT_NS * 12 * (n_bytes + 100)
HEX_1 = 0b11111001      # "1" on an active-low 7-segment display


@cocotb.test()
async def board_ping_and_matmul(dut):
    Clock(dut.clk, 20, unit="ns", impl="gpi").start()
    dut.key0_n.value = 1
    dut.key1_n.value = 1
    dut.sw.value = 0
    src = UartSource(dut.uart_rx, BIT_NS)
    sink = UartSink(dut.uart_tx, BIT_NS)
    await ClockCycles(dut.clk, 40)          # power-on reset finishes
    cocotb.start_soon(sink.run())

    # PING
    await src.send(P.enc_ping())
    info = P.dec_ping(await sink.recv(P.PING_REPLY_LEN, timeout_ns=wait_ns(P.PING_REPLY_LEN)))
    assert info["n"] == 16, info                   # the board build is 16 x 16
    P.set_array_size(info["n"])

    # One small matmul
    rng = np.random.default_rng(3)
    a = rng.integers(-128, 128, (2, P.N)).astype(np.int8)
    w = rng.integers(-128, 128, (P.N, P.N)).astype(np.int8)
    await src.send(P.enc_load_w(w) + P.enc_load_a(a) + P.enc_run())
    cycles = P.dec_run(await sink.recv(P.RUN_REPLY_LEN, timeout_ns=wait_ns(P.RUN_REPLY_LEN)))
    assert cycles == 2 + 2 * P.N
    await src.send(P.enc_read())
    c = P.dec_results(await sink.recv(P.read_len(2), timeout_ns=wait_ns(P.read_len(2))), 2)
    assert np.array_equal(c, P.golden_matmul(a, w))

    # Board status: run counter shows 1, no error LED
    await ReadOnly()
    assert int(dut.hex0.value) == HEX_1, f"HEX0 = {int(dut.hex0.value):08b}"
    assert (int(dut.ledr.value) >> 9) & 1 == 0, "error LED is on"

    # KEY[0] reset clears the run counter
    await Timer(1, unit="us")
    dut.key0_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.key0_n.value = 1
    dut.key1_n.value = 1
    dut.sw.value = 0
    await ClockCycles(dut.clk, 10)
    await ReadOnly()
    assert int(dut.hex0.value) == 0b11000000, "reset did not clear the counter"


@cocotb.test()
async def board_infer_one_image(dut):
    """The exact board build classifies one image on chip at the real baud rate."""
    from mnist_common import int8_forward, numpy_int_matmul
    P.set_array_size(16)
    Clock(dut.clk, 20, unit="ns", impl="gpi").start()
    dut.key0_n.value = 1
    dut.key1_n.value = 1
    dut.sw.value = 0
    src = UartSource(dut.uart_rx, BIT_NS)
    sink = UartSink(dut.uart_tx, BIT_NS)
    await ClockCycles(dut.clk, 40)
    cocotb.start_soon(sink.run())

    rng = np.random.default_rng(5)
    img = np.zeros((1, 784), dtype=np.uint8)
    mask = rng.random(784) < 0.2
    img[0, mask] = rng.integers(64, 256, size=int(mask.sum()))
    await src.send(P.enc_infer(img))
    digits, cycles = P.dec_infer(await sink.recv(P.infer_reply_len(1), timeout_ns=5_000_000), 1)
    q = dict(np.load(Path(__file__).resolve().parent.parent / "host" / "mnist_int8.npz"))
    pred, _, _ = int8_forward(img, q, numpy_int_matmul)
    assert digits[0] == pred[0], (digits, pred)
    assert cycles == P.infer_cycles(1), cycles
