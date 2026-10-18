"""Run the board's standalone demo over the USB-Blaster cable (no serial link,
no button presses) and print what the 7-segment displays would show.

    python demo_jtag.py all          # classify every stored image, report accuracy + time
    python demo_jtag.py one 96       # classify stored image 96

Needs Quartus (quartus_stp) and the accelerator loaded on the board.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

QUARTUS_STP = os.environ.get(
    "QUARTUS_STP", r"C:\altera_lite\25.1std\quartus\bin64\quartus_stp.exe")
TCL = Path(__file__).with_name("demo_jtag.tcl")

# (name, width) from the LSB up, matching the probe in de10lite_top.v
FIELDS = [("active", 1), ("idx", 7), ("label", 4), ("pred", 4), ("valid", 1), ("done", 1),
          ("correct", 8), ("total", 8), ("run_us", 20), ("run_cycles", 32)]


def run(*args):
    out = subprocess.run([QUARTUS_STP, "-t", str(TCL), *args], capture_output=True, text=True).stdout
    m = re.search(r"^PROBE ([0-9A-Fa-f]+)", out, re.M)
    if not m:
        sys.exit("could not read the demo probe:\n" + out[-2000:])
    v, d = int(m.group(1), 16), {}
    for name, width in FIELDS:
        d[name] = v & ((1 << width) - 1)
        v >>= width
    return d


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "read"
    d = run(mode, *sys.argv[2:])
    if mode == "one":
        verdict = "right" if d["pred"] == d["label"] else "WRONG"
        print(f"image {d['idx']}: true digit {d['label']}, board says {d['pred']} ({verdict})")
    if d["done"]:
        n = max(d["total"], 1)
        print(f"run all: {d['correct']}/{d['total']} right ({100 * d['correct'] / n:.1f}%), "
              f"{d['run_us']} us for the whole run ({d['run_us'] / n:.1f} us per image), "
              f"accelerator compute {d['run_cycles'] / 50:.0f} us")
    return 0


if __name__ == "__main__":
    sys.exit(main())
