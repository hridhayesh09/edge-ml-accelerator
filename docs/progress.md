# Progress log

What changed at each step and what it did to the numbers. All numbers are from real runs; raw
files are in [results/](../results/).

| Step | What changed | Key result |
| --- | --- | --- |
| 1. Simulation | 8x8 systolic array, UART link, MNIST network, cocotb tests | 26 tests passing, bit-exact with NumPy |
| 2. First hardware | Quartus build, board bring-up | 85.08 MHz Fmax, 7% of logic; MNIST bit-exact on the board at **665 ms/image** |
| 3. Link protection | checksums, stall timeout, host resync + retry | link errors recovered automatically |
| 4. Faster link | 115200 -> 2,000,000 baud | **42 ms/image** (16x faster) |
| 5. CI | GitHub Actions runs every test on each push | green badge on the README |
| 6. Whole network on the FPGA | weights in on-chip ROM, requantize/ReLU/argmax in hardware | **3.95 ms/image**, 97.67% on all 10,000 test images, bit-exact |

## 1. Simulation (before the board arrived)

- Weight-stationary 8x8 INT8 systolic array, UART host link, command controller with
  accumulate-across-tiles (RUN_ACC).
- 784-64-10 MNIST network trained in NumPy and quantized to INT8: float32 97.68%, INT8 97.67%
  on the 10,000 test images.
- 26 cocotb tests in 6 suites; 1,100+ random matrix products checked bit-for-bit.

## 2. First hardware run

- Quartus Prime Lite 25.1: **85.08 MHz** Fmax (needs 50), 3,331 logic elements (7%), 64 of 288
  multipliers, 21 of 182 M9K blocks, 225 mW (Quartus estimate).
- Checked the used board first with a self-test design ([boardtest/](../boardtest/)): all 64 MB
  of SDRAM, accelerometer, displays.
- On the board at 115200 baud: 12/12 random matmuls bit-exact; MNIST bit-exact on 1,000 images
  (97.9%), **20 us of compute per image** but **665 ms end to end**. 99.997% of the time was
  the serial link.
- One run hit a timeout from a single bad byte on the link (bug #3 in [bugs.md](bugs.md)).

## 3. Link protection (protocol v2)

- Problem: one lost or corrupted byte knocked the command decoder out of step and killed the run.
- Fix: checksum on every upload and result, refused-RUN reply, 50 ms stall timeout, host
  resync + retry. See [protocol.md](protocol.md).
- Tests inject a corrupted weight, a dropped byte and a corrupted command byte mid-matmul; the
  host recovers each time with an exact answer. On the board: 8/8 bit-exact.
- Cost: Fmax 85.08 -> 76.85 MHz (still well above 50 MHz).

## 4. Faster link (2 Mbaud)

- 50 MHz / 2,000,000 baud = exactly 25 clocks per bit, so no baud-rate error on either side.
- UART tests now also run at the real 25 clocks per bit, including +/-3% baud tolerance.

| Measurement | 115200 baud | 2 Mbaud | Speedup |
| --- | --- | --- | --- |
| MNIST, per image (batch of 64) | 665 ms | 42 ms | 15.7x |
| MNIST, 1,000 images | 602 s | 36 s | 16.7x |
| 256x256x64 matmul | 52.7 s | 3.1 s | 16.8x |

The link still takes 99.95% of the time, which is what the next step (running the whole network
on the FPGA) attacks.

## 5. Continuous integration

- GitHub Actions runs all 7 cocotb suites in parallel, the host-software checks (software model,
  2% fault injection, MNIST pipeline) and the board self-test simulations on every push.
- Found along the way: `run_tests.py` returned success even when a test failed (cocotb's runner
  only fails the process under pytest). It now exits with an error on any failure.

## 6. The whole network on the FPGA

- Before: the laptop sent every 8x8 weight tile over the serial link (about 2 KB per tile) and
  did the bias, requantize and argmax itself.
- Now: the weights (51 KB) are built into the bitstream as block-RAM ROMs, and the board does
  everything. The laptop sends 784 bytes per image and gets 1 byte (the digit) back.
- The requantize step became pure integer math (multiply by 9710, shift right by 24), so the
  hardware matches the NumPy reference bit for bit; accuracy is unchanged at 97.67%.
- Weight tiles load one PE row per clock from ROM (8 clocks instead of 64 bytes over UART).
- Two build problems on the way (bug #4): the ROM first got built out of logic (89% of the chip)
  until the MAX 10's memory-initialization configuration mode was enabled, and the between-layer
  math needed a 3-stage pipeline to meet timing.

| Measurement | 2 Mbaud, laptop drives matmuls | Whole network on chip | Change |
| --- | --- | --- | --- |
| MNIST, per image, end to end | 42 ms | **3.95 ms** | 10.6x faster |
| vs. the very first version (665 ms) | | | **168x faster** |
| One image, send to digit | | **4.79 ms** | |
| Accuracy on the board | 97.9% (1,000 images) | **97.67% (all 10,000)**, every logit bit-exact | |
| Compute per image | 20 us (matmuls only) | 25 us (everything) | |
| Logic / block RAM / Fmax | 3,391 LEs / 21 M9K / 70.4 MHz | 5,262 LEs / 159 M9K / 64.7 MHz | |

The serial link is still 99.4% of the end-to-end time: 784 bytes at 2 Mbaud take 3.9 ms, while
the network itself takes 25 us per image.
