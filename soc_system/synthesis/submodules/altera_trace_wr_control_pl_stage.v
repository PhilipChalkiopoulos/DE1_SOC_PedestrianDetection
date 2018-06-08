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


// notionally this is an avalon streaming pipeline stage with RL0 in and out
//  However it also does some calculations for some of the outputs. (out_ptr_out & out_last_hdr)
//
//      general description:
//
//     2 main register stages: one on the output, one as a pipeline stage to hold the data when the output register cannot.
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

module altera_trace_wr_control_pl_stage #(
    parameter ADDR_WIDTH               = 8,
    parameter DATA_WIDTH               = 64,
    parameter MAX_ADDR                 = 3
) (
    input  wire                            clk,
    input  wire                            arst_n,

    output wire                            in_ready,
    input  wire                            in_valid,
    input  wire           [ADDR_WIDTH-1:0] in_address,
    input  wire           [DATA_WIDTH-1:0] in_data,
    input  wire                            in_last_word_in_cell,
    input  wire                            in_data_is_header,
    input  wire                            in_write_wrapped,



    input  wire                             out_ready,
    output reg                              out_valid,
    output reg             [ADDR_WIDTH-1:0] out_address,
    output reg             [DATA_WIDTH-1:0] out_data,
    output reg             [ADDR_WIDTH-1:0] out_ptr_out,
    output reg             [ADDR_WIDTH-1:0] out_last_hdr,
    output reg                              out_write_wrapped,
    output reg                              out_last_word_in_cell
);


reg [DATA_WIDTH-1:0] int_data;
reg [ADDR_WIDTH-1:0] int_addr;
reg                  int_last_word_in_cell;
reg                  int_in_data_is_header;
reg                  int_in_write_wrapped;


reg [DATA_WIDTH-1:0] pl_data;
reg [ADDR_WIDTH-1:0] pl_addr;
reg                  pl_last_word_in_cell;
reg                  pl_in_data_is_header;
reg                  pl_in_write_wrapped;

reg                  pl_is_valid;


assign in_ready = ~pl_is_valid;

// pipeline stage for incomming data.
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
         pl_data              <= {DATA_WIDTH{1'b0}};
         pl_addr              <= {ADDR_WIDTH{1'b0}};
         pl_last_word_in_cell <= 1'b0;
         pl_in_data_is_header <= 1'b0;
         pl_in_write_wrapped  <= 1'b0;
    end else begin
        if (in_ready & in_valid) begin
         pl_data              <= in_data;
         pl_addr              <= in_address;
         pl_last_word_in_cell <= in_last_word_in_cell;
         pl_in_data_is_header <= in_data_is_header;
         pl_in_write_wrapped  <= in_write_wrapped;
        end
    end
end

// mux based on pl_is_valid,   I.e. do we use data from the pipeline stage or from the input.
always @(*) begin
    if (pl_is_valid) begin
        int_data              = pl_data;
        int_addr              = pl_addr;
        int_last_word_in_cell = pl_last_word_in_cell;
        int_in_data_is_header = pl_in_data_is_header;
        int_in_write_wrapped  = pl_in_write_wrapped;
    end else begin
        int_data              = in_data;
        int_addr              = in_address;
        int_last_word_in_cell = in_last_word_in_cell;
        int_in_data_is_header = in_data_is_header;
        int_in_write_wrapped  = in_write_wrapped;
    end
end


wire update_ouptuts;
assign update_ouptuts = ( (out_valid & out_ready) || (~out_valid & in_valid)) ? 1'b1 : 1'b0;

// output registers.
always @(posedge clk or negedge arst_n) begin
    if (~arst_n) begin
        out_address           <= {ADDR_WIDTH{1'b0}};
        out_data              <= {DATA_WIDTH{1'b0}};
        out_ptr_out           <= MAX_ADDR[ADDR_WIDTH-1:0];
        out_last_hdr          <= {ADDR_WIDTH{1'b0}};
        out_write_wrapped     <= 1'b0;
        out_last_word_in_cell <= 1'b0;
    end else begin
        if (update_ouptuts) begin
        	out_last_word_in_cell <= int_last_word_in_cell;
            out_data              <= int_data;
            out_address           <= int_addr;
            out_write_wrapped     <= int_in_write_wrapped;
            if (int_last_word_in_cell) begin
                out_ptr_out    <= int_addr;
            end

            if (int_in_data_is_header) begin
                out_last_hdr   <= int_addr;
            end
        end
    end
end


// control for out_valid and pl_is_valid.
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
