// Stand-in for Quartus's altsource_probe megafunction, so the board test
// top level can be syntax-checked with Icarus Verilog.
module altsource_probe #(
    parameter sld_auto_instance_index = "YES",
    parameter sld_instance_index      = 0,
    parameter instance_id             = "NONE",
    parameter probe_width             = 1,
    parameter source_width            = 1,
    parameter source_initial_value    = "0",
    parameter enable_metastability    = "NO"
) (
    input  wire [probe_width-1:0]  probe,
    output wire [source_width-1:0] source
);
    assign source = 0;
endmodule
