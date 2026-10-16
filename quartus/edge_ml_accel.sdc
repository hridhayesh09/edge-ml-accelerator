# Timing constraints for the DE10-Lite build

# 50 MHz board oscillator: 20 ns period
create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

# These inputs are asynchronous to the clock and pass through 2-flop
# synchronizers in the RTL, so there is no meaningful path to time.
set_false_path -from [get_ports {KEY[*] SW[*] ARDUINO_IO[0]}]

# Outputs drive LEDs and a 115200-baud serial line; nanosecond-level output
# timing does not matter for them.
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] ARDUINO_IO[*]}]
