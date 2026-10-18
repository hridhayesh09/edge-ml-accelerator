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

### 1. Quartus would not compile inside OneDrive
- **Symptom:** "Can't open project -- you do not have permission to write" and later
  "Cannot write to directory .../incremental_db".
- **Cause:** the repo lived in a OneDrive folder. OneDrive sets the read-only attribute on folders;
  Windows ignores it for folders, but Quartus checks it and refuses to write.
- **Fix:** build from a copy outside OneDrive (or move the repo out of OneDrive).
- **Lesson:** keep FPGA projects in a short, local, non-synced path.

### 2. Board self-test: SDRAM showed `Err FFF` right after loading (bug in the test, not the board)
- **Symptom:** the memory test reported thousands of errors immediately after the design was
  loaded, but zero errors on every pass after a restart.
- **Cause:** the test's `writing` register is declared `reg writing = 1'b1`, but on the board it
  started at 0. The first pass skipped writing and compared memory that held old data. Quartus
  also removed a "first error" register entirely because, with its default *Power-Up Don't Care*
  setting, a register that is only ever set to 1 may as well start at 1.
- **Fix:** start the test explicitly when SDRAM initialization finishes (set write phase, address
  0, clear counters) instead of trusting power-up values, and set `ALLOW_POWER_UP_DONT_CARE OFF`.
  Verified with JTAG probes: 217 million reads from power-up, 0 errors.
- **Lesson:** don't rely on Verilog initial values for control state on an FPGA. Use an explicit
  reset or initialization step, and check the synthesis report for registers it removed.
