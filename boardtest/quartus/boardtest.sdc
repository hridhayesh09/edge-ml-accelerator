# Timing constraints for the board self-test

create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

# Keys, switches and header pins are slow, asynchronous inputs that go through
# synchronizers; LEDs, displays, VGA, accelerometer and UART are slow outputs.
# SDRAM timing is handled by I/O-cell registers and an inverted SDRAM clock
# (see sdram_test.v), so its pins are not analyzed here either.
set_false_path -from [get_ports {KEY[*] SW[*] ARDUINO_IO[*] GPIO[*] GSENSOR_* DRAM_DQ[*]}]
set_false_path -to   [get_ports {LEDR[*] HEX*[*] VGA_* GSENSOR_* ARDUINO_IO[*] DRAM_*}]
