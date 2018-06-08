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


// segmentiser:
//    The purpose of this module is to create packet parts. 
//        this may be becasue we have reached the max size of a packet part, or the incomming data stream has changed source (channel)
//    Also the use of the pipeline registers breaks comb feedback into the rest of the capture cotroler.
//
//
//                             _____
//                            |     |
//                   ---------|>    |
//                 ___________|     |
//                |           |     |-----                   | pl_is_valid
//                |           |_____|     |                  |                           _____
//                |                       |   sigs named   |\|                          |     |
//       ---------+-----------------+     |   pl_?????     | \                      ----|>    |
//                                  |     +----------------|  |                         |     |
//                                  |                      |  |-------------------------|     | --------
//                                  +----------------------|  |   int_??????            |_____|
//                                                         | /     signal name prefixed with int_ 
//                                                         |/
//
`timescale 1ps / 1ps
`default_nettype none

module altera_trace_capture_segmentiser #(
    parameter DATA_WIDTH           = 32,
    parameter SYMBOL_WIDTH         = 4,
    parameter MTY_WIDTH            = 3,
    parameter CHANNEL_WIDTH        = 4,
    parameter SEGMENT_LENGTH_WIDTH = 6,
    // derived parameters...   NOTE currently expects SYMBOL_WIDTH * 2^n bus widths...
    parameter MAX_SEGMENT_LENGTH   = 1 << SEGMENT_LENGTH_WIDTH,
    parameter NUM_SYMBOLS_PER_WORD = DATA_WIDTH / SYMBOL_WIDTH

) (
   input  wire                             clk,
   input  wire                             arst_n,

   output wire                             in_ready,
   input  wire                             in_valid,
   input  wire                             in_sop,
   input  wire                             in_eop,
   input  wire            [DATA_WIDTH-1:0] in_data,
   input  wire             [MTY_WIDTH-1:0] in_mty,
   input  wire         [CHANNEL_WIDTH-1:0] in_chnl,

   input  wire                             out_ready,
   output reg                              out_valid,
   output reg                              out_sop,
   output reg                              out_eop,
   output reg             [DATA_WIDTH-1:0] out_data,
   output reg              [MTY_WIDTH-1:0] out_mty,
   output reg          [CHANNEL_WIDTH-1:0] out_chnl,


   output reg                              new_segment,
   output reg   [SEGMENT_LENGTH_WIDTH-1:0] segment_length,
   output reg                              eo_segment,
   output reg                              trigger_det
);

reg                             int_sop;
reg                             int_eop;
reg            [DATA_WIDTH-1:0] int_data;
reg             [MTY_WIDTH-1:0] int_mty;
reg         [CHANNEL_WIDTH-1:0] int_chnl;

reg                             pl_sop;
reg                             pl_eop;
reg            [DATA_WIDTH-1:0] pl_data;
reg             [MTY_WIDTH-1:0] pl_mty;
reg         [CHANNEL_WIDTH-1:0] pl_chnl;

reg                             pl_is_valid;

reg                             generate_new_ouptut;



assign in_ready = ~pl_is_valid;
// 2 input mux controlled by pl_is_valid
always @(*) begin
	if (pl_is_valid) begin
		int_sop  = pl_sop;
		int_eop  = pl_eop;
		int_data = pl_data;
		int_mty  = pl_mty;
		int_chnl = pl_chnl;
	end else begin
        int_sop  = in_sop;
        int_eop  = in_eop;
        int_data = in_data;
        int_mty  = in_mty;
        int_chnl = in_chnl;	
	end
end


// internal pipeline stage
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
        pl_sop      <= 1'b0;
        pl_eop      <= 1'b0;
        pl_mty      <= {MTY_WIDTH{1'b0}};
        pl_data     <= {DATA_WIDTH{1'b0}};
        pl_chnl     <= {CHANNEL_WIDTH{1'b0}};
    end else begin
        if (in_ready & in_valid) begin
            pl_sop      <= in_sop;
            pl_eop      <= in_eop;
            pl_data     <= in_data;
            pl_mty      <= in_mty;
            pl_chnl     <= in_chnl;                	
        end
    end
end

// generate control signal
always @(*) begin
    if (out_valid & out_ready) begin
        if (pl_is_valid) begin
            generate_new_ouptut = 1'b1;
        end else if (in_ready & in_valid) begin
            generate_new_ouptut = 1'b1;
        end else begin
        	generate_new_ouptut = 1'b0;        
        end
    end else if (~out_valid & in_valid) begin
        generate_new_ouptut = 1'b1;
    end else begin
        generate_new_ouptut = 1'b0;           
    end
end


// default av_st ouptut signals
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
        out_sop      <= 1'b0;
        out_eop      <= 1'b0;
        out_mty      <= {MTY_WIDTH{1'b0}};
        out_data     <= {DATA_WIDTH{1'b0}};
        out_chnl     <= {CHANNEL_WIDTH{1'b0}};
    end else begin
		if (generate_new_ouptut) begin		
           out_sop      <= int_sop;
           out_eop      <= int_eop;
           out_data     <= int_data;
           out_mty      <= int_mty;
           out_chnl     <= int_chnl;                	
        end
    end
end



// generate the length of the segment...
// NOTE: really big assumption here: we are assuming that empty is always 0 except if EOP is driven!
//       This should probably be checked by an assertion.
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
        segment_length <= {SEGMENT_LENGTH_WIDTH{1'b0}};
    end else begin
		if (generate_new_ouptut) begin		
            if ((1'b1 == int_sop) || (out_chnl != int_chnl)) begin
                segment_length <= {SEGMENT_LENGTH_WIDTH{1'b0}} + NUM_SYMBOLS_PER_WORD[MTY_WIDTH : 0] - int_mty[MTY_WIDTH -1 : 0];
            end else begin
                segment_length <= segment_length               + NUM_SYMBOLS_PER_WORD[MTY_WIDTH : 0] - int_mty[MTY_WIDTH -1 : 0];
            end
        end
    end
end


// additional signals for segmentation support in next module
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
        new_segment    <= 1'b0;
        eo_segment     <= 1'b0;
        trigger_det    <= 1'b0;
    end else begin
		if (generate_new_ouptut) begin
		//if ( (out_valid & out_ready) || (~out_valid & in_valid)) begin				
            if (   (out_chnl != int_chnl)
                || (segment_length == {SEGMENT_LENGTH_WIDTH{1'b0}})
                || (1'b1 == int_sop)
               )begin
                new_segment <= 1'b1;
            end else begin
                new_segment <= 1'b0;
            end

            if (  (int_eop == 1'b1)
                ||((segment_length == (1 << SEGMENT_LENGTH_WIDTH) - NUM_SYMBOLS_PER_WORD[MTY_WIDTH : 0]) && (int_sop == 1'b0))
               ) begin
               eo_segment     <= 1'b1;
            end else begin
               eo_segment     <= 1'b0;
            end

            if (int_sop) begin
                trigger_det    <= int_data[DATA_WIDTH -5];
            end else begin
                trigger_det    <= 1'b0;
            end 	
        end
    end
end

		
// valid signals for output and internal use...
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
        pl_is_valid    <= 1'b0;
        out_valid      <= 1'b0;
    end else begin
		if (out_valid & out_ready & pl_is_valid) begin
			pl_is_valid <= 1'b0;
        end else if (in_ready & in_valid & out_valid & ~out_ready) begin
            pl_is_valid <= 1'b1;
        end
        //out_valid <= generate_new_ouptut;
        if (out_valid & out_ready) begin
            out_valid <= 1'b0;
            if (pl_is_valid) begin
                out_valid <= 1'b1;
            end else if (in_ready & in_valid) begin
                out_valid <= 1'b1;
            end
        end else if (~out_valid & in_valid) begin
            out_valid <= 1'b1;
        end
    end
end




endmodule
