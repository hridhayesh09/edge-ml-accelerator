"""Byte protocol for the accelerator, plus the tiling schedule.

This file has no serial-port code in it, so the exact same functions are used
by the real host driver (accel_driver.py) and by the simulation testbench
(tb/test_system.py). If the tests pass, the bytes the laptop sends are the
bytes that were tested.

See docs/protocol.md for the full description.
"""

from dataclasses import dataclass, field

import numpy as np

N = 16           # array size (N x N). The board reports it in PING; set_array_size() updates it.
MAX_M = 256      # rows the activation/output buffers hold


def set_array_size(n):
    """Use an N x N array (the board's PING reply says which; the simulation
    testbenches build both 8x8 and 16x16)."""
    global N
    N = int(n)

CMD_PING = 0x50      # 'P'
CMD_LOAD_W = 0x57    # 'W'
CMD_LOAD_A = 0x41    # 'A'
CMD_RUN = 0x52       # 'R'
CMD_RUN_ACC = 0x55   # 'U'
CMD_READ = 0x43      # 'C'
CMD_INFER = 0x49     # 'I'  whole MNIST network on chip
CMD_LOGITS = 0x4C    # 'L'  read the last INFER's logits

RSP_PING = 0xA5
RSP_DONE = 0xD0
RSP_ERR = 0xEE
RSP_BAD = 0xEC       # RUN refused: the last LOAD had a bad checksum or timed out
RSP_INFER = 0xD1

PROTOCOL_VERSION = 3
MAX_IMG = 32         # images per INFER batch (on-chip image buffer; block RAM limits it at 16x16)
IN_PIX = 784         # MNIST: 28 x 28 pixels
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


def enc_infer(images_u8):
    """INFER: B raw MNIST images (uint8, B x 784). The board quantizes them."""
    images_u8 = np.asarray(images_u8, dtype=np.uint8)
    b = images_u8.shape[0]
    assert images_u8.shape[1] == IN_PIX and 1 <= b <= MAX_IMG, images_u8.shape
    body = bytes([b - 1]) + images_u8.tobytes()
    return bytes([CMD_INFER]) + body + bytes([checksum(body)])


def infer_reply_len(b):
    return 1 + b + 4 + 1             # status, digits, cycle count, checksum


def dec_infer(resp, b):
    if len(resp) != infer_reply_len(b) or checksum(resp[:-1]) != resp[-1]:
        raise LinkError(f"bad INFER reply: {resp[:8].hex()}...")
    if resp[0] != RSP_INFER:
        raise LinkError(f"INFER refused (status 0x{resp[0]:02X})")
    digits = np.frombuffer(resp[1:1 + b], dtype=np.uint8).astype(np.int64)
    cycles = int.from_bytes(resp[1 + b:5 + b], "little")
    return digits, cycles


def enc_read_logits():
    return bytes([CMD_LOGITS])


def logits_len(b):
    return b * 10 * 4 + 1


def dec_logits(resp, b):
    if len(resp) != logits_len(b) or checksum(resp[:-1]) != resp[-1]:
        raise LinkError("bad READ_LOGITS reply")
    return np.frombuffer(resp[:-1], dtype="<i4").reshape(b, 10).astype(np.int64)


def infer_cycles(b, n=None):
    """Exact INFER cycle count, from the controller's state machine:
    each weight tile takes 1 (setup) + N+1 (load rows) + B (feed) + 2N (drain),
    each finished output slice B*(N+4) for post-processing (read, latch, N
    lanes, 2 to empty the pipeline), argmax 11 per image."""
    n = n or N
    kt1, nt1, kt2, nt2 = IN_PIX // n, 64 // n, 64 // n, -(-10 // n)
    tile = 3 * n + b + 2
    post = b * (n + 4)
    return nt1 * (kt1 * tile + post) + nt2 * (kt2 * tile + post) + 11 * b


def infer_program(images_u8, with_logits=False):
    """Classify any number of images with the on-chip network, in batches of
    up to MAX_IMG. Same generator protocol (and retry rules) as matmul_program.
    Returns (digits, logits or None, stats dict)."""
    images_u8 = np.asarray(images_u8, dtype=np.uint8)
    total = images_u8.shape[0]
    digits = np.zeros(total, dtype=np.int64)
    logits = np.zeros((total, 10), dtype=np.int64) if with_logits else None
    st = {"batches": 0, "compute_cycles": 0, "bytes_sent": 0, "bytes_received": 0, "retries": 0}
    for i0 in range(0, total, MAX_IMG):
        batch = images_u8[i0:i0 + MAX_IMG]
        b = batch.shape[0]
        for attempt in range(MAX_RETRIES + 1):
            try:
                tx = enc_infer(batch)
                resp = yield tx, infer_reply_len(b)
                st["bytes_sent"] += len(tx)
                st["bytes_received"] += len(resp)
                d, cyc = dec_infer(resp, b)
                if with_logits:
                    resp = yield enc_read_logits(), logits_len(b)
                    st["bytes_sent"] += 1
                    st["bytes_received"] += len(resp)
                    logits[i0:i0 + b] = dec_logits(resp, b)
                digits[i0:i0 + b] = d
                st["batches"] += 1
                st["compute_cycles"] += cyc
                break
            except (RetryTile, LinkError) as e:
                if attempt == MAX_RETRIES:
                    raise LinkError(f"INFER batch failed {MAX_RETRIES + 1} times") from e
                st["retries"] += 1
                if isinstance(e, LinkError):
                    yield RESYNC, 0
    return digits, logits, st


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
