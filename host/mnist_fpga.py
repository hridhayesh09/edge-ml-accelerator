"""Run the quantized MNIST network on the accelerator.

    python mnist_fpga.py --port COM8 --num 1000                 # whole network on chip (INFER)
    python mnist_fpga.py --port COM8 --num 64 --mode matmul     # old way: laptop drives both matmuls
    python mnist_fpga.py --port sim --num 1000                  # software model, no board

Checks three things:
  1. bit-exact: the board's numbers equal NumPy's INT8 reference
       infer mode : all 10 logits of every image
       matmul mode: the int32 results of both layers
  2. accuracy: board vs. INT8 NumPy vs. the original float32 network
  3. timing: hardware compute time vs. total time including the UART
"""

import argparse
import json
import statistics
import time
from pathlib import Path

import numpy as np

from accel_driver import CLK_HZ, open_accelerator
from mnist_common import float_forward, int8_forward, load_mnist, numpy_int_matmul

MODEL = Path(__file__).resolve().parent / "mnist_int8.npz"


def run_infer(acc, x, ref_acc2, args):
    digits, logits, st = acc.infer(x, with_logits=True)
    # single-image latency: one image in, one digit out (logits not read back)
    lat = []
    for i in range(args.latency_runs):
        t0 = time.perf_counter()
        acc.infer(x[i % len(x):i % len(x) + 1])
        lat.append(time.perf_counter() - t0)
    # end-to-end throughput: the whole set again, digits only (what a user would do)
    t0 = time.perf_counter()
    acc.infer(x)
    wall = time.perf_counter() - t0
    compute_s = st["compute_time_s"]
    return {
        "mode": "infer",
        "bit_exact": bool(np.array_equal(logits, ref_acc2)),
        "pred": digits,
        "compute_time_s": compute_s,
        "compute_us_per_image": compute_s / len(x) * 1e6,
        "wall_time_s": wall,
        "wall_ms_per_image": wall / len(x) * 1e3,
        "single_image_latency_ms": statistics.median(lat) * 1e3 if lat else None,
        "batches": st["batches"],
        "retries": st["retries"],
    }


def run_matmul(acc, x, q, ref_acc1, ref_acc2):
    layer_stats = []

    def fpga_matmul(a, w):
        c, st = acc.matmul(a, w)
        layer_stats.append({"shape": [int(a.shape[0]), int(a.shape[1]), int(w.shape[1])], **st})
        print(f"  layer {len(layer_stats)}: {a.shape} x {w.shape}  "
              f"{st['tiles']} tiles, compute {st['compute_time_s'] * 1e3:.2f} ms, "
              f"wall {st['wall_time_s']:.2f} s")
        return c

    t0 = time.perf_counter()
    pred, acc1, acc2 = int8_forward(x, q, fpga_matmul)
    wall = time.perf_counter() - t0
    compute_s = sum(s["compute_time_s"] for s in layer_stats)
    return {
        "mode": "matmul",
        "bit_exact": bool(np.array_equal(acc1, ref_acc1) and np.array_equal(acc2, ref_acc2)),
        "pred": pred,
        "compute_time_s": compute_s,
        "compute_us_per_image": compute_s / len(x) * 1e6,
        "wall_time_s": wall,
        "wall_ms_per_image": wall / len(x) * 1e3,
        "layers": layer_stats,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="serial port, or 'sim'")
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--num", type=int, default=1000, help="test images to run")
    ap.add_argument("--mode", choices=["infer", "matmul"], default="infer")
    ap.add_argument("--latency-runs", type=int, default=50, help="single-image runs to time (infer mode)")
    ap.add_argument("--json", help="write results to this file")
    args = ap.parse_args()

    q = dict(np.load(MODEL))
    _, _, test_x, test_y = load_mnist()
    x, y = test_x[: args.num], test_y[: args.num]

    # Reference runs on the CPU
    float_pred = float_forward(x / 255.0, q).argmax(1)
    ref_pred, ref_acc1, ref_acc2 = int8_forward(x, q, numpy_int_matmul)

    with open_accelerator(args.port, args.baud) as acc:
        print("PING:", acc.ping())
        if args.mode == "infer":
            res = run_infer(acc, x, ref_acc2, args)
        else:
            res = run_matmul(acc, x, q, ref_acc1, ref_acc2)

    pred = res.pop("pred")
    res.update({
        "images": int(args.num),
        "accuracy_fpga": float((pred == y).mean()),
        "accuracy_int8_numpy": float((ref_pred == y).mean()),
        "accuracy_float32": float((float_pred == y).mean()),
        "uart_share_of_wall": 1 - res["compute_time_s"] / res["wall_time_s"],
        "clock_hz": CLK_HZ,
    })

    print(f"\nmode               : {res['mode']}")
    print(f"bit-exact vs NumPy : {'YES' if res['bit_exact'] else 'NO'}")
    print(f"accuracy  FPGA     : {res['accuracy_fpga']:.2%}")
    print(f"          INT8 CPU : {res['accuracy_int8_numpy']:.2%}")
    print(f"          float32  : {res['accuracy_float32']:.2%}")
    print(f"hardware compute   : {res['compute_time_s'] * 1e3:.2f} ms total, "
          f"{res['compute_us_per_image']:.1f} us/image")
    print(f"end to end (UART)  : {res['wall_time_s']:.2f} s total, {res['wall_ms_per_image']:.2f} ms/image "
          f"({res['uart_share_of_wall']:.2%} of the time is data transfer)")
    if res.get("single_image_latency_ms") is not None:
        print(f"single image       : {res['single_image_latency_ms']:.2f} ms from sending it to getting the digit")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)


if __name__ == "__main__":
    main()
