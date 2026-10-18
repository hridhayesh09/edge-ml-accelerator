# Host protocol

The board talks over a plain UART: **2,000,000 baud, 8 data bits, no parity, 1 stop bit (8N1)**.
At 50 MHz that is exactly 25 clocks per bit, so the FPGA side has no baud-rate error.
Every command is one byte, followed by its data. Multi-byte numbers are little-endian.
Commands are ASCII letters so they are easy to spot in a serial terminal.

| Command | Byte | Data sent after it | Board replies with |
| --- | --- | --- | --- |
| PING | `P` 0x50 | none | 4 bytes: `A5`, N (16 on the board), MAX_M-1 (255), version (3). The host sizes its tiles from N |
| LOAD_W | `W` 0x57 | 64 bytes: int8 weights, row-major `W[k][n]`, then 1 checksum byte | nothing |
| LOAD_A | `A` 0x41 | 1 byte M-1, then M x 8 bytes: int8 activations, row-major `A[m][k]`, then 1 checksum byte | nothing |
| RUN | `R` 0x52 | none | 5 bytes: `D0` + uint32 cycle count, or `EC 00 00 00 00` if refused |
| RUN_ACC | `U` 0x55 | none | 5 bytes: `D0` + uint32 cycle count, or `EC 00 00 00 00` if refused |
| READ_C | `C` 0x43 | none | M x 8 int32 results, row-major `C[m][n]`, 4 bytes each, then 1 checksum byte |
| INFER | `I` 0x49 | 1 byte B-1, then B x 784 raw pixels (uint8, 0..255), then 1 checksum byte. B = 1..32 | `D1`, B digits (0..9), uint32 cycle count, checksum. `EC` instead of `D1` (digits and count zero) if the checksum was wrong |
| READ_LOGITS | `L` 0x4C | none | B x 10 int32 logits of the last INFER, row-major, then 1 checksum byte |
| anything else | | | 1 byte: `EE` |

- **RUN** computes `C = A x W` and overwrites the output buffer.
- **RUN_ACC** computes `C = C + A x W`. This is how a long K dimension is split into 8-wide tiles
  without sending partial sums back to the laptop.
- **READ_C** returns as many rows as the last LOAD_A had.
- M can be 1 to 256 (the size of the on-chip buffers).
- The cycle count is measured in hardware: it starts when RUN is decoded and stops when the last
  result row is written. For M rows it is always **M + 16** (M cycles of streaming plus a 15-cycle
  pipeline fill/drain and 1 cycle for the RAM read). At 50 MHz that is 20 ns per cycle.

## INFER: the whole network on the FPGA (version 3)

INFER runs both layers of the MNIST network on chip. The weights are built into the bitstream
(`rtl/model/*.hex`, written by `host/export_model.py`), so the laptop only sends images and gets
digits back: 784 bytes in and 1 byte out per image, instead of about 2 KB per weight tile.

What the board does for a batch of B images:

1. Quantize each pixel with a 256-entry lookup table (0..255 -> 0..127) and store the batch.
2. Layer 1, for each N-wide slice of the 64 hidden units: for each of the 784/N N-wide slices
   of the inputs, load the N x N weight tile from ROM (one PE row per clock) and stream all B
   images' slice through the array, accumulating in the output buffer. (N = 16 on the board:
   4 x 49 = 196 tiles.)
3. Requantize each hidden value: `clip((acc + b1) * 9710 + 2^23 >> 24, 0, 127)` (the clip at 0
   is the ReLU). This is integer math, so it matches the NumPy reference bit for bit.
4. Layer 2 the same way from the hidden values, then `logit = acc + b2`.
5. Argmax over the 10 logits gives the digit.

The cycle count is exact (checked in the tests): each weight tile takes `3N + B + 2` cycles,
each finished output slice `B * (N + 4)`, and the argmax `11 * B`. On the 16x16 board a batch
of 32 takes 19,952 cycles = 0.40 ms at 50 MHz (12.5 us per image).

## Link protection (version 2)

A serial link can occasionally lose or corrupt a byte. Without protection, one bad byte knocks the
board's command decoder out of step and the run dies (this happened once on hardware, see
[bugs.md](bugs.md)). Version 2 detects and recovers from that:

- **Checksum:** the sum of the data bytes mod 256. For LOAD_A it covers the M-1 byte and the
  activations; for READ_C it covers the result bytes. Any single corrupted byte changes it.
- **Refused RUN:** if a LOAD's checksum is wrong, the next RUN/RUN_ACC replies `EC 00 00 00 00`
  and does nothing, so the output buffer is untouched.
- **Stall timeout:** if a LOAD goes quiet for 50 ms in the middle (a byte was lost), the board
  abandons it, marks the data bad, and goes back to idle. It can never get stuck waiting.
- **Resync:** PING clears the "data is bad" flag. After any error the host waits until the line
  is quiet, sends PING until it gets a proper `A5` reply, and then redoes the whole output tile
  from its first RUN (a partly accumulated RUN_ACC sum can't be trusted). Up to 5 retries per tile.

The simulation tests inject a corrupted weight, a dropped activation byte, and a corrupted
command byte in the middle of a tiled matmul, and check that the host recovers and the answer is
still exact.

## Example: one 8x8 tile

```
laptop -> board:  57 <64 weight bytes> <sum>    LOAD_W
                  41 01 <16 activation bytes> <sum>   LOAD_A, M = 2
                  52                            RUN
board -> laptop:  D0 12 00 00 00                done, 18 cycles (2 + 16)
laptop -> board:  43                            READ_C
board -> laptop:  <64 bytes = 2 rows x 8 int32> <sum>
```

## Tiling a big matrix product

`host/accel_proto.py: matmul_program()` does this automatically:

```
for each block of up to 256 rows of A:
    for each 8-wide slice of output columns (n):
        for each 8-wide slice of the shared dimension (k):
            LOAD_W  W[k-slice, n-slice]
            LOAD_A  A[rows, k-slice]
            RUN (first k slice) or RUN_ACC (the rest)
        READ_C  -> C[rows, n-slice]
```

Matrices whose sizes are not multiples of 8 are zero-padded, which does not change the answer.
