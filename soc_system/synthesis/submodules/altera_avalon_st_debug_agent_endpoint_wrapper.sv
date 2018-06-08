// (C) 2001-2015 Altera Corporation. All rights reserved.
// Your use of Altera Corporation's design tools, logic functions and other 
// software and tools, and its AMPP partner logic functions, and any output 
// files any of the foregoing (including device programming or simulation 
// files), and any associated documentation or information are expressly subject 
// to the terms and conditions of the Altera Program License Subscription 
// Agreement, Altera MegaCore Function License Agreement, or other applicable 
// license agreement, including, without limitation, that your use is for the 
// sole purpose of programming logic devices manufactured by Altera and sold by 
// Altera or its authorized distributors.  Please refer to the applicable 
// agreement for further details.


// altera_avalon_st_debug_agent_endpoint.sv

`timescale 1 ns / 1 ns

package altera_avalon_st_debug_agent_endpoint_wpackage;

function integer nonzero;
input value;
begin
	nonzero = (value > 0) ? value : 1;
end
endfunction

endpackage

module altera_avalon_st_debug_agent_endpoint_wrapper
    import altera_avalon_st_debug_agent_endpoint_wpackage::nonzero;
#(
    parameter DATA_WIDTH        = 8,
    parameter CHANNEL_WIDTH     = 0,
    parameter HAS_MGMT          = 0,
    parameter READY_LATENCY     = 0,
    parameter MFR_CODE          = 0,
    parameter TYPE_CODE         = 0,
    parameter PREFER_HOST       = "",
    parameter CLOCK_RATE_CLK    = 0
) (
    input         clk,
    output        reset,
    input         h2t_ready,
    output        h2t_valid,
    output [DATA_WIDTH-1:0] h2t_data,
    output        h2t_startofpacket,
    output        h2t_endofpacket,
    output [nonzero($clog2(DATA_WIDTH) - 3)-1:0] h2t_empty,
    output [nonzero(CHANNEL_WIDTH)-1:0] h2t_channel,
    output        t2h_ready,
    input         t2h_valid,
    input  [DATA_WIDTH-1:0] t2h_data,
    input         t2h_startofpacket,
    input         t2h_endofpacket,
    input  [nonzero($clog2(DATA_WIDTH) - 3)-1:0] t2h_empty,
    input  [nonzero(CHANNEL_WIDTH)-1:0] t2h_channel,
    output        mgmt_valid,
    output        mgmt_data,
    output [nonzero(CHANNEL_WIDTH)-1:0] mgmt_channel
);

	altera_avalon_st_debug_agent_endpoint #(
        .DATA_WIDTH        (DATA_WIDTH),
        .CHANNEL_WIDTH     (CHANNEL_WIDTH),
        .HAS_MGMT          (HAS_MGMT),
        .READY_LATENCY     (READY_LATENCY),
        .MFR_CODE          (MFR_CODE),
        .TYPE_CODE         (TYPE_CODE),
        .PREFER_HOST       (PREFER_HOST),
        .CLOCK_RATE_CLK    (CLOCK_RATE_CLK)
) inst (
        .clk               (clk),
        .reset             (reset),
        .h2t_ready         (h2t_ready),
        .h2t_valid         (h2t_valid),
        .h2t_data          (h2t_data),
        .h2t_startofpacket (h2t_startofpacket),
        .h2t_endofpacket   (h2t_endofpacket),
        .h2t_empty         (h2t_empty),
        .h2t_channel       (h2t_channel),
        .t2h_ready         (t2h_ready),
        .t2h_valid         (t2h_valid),
        .t2h_data          (t2h_data),
        .t2h_startofpacket (t2h_startofpacket),
        .t2h_endofpacket   (t2h_endofpacket),
        .t2h_empty         (t2h_empty),
        .t2h_channel       (t2h_channel),
        .mgmt_valid        (mgmt_valid),
        .mgmt_data         (mgmt_data),
        .mgmt_channel      (mgmt_channel)
	
	);

endmodule

// synthesis translate_off
// Empty module definition to allow simulation compilation.
module altera_avalon_st_debug_agent_endpoint
    import altera_avalon_st_debug_agent_endpoint_wpackage::nonzero;
#(
    parameter DATA_WIDTH        = 8,
    parameter CHANNEL_WIDTH     = 0,
    parameter HAS_MGMT          = 0,
    parameter READY_LATENCY     = 0,
    parameter MFR_CODE          = 0,
    parameter TYPE_CODE         = 0,
    parameter PREFER_HOST       = "",
    parameter CLOCK_RATE_CLK    = 0
) (
    input         clk,
    output        reset,
    input         h2t_ready,
    output        h2t_valid,
    output [DATA_WIDTH-1:0] h2t_data,
    output        h2t_startofpacket,
    output        h2t_endofpacket,
    output [nonzero($clog2(DATA_WIDTH) - 3)-1:0] h2t_empty,
    output [nonzero(CHANNEL_WIDTH)-1:0] h2t_channel,
    output        t2h_ready,
    input         t2h_valid,
    input  [DATA_WIDTH-1:0] t2h_data,
    input         t2h_startofpacket,
    input         t2h_endofpacket,
    input  [nonzero($clog2(DATA_WIDTH) - 3)-1:0] t2h_empty,
    input  [nonzero(CHANNEL_WIDTH)-1:0] t2h_channel,
    output        mgmt_valid,
    output        mgmt_data,
    output [nonzero(CHANNEL_WIDTH)-1:0] mgmt_channel
);
endmodule
// synthesis translate_on

