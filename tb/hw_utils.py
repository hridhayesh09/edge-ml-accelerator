"""Small helpers shared by the testbenches: packing int8/int32 lanes into the
flat bit vectors the RTL uses, and the NumPy golden model."""

import numpy as np


def to_signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def pack(values, bits):
    """Pack a list of signed ints into one integer, lane 0 in the low bits."""
    word = 0
    for i, v in enumerate(values):
        word |= (int(v) & ((1 << bits) - 1)) << (bits * i)
    return word


def unpack(word, bits, count):
    """Inverse of pack: split an integer into `count` signed lanes."""
    word = int(word)
    return [to_signed(word >> (bits * i), bits) for i in range(count)]


def golden_matmul(a, w):
    """Bit-exact model of the hardware: int8 x int8, int32 wrap-around sums."""
    c = a.astype(np.int64) @ w.astype(np.int64)
    return ((c + 2**31) % 2**32 - 2**31).astype(np.int32)


def rand_int8(rng, shape, mode="uniform"):
    """Random int8 test data. Modes stress different corners of the datapath."""
    if mode == "uniform":
        return rng.integers(-128, 128, size=shape, dtype=np.int64).astype(np.int8)
    if mode == "extreme":
        return rng.choice(np.array([-128, -127, -1, 0, 1, 126, 127]), size=shape).astype(np.int8)
    if mode == "sparse":
        x = rng.integers(-128, 128, size=shape, dtype=np.int64)
        x[rng.random(shape) < 0.7] = 0
        return x.astype(np.int8)
    if mode == "min":
        return np.full(shape, -128, dtype=np.int8)
    if mode == "max":
        return np.full(shape, 127, dtype=np.int8)
    raise ValueError(mode)
