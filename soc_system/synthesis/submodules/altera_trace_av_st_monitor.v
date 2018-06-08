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


`timescale 1ps / 1ps
`default_nettype none
module altera_trace_av_st_monitor #(
    parameter DEVICE_FAMILY           = "Cyclone IV GX",
    parameter MON_DATA_WIDTH          = 32,
    parameter MON_CHANNEL_WIDTH       = 1,
    parameter MON_EMPTY_WIDTH         = 2,
    parameter MON_ERR_WIDTH           = 1,
    parameter MON_READY_LATENCY       = 0,
    
    parameter FULL_TS_LENGTH          = 40,     // Full resolution timestamp bitwidth // should be a multiple of 8 bits!
    parameter COUNTER_WIDTHS          = 16,     // counter wisths
    parameter WAKE_UP_RUNNING         = 0,      // NOTE NOT YET SUPPORTED...

    parameter TAP_CAPTURED_WORDS      = 1,
    
    parameter TRACE_OUT_SYMBOL_WIDTH  = 4,

    parameter BUFFER_DEPTH_WIDTH      = 6,

    parameter MFGR_ID                 = 110,
    parameter TYPE_NUM                = 270,

// derived parameters.
    parameter EFF_MON_CHANNEL_WIDTH = (MON_CHANNEL_WIDTH) ? MON_CHANNEL_WIDTH : 1,
    parameter EFF_MON_EMPTY_WIDTH   = (MON_EMPTY_WIDTH  ) ? MON_EMPTY_WIDTH   : 1,
    parameter EFF_MON_ERR_WIDTH     = (MON_ERR_WIDTH)     ? MON_ERR_WIDTH     : 1,

    parameter TRACE_DATA_WIDTH      = 8 * TRACE_OUT_SYMBOL_WIDTH,
    parameter TRACE_EMPTY_WIDTH     = $clog2(TRACE_OUT_SYMBOL_WIDTH)

) (
    input  wire clk,
    input  wire arst_n,

// the IUT....     note this is excessive!
    input  wire                              iut_st_ready,
    input  wire                              iut_st_valid,
    input  wire                              iut_st_sop,
    input  wire                              iut_st_eop,
    input  wire         [MON_DATA_WIDTH-1:0] iut_st_data,
    input  wire  [EFF_MON_CHANNEL_WIDTH-1:0] iut_st_ch,
    input  wire    [EFF_MON_EMPTY_WIDTH-1:0] iut_st_empty,
    input  wire      [EFF_MON_ERR_WIDTH-1:0] iut_st_err,

// av_st_trace output
    input  wire                         av_st_tr_ready,
    output wire                         av_st_tr_valid,
    output wire                         av_st_tr_sop,
    output wire                         av_st_tr_eop,
    output wire  [TRACE_DATA_WIDTH-1:0] av_st_tr_data,
    output wire [TRACE_EMPTY_WIDTH-1:0] av_st_tr_empty,


    input  wire                         csr_s_write,
    input  wire                         csr_s_read,
    input  wire                   [3:0] csr_s_address,
    input  wire                  [31:0] csr_s_write_data,
    output wire                  [31:0] csr_s_readdata

);

    localparam NUM_TS_SYMBOLS           = (FULL_TS_LENGTH    + 7) / 8;
    localparam CH_WIDTH_IN_SYMBOLS      = (MON_CHANNEL_WIDTH + 7)/8;
    localparam DAT_WIDTH_IN_SYMBOLS     = ((MON_DATA_WIDTH  *TAP_CAPTURED_WORDS) + 7)/8;
    localparam MTY_WIDTH_IN_SYMBOLS     = (MON_EMPTY_WIDTH   + 7)/8;
    localparam ERR_WIDTH_IN_SYMBOLS     = (MON_ERR_WIDTH     + 7)/8;

    localparam TRACE_DATA_SECTION_WIDTH  = DAT_WIDTH_IN_SYMBOLS + MTY_WIDTH_IN_SYMBOLS + ERR_WIDTH_IN_SYMBOLS + CH_WIDTH_IN_SYMBOLS;
    localparam COUNTER_WIDTH_IN_SYMBOLS  = (COUNTER_WIDTHS + 7) / 8;
    localparam NET_COUNTER_SYM_WIDTH     = (6 * COUNTER_WIDTH_IN_SYMBOLS) + 1;
    localparam TRACE_INT_SYMBOL_WIDTH    = (1 + NUM_TS_SYMBOLS + 1 + TRACE_DATA_SECTION_WIDTH + NET_COUNTER_SYM_WIDTH);
    localparam TRACE_INT_MTY_WIDTH       = $clog2(TRACE_INT_SYMBOL_WIDTH);

wire                                 int_ready;
wire                                 int_valid;
wire                                 int_sop;
wire                                 int_eop;
wire [TRACE_INT_SYMBOL_WIDTH*8 -1:0] int_data;
wire       [TRACE_INT_MTY_WIDTH-1:0] int_empty;



altera_trace_av_st_example_monitor #(
     .MON_DATA_WIDTH     (MON_DATA_WIDTH)
    ,.MON_CHANNEL_WIDTH  (MON_CHANNEL_WIDTH)
    ,.MON_EMPTY_WIDTH    (MON_EMPTY_WIDTH)
    ,.MON_ERR_WIDTH      (MON_ERR_WIDTH)
    ,.READY_LATENCY      (MON_READY_LATENCY)    
    ,.FULL_TS_LENGTH     (FULL_TS_LENGTH)
    ,.COUNTER_WIDTHS     (COUNTER_WIDTHS)
    ,.WAKE_UP_RUNNING    (WAKE_UP_RUNNING)
    ,.MFGR_ID            (MFGR_ID)
    ,.TYPE_NUM           (TYPE_NUM)
    ,.TAP_CAPTURED_WORDS (TAP_CAPTURED_WORDS)
    ,.USE_READY          (1)
) encoder (              
     .clk                (clk)
    ,.arst_n             (arst_n)
    ,.iut_st_ready       (iut_st_ready)
    ,.iut_st_valid       (iut_st_valid)
    ,.iut_st_sop         (iut_st_sop)
    ,.iut_st_eop         (iut_st_eop)
    ,.iut_st_data        (iut_st_data)
    ,.iut_st_ch          (iut_st_ch)
    ,.iut_st_empty       (iut_st_empty)
    ,.iut_st_err         (iut_st_err)
    ,.av_st_tr_ready     (int_ready)
    ,.av_st_tr_valid     (int_valid)
    ,.av_st_tr_sop       (int_sop)
    ,.av_st_tr_eop       (int_eop)
    ,.av_st_tr_data      (int_data)
    ,.av_st_tr_empty     (int_empty)
    ,.csr_s_write        (csr_s_write)
    ,.csr_s_read         (csr_s_read)
    ,.csr_s_address      (csr_s_address)
    ,.csr_s_write_data   (csr_s_write_data)
    ,.csr_s_readdata     (csr_s_readdata)
    ,.prot_err_x_trigger ()
);



altera_trace_av_st_ex_monitor_buffered_width_adapter #(
     .DEVICE_FAMILY      (DEVICE_FAMILY)
    ,.SYMBOL_WIDTH       (8)
    ,.NUM_SYMBOLS_IN     (TRACE_INT_SYMBOL_WIDTH)
    ,.NUM_SYMBOLS_OUT    (TRACE_OUT_SYMBOL_WIDTH)
    ,.BUFFER_DEPTH_WIDTH (BUFFER_DEPTH_WIDTH)
) buffer (
     .clk             (clk)
    ,.arst_n          (arst_n)
    ,.in_ready        (int_ready)
    ,.in_valid        (int_valid)
    ,.in_sop          (int_sop)
    ,.in_eop          (int_eop)
    ,.in_data         (int_data)
    ,.in_empty        (int_empty)
    ,.out_ready       (av_st_tr_ready)
    ,.out_valid       (av_st_tr_valid)
    ,.out_sop         (av_st_tr_sop)
    ,.out_eop         (av_st_tr_eop)
    ,.out_data        (av_st_tr_data)
    ,.out_empty       (av_st_tr_empty)
);


endmodule
