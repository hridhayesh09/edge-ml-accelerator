# Board bring-up guide (DE10-Lite)

Follow these in order the day the board arrives. Each step has a clear "it worked" sign, so if
something breaks you know exactly which step to look at. Write every number you collect into
`results/` (make the folder) and the table in the README.

## What you need

- DE10-Lite board + its USB cable (USB-A to USB-B, like a printer cable)
- CP2102 USB-to-serial adapter, **set to 3.3 V**
- 3 jumper wires
- Quartus Prime Lite with **MAX 10** device support installed
- Python 3.10+ with `pip install -r requirements.txt`

---

## Step 1: Day-one board check (before any of our code)

1. Plug the board into your laptop with the USB-B cable.
2. The factory demo should start on its own: LEDs and the 7-segment displays light up.
3. Open Quartus, go to **Tools > Programmer > Hardware Setup**. "USB-Blaster" should be listed.
   - Not listed on Windows: open Device Manager, find the unknown "USB-Blaster" device, choose
     *Update driver > Browse*, and point it at `C:\intelFPGA_lite\<version>\quartus\drivers\usb-blaster`.

**It worked if:** the demo runs and the Programmer sees the USB-Blaster.
If the demo doesn't run, you're still inside the eBay return window, so message the seller.

## Step 2: Compile the design

1. In Quartus: **File > Open Project** and pick `quartus/edge_ml_accel.qpf`.
2. **Processing > Start Compilation** (takes a few minutes).
   - Command line alternative, from the `quartus/` folder: `quartus_sh --flow compile edge_ml_accel`

**It worked if:** compilation finishes with 0 errors. Warnings are normal.

## Step 3: Record resource usage and Fmax (resume numbers)

1. **Compilation Report > Fitter > Resource Usage Summary**. Write down:
   - Total logic elements (out of 49,760)
   - Total registers
   - Embedded multiplier 9-bit elements (out of 288) and how many 18x18 multipliers that is
   - M9K memory blocks (out of 182)
2. **Compilation Report > Timing Analyzer > Slow 1200mV 85C Model > Fmax Summary**. Write down Fmax
   for `clk50`.
3. **Timing Analyzer > ... > Setup Summary**: slack must be **positive** (green). Positive slack at
   20 ns means it meets timing at 50 MHz.

These go in the resume bullet: "closing timing at [X] MHz while using [X]% of logic elements and
[X] of 144 hardware multipliers". Use 50 MHz for "closing timing" (that's what it runs at), and you
can mention the Fmax number in interviews as headroom.

## Step 4: Program the board

1. **Tools > Programmer**. Hardware Setup = USB-Blaster. Mode = JTAG.
2. **Add File...** and pick `quartus/output_files/edge_ml_accel.sof`.
3. Tick **Program/Configure** and click **Start**.

**It worked if:** LEDR0 blinks about once a second and HEX1-HEX0 show `00`.

(A .sof is lost when power is removed. That's fine for development; just reprogram after unplugging.)

## Step 5: Wire the serial adapter

| CP2102 pin | DE10-Lite pin | Why |
| --- | --- | --- |
| TXD | Arduino header **D0** (`ARDUINO_IO[0]`, marked RX) | laptop sends, FPGA receives |
| RXD | Arduino header **D1** (`ARDUINO_IO[1]`, marked TX) | FPGA sends, laptop receives |
| GND | any **GND** pin on the Arduino header | shared ground, required |
| 3V3 / 5V | **leave unconnected** | the board has its own power |

Make sure the adapter's voltage jumper is on **3.3 V**. The FPGA pins are 3.3 V only.

Find the port name:
- Windows: Device Manager > Ports (COM & LPT) > "Silicon Labs CP210x ... (COM5)". If it shows as
  unknown, install the Silicon Labs CP210x VCP driver.
- Linux: `ls /dev/ttyUSB*`  (usually `/dev/ttyUSB0`; you may need `sudo usermod -aG dialout $USER`)
- Mac: `ls /dev/tty.usbserial*` or `/dev/tty.SLAB_USBtoUART`

On the DE10-Lite the Arduino pins are printed as `IO0`, `IO1`, ... along the top edge, below the
40-pin GPIO header. IO0 is the rightmost hole (next to the VGA connector); GND is the 4th hole
from the left on the left-hand strip.

### Using an ESP32 dev board as the bridge

The measurements in the README used an ESP32-S3 dev board as the USB-to-serial bridge. Most ESP32
dev boards have a USB-to-serial chip (CP2102, CH340 or CH343) on board. Holding the ESP32 itself
in reset frees its TX/RX pins, so the laptop talks through that chip straight to the FPGA. No
ESP32 code is needed.

| ESP32 pin | Connect to | Why |
| --- | --- | --- |
| EN / RST | ESP32 GND | holds the ESP32 in reset |
| RX (GPIO3; GPIO44 on an S3) | FPGA **IO0** | laptop -> FPGA (with the ESP32 in reset, "RX" carries what the laptop sends) |
| TX (GPIO1; GPIO43 on an S3) | FPGA **IO1** | FPGA -> laptop |
| GND | FPGA GND | shared ground |

On an ESP32-S3 with two USB-C ports, use the one labeled **UART** (or COM), not **USB**. Boards
with only native USB (no bridge chip) won't work this way.

## Step 6: First contact

From the repo root:

```
cd host
python demo_matmul.py --port COM5 --json ../results/demo_matmul.json
```

**It worked if:** it prints `PING: {'n': 8, 'max_m': 256, 'version': 1}`, then a table where every
row says `yes`, ending with `all 12 results matched NumPy bit for bit`. LEDR1/LEDR2 flicker while
bytes move, and the HEX display counts up the number of RUN commands.

## Step 7: MNIST on the FPGA

```
python mnist_fpga.py --port COM5 --num 64 --json ../results/fpga_mnist.json
```

Takes about 40 seconds at 115200 baud. Write down:
- `bit-exact vs NumPy: YES`
- accuracy (FPGA should equal INT8 CPU exactly)
- hardware compute time per image
- end-to-end time per image and the % spent on data transfer

That last pair is the bottleneck story: the array finishes its work in microseconds, the serial
link takes most of the time.

## Step 8: FPGA power estimate

1. In Quartus: **Processing > Power Analyzer Tool**, click **Start**.
2. Write down **Total Thermal Power Dissipation** and **Core Dynamic Thermal Power Dissipation**.

This is an estimate using a default 12.5% signal toggle rate, so say "estimated" when you quote it.

## Step 9: Raspberry Pi and Jetson baselines (ask your PI first)

Copy the `host/` folder to the device (it only needs NumPy; PyTorch is used if it's installed), then:

```
python bench_edge.py --batch 64 --json pi_results.json
```

For power, start the script in loop mode and read the meter while it runs:

```
python bench_edge.py --batch 64 --loop 30
```

- Jetson: in a second terminal run `tegrastats` and note the total input power (VDD_IN).
- Raspberry Pi: put a USB-C power meter between the power supply and the Pi.

Perf per watt = GOPS / watts. Compare like with like: the FPGA's "hardware compute" GOPS against
each device's compute-only GOPS from `bench_edge.py`.

## Optional: faster serial link

The CP2102 can go up to 921600 baud, which makes everything about 8x faster.
1. In `rtl/de10lite_top.v`, change `parameter BAUD = 115_200` to `921_600`, recompile, reprogram.
2. Add `--baud 921600` to every host command.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `TimeoutError` on PING, LEDR1 never flickers | wrong COM port, or TX/RX not reaching D0 | check the port name; check the wire from adapter TXD to D0 |
| LEDR1 flickers but no reply | adapter RXD not on D1, or no shared GND | check D1 and the GND wire |
| LEDR9 turns on | bad bytes: baud mismatch or a loose wire | confirm both sides use 115200; reseat wires; press KEY0 to clear |
| Garbage bytes / wrong results | adapter at 5 V, or a flaky ground | set the adapter jumper to 3.3 V; use a short GND wire |
| LEDR0 not blinking | board not programmed, or reset held | reprogram the .sof; make sure KEY0 isn't stuck |
| Programmer can't find USB-Blaster | driver | see Step 1 |

When something goes wrong and you fix it, write it in `docs/bugs.md`. Those make the best
interview stories.
