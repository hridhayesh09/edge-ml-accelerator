# Start the standalone demo over JTAG and read its results.
#   quartus_stp -t host/demo_jtag.tcl all          classify every stored image
#   quartus_stp -t host/demo_jtag.tcl one <index>  classify one image
#   quartus_stp -t host/demo_jtag.tcl read         just read the results
# Prints the raw probe word in hex; demo_jtag.py runs this and decodes it.

set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -hardware_name $hw -device_name $dev

set mode [lindex $argv 0]
# source = {select[6:0], start_one, start_all}; the board starts on a rising edge
if {$mode == "all"} {
    write_source_data -instance_index 0 -value 001 -value_in_hex
    write_source_data -instance_index 0 -value 000 -value_in_hex
} elseif {$mode == "one"} {
    set k [lindex $argv 1]
    set word [expr {($k << 2) | 2}]
    write_source_data -instance_index 0 -value [format %03X [expr {$k << 2}]] -value_in_hex
    write_source_data -instance_index 0 -value [format %03X $word] -value_in_hex
    write_source_data -instance_index 0 -value [format %03X [expr {$k << 2}]] -value_in_hex
}
after 300
puts "PROBE [read_probe_data -instance_index 0 -value_in_hex]"
end_insystem_source_probe
