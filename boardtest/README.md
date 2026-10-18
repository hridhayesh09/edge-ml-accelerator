# DE10-Lite board self-test

A separate FPGA design that checks a DE10-Lite board before you trust it with the accelerator.
I used it to check a used board before its return window closed. It doesn't touch the accelerator
RTL; it only reuses `rtl/uart_rx.v` and `rtl/uart_tx.v`.

## What it checks

| Part | How | Pass looks like |
| --- | --- | --- |
| LEDs, 7-segment | hold **KEY0** (lamp test) | every LED, segment and dot lights |
| Switches | always mirrored to the LEDs | each switch lights the LED above it |
| Push-buttons | KEY0 = lamp test, KEY1 = next mode | both respond |
| Display decoder | mode 0 | all six digits count 0..F together |
| Accelerometer (ADXL345, 3-wire SPI) | mode 1 | HEX5-4 show `E5` (chip ID); X/Y change when tilted |
| 64 MB SDRAM | mode 2, runs from power-up | passes keep counting, never `Err` |
| Arduino + GPIO header pins | mode 3, touch each pin with a GND jumper | each pin shows up (`A 07`, `G 12`); 52 = all |
| VGA | always on | 8 color bars + red/green/blue/gray ramps |
| Arduino D0/D1 serial | `uart_echo_test.py` (modes 0-2) | `PASS` |

Mode 3 warning: never touch GPIO header pins 11 (5 V) or 29 (3.3 V) with the GND jumper.

## Build and load

Quartus refuses to build inside a OneDrive folder (it keeps marking the build folders
read-only), so build from a copy outside OneDrive if the repo lives there. Then:

```
cd boardtest/quartus
quartus_sh --flow compile boardtest
quartus_pgm -c "USB-Blaster [USB-0]" -m jtag -o "p;output_files/boardtest.sof"
```

Loading over JTAG is temporary: unplugging the board brings back whatever is in flash.

## Reading results over JTAG

The design has an In-System Sources and Probes block, so the laptop can read the SDRAM error
counters and the accelerometer ID directly, without reading the display:

```
python boardtest/read_probes.py        # read
python boardtest/read_probes.py 1      # restart the SDRAM test in mode 1, then read
```

SDRAM test modes: 0 = full 64 MB write-then-read passes, 1 = write each word and read it back
immediately, 2 = twice the refresh rate, 3 = only the first 64K words (data is ~10 ms old).
Read data is sampled at five moments (T+30 to T+70 ns after READ); the controller uses T+50.
On the tested board, T+30 and T+40 fail (too early) and T+50 to T+70 are clean.

## Simulation

```
cd boardtest/tb
iverilog -g2012 -o sim -P tb_sdram_test.INJECT=0 tb_sdram_test.v sdram_model.v ../rtl/sdram_test.v && vvp sim
iverilog -g2012 -o sim tb_adxl345.v ../rtl/adxl345_spi.v && vvp sim
```

`INJECT=1` makes the SDRAM model corrupt one word, to prove the tester catches it. `MODE=0..2`
selects the test mode.

## Result on my board

Confirmed: power, USB-Blaster and JTAG (finds the 10M50DA), configuration over JTAG, the
7-segment displays, the accelerometer (`E5`, X/Y follow tilt) and all 64 MB of SDRAM
(6 full passes from power-up, 217 million reads, 0 errors). Not yet run: lamp test, switches,
header pin scan, VGA, serial echo.
