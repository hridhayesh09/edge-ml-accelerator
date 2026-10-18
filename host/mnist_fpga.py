"""Run the quantized MNIST network with both matmuls on the accelerator.

    python mnist_fpga.py --port COM5 --num 64
    python mnist_fpga.py --port sim --num 1000      # software model, no board

Checks three things:
  1. bit-exact: the board's int32 results equal NumPy's for every layer
  2. accuracy: board vs. INT8 NumPy vs. the original float32 network
  3. timing: hardware compute time vs. total time including the UART
"""

import argparse
import json
import time
from pathlib import Path

import numpy as np

from accel_driver import open_accelerator
from mnist_common import float_forward, int8_forward, load_mnist, numpy_int_matmul

MODEL = Path(__file__).resolve().parent / "mnist_int8.npz"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="serial port, or 'sim'")
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--num", type=int, default=64, help="test images to run")
    ap.add_argument("--json", help="write results to this file")
    args = ap.parse_args()

    q = dict(np.load(MODEL))
    _, _, test_x, test_y = load_mnist()
    x, y = test_x[: args.num], test_y[: args.num]

    # Reference runs on the CPU
    float_pred = float_forward(x / 255.0, q).argmax(1)
    ref_pred, ref_acc1, ref_acc2 = int8_forward(x, q, numpy_int_matmul)

    # Accelerator run: record per-layer stats
    layer_stats = []
    with open_accelerator(args.port, args.baud) as acc:
        print("PING:", acc.ping())

        def fpga_matmul(a, w):
            c, st = acc.matmul(a, w)
            layer_stats.append({"shape": [int(a.shape[0]), int(a.shape[1]), int(w.shape[1])], **st})
            print(f"  layer {len(layer_stats)}: {a.shape} x {w.shape}  "
                  f"{st['tiles']} tiles, compute {st['compute_time_s'] * 1e3:.2f} ms, "
                  f"wall {st['wall_time_s']:.2f} s")
            return c

        t0 = time.perf_counter()
        hw_pred, hw_acc1, hw_acc2 = int8_forward(x, q, fpga_matmul)
        wall = time.perf_counter() - t0

    bit_exact = np.array_equal(hw_acc1, ref_acc1) and np.array_equal(hw_acc2, ref_acc2)
    compute_s = sum(s["compute_time_s"] for s in layer_stats)
    res = {
        "images": int(args.num),
        "bit_exact": bool(bit_exact),
        "accuracy_fpga": float((hw_pred == y).mean()),
        "accuracy_int8_numpy": float((ref_pred == y).mean()),
        "accuracy_float32": float((float_pred == y).mean()),
        "compute_time_s": compute_s,
        "compute_us_per_image": compute_s / args.num * 1e6,
        "wall_time_s": wall,
        "wall_ms_per_image": wall / args.num * 1e3,
        "uart_share_of_wall": 1 - compute_s / wall if wall else 0.0,
        "layers": layer_stats,
    }

    print(f"\nbit-exact vs NumPy : {'YES' if bit_exact else 'NO'}")
    print(f"accuracy  FPGA     : {res['accuracy_fpga']:.2%}")
    print(f"          INT8 CPU : {res['accuracy_int8_numpy']:.2%}")
    print(f"          float32  : {res['accuracy_float32']:.2%}")
    print(f"hardware compute   : {compute_s * 1e3:.2f} ms total, {res['compute_us_per_image']:.1f} us/image")
    print(f"end to end (UART)  : {wall:.2f} s total, {res['wall_ms_per_image']:.1f} ms/image "
          f"({res['uart_share_of_wall']:.2%} of the time is data transfer)")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)


if __name__ == "__main__":
    main()
