# How it works: a study guide

Read this with the code open. The goal is that you can explain every file from memory and answer
any "why" question an interviewer throws at you.

**Suggested reading order:** `pe.v` → `systolic_array.v` → `uart_rx.v` / `uart_tx.v` →
`sync_fifo.v` → `accel_core.v` → `accel_top.v` → `de10lite_top.v` → `host/accel_proto.py`.

---

## 1. The big idea

Neural network layers are mostly matrix multiplication: `C = A x W`.
For an M x K matrix times a K x N matrix, every output is a dot product of length K,
so there are M x K x N multiply-accumulates (MACs).

A CPU does a few MACs per cycle. This design does **256 per cycle** with a 16x16 grid of
processing elements (PEs), each doing one multiply and one add every clock.

At 50 MHz: 256 MACs x 2 ops (multiply + add) x 50 million cycles/s = **25.6 GOPS peak**.
(The first version was 8x8: 64 MACs, 6.4 GOPS. The RTL is parameterized by N, and the
tests build both sizes.)

## 2. The processing element (`rtl/pe.v`)

```
            p_in (from above)
               |
a_in --> [ w ] [ x ] --> [ + ] --> p_out (down)
   \_____________________________ a_out (right)
```

Every cycle: `p_out <= p_in + a_in * w` and `a_out <= a_in`.
Both are registers, so values move exactly one PE per clock. That rhythm is why it's called
"systolic", like a heartbeat pumping data through.

**Why 32-bit sums?** The worst case for one tile is 8 x (-128) x (-128) = 131,072, which needs
18 bits. 32 bits leaves room to accumulate thousands of tiles (RUN_ACC) without overflow.

## 3. The array and dataflow (`rtl/systolic_array.v`)

**Weight-stationary**: PE[i][j] keeps weight W[i][j] the whole time.
- Activations A[m][i] flow **left to right** along row i.
- Partial sums flow **top to bottom** down column j.
- The bottom of column j outputs sum over i of A[m][i] x W[i][j] = C[m][j].

**Why weight-stationary?** Weights are loaded once (64 bytes) and then reused for every row of A
(up to 256 rows). Weight reuse is the main reason accelerators beat CPUs: data movement costs more
energy and time than math, so you want each byte you fetch to be used as many times as possible.
(Output-stationary is the other common choice: each PE keeps one output and accumulates in place.
Google's TPU v1 is weight-stationary.)

### Why skew the inputs?

Look at column 0. PE[0][0] adds its product at cycle t. That sum moves down one PE per cycle, so
it reaches PE[1][0] at t+1, PE[2][0] at t+2, and so on. For the sum to be correct, A[m][1] must
arrive at row 1 at t+1, A[m][2] at row 2 at t+2. So row i gets delayed by i cycles. That's the
input skew.

Also, activations move right one PE per cycle, so column j starts j cycles later than column 0.
Its result comes out j cycles later too. The output deskew delays column j by (7-j) cycles so a
whole row of C comes out together.

Small example, 2x2 array, one input row [a0, a1]:

```
cycle 1: PE00 gets a0          -> p = a0*w00
cycle 2: PE10 gets a1 (skewed) -> p = a0*w00 + a1*w10 = C[0][0]   (bottom of col 0)
         PE01 gets a0          -> p = a0*w01
cycle 3: PE11 gets a1          -> p = a0*w01 + a1*w11 = C[0][1]   (bottom of col 1)
deskew delays col 0 by 1 cycle, so both come out together.
```

### Latency and throughput

- **Latency:** a row goes in and its result comes out **2N-1 = 15 cycles** later.
- **Throughput:** after the pipeline fills, **one full row of results per cycle**.
- So M rows take about M + 15 cycles. The hardware counter reports **M + 16** (one extra cycle for
  the activation RAM read). The tests check this exact number.
- **Utilization** = M / (M + 16). M = 256 gives 94.1%. M = 8 gives only 33%: the fill/drain
  overhead dominates small batches. This is why batching matters on real accelerators too.

## 4. UART (`rtl/uart_rx.v`, `rtl/uart_tx.v`)

UART frame (8N1): line idles high, **start bit = 0**, 8 data bits **LSB first**, **stop bit = 1**.

- `CLKS_PER_BIT = 50,000,000 / 2,000,000 = 25` clock cycles per bit (exact). The first version
  ran at 115,200 baud (434 clocks per bit); going to 2 Mbaud made everything about 16x faster.
- **2-flop synchronizer:** the RX pin is asynchronous to our clock. Sampling it directly can catch
  a flip-flop mid-transition (metastability). Passing it through two flip-flops gives the first one
  a full cycle to settle.
- **Sample in the middle of each bit:** on the falling edge, wait half a bit, confirm it's still 0
  (rejects glitches), then sample every full bit period. The middle is farthest from the edges, so
  it tolerates the most clock mismatch. The tests prove it works with the sender 3% fast or slow.
- **Frame error:** if the stop bit isn't 1, the byte is dropped and flagged (LEDR9).

## 5. FIFOs (`rtl/sync_fifo.v`)

The serial link delivers one byte every ~4,340 cycles, but the core can consume one byte per cycle.
And when the core sends results, it produces bytes faster than the UART can send them.
FIFOs between them let each side run at its own pace.

**Full vs. empty trick:** pointers have one extra bit. Same address + same extra bit = empty.
Same address + different extra bit = the write pointer lapped the read pointer = full.

## 6. The controller (`rtl/accel_core.v`)

A state machine that reads command bytes and runs the array:

```
IDLE --'W'--> LOAD_W (64 bytes straight into the PEs) --> IDLE
IDLE --'A'--> ALEN (M-1) --> LOAD_A (M*8 bytes into activation RAM) --> IDLE
IDLE --'R'/'U'--> FEED (one RAM row per cycle into the array) --> DRAIN --> RESP (D0 + cycles) --> IDLE
IDLE --'C'--> RD_ADDR <--> RD_SEND (send each output row byte by byte) --> IDLE
IDLE --'P'--> RESP (A5 08 FF 01) --> IDLE
```

**Block RAM reads take one cycle.** You give an address now, data comes out next cycle. FEED
issues address t, and `feed_v` (a register) marks the data valid one cycle later.

**Accumulate mode (RUN_ACC):** the output buffer does a read-modify-write. The array raises
`pre_valid` one cycle before each result, the controller reads the old value from RAM, and when the
result arrives it writes `old + new`. This lets the laptop split a K=784 dot product into 98 tiles
and only read back the final sum.

## 7. Tiling on the host (`host/accel_proto.py`)

The hardware only does 8x8 weights. A 784 x 64 layer becomes 98 x 8 = 784 tiles:

```
for each 8 output columns:
    for each 8 input features:   LOAD_W, LOAD_A, RUN (first) or RUN_ACC (rest)
    READ_C
```

Padding: if a size isn't a multiple of 8, it's padded with zeros, which add nothing to the sums.

## 8. INT8 quantization (`host/mnist_train.py`, `host/mnist_common.py`)

Float weights are mapped to integers: `w_q = round(w / scale)`, with `scale = max|w| / 127`.
Integer math is much cheaper in hardware than floating point (an 8x8 multiplier is tiny compared to
a float32 multiplier).

Between layers, the int32 sums are **requantized** back to int8: multiply by
`scale_x * scale_w / scale_h`, round, and clip to 0..127 (the clip at 0 is the ReLU).

Result: **97.68% float32 vs 97.67% INT8** on the 10,000-image MNIST test set. Basically no loss.

## 9. Verification (`tb/`)

Every module is tested in simulation with **cocotb**: Python tests that drive the Verilog
simulation and check results against a **golden model** (NumPy for the math, a Python UART model
for serial).

| Suite | What it proves |
| --- | --- |
| uart | random bytes, +/-3% baud error, glitch rejection, frame errors, loopback |
| fifo | 20,000 random push/pop cycles vs a Python deque, full/empty flags |
| pe | every corner case of int8 x int8 + int32, plus 5,000 random |
| array | 1,085 random matrices (34,000+ rows), exact latency, gaps in the input stream |
| system | the whole design through its UART pins using the real host protocol code |
| board | the exact board top level at the real 2 Mbaud |

**Run them:** `python tb/run_tests.py` (or one suite: `python tb/run_tests.py array`).
**See waveforms:** `python tb/run_tests.py array --waves`, then open
`tb/sim_build/array/systolic_array.fst` in GTKWave or Surfer. Watch `a_row` go in, the skewed
values march across, and `c_row` come out 15 cycles later. This is the single best way to
understand the design.

**Try this:** change `p_out <= p_in + a_in * w` to `p_out <= p_in - a_in * w` in `pe.v` and run
the array tests. They fail immediately with the exact matrix that broke. Change it back.

---

## Interview questions you should be able to answer

**Why does a systolic array reuse data so well?**
Each activation is fetched once but used by 8 PEs as it moves across a row. Each weight is loaded
once and used for every row of A. Neighbors pass data directly, so there's no repeated memory
access per MAC.

**Weight-stationary vs output-stationary?**
Weight-stationary keeps weights in the PEs and streams inputs; best when the same weights are used
for many inputs (batches). Output-stationary keeps each output's sum in a PE; avoids moving partial
sums but has to stream weights. I picked weight-stationary because a layer's weights are reused
across the whole batch.

**Why skew the inputs?**
The partial sum for a column moves down one PE per cycle, so the input for row i has to arrive i
cycles later to meet it at the right moment.

**How do you prevent overflow?**
int8 x int8 fits in 16 bits; 8 of them fit in 18 bits. The accumulator is 32 bits, enough for
thousands of accumulated tiles. The worst case is tested explicitly.

**What's your critical path?**
Inside each PE: an 8x8 multiply feeding a 32-bit add, before the register. The MAX 10's hardware
multipliers do the multiply; the add uses the carry chain. (Check the Timing Analyzer's worst path
after you compile and quote it.)

**What limits utilization?**
Pipeline fill/drain (16 cycles per tile, so small batches waste time), and the UART: the array
finishes a tile in microseconds, but sending the data takes much longer. At 115,200 baud,
99.997% of MNIST end-to-end time was data transfer; at 2 Mbaud it is still 99.95%. Fixes: faster I/O (SPI, Ethernet, PCIe), bigger on-chip
buffers so data is sent once, or an output-stationary design for a different reuse pattern.

**Why is your FPGA slower than a Jetson?**
64 MACs at 50 MHz vs thousands of GPU cores at ~1 GHz with fast memory. The FPGA isn't meant to
win; it shows the architecture. Scaling up means a bigger array, a higher clock, and a fast
memory interface.

**How does UART work?** Start bit 0, 8 data bits LSB first, stop bit 1, both sides agree on the
baud rate, receiver samples mid-bit after synchronizing the input.

**Why FIFOs?** Producer and consumer run at different rates; the FIFO absorbs bursts so neither
side drops data or stalls the other.

**How did you verify it?** cocotb testbenches per module plus full-system tests through the UART,
all compared bit-for-bit against NumPy. Then on hardware, every result is checked against NumPy
again. See `docs/bugs.md` for what broke along the way.
