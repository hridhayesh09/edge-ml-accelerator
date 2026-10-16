"""Behavioral UART models used by the testbenches.

UartSource drives a serial line (plays the part of the laptop sending bytes).
UartSink watches a serial line and decodes bytes (plays the laptop receiving).

Timing uses simulation time rather than clock cycles, so tests can also run
the line slightly fast or slow to check the receiver's baud tolerance.
"""

from collections import deque

from cocotb.triggers import FallingEdge, Timer


class UartSource:
    def __init__(self, signal, bit_time_ns):
        self.signal = signal
        self.bit_time_ns = bit_time_ns
        self.signal.value = 1  # idle high

    async def send_byte(self, byte, bit_time_ns=None):
        t = bit_time_ns if bit_time_ns is not None else self.bit_time_ns
        bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1]  # start, data LSB first, stop
        for b in bits:
            self.signal.value = b
            await Timer(t, unit="ns")

    async def send(self, data, bit_time_ns=None):
        for byte in data:
            await self.send_byte(byte, bit_time_ns)


class UartSink:
    def __init__(self, signal, bit_time_ns):
        self.signal = signal
        self.bit_time_ns = bit_time_ns
        self.queue = deque()
        self.frame_errors = 0

    async def run(self):
        """Run forever, decoding bytes into self.queue."""
        while True:
            await FallingEdge(self.signal)
            # Middle of the start bit
            await Timer(self.bit_time_ns / 2, unit="ns")
            if int(self.signal.value) != 0:
                continue  # glitch
            byte = 0
            for i in range(8):
                await Timer(self.bit_time_ns, unit="ns")
                byte |= int(self.signal.value) << i
            await Timer(self.bit_time_ns, unit="ns")
            if int(self.signal.value) != 1:
                self.frame_errors += 1
            self.queue.append(byte)
            # Now in the middle of the stop bit; the next falling edge is the
            # next start bit.

    async def recv(self, n, timeout_ns=None):
        """Wait until n bytes have arrived and return them."""
        waited = 0
        step = self.bit_time_ns * 10
        while len(self.queue) < n:
            await Timer(step, unit="ns")
            waited += step
            if timeout_ns is not None and waited > timeout_ns:
                raise TimeoutError(f"expected {n} bytes, got {len(self.queue)}")
        return bytes(self.queue.popleft() for _ in range(n))
