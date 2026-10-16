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

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent
RTL = ROOT / "rtl"
TB = ROOT / "tb"

RTL_CORE = [
    RTL / "uart_rx.v",
    RTL / "uart_tx.v",
    RTL / "sync_fifo.v",
    RTL / "pe.v",
    RTL / "systolic_array.v",
    RTL / "sdp_ram.v",
    RTL / "accel_core.v",
    RTL / "accel_top.v",
    RTL / "de10lite_top.v",
]

# suite name -> (top-level module, extra sources, parameters, python test module)
SUITES = {
    "uart":   ("tb_uart",        [TB / "tb_uart.v"], {"CLKS_PER_BIT": 16}, "test_uart"),
    "fifo":   ("sync_fifo",      [],                 {"DEPTH": 16},        "test_fifo"),
    "pe":     ("pe",             [],                 {},                   "test_pe"),
    "array":  ("systolic_array", [],                 {"N": 8},             "test_array"),
    "system": ("accel_top",      [],                 {"CLKS_PER_BIT": 8, "N": 8, "MAX_M": 256}, "test_system"),
    "board":  ("tb_board",       [TB / "tb_board.v"], {},                  "test_board"),
}


def run_suite(name, waves=False):
    top, extra, params, module = SUITES[name]
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
    )
    return results


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    waves = "--waves" in sys.argv
    names = args or list(SUITES)
    sys.path.insert(0, str(TB))
    os.environ.setdefault("COCOTB_RANDOM_SEED", "12345")
    for name in names:
        print(f"\n===== {name} =====")
        run_suite(name, waves)


if __name__ == "__main__":
    main()
