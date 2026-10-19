# Edge ML Accelerator on FPGA

[![tests](https://github.com/hridhayesh09/edge-ml-accelerator/actions/workflows/tests.yml/badge.svg)](https://github.com/hridhayesh09/edge-ml-accelerator/actions/workflows/tests.yml)

A small TPU-style matrix engine in Verilog: a **16x16 systolic array of INT8 multiply-accumulate
units** running on a Terasic DE10-Lite (Intel MAX 10) at 50 MHz.

It runs a complete MNIST digit classifier on the FPGA: the laptop sends an image over a serial
link and gets the digit back. The weights live in on-chip memory, and every layer, the
requantization in between and the final argmax run in hardware, matching NumPy bit for bit.
It can also act as a general INT8 matrix-multiply engine, and it runs a **standalone demo**
with no laptop at all: 98 test images stored on the chip, picked with the switches, answers on
the 7-segment displays.

```
Laptop --image (784 bytes)--> DE10-Lite --digit (1 byte)--> Laptop
                                  |
  UART -> pixel quantizer -> image RAM -> 16x16 PE grid <- weight ROM (51 KB)
                                              |
                     output RAM -> requantize + ReLU -> hidden RAM -> layer 2 -> argmax
```

## Results

All numbers below come from simulation, Quartus reports, or runs on the real board
(raw files in [results/](results/)).

**On the board**

| | |
| --- | --- |
| Matrix products | all bit-exact with NumPy (up to 256x256x64), **22.8 GOPS** at 89% utilization |
| MNIST accuracy on the board | **97.67% on all 10,000 test images**, every logit bit-exact with NumPy |
| MNIST end-to-end time | **1.07 ms per image** with compressed images (first version: 665 ms, 621x slower) |
| One image, send to digit | 2.0 ms |
| MNIST compute time | **12.5 us per image** (both layers, requantize, argmax) |
| Standalone demo (no laptop) | **97/98 right, 3.2 ms for all 98 images = 33 us per image** |

**FPGA build (Quartus Prime Lite 25.1)**

| | |
| --- | --- |
| Processing elements | **256** (16x16), 25.6 GOPS peak |
| Max clock (Fmax) | **63.34 MHz** (runs at 50 MHz) |
| Logic elements | 30,977 of 49,760 (62%) |
| Hardware multipliers | 132 of 288: 128 PEs + requantize; the other 128 PEs use logic multipliers |
| Memory blocks (M9K) | 169 of 182 (weights, image buffer, demo images) |
| Power | 484 mW (Quartus estimate) |

**Simulation**

| | |
| --- | --- |
| Tests | 55 tests in 10 suites (8x8 and 16x16 builds, plus the board demo), all passing |
| Random matrix products checked | 1,100+ bit-exact with NumPy |
| MNIST accuracy (10,000 images) | float32 97.68%, INT8 97.67% |
| Peak throughput | 25.6 GOPS (256 MACs x 2 ops x 50 MHz) |

**Edge comparison (same MNIST network, batch of 64)**

| Platform | Compute time | GOPS | Power | GOPS/W |
| --- | --- | --- | --- | --- |
| DE10-Lite FPGA | 0.80 ms (whole network) | 8.15 | 484 mW (estimate) | 16.8 |
| Raspberry Pi | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| NVIDIA Jetson | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## Standalone demo

No laptop needed. 98 MNIST test images are stored on the chip (compressed, 16 KB):

- **SW9 down:** SW6-SW0 pick an image, HEX5-4 show its number. Press **KEY1**: HEX2 shows the
  true digit, HEX0 the board's answer, and LEDR5/LEDR6 light for right/wrong.
- **SW9 up:** press **KEY1** to classify all 98. The displays show **097 098** (right / total);
  flip **SW8** to see the time for the whole run in microseconds (**3223**).
- It can also be run over the USB-Blaster cable: `python host/demo_jtag.py all`.

The one image it gets wrong (number 96, a 1 read as a 9) is a genuine mistake of the network,
not of the hardware: NumPy makes the same call.

## How it works

- **Systolic array:** weights stay inside the 256 PEs; activations flow in from the left and
  partial sums flow down. After a short pipeline fill, one result row comes out every clock.
- **Whole network on chip:** the 51 KB of INT8 weights are built into the bitstream as block-RAM
  ROMs. For each 16x16 weight tile the controller loads one PE row per clock, streams the images
  through, and accumulates; a 3-stage pipeline then does bias + integer requantize + ReLU, and
  an argmax picks the digit. See [docs/protocol.md](docs/protocol.md).
- **Fitting 256 PEs:** the MAX 10 has 144 DSP blocks, and each PE's weight register needs its
  own one, so half the PEs use DSP multipliers and half use a shift-and-add multiplier built
  from logic (checked against the DSP version on all 65,536 input pairs).
- **Tiling:** big matrices are cut into 16x16 tiles. Long dot products (like MNIST's 784 inputs)
  are added up inside the FPGA, so only final results go back to the laptop.
- **Serial link:** 2 Mbaud UART (exactly 25 clocks per bit) with FIFOs in both directions. Every transfer carries a
  checksum; a corrupted or lost byte is detected, and the host resyncs and retries the tile. An
  ESP32-S3 dev board is used as the USB-to-serial bridge.
- **Standalone mode:** a small controller inside the chip plays the role of the laptop: it feeds
  stored, compressed images to the accelerator through the same command interface the UART
  uses, and reads the answers back.
- **Verification:** every module is tested with cocotb against NumPy, including the full design
  driven through its UART pins and the exact board build driven through its switches and button.

More detail in [docs/how_it_works.md](docs/how_it_works.md).

## Project layout

```
rtl/        Verilog source (PE, systolic array, controller, UART, FIFOs)
tb/         cocotb testbenches
host/       Python driver, demos, MNIST training, edge benchmark
quartus/    Quartus project, pins, timing constraints
boardtest/  self-test design for checking the DE10-Lite board
docs/       protocol, bring-up guide, design notes, bug log
```

## Try it

**Run the simulations** (Python 3.10+ and Icarus Verilog 12):

```
pip install -r requirements.txt
python tb/run_tests.py
```

**Run on the board** (see [docs/bringup.md](docs/bringup.md) for setup):

```
cd host
python demo_matmul.py --port COM8
python mnist_fpga.py --port COM8 --num 10000
```

**No board?** Use `--port sim` to run the same commands on a software model.

## Docs

- [How it works](docs/how_it_works.md)
- [Protocol](docs/protocol.md)
- [Board bring-up](docs/bringup.md)
- [Bug log](docs/bugs.md)
- [Progress log](docs/progress.md): what each step changed, with before/after numbers
