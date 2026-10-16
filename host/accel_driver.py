"""Host-side driver for the accelerator.

Two backends with the same interface:
  * Accelerator     talks to the real board over a USB serial port
  * SimAccelerator  a byte-level software model of the board, for trying the
                    host scripts without hardware (python demo_matmul.py --sim)

Example:
    from accel_driver import open_accelerator
    acc = open_accelerator("COM5")          # or "/dev/ttyUSB0", or "sim"
    print(acc.ping())
    c, stats = acc.matmul(a, w)              # a: (M,K) int8, w: (K,N) int8
"""

import time

import numpy as np

import accel_proto as P

CLK_HZ = 50_000_000
PEAK_OPS = 2 * P.N * P.N * CLK_HZ   # 64 MACs/cycle, 2 ops per MAC = 6.4 GOPS


class _Base:
    def xfer(self, tx, n_rx):
        raise NotImplementedError

    def ping(self):
        return P.dec_ping(self.xfer(P.enc_ping(), P.PING_REPLY_LEN))

    def run_program(self, gen):
        try:
            tx, n = next(gen)
            while True:
                tx, n = gen.send(self.xfer(tx, n))
        except StopIteration as stop:
            return stop.value

    def matmul(self, a, w):
        """C = A @ W on the accelerator. Returns (C, stats dict)."""
        t0 = time.perf_counter()
        c, st = self.run_program(P.matmul_program(a, w))
        wall = time.perf_counter() - t0
        return c, summarize(st, wall)

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class Accelerator(_Base):
    """The real board, over a serial port."""

    def __init__(self, port, baud=115200, timeout=10.0):
        import serial  # pyserial

        self.ser = serial.Serial(port, baud, timeout=timeout)
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    def xfer(self, tx, n_rx):
        self.ser.write(tx)
        data = self.ser.read(n_rx)
        if len(data) != n_rx:
            raise TimeoutError(
                f"expected {n_rx} bytes from the board, got {len(data)} "
                f"(check wiring, baud rate, and that the FPGA is programmed)"
            )
        return data

    def close(self):
        self.ser.close()


class SimAccelerator(_Base):
    """Software model of the board's command protocol (no timing, no UART).

    It decodes the same bytes the real board does, so it checks that the host
    code builds correct commands. Cycle counts use the hardware formula that
    the simulation tests confirmed: M rows take M + 2N cycles.
    """

    def __init__(self):
        self.w = np.zeros((P.N, P.N), dtype=np.int8)
        self.a = np.zeros((1, P.N), dtype=np.int8)
        self.obuf = np.zeros((P.MAX_M, P.N), dtype=np.int64)   # output buffer

    def xfer(self, tx, n_rx):
        out = bytearray()
        i = 0
        while i < len(tx):
            cmd = tx[i]
            i += 1
            if cmd == P.CMD_PING:
                out += bytes([P.RSP_PING, P.N, P.MAX_M - 1, 1])
            elif cmd == P.CMD_LOAD_W:
                self.w = np.frombuffer(tx[i:i + P.N * P.N], dtype=np.int8).reshape(P.N, P.N)
                i += P.N * P.N
            elif cmd == P.CMD_LOAD_A:
                m = tx[i] + 1
                i += 1
                self.a = np.frombuffer(tx[i:i + m * P.N], dtype=np.int8).reshape(m, P.N)
                i += m * P.N
            elif cmd in (P.CMD_RUN, P.CMD_RUN_ACC):
                m = self.a.shape[0]
                prod = P.golden_matmul(self.a, self.w).astype(np.int64)
                if cmd == P.CMD_RUN_ACC:
                    prod = prod + self.obuf[:m]
                self.obuf[:m] = (prod + 2**31) % 2**32 - 2**31      # int32 wrap
                cycles = m + 2 * P.N
                out += bytes([P.RSP_DONE]) + cycles.to_bytes(4, "little")
            elif cmd == P.CMD_READ:
                m = self.a.shape[0]
                out += self.obuf[:m].astype("<i4").tobytes()
            else:
                out += bytes([P.RSP_ERR])
        assert len(out) == n_rx, f"model produced {len(out)} bytes, host expected {n_rx}"
        return bytes(out)


def open_accelerator(port, baud=115200):
    if port == "sim":
        return SimAccelerator()
    return Accelerator(port, baud)


def summarize(st, wall_s):
    """Turn raw counters into the numbers that go in the README."""
    compute_s = st.compute_cycles / CLK_HZ
    ops = 2 * st.useful_macs
    return {
        "tiles": st.tiles,
        "compute_cycles": st.compute_cycles,
        "compute_time_s": compute_s,
        "gops_compute": ops / compute_s / 1e9 if compute_s else 0.0,
        "peak_gops": PEAK_OPS / 1e9,
        "pe_utilization": st.useful_macs / (st.compute_cycles * P.N * P.N) if st.compute_cycles else 0.0,
        "bytes_sent": st.bytes_sent,
        "bytes_received": st.bytes_received,
        "wall_time_s": wall_s,
        "gops_end_to_end": ops / wall_s / 1e9 if wall_s else 0.0,
        "compute_share_of_wall": compute_s / wall_s if wall_s else 0.0,
    }
