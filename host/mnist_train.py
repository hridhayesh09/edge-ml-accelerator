"""Train the 784-64-10 MNIST network in NumPy, then quantize it to INT8.

    python mnist_train.py            # writes mnist_int8.npz next to this file

Plain NumPy so it runs anywhere (laptop, Raspberry Pi, Jetson) with no
framework install. Takes about a minute on a laptop.
"""

import argparse
from pathlib import Path

import numpy as np

from mnist_common import float_forward, int8_forward, load_mnist, numpy_int_matmul, quantize_input

OUT = Path(__file__).resolve().parent / "mnist_int8.npz"


def train(train_x, train_y, epochs=10, hidden=64, lr=0.05, batch=64, seed=0):
    rng = np.random.default_rng(seed)
    x_all = train_x.astype(np.float32) / 255.0
    n_in, n_out = 784, 10
    W1 = rng.normal(0, np.sqrt(2 / n_in), (n_in, hidden)).astype(np.float32)
    b1 = np.zeros(hidden, np.float32)
    W2 = rng.normal(0, np.sqrt(2 / hidden), (hidden, n_out)).astype(np.float32)
    b2 = np.zeros(n_out, np.float32)
    vel = [np.zeros_like(p) for p in (W1, b1, W2, b2)]
    mom = 0.9

    for ep in range(epochs):
        order = rng.permutation(len(x_all))
        step_lr = lr * (0.5 ** (ep // 4))
        for s in range(0, len(order), batch):
            idx = order[s:s + batch]
            x, y = x_all[idx], train_y[idx]
            # forward
            z1 = x @ W1 + b1
            h = np.maximum(z1, 0)
            logits = h @ W2 + b2
            logits -= logits.max(axis=1, keepdims=True)
            p = np.exp(logits)
            p /= p.sum(axis=1, keepdims=True)
            # backward (softmax cross-entropy)
            g = p
            g[np.arange(len(y)), y] -= 1
            g /= len(y)
            gW2 = h.T @ g
            gb2 = g.sum(0)
            gh = g @ W2.T
            gh[z1 <= 0] = 0
            gW1 = x.T @ gh
            gb1 = gh.sum(0)
            for i, (param, grad) in enumerate(zip((W1, b1, W2, b2), (gW1, gb1, gW2, gb2))):
                vel[i] = mom * vel[i] - step_lr * grad
                param += vel[i]
        print(f"epoch {ep + 1}/{epochs} done")
    return {"W1": W1, "b1": b1, "W2": W2, "b2": b2}


def quantize(model, calib_x_u8):
    s_x = 1.0 / 127.0
    s_w1 = np.abs(model["W1"]).max() / 127.0
    s_w2 = np.abs(model["W2"]).max() / 127.0
    W1_q = np.clip(np.round(model["W1"] / s_w1), -127, 127).astype(np.int8)
    W2_q = np.clip(np.round(model["W2"] / s_w2), -127, 127).astype(np.int8)
    b1_q = np.round(model["b1"] / (s_x * s_w1)).astype(np.int64)

    # Calibrate the hidden-layer scale on training images: pick the scale so
    # the 99.99th percentile of hidden activations maps to 127.
    acc1 = numpy_int_matmul(quantize_input(calib_x_u8), W1_q).astype(np.int64) + b1_q
    h_real = np.maximum(acc1 * (s_x * s_w1), 0)
    s_h = np.percentile(h_real, 99.99) / 127.0
    b2_q = np.round(model["b2"] / (s_h * s_w2)).astype(np.int64)

    return {
        "W1_q": W1_q, "b1_q": b1_q, "W2_q": W2_q, "b2_q": b2_q,
        "requant1": np.float64(s_x * s_w1 / s_h),
        "s_x": s_x, "s_w1": s_w1, "s_w2": s_w2, "s_h": s_h,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=10)
    args = ap.parse_args()

    train_x, train_y, test_x, test_y = load_mnist()
    model = train(train_x, train_y, epochs=args.epochs)
    q = quantize(model, train_x[:5000])

    float_acc = (float_forward(test_x / 255.0, model).argmax(1) == test_y).mean()
    pred, _, _ = int8_forward(test_x, q, numpy_int_matmul)
    int8_acc = (pred == test_y).mean()
    print(f"test accuracy  float32: {float_acc:.2%}   int8: {int8_acc:.2%}")

    np.savez(OUT, **q, **{k: v for k, v in model.items()},
             float_acc=float_acc, int8_acc=int8_acc)
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
