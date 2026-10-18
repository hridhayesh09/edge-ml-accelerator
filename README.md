# Edge ML Accelerator on FPGA

A small TPU-style matrix engine in Verilog: an **8x8 systolic array of INT8 multiply-accumulate
units** running on a Terasic DE10-Lite (Intel MAX 10) at 50 MHz.

A laptop sends matrices to the FPGA over a serial link, the 64 processing elements multiply them
in parallel, and the results come back. It runs both layers of an MNIST digit classifier and
matches NumPy bit for bit.

```
Laptop (Python) --USB serial--> DE10-Lite
                                  |
  UART -> FIFO -> controller -> 8x8 PE grid -> output RAM -> FIFO -> UART
```

## Results

All numbers below come from simulation, Quartus reports, or runs on the real board
(raw files in [results/](results/)).

**On the board**

| | |
| --- | --- |
| Matrix products | all bit-exact with NumPy (up to 256x256x64) |
| MNIST | bit-exact with NumPy on both layers, 1,000 test images |
| MNIST accuracy on the board | 97.9% on those 1,000 images (same as NumPy) |
| MNIST compute time | **20 us per image** (batch of 64) |
| MNIST end-to-end time | **42 ms per image** at 2 Mbaud (was 665 ms at 115200 baud) |
| 1,000 MNIST images end to end | 36 s (was 10 min) |
| PE utilization | 94.1% for 256-row tiles |

**FPGA build (Quartus Prime Lite 25.1)**

| | |
| --- | --- |
| Max clock (Fmax) | **70.35 MHz** (runs at 50 MHz) |
| Logic elements | 3,391 of 49,760 (7%) |
| Hardware multipliers | 64 of 288 (one per PE) |
| Memory blocks (M9K) | 21 of 182 |
| Power | 224 mW (Quartus estimate) |

**Simulation**

| | |
| --- | --- |
| Tests | 35 tests in 7 suites, all passing |
| Random matrix products checked | 1,100+ bit-exact with NumPy |
| MNIST accuracy (10,000 images) | float32 97.68%, INT8 97.67% |
| Peak throughput | 6.4 GOPS (64 MACs x 2 ops x 50 MHz) |

**Edge comparison (same two MNIST layers, batch of 64)**

| Platform | Compute time | GOPS | Power | GOPS/W |
| --- | --- | --- | --- | --- |
| DE10-Lite FPGA | 1.28 ms | 5.08 | 224 mW (estimate) | 22.6 |
| Raspberry Pi | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| NVIDIA Jetson | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

## How it works

- **Systolic array:** weights stay inside the 64 PEs; activations flow in from the left and
  partial sums flow down. After a short pipeline fill, one result row comes out every clock.
- **Tiling:** big matrices are cut into 8x8 tiles. Long dot products (like MNIST's 784 inputs)
  are added up inside the FPGA, so only final results go back to the laptop.
- **Serial link:** 2 Mbaud UART (exactly 25 clocks per bit) with FIFOs in both directions. Every transfer carries a
  checksum; a corrupted or lost byte is detected, and the host resyncs and retries the tile. An
  ESP32-S3 dev board is used as the USB-to-serial bridge.
- **Verification:** every module is tested with cocotb against NumPy, including the full design
  driven through its UART pins.

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
python mnist_fpga.py --port COM8 --num 64
```

**No board?** Use `--port sim` to run the same commands on a software model.

## Docs

- [How it works](docs/how_it_works.md)
- [Protocol](docs/protocol.md)
- [Board bring-up](docs/bringup.md)
- [Bug log](docs/bugs.md)
