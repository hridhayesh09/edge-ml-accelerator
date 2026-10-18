"""Run every testbench with Icarus Verilog + cocotb.

Usage:
    python tb/run_tests.py            # run all suites
    python tb/run_tests.py array      # run one suite
    python tb/run_tests.py --waves    # also dump waveforms (open with GTKWave/Surfer)

Results (JUnit XML) and waveforms land in tb/sim_build/<suite>/.
"""

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

ROOT = Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl"
TB = ROOT / "tb"

# The on-chip MNIST weights are loaded from these files ($readmemh); the
# simulator needs the absolute path (Quartus uses the default relative one).
MODEL_DIR = '"' + (RTL / "model").as_posix() + '/"'

RTL_CORE = [
    RTL / "uart_rx.v",
    RTL / "uart_tx.v",
    RTL / "sync_fifo.v",
    RTL / "pe.v",
    RTL / "systolic_array.v",
    RTL / "sdp_ram.v",
    RTL / "rom.v",
    RTL / "accel_core.v",
    RTL / "accel_top.v",
    RTL / "de10lite_top.v",
]

# suite name -> (top-level module, extra sources, parameters, python test module[, test filter regex])
SUITES = {
    "uart":   ("tb_uart",        [TB / "tb_uart.v"], {"CLKS_PER_BIT": 16}, "test_uart"),
    # same UART tests at the board's real setting: 50 MHz / 2 Mbaud = 25 clocks per bit
    "uart25": ("tb_uart",        [TB / "tb_uart.v"], {"CLKS_PER_BIT": 25}, "test_uart"),
    "fifo":   ("sync_fifo",      [],                 {"DEPTH": 16},        "test_fifo"),
    "pe":     ("pe",             [],                 {},                   "test_pe"),
    "array":  ("systolic_array", [],                 {"N": 8},             "test_array"),
    "array16": ("systolic_array", [],                {"N": 16},            "test_array"),
    "system": ("accel_top",      [],                 {"CLKS_PER_BIT": 8, "N": 8, "MAX_M": 256, "RX_TIMEOUT": 3000, "MODEL_DIR": MODEL_DIR}, "test_system"),
    # the board's real 16x16 array: a focused subset (256 PEs simulate ~4x slower)
    "system16": ("accel_top",    [],                 {"CLKS_PER_BIT": 8, "N": 16, "MAX_M": 256, "RX_TIMEOUT": 3000, "MODEL_DIR": MODEL_DIR}, "test_system",
                 "ping|single_tile|commands_back|bad_checksum|infer_"),
    "board":  ("tb_board",       [TB / "tb_board.v"], {"MODEL_DIR": MODEL_DIR}, "test_board"),
}


def run_suite(name, waves=False):
    top, extra, params, module = SUITES[name][:4]
    test_filter = SUITES[name][4] if len(SUITES[name]) > 4 else None
    runner = get_runner("icarus")
    build_dir = TB / "sim_build" / name
    runner.build(
        sources=RTL_CORE + extra,
        hdl_toplevel=top,
        parameters=params,
        build_dir=build_dir,
        waves=waves,
        always=True,
        timescale=("1ns", "1ps"),
    )
    results = runner.test(
        hdl_toplevel=top,
        test_module=module,
        test_dir=TB,
        build_dir=build_dir,
        waves=waves,
        test_filter=test_filter,
    )
    return results


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    waves = "--waves" in sys.argv
    names = args or list(SUITES)
    sys.path.insert(0, str(TB))
    os.environ.setdefault("COCOTB_RANDOM_SEED", "12345")
    totals = {}
    for name in names:
        print(f"\n===== {name} =====")
        totals[name] = get_results(run_suite(name, waves))   # (tests, failed)

    # cocotb's runner only fails the process under pytest, so check here:
    # the exit code is what CI (GitHub Actions) looks at.
    print("\n===== summary =====")
    for name, (n, failed) in totals.items():
        print(f"{name:>8}: {n - failed}/{n} passed")
    n_all = sum(n for n, _ in totals.values())
    failed_all = sum(f for _, f in totals.values())
    print(f"   total: {n_all - failed_all}/{n_all} passed")
    sys.exit(1 if failed_all else 0)


if __name__ == "__main__":
    main()
