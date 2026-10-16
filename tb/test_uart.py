"""Tests for uart_rx and uart_tx (top level: tb_uart)."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from uart_model import UartSink, UartSource

CLK_NS = 20  # 50 MHz


async def setup(dut):
    clks_per_bit = int(dut.CLKS_PER_BIT.value)
    bit_ns = clks_per_bit * CLK_NS
    Clock(dut.clk, CLK_NS, unit="ns", impl="gpi").start()
    dut.rx.value = 1
    dut.tx_start.value = 0
    dut.tx_data.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    await ClockCycles(dut.clk, 5)
    return bit_ns


async def collect_rx(dut, out, errors):
    while True:
        await RisingEdge(dut.clk)
        if int(dut.rx_valid.value):
            out.append(int(dut.rx_data.value))
        if int(dut.rx_frame_err.value):
            errors.append(1)


@cocotb.test()
async def rx_random_bytes(dut):
    """Receiver decodes 300 random back-to-back bytes, plus 0x00 and 0xFF."""
    bit_ns = await setup(dut)
    got, errs = [], []
    cocotb.start_soon(collect_rx(dut, got, errs))
    src = UartSource(dut.rx, bit_ns)
    data = [0x00, 0xFF, 0x55, 0xAA] + [random.randrange(256) for _ in range(300)]
    await src.send(data)
    await Timer(bit_ns * 2, unit="ns")
    assert got == data, "received bytes do not match"
    assert not errs, "unexpected frame errors"


@cocotb.test()
async def rx_baud_tolerance(dut):
    """Receiver still works when the sender's baud rate is off by +/-3%."""
    bit_ns = await setup(dut)
    got, errs = [], []
    cocotb.start_soon(collect_rx(dut, got, errs))
    src = UartSource(dut.rx, bit_ns)
    for err in (-0.03, 0.03):
        data = [random.randrange(256) for _ in range(50)]
        got.clear()
        await src.send(data, bit_time_ns=bit_ns * (1 + err))
        await Timer(bit_ns * 2, unit="ns")
        assert got == data, f"failed at baud error {err:+.0%}"


@cocotb.test()
async def rx_rejects_glitch(dut):
    """A low pulse shorter than half a bit is not mistaken for a start bit."""
    bit_ns = await setup(dut)
    got, errs = [], []
    cocotb.start_soon(collect_rx(dut, got, errs))
    for _ in range(5):
        dut.rx.value = 0
        await Timer(bit_ns // 4, unit="ns")
        dut.rx.value = 1
        await Timer(bit_ns * 12, unit="ns")
    assert got == [], "glitch produced a byte"


@cocotb.test()
async def rx_frame_error(dut):
    """A byte whose stop bit is 0 is flagged and dropped."""
    bit_ns = await setup(dut)
    got, errs = [], []
    cocotb.start_soon(collect_rx(dut, got, errs))
    # start bit, 8 data bits of 0x3C, then a 0 where the stop bit should be
    bits = [0] + [(0x3C >> i) & 1 for i in range(8)] + [0]
    for b in bits:
        dut.rx.value = b
        await Timer(bit_ns, unit="ns")
    dut.rx.value = 1
    await Timer(bit_ns * 3, unit="ns")
    assert got == [], "bad byte was accepted"
    assert len(errs) == 1, "frame error not flagged"


@cocotb.test()
async def tx_random_bytes(dut):
    """Transmitter sends 300 random bytes that decode correctly."""
    bit_ns = await setup(dut)
    sink = UartSink(dut.tx, bit_ns)
    cocotb.start_soon(sink.run())
    data = [0x00, 0xFF] + [random.randrange(256) for _ in range(300)]
    for byte in data:
        while int(dut.tx_busy.value):
            await RisingEdge(dut.clk)
        dut.tx_data.value = byte
        dut.tx_start.value = 1
        await RisingEdge(dut.clk)
        dut.tx_start.value = 0
        await RisingEdge(dut.clk)
    got = await sink.recv(len(data), timeout_ns=bit_ns * 20 * len(data))
    assert list(got) == data, "transmitted bytes do not match"
    assert sink.frame_errors == 0


@cocotb.test()
async def loopback(dut):
    """tx wired back into rx: 200 bytes survive the round trip."""
    bit_ns = await setup(dut)
    got, errs = [], []
    cocotb.start_soon(collect_rx(dut, got, errs))

    async def wire():
        while True:
            await RisingEdge(dut.clk)
            dut.rx.value = int(dut.tx.value)

    cocotb.start_soon(wire())
    data = [random.randrange(256) for _ in range(200)]
    for byte in data:
        while int(dut.tx_busy.value):
            await RisingEdge(dut.clk)
        dut.tx_data.value = byte
        dut.tx_start.value = 1
        await RisingEdge(dut.clk)
        dut.tx_start.value = 0
        await RisingEdge(dut.clk)
    await Timer(bit_ns * 15, unit="ns")
    assert got == data
