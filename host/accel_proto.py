"""Byte protocol for the accelerator, plus the tiling schedule.

This file has no serial-port code in it, so the exact same functions are used
by the real host driver (accel_driver.py) and by the simulation testbench
(tb/test_system.py). If the tests pass, the bytes the laptop sends are the
bytes that were tested.

See docs/protocol.md for the full description.
"""

from dataclasses import dataclass, field

import numpy as np

N = 8            # array size (8x8)
MAX_M = 256      # rows the activation/output buffers hold

CMD_PING = 0x50      # 'P'
CMD_LOAD_W = 0x57    # 'W'
CMD_LOAD_A = 0x41    # 'A'
CMD_RUN = 0x52       # 'R'
CMD_RUN_ACC = 0x55   # 'U'
CMD_READ = 0x43      # 'C'

RSP_PING = 0xA5
RSP_DONE = 0xD0
RSP_ERR = 0xEE
RSP_BAD = 0xEC       # RUN refused: the last LOAD had a bad checksum or timed out

PROTOCOL_VERSION = 2
PING_REPLY_LEN = 4
RUN_REPLY_LEN = 5
MAX_RETRIES = 5      # per output tile, before giving up


class LinkError(Exception):
    """The board's reply was wrong (bad checksum, error code, or garbage)."""


# matmul_program yields (RESYNC, 0) when it saw a bad reply: the driver must
# get back in step with the board (see resync() in accel_driver.py) and then
# send() anything back to continue.
RESYNC = None


class RetryTile(Exception):
    """Thrown into matmul_program by the driver after it has resynchronized
    with the board: redo the current output tile from its first RUN."""


def checksum(data):
    """Sum of the bytes mod 256. Catches any single corrupted byte."""
    return sum(data) & 0xFF


# ---------------------------------------------------------------------------
# Encoders / decoders
# ---------------------------------------------------------------------------

def enc_ping():
    return bytes([CMD_PING])


def dec_ping(resp):
    if len(resp) != PING_REPLY_LEN or resp[0] != RSP_PING:
        raise ValueError(f"bad PING reply: {resp.hex()}")
    return {"n": resp[1], "max_m": resp[2] + 1, "version": resp[3]}


def enc_load_w(w):
    w = np.asarray(w)
    assert w.shape == (N, N), w.shape
    body = w.astype(np.int8).tobytes()                          # row-major W[k][n]
    return bytes([CMD_LOAD_W]) + body + bytes([checksum(body)])


def enc_load_a(a):
    a = np.asarray(a)
    m = a.shape[0]
    assert a.shape[1] == N and 1 <= m <= MAX_M, a.shape
    body = bytes([m - 1]) + a.astype(np.int8).tobytes()        # row-major A[m][k]
    return bytes([CMD_LOAD_A]) + body + bytes([checksum(body)])


def enc_run(accumulate=False):
    return bytes([CMD_RUN_ACC if accumulate else CMD_RUN])


def dec_run(resp):
    if len(resp) != RUN_REPLY_LEN or resp[0] != RSP_DONE:
        raise LinkError(f"bad RUN reply: {resp.hex()}")
    return int.from_bytes(resp[1:5], "little")


def enc_read():
    return bytes([CMD_READ])


def read_len(m):
    return m * N * 4 + 1             # results + checksum byte


def dec_results(resp, m):
    if len(resp) != read_len(m):
        raise LinkError(f"expected {read_len(m)} result bytes, got {len(resp)}")
    if checksum(resp[:-1]) != resp[-1]:
        raise LinkError("result checksum mismatch")
    return np.frombuffer(resp[:-1], dtype="<i4").reshape(m, N).astype(np.int32)


# ---------------------------------------------------------------------------
# Tiled matrix multiply
# ---------------------------------------------------------------------------

@dataclass
class RunStats:
    tiles: int = 0             # RUN commands issued
    compute_cycles: int = 0    # sum of hardware cycle counts
    useful_macs: int = 0       # multiply-accumulates that touch real (unpadded) data
    issued_macs: int = 0       # MACs the array performed, padding included
    bytes_sent: int = 0
    bytes_received: int = 0
    retries: int = 0           # output tiles redone after a link error
    per_tile_cycles: list = field(default_factory=list)


def _pad_to(x, rows, cols):
    out = np.zeros((rows, cols), dtype=np.int8)
    out[: x.shape[0], : x.shape[1]] = x
    return out


def matmul_program(a, w):
    """Compute C = A @ W (int8 in, int32 out) on the accelerator.

    This is a generator so it can drive either a real serial port or a
    simulation. Each step yields (bytes_to_send, number_of_bytes_to_read),
    and the caller sends back the bytes it read. The final result is the
    generator's return value: (C, RunStats).

    Tiling:
      * K (shared dimension) is cut into N-wide slices. The first slice uses
        RUN, the rest use RUN_ACC, so the hardware adds them up.
      * The output columns are cut into N-wide slices, one weight tile each.
      * M is cut into chunks of at most MAX_M rows (the buffer size).
    Only the finished sum for each output tile is read back.

    Errors: the driver resynchronizes with the board and throws RetryTile in
    here; the current output tile is then redone from its first RUN (a
    partial RUN_ACC sum can't be trusted, so the whole tile is repeated).
    """
    a = np.asarray(a, dtype=np.int8)
    w = np.asarray(w, dtype=np.int8)
    m_total, k_total = a.shape
    k2, n_total = w.shape
    assert k_total == k2, "inner dimensions must match"

    kp = -(-k_total // N) * N
    np_ = -(-n_total // N) * N
    a_p = _pad_to(a, m_total, kp)
    w_p = _pad_to(w, kp, np_)

    c = np.zeros((m_total, np_), dtype=np.int32)
    st = RunStats()
    st.useful_macs = m_total * k_total * n_total

    for m0 in range(0, m_total, MAX_M):
        m1 = min(m0 + MAX_M, m_total)
        mb = m1 - m0
        for n0 in range(0, np_, N):
            for attempt in range(MAX_RETRIES + 1):
                try:
                    tile_stats = []
                    for ki, k0 in enumerate(range(0, kp, N)):
                        tx = (enc_load_w(w_p[k0:k0 + N, n0:n0 + N])
                              + enc_load_a(a_p[m0:m1, k0:k0 + N])
                              + enc_run(accumulate=ki > 0))
                        resp = yield tx, RUN_REPLY_LEN
                        st.bytes_sent += len(tx)
                        st.bytes_received += len(resp)
                        tile_stats.append(dec_run(resp))
                    tx = enc_read()
                    resp = yield tx, read_len(mb)
                    st.bytes_sent += len(tx)
                    st.bytes_received += len(resp)
                    c[m0:m1, n0:n0 + N] = dec_results(resp, mb)
                    break
                except (RetryTile, LinkError) as e:
                    if attempt == MAX_RETRIES:
                        raise LinkError(f"output tile failed {MAX_RETRIES + 1} times") from e
                    st.retries += 1
                    if isinstance(e, LinkError):
                        yield RESYNC, 0            # ask the driver to resync first
            for cyc in tile_stats:                 # count the attempt that worked
                st.tiles += 1
                st.compute_cycles += cyc
                st.per_tile_cycles.append((mb, cyc))
                st.issued_macs += mb * N * N

    return c[:, :n_total], st


def golden_matmul(a, w):
    """Bit-exact reference: what the hardware must return."""
    c = np.asarray(a, dtype=np.int64) @ np.asarray(w, dtype=np.int64)
    return ((c + 2**31) % 2**32 - 2**31).astype(np.int32)
