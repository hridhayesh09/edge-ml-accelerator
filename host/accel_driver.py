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


def peak_ops():
    """N*N MACs per cycle, 2 ops per MAC: 25.6 GOPS for 16x16 at 50 MHz."""
    return 2 * P.N * P.N * CLK_HZ


class _Base:
    def xfer(self, tx, n_rx):
        raise NotImplementedError

    def ping(self):
        return P.dec_ping(self.xfer(P.enc_ping(), P.PING_REPLY_LEN))

    def resync(self):
        """Get back in step with the board after a link error."""

    def run_program(self, gen):
        """Drive a protocol generator (see accel_proto.matmul_program),
        recovering from link errors: on a timeout or a RESYNC request, resync
        with the board and let the generator redo the current output tile."""
        try:
            tx, n = next(gen)
            while True:
                if tx is P.RESYNC:
                    self.resync()
                    tx, n = gen.send(b"")
                    continue
                try:
                    rx = self.xfer(tx, n)
                except TimeoutError:
                    self.resync()
                    tx, n = gen.throw(P.RetryTile())
                    continue
                tx, n = gen.send(rx)
        except StopIteration as stop:
            return stop.value

    def matmul(self, a, w):
        """C = A @ W on the accelerator. Returns (C, stats dict)."""
        t0 = time.perf_counter()
        c, st = self.run_program(P.matmul_program(a, w))
        wall = time.perf_counter() - t0
        return c, summarize(st, wall)

    def infer(self, images_u8, with_logits=False):
        """Classify MNIST images with the network running entirely on the
        board. Returns (digits, logits or None, stats dict)."""
        t0 = time.perf_counter()
        digits, logits, st = self.run_program(P.infer_program(images_u8, with_logits))
        st["wall_time_s"] = time.perf_counter() - t0
        st["compute_time_s"] = st["compute_cycles"] / CLK_HZ
        return digits, logits, st

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class Accelerator(_Base):
    """The real board, over a serial port."""

    def __init__(self, port, baud=2_000_000):
        import serial  # pyserial

        self.baud = baud
        self.ser = serial.Serial(port, baud, timeout=1.0)
        time.sleep(0.05)
        self.ser.reset_input_buffer()
        P.set_array_size(self.ping()["n"])        # tile size follows the board's array

    def resync(self):
        # The board drops a stalled LOAD after 50 ms of silence. Wait longer
        # than that, throw away anything half-sent, and check with a PING.
        # If a command byte was hit, the board may be busy answering garbage
        # it took for commands, so first wait until the line goes quiet.
        self.ser.timeout = 0.5
        for _ in range(20):
            self.ser.reset_input_buffer()
            time.sleep(0.2)
            if self.ser.in_waiting:
                continue
            self.ser.write(P.enc_ping())
            if self.ser.read(P.PING_REPLY_LEN)[:1] == bytes([P.RSP_PING]):
                return
        raise TimeoutError("board did not answer PING after a link error")

    def xfer(self, tx, n_rx):
        # timeout: time to send and receive everything at this baud, plus slack
        self.ser.timeout = 0.5 + 2 * 10 * (len(tx) + n_rx) / self.baud
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

    def __init__(self, corrupt_prob=0.0, seed=0):
        self.w = np.zeros((P.N, P.N), dtype=np.int8)
        self.a = np.zeros((1, P.N), dtype=np.int8)
        self.obuf = np.zeros((P.MAX_M, P.N), dtype=np.int64)   # output buffer
        self.bad = False
        self.logits = np.zeros((1, 10), dtype=np.int64)
        self.model = None
        # Fault injection for testing the retry path: each transfer has a
        # `corrupt_prob` chance of one payload byte arriving corrupted.
        self.corrupt_prob = corrupt_prob
        self.rng = np.random.default_rng(seed)

    def xfer(self, tx, n_rx):
        if self.corrupt_prob and len(tx) > 3 and self.rng.random() < self.corrupt_prob:
            tx = bytearray(tx)
            tx[2] ^= 0x40                       # a payload byte, never the command
            tx = bytes(tx)
        out = bytearray()
        i = 0
        while i < len(tx):
            cmd = tx[i]
            i += 1
            if cmd == P.CMD_PING:
                out += bytes([P.RSP_PING, P.N, P.MAX_M - 1, P.PROTOCOL_VERSION])
            elif cmd == P.CMD_LOAD_W:
                body = tx[i:i + P.N * P.N]
                self.w = np.frombuffer(body, dtype=np.int8).reshape(P.N, P.N)
                self.bad |= P.checksum(body) != tx[i + P.N * P.N]
                i += P.N * P.N + 1
            elif cmd == P.CMD_LOAD_A:
                m = tx[i] + 1
                body = tx[i:i + 1 + m * P.N]
                self.a = np.frombuffer(body[1:], dtype=np.int8).reshape(m, P.N)
                self.bad |= P.checksum(body) != tx[i + 1 + m * P.N]
                i += 1 + m * P.N + 1
            elif cmd in (P.CMD_RUN, P.CMD_RUN_ACC) and self.bad:
                self.bad = False
                out += bytes([P.RSP_BAD, 0, 0, 0, 0])
            elif cmd in (P.CMD_RUN, P.CMD_RUN_ACC):
                m = self.a.shape[0]
                prod = P.golden_matmul(self.a, self.w).astype(np.int64)
                if cmd == P.CMD_RUN_ACC:
                    prod = prod + self.obuf[:m]
                self.obuf[:m] = (prod + 2**31) % 2**32 - 2**31      # int32 wrap
                cycles = m + 2 * P.N
                out += bytes([P.RSP_DONE]) + cycles.to_bytes(4, "little")
            elif cmd == P.CMD_INFER:
                b = tx[i] + 1
                body = tx[i:i + 1 + b * P.IN_PIX]
                ok = P.checksum(body) == tx[i + 1 + b * P.IN_PIX]
                images = np.frombuffer(body[1:], dtype=np.uint8).reshape(b, P.IN_PIX)
                i += 1 + b * P.IN_PIX + 1
                frame = bytearray([P.RSP_BAD]) + bytes(b + 4)
                if ok:
                    digits, logits = self._mnist(images)
                    self.logits = logits
                    frame = (bytearray([P.RSP_INFER]) + bytes(digits.astype(np.uint8))
                             + P.infer_cycles(b).to_bytes(4, "little"))
                out += frame + bytes([P.checksum(frame)])
            elif cmd == P.CMD_LOGITS:
                res = self.logits.astype("<i4").tobytes()
                out += res + bytes([P.checksum(res)])
            elif cmd == P.CMD_READ:
                m = self.a.shape[0]
                res = self.obuf[:m].astype("<i4").tobytes()
                out += res + bytes([P.checksum(res)])
            else:
                out += bytes([P.RSP_ERR])
        assert len(out) == n_rx, f"model produced {len(out)} bytes, host expected {n_rx}"
        return bytes(out)

    def _mnist(self, images):
        """What INFER computes: the INT8 network, bit-exact (NumPy reference)."""
        from mnist_common import int8_forward, numpy_int_matmul
        if self.model is None:
            from pathlib import Path
            self.model = dict(np.load(Path(__file__).with_name("mnist_int8.npz")))
        pred, _, acc2 = int8_forward(images, self.model, numpy_int_matmul)
        return pred, acc2


def open_accelerator(port, baud=2_000_000):
    if port == "sim":
        return SimAccelerator()
    if port.startswith("sim-faulty"):          # e.g. "sim-faulty:0.05" for testing retries
        return SimAccelerator(corrupt_prob=float(port.split(":")[1]) if ":" in port else 0.02)
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
        "peak_gops": peak_ops() / 1e9,
        "pe_utilization": st.useful_macs / (st.compute_cycles * P.N * P.N) if st.compute_cycles else 0.0,
        "bytes_sent": st.bytes_sent,
        "bytes_received": st.bytes_received,
        "retries": st.retries,
        "wall_time_s": wall_s,
        "gops_end_to_end": ops / wall_s / 1e9 if wall_s else 0.0,
        "compute_share_of_wall": compute_s / wall_s if wall_s else 0.0,
    }
