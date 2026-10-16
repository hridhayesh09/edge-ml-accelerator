"""MNIST data loading and the INT8 inference pipeline.

The network is a small multilayer perceptron:  784 -> 64 -> 10
  layer 1:  h      = ReLU(x @ W1 + b1)
  layer 2:  logits = h @ W2 + b2

INT8 version (what runs on the accelerator):
  x_q   = round(x * 127)                       pixels in [0, 1] -> int8 [0, 127]
  acc1  = x_q @ W1_q + b1_q                    int32   <- matmul on the FPGA
  h_q   = clip(round(acc1 * requant1), 0, 127) int8    (ReLU folded into the clip)
  acc2  = h_q @ W2_q + b2_q                    int32   <- matmul on the FPGA
  pred  = argmax(acc2)

All weights use symmetric per-tensor scales (int8 range -127..127).
The only work on the CPU is adding biases, the requantize step, and argmax.
"""

import gzip
import urllib.request
from pathlib import Path

import numpy as np

DATA_DIR = Path(__file__).resolve().parent / "data"
MIRRORS = [
    "https://raw.githubusercontent.com/fgnt/mnist/master/",
    "https://ossci-datasets.s3.amazonaws.com/mnist/",
    "https://storage.googleapis.com/cvdf-datasets/mnist/",
]
FILES = {
    "train_x": "train-images-idx3-ubyte.gz",
    "train_y": "train-labels-idx1-ubyte.gz",
    "test_x": "t10k-images-idx3-ubyte.gz",
    "test_y": "t10k-labels-idx1-ubyte.gz",
}


def _download(name):
    DATA_DIR.mkdir(exist_ok=True)
    path = DATA_DIR / name
    if path.exists():
        return path
    last = None
    for base in MIRRORS:
        try:
            print(f"downloading {base}{name}")
            urllib.request.urlretrieve(base + name, path)
            return path
        except Exception as e:  # try the next mirror
            last = e
            path.unlink(missing_ok=True)
    raise RuntimeError(f"could not download {name}: {last}")


def _read_idx(path):
    with gzip.open(path, "rb") as f:
        data = f.read()
    ndim = data[3]
    dims = [int.from_bytes(data[4 + 4 * i: 8 + 4 * i], "big") for i in range(ndim)]
    return np.frombuffer(data, dtype=np.uint8, offset=4 + 4 * ndim).reshape(dims)


def load_mnist():
    """Returns (train_x, train_y, test_x, test_y). Images are uint8 (n, 784)."""
    arrays = {k: _read_idx(_download(v)) for k, v in FILES.items()}
    return (arrays["train_x"].reshape(-1, 784), arrays["train_y"].astype(np.int64),
            arrays["test_x"].reshape(-1, 784), arrays["test_y"].astype(np.int64))


def quantize_input(images_u8):
    """uint8 pixels 0..255 -> int8 0..127 (scale 1/127 on the [0,1] range)."""
    x = images_u8.astype(np.float32) / 255.0
    return np.round(x * 127).astype(np.int8)


def float_forward(x01, model):
    h = np.maximum(x01 @ model["W1"] + model["b1"], 0)
    return h @ model["W2"] + model["b2"]


def int8_forward(images_u8, q, matmul):
    """Run the INT8 network. `matmul(a, w)` does the int8 x int8 -> int32 work
    (NumPy reference or the accelerator). Returns (predictions, acc1, acc2)."""
    x_q = quantize_input(images_u8)
    acc1 = matmul(x_q, q["W1_q"]).astype(np.int64) + q["b1_q"]
    h_q = np.clip(np.round(acc1 * q["requant1"]), 0, 127).astype(np.int8)
    acc2 = matmul(h_q, q["W2_q"]).astype(np.int64) + q["b2_q"]
    return acc2.argmax(axis=1), acc1, acc2


def numpy_int_matmul(a, w):
    """Bit-exact NumPy version of what the accelerator computes."""
    c = a.astype(np.int64) @ w.astype(np.int64)
    return ((c + 2**31) % 2**32 - 2**31).astype(np.int32)
