# Edge ML Accelerator on FPGA

[![tests](https://github.com/hridhayesh09/edge-ml-accelerator/actions/workflows/tests.yml/badge.svg)](https://github.com/hridhayesh09/edge-ml-accelerator/actions/workflows/tests.yml)

A TPU-style **16x16 systolic array of INT8 multiply-accumulate units** in Verilog, running a
complete MNIST digit classifier on a Terasic DE10-Lite (Intel MAX 10, 50 MHz). The laptop sends
an image and gets the digit back; the weights, both layers, the requantization and the argmax
all run on the chip, bit-exact with NumPy. It also works as a general INT8 matrix engine, and
as a **standalone demo** with no laptop at all.

```
Laptop --image (784 bytes)--> DE10-Lite --digit (1 byte)--> Laptop
  UART -> pixel quantizer -> image RAM -> 16x16 PE grid <- weight ROM (51 KB)
       -> output RAM -> requantize + ReLU -> hidden RAM -> layer 2 -> argmax
```

## Results

Measured on the board unless noted; raw files in [results/](results/).

| | |
| --- | --- |
| MNIST accuracy | **97.67% on all 10,000 test images**, every logit bit-exact with NumPy (float32: 97.68%) |
| MNIST end to end | **1.07 ms per image**, 2.0 ms for a single image (first version: 665 ms, **621x slower**) |
| MNIST compute | **12.5 us per image** (both layers, requantize, argmax) |
| Standalone demo | **97/98 right in 3.2 ms** (33 us per image), no laptop |
| Matrix products | bit-exact up to 256x256x64, **22.8 GOPS** at 89% of the 25.6 GOPS peak |
| FPGA build | 256 PEs, **63.34 MHz Fmax** (runs at 50), 30,977 LEs (62%), 132/288 multipliers, 169/182 M9K, 484 mW (Quartus estimate) |
| Verification | 55 cocotb tests in 10 suites (8x8, 16x16, board demo), 1,100+ random matmuls checked |

## How it works

- **Systolic array:** weights stay in the 256 PEs; activations flow right, partial sums flow
  down, and one result row comes out every clock.
- **Whole network on chip:** 51 KB of INT8 weights are built into the bitstream as block-RAM
  ROMs. Each 16x16 tile loads one PE row per clock; a 3-stage pipeline does bias + integer
  requantize + ReLU, then an argmax picks the digit.
- **Tiling:** big matrices are cut into 16x16 tiles, and long dot products (MNIST's 784 inputs)
  are summed on the chip so only final results go back.
- **Fitting 256 PEs:** the MAX 10's 144 DSP blocks fit one PE each, so half the PEs use a
  shift-and-add multiplier built from logic (checked on all 65,536 input pairs).
- **Serial link:** 2 Mbaud UART with compressed images and a checksum on every transfer; a
  corrupted or lost byte is detected and the tile retried. An ESP32-S3 is the USB-serial bridge.
- **Verified** with cocotb against NumPy, through the UART pins and through the board's own
  switches and button. Every step's before/after numbers are in the
  [progress log](docs/progress.md); every hardware bug and fix in the [bug log](docs/bugs.md).

## Standalone demo

98 MNIST test images are stored on the chip (compressed, 16 KB); a small controller inside the
chip feeds them to the accelerator the same way the UART does:

- **SW9 down:** SW6-SW0 pick an image (number on HEX5-4). **KEY1:** HEX2 = true digit,
  HEX0 = the board's answer, LEDR5/LEDR6 = right/wrong.
- **SW9 up + KEY1:** classify all 98. Shows **097 098** (right/total); **SW8** shows the time in us.
- Or over the USB-Blaster cable: `python host/demo_jtag.py all`

The one miss (image 96, a 1 read as a 9) is the network's own mistake: NumPy agrees.

## Try it

```
pip install -r requirements.txt
python tb/run_tests.py                                   # all simulations (Icarus Verilog 12)
cd host && python mnist_fpga.py --port COM8 --num 10000  # on the board, or --port sim
python demo_matmul.py --port COM8                        # random matrix products
```

Board setup: [docs/bringup.md](docs/bringup.md). More: [how it works](docs/how_it_works.md),
[protocol](docs/protocol.md).

```
rtl/  Verilog    tb/  cocotb tests    host/  Python driver, demos, MNIST training
quartus/  project, pins, timing    boardtest/  board self-test    docs/  guides and logs
```
