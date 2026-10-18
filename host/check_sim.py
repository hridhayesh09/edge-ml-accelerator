"""Host-software checks that need no board and no simulator (run in CI).

  * random matmuls through the software model of the board, bit-exact
  * the same with ~2% of transfers corrupted, to exercise checksum + retry
  * the INT8 MNIST pipeline on the model vs. the NumPy reference

    python host/check_sim.py
"""

import sys

import numpy as np

import accel_proto as P
from accel_driver import open_accelerator
from mnist_common import int8_forward, numpy_int_matmul

SHAPES = [(1, 1, 1), (8, 8, 8), (5, 17, 9), (64, 64, 64), (300, 40, 20), (256, 256, 64)]


def check_matmuls(port):
    rng = np.random.default_rng(0)
    acc = open_accelerator(port)
    retries = 0
    for m, k, n in SHAPES:
        a = rng.integers(-128, 128, (m, k)).astype(np.int8)
        w = rng.integers(-128, 128, (k, n)).astype(np.int8)
        c, st = acc.matmul(a, w)
        assert np.array_equal(c, P.golden_matmul(a, w)), f"{port}: mismatch for {(m, k, n)}"
        retries += st["retries"]
    return retries


def check_mnist():
    q = dict(np.load(__file__.replace("check_sim.py", "mnist_int8.npz")))
    rng = np.random.default_rng(1)
    x = rng.integers(0, 256, (40, 784)).astype(np.uint8)   # random "images": no dataset download
    acc = open_accelerator("sim")
    hw = int8_forward(x, q, lambda a, w: acc.matmul(a, w)[0])
    ref = int8_forward(x, q, numpy_int_matmul)
    for got, want in zip(hw, ref):
        assert np.array_equal(got, want), "MNIST pipeline differs from NumPy"


def check_infer():
    q = dict(np.load(__file__.replace("check_sim.py", "mnist_int8.npz")))
    x = np.random.default_rng(2).integers(0, 256, (130, 784)).astype(np.uint8)   # 3 batches
    ref_pred, _, ref_logits = int8_forward(x, q, numpy_int_matmul)
    for port in ("sim", "sim-faulty:0.3"):
        digits, logits, _ = open_accelerator(port).infer(x, with_logits=True)
        assert np.array_equal(digits, ref_pred) and np.array_equal(logits, ref_logits), port
    assert P.infer_cycles(64, n=8) == 80384


def main():
    print("matmuls on the model:", "ok", f"(retries: {check_matmuls('sim')})")
    r = check_matmuls("sim-faulty:0.02")
    print("matmuls with 2% corrupted transfers:", "ok", f"(recovered {r} errors)")
    assert r > 0, "fault injection never triggered"
    check_mnist()
    print("MNIST pipeline on the model: ok")
    check_infer()
    print("INFER (whole network) on the model, with fault injection: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
