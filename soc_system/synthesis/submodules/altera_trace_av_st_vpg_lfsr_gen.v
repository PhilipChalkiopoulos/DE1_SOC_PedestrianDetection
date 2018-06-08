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


// Create a PRBS generator for lengths 23 and 31.
// the the output is syncronous. and updates the cycle after load or advance is asserted.
// if load and advance are asserted simultaneousley then the load takes precedance
// 
//  
`timescale 1ps / 1ps
`default_nettype none
module altera_trace_av_st_vpg_lfsr_gen #(
    parameter LFSR_ADVANCE_SIZE = 1 
) (
    input  wire                clk,
    input  wire                arst_n,
                                    
    input  wire                prbs_23_n31_mode,
    input  wire                lfsr_load,
    input  wire         [30:0] lfsr_load_val,
    input  wire                lfsr_advance,   
    output wire         [30:0] lfsr_val
    
);

reg                 [31:1] lfsr;
wire [LFSR_ADVANCE_SIZE:1] lfsr_nextbits;


// PRBS 31    x^31 + x^18 + 1
// PRBS 23    x^23 + x^18 + 1
assign lfsr_nextbits[LFSR_ADVANCE_SIZE -: LFSR_ADVANCE_SIZE] =  ~(((prbs_23_n31_mode)?  lfsr[23 -: LFSR_ADVANCE_SIZE] 
                                                                                      : lfsr[31 -: LFSR_ADVANCE_SIZE]
                                                                   )
                                                                 ^ lfsr[18 -: LFSR_ADVANCE_SIZE]); 
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        lfsr             <= {31{1'b0}};
    end else begin
        if (lfsr_load == 1'b1) begin
            lfsr <= lfsr_load_val;
        end else if (lfsr_advance == 1'b1) begin
            lfsr                      <= lfsr << LFSR_ADVANCE_SIZE;
            lfsr[LFSR_ADVANCE_SIZE:1] <= lfsr_nextbits;
        end
    end
end

assign lfsr_val[30:0] =  lfsr[31:1];

endmodule
`default_nettype wire

