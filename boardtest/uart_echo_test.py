"""Check the Arduino D0/D1 serial link with the board self-test loaded.

The self-test echoes every byte it receives on D0 back out on D1 (modes 0-2).
This sends random bytes and checks they all come back unchanged.

    python boardtest/uart_echo_test.py --port COM5
"""

import argparse
import os
import sys

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--bytes", type=int, default=4096)
    args = ap.parse_args()

    with serial.Serial(args.port, 115200, timeout=2) as s:
        s.reset_input_buffer()
        sent = os.urandom(args.bytes)
        got = bytearray()
        for i in range(0, len(sent), 64):           # small chunks: never overrun
            chunk = sent[i:i + 64]
            s.write(chunk)
            got += s.read(len(chunk))

    bad = sum(a != b for a, b in zip(sent, got)) + abs(len(sent) - len(got))
    print(f"sent {len(sent)} bytes, received {len(got)}, mismatches {bad}")
    if bad == 0:
        print("PASS: D0 (receive) and D1 (transmit) both work")
        return 0
    if not got:
        print("FAIL: nothing came back. Check wiring (adapter TXD->D0, RXD->D1, GND), "
              "the COM port, and that the board is not in mode 3")
    else:
        print("FAIL: data came back corrupted")
    return 1


if __name__ == "__main__":
    sys.exit(main())
