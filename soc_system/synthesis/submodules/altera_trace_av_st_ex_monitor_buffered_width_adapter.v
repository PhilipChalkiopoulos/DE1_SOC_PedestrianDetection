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


// module which is designed to buffer a parameterisable number of packets (1 word in input = 1 packet)
// and adjust the width for the output.
`default_nettype none
module altera_trace_av_st_ex_monitor_buffered_width_adapter #(
    parameter DEVICE_FAMILY            = "Cyclone IV GX",
    parameter SYMBOL_WIDTH             =  8,
    parameter NUM_SYMBOLS_IN           = 24,
    parameter NUM_SYMBOLS_OUT          =  4,
    parameter BUFFER_DEPTH_WIDTH       =  6,

// derived parameters
    parameter EMPTY_WIDTH_IN        = $clog2(NUM_SYMBOLS_IN),
    parameter TRACE_DATA_WIDTH_IN   = SYMBOL_WIDTH * NUM_SYMBOLS_IN,

    parameter TRACE_EMPTY_WIDTH_OUT = $clog2(NUM_SYMBOLS_OUT),
    parameter TRACE_DATA_WIDTH_OUT  = SYMBOL_WIDTH * NUM_SYMBOLS_OUT
) (
    input  wire clk,
    input  wire arst_n,

    output wire                             in_ready,
    input  wire                             in_valid,
    input  wire                             in_sop,    // unused except possibly for validation!
    input  wire                             in_eop,    // unused except possibly for validation!
    input  wire   [TRACE_DATA_WIDTH_IN-1:0] in_data,
    input  wire        [EMPTY_WIDTH_IN-1:0] in_empty,

    input  wire                             out_ready,
    output reg                              out_valid,
    output reg                              out_sop,
    output reg                              out_eop,
    output wire  [TRACE_DATA_WIDTH_OUT-1:0] out_data,
    output reg  [TRACE_EMPTY_WIDTH_OUT-1:0] out_empty

);

wire                           fifo_full;

wire                           fifo_empty;
wire [TRACE_DATA_WIDTH_IN-1:0] fifo_out_data;
wire      [EMPTY_WIDTH_IN-1:0] fifo_out_empty;
wire                           fifo_read;


reg       [EMPTY_WIDTH_IN  :0] symbols_to_send;
reg [TRACE_DATA_WIDTH_IN -1:0] data_reg;


assign in_ready = ~fifo_full ;

    scfifo #(
         .intended_device_family  (DEVICE_FAMILY)
        ,.lpm_type                ("scfifo")
        ,.lpm_width               (EMPTY_WIDTH_IN + TRACE_DATA_WIDTH_IN)
        ,.lpm_numwords            (1 << BUFFER_DEPTH_WIDTH)
        ,.lpm_widthu              (BUFFER_DEPTH_WIDTH)
        ,.almost_empty_value      (2)
        ,.almost_full_value       (8)
        ,.add_ram_output_register ("ON")
        ,.lpm_showahead           ("ON")
        ,.overflow_checking       ("OFF")
        ,.underflow_checking      ("OFF")
        ,.use_eab                 ("ON")
    )fifo(
         .clock                   (clk)
        ,.aclr                    (~arst_n)
        ,.usedw                   ()
        ,.full                    (fifo_full)
        ,.almost_full             ()
        ,.wrreq                   (in_valid & ~fifo_full)
        ,.data                    ({in_empty, in_data})
        ,.empty                   (fifo_empty)
        ,.almost_empty            ()
        ,.rdreq                   (fifo_read)
        ,.q                       ({fifo_out_empty, fifo_out_data})
//synthesis translate_off
        ,.sclr ()
//synthesis translate_on
    );






// out data is the top TRACE_DATA_WIDTH_OUT bits of data_reg; then we can just shift it!
assign out_data[TRACE_DATA_WIDTH_OUT-1-:TRACE_DATA_WIDTH_OUT] = {TRACE_DATA_WIDTH_OUT{1'b0}} | data_reg[TRACE_DATA_WIDTH_IN-1-:TRACE_DATA_WIDTH_OUT];

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
        data_reg      <= {TRACE_DATA_WIDTH_IN{1'b0}};
    end else begin
        if (   ((1'b1 == (1'b1 == out_ready) & (1'b1 == out_valid)) & (1'b1 == out_valid))
            || ((~out_valid) & (~fifo_empty))
           )begin
            if ((out_eop == 1'b1) || (1'b0 == out_valid)) begin
                data_reg <= fifo_out_data;
            end else begin
                data_reg <= data_reg << TRACE_DATA_WIDTH_OUT;
            end
        end
    end
end

assign fifo_read = ( out_ready & out_valid & out_eop &~fifo_empty) | ((~out_valid) & ~fifo_empty);


wire [EMPTY_WIDTH_IN:0] valid_bytes_from_fifo;
assign valid_bytes_from_fifo = NUM_SYMBOLS_IN[EMPTY_WIDTH_IN : 0] - fifo_out_empty;


wire [TRACE_EMPTY_WIDTH_OUT:0] precalculated_empty;
assign precalculated_empty = NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT:0] - symbols_to_send[TRACE_EMPTY_WIDTH_OUT:0];

// process to work out sop, eop, valid, empty
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
        out_valid       <= 1'b0;
        out_sop         <= 1'b0;
        out_eop         <= 1'b0;
        out_empty       <= {TRACE_EMPTY_WIDTH_OUT{1'b0}};
        symbols_to_send <= {(EMPTY_WIDTH_IN + 1){1'b0}};
    end else begin
        if (   ((1'b1 == out_ready) & (1'b1 == out_valid))
             || ((~out_valid) & (~fifo_empty))
           )begin
            if ((out_eop == 1'b1) || (1'b0 == out_valid)) begin  // new entry!
                out_sop    <= 1'b1;
                out_eop    <= 1'b0;

                out_valid  <= (~out_eop) | (~fifo_empty);
                // expect a warning from this...
                symbols_to_send <= valid_bytes_from_fifo - NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT:0];

                // work out and set empty & eop
                if (NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT:0] >= valid_bytes_from_fifo) begin
                    out_eop   <= 1'b1;
                    out_empty <= NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT-1:0] - valid_bytes_from_fifo[TRACE_EMPTY_WIDTH_OUT-1:0];
                end else begin
                    out_empty <= {TRACE_EMPTY_WIDTH_OUT{1'b0}};
                    out_eop   <= 1'b0;
                end
            end else if ((1'b1 == out_ready) && (1'b1 == out_valid)) begin   // shifting out old entry
                out_sop    <= 1'b0;
                // if we have set enough data then set EOP adn EMPTY else
                if ( NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT:0] >= symbols_to_send) begin
                    //out_empty <= NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT:0] - symbols_to_send[TRACE_EMPTY_WIDTH_OUT:0];
                    out_empty <= precalculated_empty [TRACE_EMPTY_WIDTH_OUT-1:0] ;
                    out_eop   <= 1'b1;
                end else begin
                    out_empty <= {TRACE_EMPTY_WIDTH_OUT{1'b0}};
                    out_eop   <= 1'b0;
                end

                symbols_to_send <= symbols_to_send - NUM_SYMBOLS_OUT[TRACE_EMPTY_WIDTH_OUT:0];
            end
        end
    end
end


endmodule
`default_nettype wire
