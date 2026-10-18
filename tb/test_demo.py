"""Standalone demo on the exact board build: switches + KEY1 in, 7-segment
displays and LEDs out. No UART involved.

The expected answers come from decoding the stored images (rtl/model/demo_*.hex)
in Python and running the NumPy INT8 reference on them, so the test needs no
MNIST download.
"""

import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "host"))
import accel_proto as P  # noqa: E402
from mnist_common import int8_forward, numpy_int_matmul, quantize_input  # noqa: E402

MODEL = ROOT / "rtl" / "model"
SEG = {0b1000000: 0, 0b1111001: 1, 0b0100100: 2, 0b0110000: 3, 0b0011001: 4,
       0b0010010: 5, 0b0000010: 6, 0b1111000: 7, 0b0000000: 8, 0b0010000: 9}


def read_hex(name):
    return [int(line, 16) for line in (MODEL / name).read_text().split()]


def demo_reference():
    """(labels, predictions) for every stored demo image."""
    blob = bytes(read_hex("demo_bytes.hex"))
    index = read_hex("demo_index.hex")
    labels = read_hex("demo_labels.hex")
    n = read_hex("demo_count.hex")[0]
    images_q = np.array([np.frombuffer(P.rle_decode(blob[index[k]:index[k + 1]], 784), np.uint8)
                         for k in range(n)])
    # undo the quantizer table to reuse the reference pipeline exactly
    table = quantize_input(np.arange(256, dtype=np.uint8)).view(np.uint8)
    inverse = np.zeros(128, dtype=np.uint8)
    for raw in range(255, -1, -1):
        inverse[table[raw]] = raw
    q = dict(np.load(ROOT / "host" / "mnist_int8.npz"))
    pred, _, _ = int8_forward(inverse[images_q], q, numpy_int_matmul)
    return np.array(labels[:n]), pred


def led(dut, k):
    """One LED (reading single bits avoids unrelated simulation-only X bits)."""
    return str(dut.ledr.value)[9 - k] == "1"


def digit(sig):
    return SEG.get(int(sig.value) & 0x7F)


async def boot(dut, sw):
    Clock(dut.clk, 20, unit="ns", impl="gpi").start()
    dut.key0_n.value = 1
    dut.key1_n.value = 1
    dut.uart_rx.value = 1
    dut.sw.value = sw
    await ClockCycles(dut.clk, 100)


async def press_key1(dut):
    dut.key1_n.value = 0
    await ClockCycles(dut.clk, 400)       # longer than the (shortened) debounce
    dut.key1_n.value = 1
    await ClockCycles(dut.clk, 400)


async def wait_led(dut, bit, max_cycles):
    for _ in range(max_cycles // 100):
        await ClockCycles(dut.clk, 100)
        await ReadOnly()
        if led(dut, bit):
            await RisingEdge(dut.clk)
            return
        await RisingEdge(dut.clk)
    raise TimeoutError(f"LEDR{bit} never turned on")


@cocotb.test()
async def demo_single_images(dut):
    """Pick images with the switches, press KEY1: the displays show the image
    number, the true digit and the board's prediction (same as NumPy)."""
    labels, pred = demo_reference()
    wrong = [k for k in range(len(labels)) if pred[k] != labels[k]]
    picks = [3, 42] + wrong[:1]
    await boot(dut, picks[0])
    for k in picks:
        dut.sw.value = k
        await ClockCycles(dut.clk, 10)
        await press_key1(dut)
        await ClockCycles(dut.clk, 30_000)  # one image: ~10k compute + streaming
        await ReadOnly()
        shown = (digit(dut.hex5), digit(dut.hex4), digit(dut.hex2), digit(dut.hex0))
        assert shown == (k // 10, k % 10, labels[k], pred[k]), (k, shown, labels[k], pred[k])
        assert (led(dut, 5), led(dut, 6)) == ((True, False) if pred[k] == labels[k] else (False, True))
        dut._log.info(f"image {k}: true {labels[k]}, board says {pred[k]}")
        await RisingEdge(dut.clk)


@cocotb.test()
async def demo_run_all(dut):
    """SW9 up + KEY1: every stored image is classified; the displays show
    right/total, and (SW8 up) the run time in microseconds."""
    labels, pred = demo_reference()
    await boot(dut, 1 << 9)
    await press_key1(dut)
    await wait_led(dut, 7, 400_000)
    await ReadOnly()
    right = 100 * digit(dut.hex5) + 10 * digit(dut.hex4) + digit(dut.hex3)
    total = 100 * digit(dut.hex2) + 10 * digit(dut.hex1) + digit(dut.hex0)
    assert total == len(labels), total
    assert right == int((pred == labels).sum()), (right, int((pred == labels).sum()))
    await RisingEdge(dut.clk)
    dut.sw.value = (1 << 9) | (1 << 8)
    await ClockCycles(dut.clk, 100)
    await ReadOnly()
    us = int("".join(str(digit(h)) for h in (dut.hex5, dut.hex4, dut.hex3, dut.hex2, dut.hex1, dut.hex0)))
    assert 0 < us < 10_000, us
    dut._log.info(f"run all: {right}/{total} right in {us} us")


@cocotb.test()
async def demo_singles_dont_change_totals(dut):
    """Classifying single images after a run-all leaves the run-all result alone
    (found on the board: the totals used to keep counting)."""
    labels, pred = demo_reference()
    await boot(dut, 1 << 9)
    await press_key1(dut)
    await wait_led(dut, 7, 400_000)
    dut.sw.value = 5                                   # single image mode
    await ClockCycles(dut.clk, 10)
    await press_key1(dut)
    await ClockCycles(dut.clk, 30_000)
    dut.sw.value = 1 << 9                              # back to the run-all view
    await ClockCycles(dut.clk, 100)
    await ReadOnly()
    right = 100 * digit(dut.hex5) + 10 * digit(dut.hex4) + digit(dut.hex3)
    total = 100 * digit(dut.hex2) + 10 * digit(dut.hex1) + digit(dut.hex0)
    assert (right, total) == (int((pred == labels).sum()), len(labels)), (right, total)
