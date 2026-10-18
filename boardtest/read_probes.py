"""Decode the board self-test's JTAG probe word (see boardtest_top.v).

    python boardtest/read_probes.py            read once
    python boardtest/read_probes.py 2          restart SDRAM test in mode 2, then read

Runs quartus_stp with read_probes.tcl, so Quartus must be installed.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

QUARTUS_STP = os.environ.get(
    "QUARTUS_STP", r"C:\altera_lite\25.1std\quartus\bin64\quartus_stp.exe")
TCL = Path(__file__).with_name("read_probes.tcl")

# (name, width) from the LSB up, matching probe_bus in boardtest_top.v
FIELDS = [
    ("err_a", 24), ("err_b", 24), ("err_c", 24), ("err_d", 24), ("err_e", 24),
    ("reads", 32), ("err_after_ref", 24), ("err_bits", 16), ("err_banks", 4),
    ("first_seen", 1), ("first_addr", 25), ("first_exp", 16), ("first_got", 16),
    ("passes", 16), ("writing", 1), ("init_done", 1), ("accel_id", 8),
]


def read_raw(mode=None):
    cmd = [QUARTUS_STP, "-t", str(TCL)] + ([str(mode)] if mode is not None else [])
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    m = re.search(r"^PROBE ([0-9A-Fa-f]+)", out, re.M)
    if not m:
        sys.exit("could not read probes:\n" + out[-2000:])
    return int(m.group(1), 16)


def decode(v):
    d = {}
    for name, width in FIELDS:
        d[name] = v & ((1 << width) - 1)
        v >>= width
    return d


def main():
    mode = int(sys.argv[1]) if len(sys.argv) > 1 else None
    d = decode(read_raw(mode))
    reads = max(d["reads"], 1)
    print(f"accelerometer ID: 0x{d['accel_id']:02X} (expect 0xE5)")
    print(f"SDRAM: passes {d['passes']}, reads checked {d['reads']:,}, writing={d['writing']} init={d['init_done']}")
    for p, t in zip("abcde", (30, 40, 50, 60, 70)):
        e = d[f"err_{p}"]
        print(f"  errors sampling at T+{t} ns ({p}): {e:,} ({100 * e / reads:.3f}%)")
    print(f"  errors on first read after a refresh: {d['err_after_ref']:,}")
    print(f"  failing data bits: 0x{d['err_bits']:04X}   banks with errors: {d['err_banks']:04b}")
    if d["first_seen"]:
        print(f"  first error: address 0x{d['first_addr']:07X} expected 0x{d['first_exp']:04X} "
              f"got 0x{d['first_got']:04X}")


if __name__ == "__main__":
    main()
