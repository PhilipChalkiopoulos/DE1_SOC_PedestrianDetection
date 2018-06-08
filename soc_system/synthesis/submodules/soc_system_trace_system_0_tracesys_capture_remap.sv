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


// $Id: //acds/rel/15.1/ip/sld/trace/core/altera_trace_channel_mapper/altera_trace_channel_mapper.sv.terp#3 $
// $Revision: #3 $
// $Date: 2015/08/25 $
// $Author: aferrucc $

// -------------------------------------------------------
// Altera Trace Channel Mapper
//
// Parameters
//   DATA_WIDTH    : 32
//   EMPTY_WIDTH   : 2
//   IN_CHANNEL    : 3
//   OUT_CHANNEL   : 3
//   MAPPING       : 0 1 2 3 4
//
// -------------------------------------------------------

`timescale 1 ns / 1 ns
`default_nettype none
module soc_system_trace_system_0_tracesys_capture_remap
(
    // -------------------
    // Clock & Reset
    // -------------------
    input wire clk,
    input wire reset,

    // -------------------
    // Input
    // -------------------
    output wire in_ready,
    input wire in_valid,
    input wire [32-1:0] in_data,
    input wire in_startofpacket,
    input wire in_endofpacket,
    input wire [2-1:0] in_empty,
    input wire [3-1:0] in_channel,

    // -------------------
    // Output
    // -------------------
    input wire out_ready,
    output wire out_valid,
    output wire [32-1:0] out_data,
    output wire out_startofpacket,
    output wire out_endofpacket,
    output wire [2-1:0] out_empty,
    output reg [3-1:0] out_channel
);

assign in_ready = out_ready;

assign out_valid = in_valid;
assign out_data = in_data;
assign out_startofpacket = in_startofpacket;
assign out_endofpacket = in_endofpacket;
assign out_empty = in_empty;

always @(in_channel) begin

    case (in_channel)
        0: out_channel = 3'd0;    
        1: out_channel = 3'd1;    
        2: out_channel = 3'd2;    
        3: out_channel = 3'd3;    
        4: out_channel = 3'd4;    
        default: out_channel = 3'd0;
    endcase

end

endmodule
`default_nettype wire


