# Edge ML Accelerator on FPGA

An 8x8 INT8 **systolic array** (a tiny TPU-style matrix engine) written in Verilog for the
Terasic DE10-Lite (Intel MAX 10). A laptop sends matrices over UART, the FPGA multiplies them with
64 multiply-accumulate units running in parallel, and sends the results back. It runs both layers
of a quantized MNIST digit classifier, bit-exact with NumPy, and is benchmarked against a
Raspberry Pi and NVIDIA Jetson running the same layers.

```
Laptop (Python) --USB serial, 115200 baud--> DE10-Lite
                                               |
   uart_rx -> RX FIFO -> controller FSM -> weight load ----------+
                              |                                   v
                              +-> activation RAM --skew--> [ 8x8 PE grid ] --deskew--> output RAM
                              |                                                    (accumulate)
   uart_tx <- TX FIFO <-------+---------------------------------------------------------+
```

## Highlights

- **Weight-stationary 8x8 systolic array:** 64 PEs, each an int8 x int8 multiply into a 32-bit
  accumulate, one result row per clock after a 15-cycle pipeline fill.
- **Hardware accumulation across tiles (RUN_ACC):** a 784-long dot product is split into 98
  tiles, summed in the output RAM, and only the final result crosses the serial link.
- **UART host interface** with 2-flop synchronizers, mid-bit sampling, glitch and frame-error
  handling, and FIFOs on both directions.
- **cocotb verification** of every module against NumPy and Python models, including the full
  design driven through its UART pins at the real 115200 baud.
- **INT8 MNIST:** 784-64-10 network trained in NumPy, quantized to int8 with no meaningful loss.

## Results

### Verified in simulation (cycle-accurate, same numbers as hardware)

| Metric | Value |
| --- | --- |
| Peak throughput | 64 MACs/cycle x 2 ops x 50 MHz = **6.4 GOPS** |
| Cycles for an M-row tile | **M + 16** (checked exactly in the tests) |
| PE utilization at M = 256 | **94.1%** (256 / 272), i.e. **6.02 GOPS** of compute |
| PE utilization at M = 8 | 33.3% (pipeline fill dominates small batches) |
| MNIST test accuracy (10,000 images) | float32 **97.68%**, INT8 **97.67%** |
| Simulation tests | **26 tests in 6 suites, all passing**; 1,100+ random matrix products checked bit-for-bit against NumPy |

### Measured on the board (fill in during bring-up, see docs/bringup.md)

| Metric | Value |
| --- | --- |
| Fmax (Slow 1200mV 85C) | _TBD_ MHz (runs at 50 MHz) |
| Logic elements | _TBD_ / 49,760 |
| 9-bit multiplier elements | _TBD_ / 288 |
| M9K memory blocks | _TBD_ / 182 |
| Estimated power (Quartus Power Analyzer) | _TBD_ mW |
| MNIST bit-exact vs NumPy | _TBD_ |
| MNIST compute time per image | _TBD_ us |
| MNIST end-to-end time per image (UART) | _TBD_ ms |
| Share of end-to-end time spent on data transfer | _TBD_ % |

### Edge comparison (same two layers, batch 64)

| Platform | Compute latency | GOPS | Power | GOPS/W |
| --- | --- | --- | --- | --- |
| DE10-Lite FPGA (this design) | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| Raspberry Pi | _TBD_ | _TBD_ | _TBD_ | _TBD_ |
| NVIDIA Jetson | _TBD_ | _TBD_ | _TBD_ | _TBD_ |

The expected story: the Jetson wins on raw throughput by orders of magnitude (thousands of GPU
cores at ~1 GHz vs 64 MACs at 50 MHz), and the FPGA's end-to-end time is dominated by the serial
link, not the array. See `docs/how_it_works.md` for the analysis.

## Repository layout

```
rtl/        Verilog source
  pe.v              one processing element (multiply-accumulate)
  systolic_array.v  8x8 grid + input skew + output deskew + valid pipeline
  accel_core.v      command FSM, activation/output RAMs, accumulate logic, cycle counter
  accel_top.v       UART + FIFOs + core (board independent)
  de10lite_top.v    DE10-Lite pins, reset, LEDs, 7-segment run counter
  uart_rx.v, uart_tx.v, sync_fifo.v, sdp_ram.v
tb/         cocotb testbenches (run_tests.py runs them all)
host/       Python: protocol, driver, demos, MNIST training, edge benchmark
quartus/    Quartus Prime Lite project, pin assignments, timing constraints
docs/       protocol, bring-up guide, study guide, bug log
```

## Quick start

### Run the simulations

Needs Python 3.10+, [Icarus Verilog](https://steveicarus.github.io/iverilog/) 12, and the
Python packages. On Windows the easiest route is WSL (Ubuntu):

```
sudo apt install iverilog python3-pip      # WSL / Ubuntu
pip install -r requirements.txt
python tb/run_tests.py                     # all 6 suites (~7 min)
python tb/run_tests.py array --waves       # one suite, with a waveform file
```

### Try the host software without a board

```
cd host
python demo_matmul.py --port sim
python mnist_fpga.py --port sim --num 1000
```

`sim` uses a byte-level software model of the board, so the same commands and tiling run end to end.

### Retrain the network (optional, ~2 min)

```
cd host
python mnist_train.py          # downloads MNIST, writes mnist_int8.npz
```

### Build and run on the DE10-Lite

See **[docs/bringup.md](docs/bringup.md)**: compile in Quartus, program the board, wire a 3.3 V
USB-serial adapter to Arduino pins D0/D1, then:

```
cd host
python demo_matmul.py --port COM5
python mnist_fpga.py --port COM5 --num 64
```

## Documentation

- [docs/how_it_works.md](docs/how_it_works.md): design walkthrough and interview prep
- [docs/protocol.md](docs/protocol.md): command bytes and tiling
- [docs/bringup.md](docs/bringup.md): step-by-step hardware bring-up and measurements
- [docs/bugs.md](docs/bugs.md): what broke and how it was fixed
