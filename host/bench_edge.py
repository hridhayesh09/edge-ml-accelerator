"""Baseline benchmark for the Raspberry Pi, Jetson, or a laptop.

Runs the SAME two INT8 matrix multiplies as the FPGA (the MNIST layers) on
the CPU with NumPy, and on the GPU with PyTorch if it is installed and a GPU
is present. Reports latency and throughput for the compute only, so it lines
up with the FPGA's "hardware compute" number.

    python bench_edge.py --batch 64
    python bench_edge.py --batch 64 --json pi_results.json

Power is measured outside this script while it runs in --loop mode:
  * Jetson: run `tegrastats` (or `sudo tegrastats`) in another terminal and
            read the VDD_IN / POM_5V_IN number
  * Raspberry Pi: use a USB-C power meter between the supply and the Pi
  * FPGA: Quartus Power Analyzer estimate (see docs/bringup.md)
Then perf per watt = GOPS / watts.
"""

import argparse
import json
import platform
import time
from pathlib import Path

import numpy as np

MODEL = Path(__file__).resolve().parent / "mnist_int8.npz"


def time_fn(fn, repeat):
    fn()  # warm up
    times = []
    for _ in range(repeat):
        t0 = time.perf_counter()
        fn()
        times.append(time.perf_counter() - t0)
    return float(np.median(times))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--repeat", type=int, default=50)
    ap.add_argument("--loop", type=float, default=0, help="keep running for this many seconds (for power readings)")
    ap.add_argument("--json")
    args = ap.parse_args()

    q = np.load(MODEL)
    rng = np.random.default_rng(0)
    x = rng.integers(0, 128, (args.batch, 784)).astype(np.int8)
    h = rng.integers(0, 128, (args.batch, 64)).astype(np.int8)
    W1, W2 = q["W1_q"], q["W2_q"]
    ops = 2 * args.batch * (784 * 64 + 64 * 10)

    results = {"platform": platform.platform(), "machine": platform.machine(),
               "batch": args.batch, "ops_per_batch": ops, "backends": {}}

    # NumPy int32 (exact integer math, like the FPGA)
    x32, h32, W1_32, W2_32 = (m.astype(np.int32) for m in (x, h, W1, W2))
    t = time_fn(lambda: (x32 @ W1_32, h32 @ W2_32), args.repeat)
    results["backends"]["numpy_int32"] = {"latency_ms": t * 1e3, "gops": ops / t / 1e9}

    # NumPy float32 (uses the optimized BLAS library; usually much faster)
    xf, hf, W1f, W2f = (m.astype(np.float32) for m in (x, h, W1, W2))
    t = time_fn(lambda: (xf @ W1f, hf @ W2f), args.repeat)
    results["backends"]["numpy_float32"] = {"latency_ms": t * 1e3, "gops": ops / t / 1e9}

    try:
        import torch

        dev = "cuda" if torch.cuda.is_available() else "cpu"
        tx, th = torch.tensor(xf, device=dev), torch.tensor(hf, device=dev)
        tw1, tw2 = torch.tensor(W1f, device=dev), torch.tensor(W2f, device=dev)

        def run():
            tx @ tw1
            th @ tw2
            if dev == "cuda":
                torch.cuda.synchronize()

        t = time_fn(run, args.repeat)
        results["backends"][f"torch_{dev}_float32"] = {"latency_ms": t * 1e3, "gops": ops / t / 1e9}
        if dev == "cuda":
            tx16, th16, tw1h, tw2h = tx.half(), th.half(), tw1.half(), tw2.half()

            def run16():
                tx16 @ tw1h
                th16 @ tw2h
                torch.cuda.synchronize()

            t = time_fn(run16, args.repeat)
            results["backends"]["torch_cuda_float16"] = {"latency_ms": t * 1e3, "gops": ops / t / 1e9}
    except ImportError:
        pass

    print(f"{results['platform']}  batch={args.batch}  ({ops / 1e6:.1f} M ops per batch)")
    for name, r in results["backends"].items():
        print(f"  {name:22s} {r['latency_ms']:9.3f} ms   {r['gops']:8.2f} GOPS")

    if args.loop:
        print(f"looping for {args.loop:.0f} s, read the power meter now...")
        end = time.time() + args.loop
        while time.time() < end:
            x32 @ W1_32
            h32 @ W2_32

    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
