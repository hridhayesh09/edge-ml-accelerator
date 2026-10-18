# Talk to the board self-test's diagnostics over JTAG.
#   quartus_stp -t boardtest/read_probes.tcl            read once
#   quartus_stp -t boardtest/read_probes.tcl <mode>     restart the SDRAM test in
#                                                       mode 0-3, then read
# Prints the raw probe word in hex; read_probes.py decodes it.

set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev
if {[llength $argv] > 0} {
    set mode [lindex $argv 0]
    # source = {mode[1:0], clear}: pulse clear high then low with the new mode
    write_source_data -instance_index 0 -value [format %X [expr {($mode << 1) | 1}]] -value_in_hex
    write_source_data -instance_index 0 -value [format %X [expr {$mode << 1}]] -value_in_hex
    puts "MODE $mode"
}
puts "PROBE [read_probe_data -instance_index 0 -value_in_hex]"
end_insystem_source_probe
