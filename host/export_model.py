"""Write the INT8 MNIST model as memory-init files for the FPGA.

The weights are built into the bitstream (Quartus and Icarus both load them
with $readmemh at start-up), so the board can classify digits without the
laptop sending any weights.

    python export_model.py            # writes rtl/model/*.hex for N = 8 and N = 16

Files (one hex word per line, lane 0 in the low byte):
  w1_n{N}.hex  layer-1 weights. Word (nt*784 + k) holds W1[k][nt*N .. nt*N+N-1]:
               one row of an N x N weight tile, loaded into the array in one clock.
  w2_n{N}.hex  layer-2 weights, same layout, output columns padded from 10 to a
               multiple of N with zeros. Word (nt*64 + k).
  b1.hex       64 layer-1 biases, 32-bit two's complement
  b2.hex       16 layer-2 biases (10 real + 6 zero)
  qlut.hex     256-entry input quantizer: pixel 0..255 -> round(p * 127 / 255)
"""

from pathlib import Path

import numpy as np

from mnist_common import quantize_input

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "rtl" / "model"
MODEL = HERE / "mnist_int8.npz"

REQ_MULT = 9710      # must match accel_core.v parameters REQ_MULT / REQ_SHIFT
REQ_SHIFT = 24


def tile_rows(w, n):
    """(K, C) int8 matrix -> list of N-byte words, ordered (column tile, k)."""
    k_total, c_total = w.shape
    nt = -(-c_total // n)
    wp = np.zeros((k_total, nt * n), dtype=np.int8)
    wp[:, :c_total] = w
    words = []
    for t in range(nt):
        for k in range(k_total):
            lanes = wp[k, t * n:(t + 1) * n].view(np.uint8)
            words.append("".join(f"{b:02x}" for b in lanes[::-1]))   # lane 0 = low byte
    return words


def write(name, lines):
    (OUT / name).write_text("\n".join(lines) + "\n")


def main():
    q = dict(np.load(MODEL))
    assert int(q["requant1_mult"]) == REQ_MULT and int(q["requant1_shift"]) == REQ_SHIFT, \
        "model requant constants changed: update REQ_MULT/REQ_SHIFT here and in accel_core.v"
    OUT.mkdir(parents=True, exist_ok=True)
    for n in (8, 16):
        write(f"w1_n{n}.hex", tile_rows(q["W1_q"], n))
        write(f"w2_n{n}.hex", tile_rows(q["W2_q"], n))
    b2 = np.zeros(16, dtype=np.int64)
    b2[:10] = q["b2_q"]
    write("b1.hex", [f"{int(v) & 0xFFFFFFFF:08x}" for v in q["b1_q"]])
    write("b2.hex", [f"{int(v) & 0xFFFFFFFF:08x}" for v in b2])
    lut = quantize_input(np.arange(256, dtype=np.uint8)).view(np.uint8)
    write("qlut.hex", [f"{int(v):02x}" for v in lut])
    print(f"wrote {sorted(p.name for p in OUT.glob('*.hex'))} to {OUT}")


if __name__ == "__main__":
    main()
