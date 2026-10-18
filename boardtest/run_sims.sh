#!/usr/bin/env bash
# Simulations for the board self-test (plain Icarus Verilog, no cocotb).
# Fails if any testbench prints something other than "RESULT: PASS".
set -euo pipefail
cd "$(dirname "$0")/tb"
out=$(mktemp)
fail=0

run() {   # run <name> <iverilog args...>
    local name=$1; shift
    iverilog -g2012 -o "$out" "$@"
    if vvp -n "$out" | grep -q "RESULT: PASS"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"; fail=1
    fi
}

for mode in 0 1 2; do
    for inj in 0 1; do
        run "sdram mode=$mode inject=$inj" -P tb_sdram_test.MODE=$mode -P tb_sdram_test.INJECT=$inj \
            tb_sdram_test.v sdram_model.v ../rtl/sdram_test.v
    done
done
run "adxl345 spi" tb_adxl345.v ../rtl/adxl345_spi.v
rm -f "$out"
exit $fail
