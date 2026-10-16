# Bug log

What broke, how it showed up, and how it was fixed. Keep adding to this as you work on the board.

Format: **symptom → cause → fix → lesson**.

## Found during simulation

### 1. Array simulation ran about 200x slower once data was flowing
- **Symptom:** streaming 64 rows through the array took 2.4 seconds of wall time, while the same
  design sat idle at normal speed.
- **Cause:** all the wires between PEs were packed into two giant flat buses (2,304 bits for the
  partial sums). In Icarus Verilog, writing to any slice of a bus wakes up every reader of the whole
  bus, so each PE update re-evaluated all 64 PEs.
- **Fix:** declared the wires as arrays of separate wires (`wire [31:0] p_v [0:71]`), one per PE
  connection. Same hardware, but the simulator only wakes the PE that actually reads each wire.
  Streaming 64 rows dropped to 0.01 s.
- **Lesson:** how you write RTL affects simulation speed even when the synthesized hardware is
  identical. It also reads more like the grid it describes.

### 2. Latency test reported 16 cycles instead of 15
- **Symptom:** every correctness test passed, but the latency check failed by exactly one cycle.
- **Cause:** a testbench bug, not a hardware bug. The input timestamp was taken in one coroutine and
  the output timestamp in another, and which one ran first after a clock edge wasn't guaranteed.
- **Fix:** take both timestamps in the same monitor coroutine, reading `in_valid` in the read-only
  phase and counting from the edge that actually captures it.
- **Lesson:** when a test fails by exactly one cycle, check the testbench's notion of "when" before
  touching the RTL.

### 3. Every test failed: "Unable to accurately represent 20(ns)"
- **Cause:** no `timescale` was set, so the simulator's time unit was 1 s.
- **Fix:** pass `timescale=("1ns", "1ps")` to the cocotb build.

### 4. Real-baud test failed: "Unable to represent 8680.555 ns"
- **Cause:** 1/115200 s isn't a whole number of picoseconds.
- **Fix:** use 8,681 ns per bit. That's 0.005% off, far inside the +/-3% the receiver is tested to
  handle. (The FPGA side also rounds: 434 clocks x 20 ns = 8,680 ns, 0.006% off.)

### 5. Software model disagreed with the hardware on RUN_ACC
- **Cause:** the first version of `SimAccelerator` only added to the previous result when the
  matrix shapes matched. The real hardware just adds onto whatever is in output buffer rows 0..M-1.
- **Fix:** model the output buffer as a full 256-row array, exactly like the RAM.
- **Lesson:** a reference model has to model the hardware's real behavior, including the odd cases,
  or it hides bugs instead of finding them.

## Found on hardware

_(fill these in during bring-up)_
