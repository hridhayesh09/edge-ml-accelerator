"""Random matrix multiplies on the accelerator, checked against NumPy.

    python demo_matmul.py --port COM5                 # Windows
    python demo_matmul.py --port /dev/ttyUSB0         # Linux / Mac
    python demo_matmul.py --port sim                  # no board: software model

Prints correctness and performance for a few matrix sizes.
"""

import argparse
import json

import numpy as np

import accel_proto as P
from accel_driver import open_accelerator

SHAPES = [(8, 8, 8), (64, 64, 64), (256, 64, 64), (256, 256, 64)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="serial port, or 'sim'")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--trials", type=int, default=3, help="random matrices per shape")
    ap.add_argument("--json", help="write results to this file")
    args = ap.parse_args()

    rng = np.random.default_rng(0)
    results = []
    with open_accelerator(args.port, args.baud) as acc:
        print("PING:", acc.ping())
        print(f"{'shape (M,K,N)':>16} {'ok':>4} {'tiles':>6} {'compute us':>11} {'GOPS':>6} "
              f"{'util':>6} {'wall s':>8} {'compute/wall':>13}")
        for (m, k, n) in SHAPES:
            for t in range(args.trials):
                a = rng.integers(-128, 128, (m, k)).astype(np.int8)
                w = rng.integers(-128, 128, (k, n)).astype(np.int8)
                c, st = acc.matmul(a, w)
                ok = np.array_equal(c, P.golden_matmul(a, w))
                results.append({"shape": [m, k, n], "correct": bool(ok), **st})
                print(f"{str((m, k, n)):>16} {'yes' if ok else 'NO':>4} {st['tiles']:>6} "
                      f"{st['compute_time_s'] * 1e6:>11.1f} {st['gops_compute']:>6.2f} "
                      f"{st['pe_utilization']:>6.1%} {st['wall_time_s']:>8.3f} "
                      f"{st['compute_share_of_wall']:>13.4%}")
                if not ok:
                    raise SystemExit("MISMATCH: hardware result differs from NumPy")

    print(f"\nall {len(results)} results matched NumPy bit for bit")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
