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

### 3. One timeout during the first big matmul over UART (fixed with protocol v2)
- **Symptom:** in the first `demo_matmul.py` run on the board, the 256x256x64 product timed out:
  the board sent 1 byte where a 5-byte RUN reply was expected. The 9 smaller products before it
  were bit-exact.
- **What we know:** it did not come back. Three 256x256x64 products (1.6 MB) in a logging
  script, the full demo again (12/12 bit-exact, ~2.3 MB), MNIST on 64 images, and MNIST on 1,000 images
  (~7 MB, bit-exact) all ran clean right after.
  One byte is consistent with an `EE` error reply, i.e. a dropped or corrupted byte knocked the
  command decoder out of step. Suspects: the jumper-wire link through the ESP32 board, or the
  Windows USB-serial driver. Not yet confirmed.
- **Fix:** protocol version 2 (see [protocol.md](protocol.md)): a checksum on every LOAD and
  READ_C, a refused-RUN reply (`EC`), a 50 ms stall timeout so a lost byte can't hang the
  board, and host-side resync + retry of the output tile. Tests inject a corrupted weight, a
  dropped byte and a corrupted command byte mid-matmul; the host recovers each time and the
  answer stays exact. On the board: 8/8 matmuls bit-exact with v2.
- **Lesson:** a long unframed byte stream needs error detection (a checksum per tile) and a way to
  resynchronize; "it passed once" isn't the same as "the link is reliable".

### 4. On-chip MNIST build used 89% of the logic and missed timing
- **Symptom:** after adding the on-chip network, Quartus reported 44,106 logic elements (up from
  3,391) and 48 MHz Fmax, below the 50 MHz clock.
- **Cause:** "MIF is not supported for the selected family". A MAX 10 can only preload block RAM
  at power-up in a configuration mode with memory initialization. In the default mode Quartus
  quietly built the 50 KB weight ROM out of logic elements instead.
- **Fix:** `INTERNAL_FLASH_UPDATE_MODE "SINGLE IMAGE WITH ERAM"` in the .qsf. Logic dropped to
  5,176 elements. Timing still missed (47 MHz): the between-layer math (select, add, multiply,
  shift, clip) was one long path, so it was split into a 3-stage pipeline -> 64.7 MHz.
- **Lesson:** read the synthesis messages, not just "compilation successful". A RAM that doesn't
  map to block RAM shows up as a huge logic count, and timing reports name the slow path.

### 5. 16x16 array didn't fit: "Can't find legal locations for 99 DSP block slices"
- **Symptom:** 260 of 288 9-bit multipliers used, yet the fitter failed; block RAM was also at
  182/182.
- **Cause:** a MAX 10 DSP block holds two 9x9 multipliers only if they share controls. Each PE's
  weight register (packed into the DSP block) has its own load enable, so effectively one PE fits
  per block: 144 blocks for 256 PEs. A `multstyle = "logic"` hint to push some multipliers into
  logic was silently ignored.
- **Fix:** half the PEs (128) keep DSP multipliers; the other 128 use a shift-and-add multiplier
  written out explicitly (no `*`, so Quartus can't map it to DSP). It matches the DSP version on
  all 65,536 int8 x int8 input pairs. The INFER batch went from 64 to 32 images to free block RAM.
  Result: 132 DSP multipliers, 59% logic, 152/182 M9K, 66.9 MHz.
- **Lesson:** resource counts aren't the whole story; placement rules matter. Check the fitter
  report, and don't trust synthesis hints without confirming they took effect.

### 6. Faster-baud experiment hung the USB-serial driver (COM8 locked)
- **Goal:** go above 2 Mbaud. The CH343 bridge derives baud from 48 MHz and the FPGA from 50 MHz,
  so 2 Mbaud is the fastest rate that is exact on both sides; higher rates are off by a few %.
  An echo design (`boardtest/rtl/uart_echo_top.v`) was built at 3.125, 4.17, 5 and 6 Mbaud
  (6 Mbaud from a 48 MHz PLL clock) to measure error rates on the real link.
- **Symptom 1:** every rate "failed". Cause: the script pointed at the wrong bitstream folder, so
  the board was never reprogrammed and was still running the accelerator. Fix: correct path, and
  stop instead of testing when programming fails.
- **Symptom 2:** after that, the test hung and COM8 stayed locked ("Access is denied"). An earlier
  killed test process was stuck inside the CH343 driver after asking for 3.125 Mbaud. Restarting
  the device needs admin rights, so it needs a physical replug.
- **Decision:** stay at 2 Mbaud (exact and proven) and cut the bytes instead: compressed images
  (INFER_RLE, 4.4x fewer bytes).
- **Lessons:** make test scripts fail loudly when a setup step fails, because silent setup
  failures produce convincing-looking wrong results. And probe unusual settings on hardware
  carefully: a driver can wedge in a way only a replug fixes.
