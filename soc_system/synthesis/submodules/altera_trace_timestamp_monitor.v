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


//Timstamp module
//
//      TODO:   change error detection to a "fifo counters" Style implementation   (count on rising adn falling edges)..   this will stop aliasing issues...
//
//
// generates long tiemstamps opon detectin of a change of value on async_ts_sync_clk



`timescale 1ps / 1ps
`default_nettype none

module altera_trace_timestamp_monitor #(
    parameter TRACE_DATA_WIDTH   = 32,
    parameter TRACE_SYMBOL_WIDTH = 8,      // should probably be fixed!
    parameter FULL_TS_LENGTH     = 40,     // Full resolution trimestamp
    parameter SHORT_TS_BITS      = 16,     // Short timestamp resolution


    parameter SYNC_DEPTH         = 3,

    // derived parameters
    parameter TRACE_SYM_PER_WORD = TRACE_DATA_WIDTH/TRACE_SYMBOL_WIDTH,
    parameter TRACE_EMPTY_WIDTH  = (TRACE_SYM_PER_WORD>1)? $clog2(TRACE_DATA_WIDTH/TRACE_SYMBOL_WIDTH) : 1,
    parameter LONG_TS_SYMBOLS    = (FULL_TS_LENGTH + TRACE_SYMBOL_WIDTH -1) / TRACE_SYMBOL_WIDTH,

    parameter WORDS_FOR_MGMNT    = (LONG_TS_SYMBOLS + TRACE_SYM_PER_WORD) / TRACE_SYM_PER_WORD,
    parameter TS_REM_BITS        = ((FULL_TS_LENGTH-SHORT_TS_BITS)>=1) ? FULL_TS_LENGTH-SHORT_TS_BITS : 1

) (
    input  wire clk,
    input  wire arst_n,

// Asynchronous input for timestamp synchronisation  both edges cause a full TS managemetn packet with TS_SYNC set to be inserted at the next possible oppertunity!
    input  wire async_ts_sync_clk,

//  drive out the timestamp in case something else can use it....     NOT RECCOMENDED!
    output wire    [FULL_TS_LENGTH-1:0] full_ts,

// av_st_trace output
    input  wire                         av_st_tr_ready,
    output reg                          av_st_tr_valid,
    output reg                          av_st_tr_sop,
    output reg                          av_st_tr_eop,
    output reg   [TRACE_DATA_WIDTH-1:0] av_st_tr_data,
    output reg  [TRACE_EMPTY_WIDTH-1:0] av_st_tr_empty


);

reg [FULL_TS_LENGTH -1 : 0] sync_sampled_ts;

(* dont_merge *) reg [FULL_TS_LENGTH -1 : 0] int_full_ts;

reg                         pendinng_sync_sample;
reg                         sync_sample_error;

wire ts_sync_req;
reg  ts_sync_req_1t;
wire sample_ts_sync;


localparam LAST_WORD_EMPTY_VALUE = (TRACE_SYM_PER_WORD - ((LONG_TS_SYMBOLS + 1 ) %TRACE_SYM_PER_WORD )) % TRACE_SYM_PER_WORD;
localparam NUM_WORDS_WIDTH       = $clog2(WORDS_FOR_MGMNT + 1);


always @(posedge clk or negedge arst_n) begin
    if (0 == arst_n) begin
        int_full_ts <= {FULL_TS_LENGTH{1'b0}};
    end else begin
        int_full_ts <= int_full_ts + 1'b1;
    end
end

assign full_ts = int_full_ts;

altera_std_synchronizer #(
    .depth      (SYNC_DEPTH)
)async_ts_sync_clk_synchronizer(
    .clk        (clk),
    .reset_n    (arst_n),
    .din        (async_ts_sync_clk),
    .dout       (ts_sync_req)
);


wire sent_ts;
wire new_ts_send_req;

assign new_ts_send_req = (ts_sync_req_1t ^ ts_sync_req);

always @(posedge clk or negedge arst_n) begin
    if (0 == arst_n) begin
        ts_sync_req_1t       <= 1'b0;
        pendinng_sync_sample <= 1'b0;
        sync_sampled_ts      <= {FULL_TS_LENGTH{1'b0}};
    end else begin
        ts_sync_req_1t       <= ts_sync_req;
        if ((new_ts_send_req == 1'b1) && (pendinng_sync_sample == 1'b0)) begin
            pendinng_sync_sample <= 1'b1;
            if (pendinng_sync_sample == 0) begin  // only hold a single sample
                sync_sampled_ts      <= int_full_ts;
            end
        end else if (1'b1 == sent_ts) begin
            pendinng_sync_sample <= 1'b0; // sync_sample_error;
            //pendinng_sync_sample <= sync_sample_error;
        end
    end
end

reg next_sample_is_errored;
always @(posedge clk or negedge arst_n) begin
    if (0 == arst_n) begin
        sync_sample_error      <= 1'b0;
        next_sample_is_errored <= 1'b0;
    end else begin
        if (pendinng_sync_sample == 1'b1) begin
            if (new_ts_send_req == 1'b1) begin
                next_sample_is_errored <= 1'b1;
            end
        end else begin
            if (new_ts_send_req == 1'b1) begin
                next_sample_is_errored <= 1'b0;
                sync_sample_error      <= next_sample_is_errored;
            end
        end


    end
end




reg [TRACE_SYMBOL_WIDTH-1 : 0] int_av_st_data [LONG_TS_SYMBOLS-1 : 0];
wire [TRACE_SYMBOL_WIDTH * LONG_TS_SYMBOLS -1 : 0] padded_ts;
assign padded_ts = {(TRACE_SYMBOL_WIDTH * LONG_TS_SYMBOLS){1'b0}} | sync_sampled_ts;
always @(*) begin : pack_ts_into_symbols
    integer symbolnum;
    //reg [TRACE_SYMBOL_WIDTH * LONG_TS_SYMBOLS -1 : 0] padded_ts;
    //padded_ts = {(TRACE_SYMBOL_WIDTH * LONG_TS_SYMBOLS){1'b0}};
    //padded_ts = padded_ts | sync_sampled_ts;
    for (symbolnum = 0; symbolnum < LONG_TS_SYMBOLS; symbolnum = symbolnum + 1) begin : inner_loop
        int_av_st_data[symbolnum] =  padded_ts[symbolnum*TRACE_SYMBOL_WIDTH +: TRACE_SYMBOL_WIDTH];
    end
end



reg [NUM_WORDS_WIDTH -1 : 0] av_st_word_num;

always @(posedge clk or negedge arst_n) begin
    if (0 == arst_n) begin
        av_st_tr_valid <= 1'b0;
        av_st_tr_sop   <= 1'b0;
        av_st_tr_eop   <= 1'b0;
        av_st_tr_data  <= {TRACE_DATA_WIDTH{1'b0}};
        av_st_tr_empty <= {TRACE_EMPTY_WIDTH{1'b0}};
        av_st_word_num <= 'd0;
    end else begin : clocked_part
        integer i;
        if (0 == av_st_tr_valid) begin
            if (1 == pendinng_sync_sample) begin
                av_st_tr_valid <= 1'b1;
                av_st_tr_sop   <= 1'b1;
                av_st_tr_eop   <= 1'b0;
                av_st_word_num <= 'd1;

                av_st_tr_data   <= {TRACE_DATA_WIDTH{1'b0}};

                // if IF width is wide enough...
                if (TRACE_SYM_PER_WORD > 2) begin
                    for (i = 0; i< TRACE_SYM_PER_WORD -1; i = i + 1) begin
                        if (LONG_TS_SYMBOLS > (TRACE_SYM_PER_WORD-2)-i) begin
                            av_st_tr_data[(TRACE_SYMBOL_WIDTH * i) +: TRACE_SYMBOL_WIDTH] <= int_av_st_data[(TRACE_SYM_PER_WORD-2)-i];
                        end
                    end
                end

                av_st_tr_data[TRACE_DATA_WIDTH-1-:TRACE_SYMBOL_WIDTH] <= 8'h80;                // header is long TS
                av_st_tr_data[(TRACE_DATA_WIDTH -TRACE_SYMBOL_WIDTH)] <= sync_sample_error;    // set bit if we dropped the last packet;

                av_st_tr_empty <= {TRACE_EMPTY_WIDTH{1'b0}};

                // Special case for when EOP gets set here....
                if (1 == WORDS_FOR_MGMNT) begin
                    av_st_tr_eop   <= 1'b1;
                    av_st_tr_empty <= LAST_WORD_EMPTY_VALUE[0+:TRACE_EMPTY_WIDTH]; //(TRACE_SYM_PER_WORD - ((LONG_TS_SYMBOLS + 1 ) %TRACE_SYM_PER_WORD )) % TRACE_SYM_PER_WORD ;
                end
            end
        end else if (1'b1 == av_st_tr_ready) begin  // && av_st_tr_valid == 1'b1
            av_st_word_num <= av_st_word_num + 1'b1;
            av_st_tr_sop   <= 1'b0;
            av_st_tr_eop   <= 1'b0;

            for (i = 0 ; i< TRACE_SYM_PER_WORD; i = i +1) begin
                if ((TRACE_SYM_PER_WORD * av_st_word_num) -1 +i < LONG_TS_SYMBOLS) begin
                    av_st_tr_data[TRACE_DATA_WIDTH -(i * TRACE_SYMBOL_WIDTH)-1 -: TRACE_SYMBOL_WIDTH] <= int_av_st_data[(TRACE_SYM_PER_WORD * av_st_word_num) -1 +i];
                end
            end

            if (av_st_word_num >= WORDS_FOR_MGMNT-1) begin
                av_st_tr_eop   <= 1'b1;
                av_st_tr_empty <= LAST_WORD_EMPTY_VALUE[0+:TRACE_EMPTY_WIDTH]; //(TRACE_SYM_PER_WORD - ((LONG_TS_SYMBOLS + 1 ) %TRACE_SYM_PER_WORD )) % TRACE_SYM_PER_WORD ;
            end

            if (1'b1 == av_st_tr_eop) begin
                av_st_tr_valid <= 1'b0;
                av_st_tr_eop   <= 1'b0;
            end

        end
    end
end

assign sent_ts = av_st_tr_eop & av_st_tr_ready & av_st_tr_valid;


endmodule
`default_nettype wire
