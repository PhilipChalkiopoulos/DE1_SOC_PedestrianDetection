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


//
//   an example distiller used to highlight the packet dropping messaging & highlight simple behaviours.
//     it is based on monitoring avalon streaming packets.
//
//  Packet format is as follows:
//     packet encap byte (indicates long TS)
//     long TS
//     flags (what is in packet data &| counters)
//     <data>
//     <counters>
//    EOP
//
//   Extensions to consider:
//      do we have option to compile out the ability to send data or counters to save size?
//   TODO:
//      variable timestamp length?
//      USE_READY
//      USE_PACKETS

`timescale 1ps / 1ps
`default_nettype none
module altera_trace_av_st_example_monitor #(
    parameter MON_DATA_WIDTH     = 32,
    parameter MON_CHANNEL_WIDTH  = 1,
    parameter MON_EMPTY_WIDTH    = 2,
    parameter MON_ERR_WIDTH      = 1,

    parameter FULL_TS_LENGTH     = 40,     // Full resolution timestamp bitwidth // should be a multiple of 8 bits!
    parameter COUNTER_WIDTHS     = 16,     // counter wisths
    parameter WAKE_UP_RUNNING    = 0,      // SORT of supported, but how do we control the enabl bits?

    parameter TAP_CAPTURED_WORDS = 1,      // number of words captured from the TAP
    parameter USE_READY          = 1,      // indicates if we should be using the AV_ST ready signal
    parameter READY_LATENCY      = 0,
    parameter USE_PACKETS        = 1,

    parameter MFGR_ID            = 110,
    parameter TYPE_NUM           = 270,

// derived parameters.  note symbols here refers to (8 bit) AV_ST_TRACE event packet symbols and not symbols in the input word
    parameter EFF_MON_CHANNEL_WIDTH = (MON_CHANNEL_WIDTH) ? MON_CHANNEL_WIDTH : 1,
    parameter EFF_MON_EMPTY_WIDTH   = (MON_EMPTY_WIDTH  ) ? MON_EMPTY_WIDTH   : 1,
    parameter EFF_MON_ERR_WIDTH     = (MON_ERR_WIDTH)     ? MON_ERR_WIDTH     : 1,

    parameter NUM_TS_SYMBOLS           = (FULL_TS_LENGTH    + 7)/8,
    parameter CH_WIDTH_IN_SYMBOLS      = (MON_CHANNEL_WIDTH + 7)/8,
    parameter DAT_WIDTH_IN_SYMBOLS     = ((MON_DATA_WIDTH * TAP_CAPTURED_WORDS)   + 7)/8,
    parameter MTY_WIDTH_IN_SYMBOLS     = (MON_EMPTY_WIDTH   + 7)/8,
    parameter ERR_WIDTH_IN_SYMBOLS     = (MON_ERR_WIDTH     + 7)/8,
    parameter COUNTER_WIDTH_IN_SYMBOLS = (COUNTER_WIDTHS    + 7)/8,

    parameter TRACE_DATA_SECTION_WIDTH  = DAT_WIDTH_IN_SYMBOLS + MTY_WIDTH_IN_SYMBOLS + ERR_WIDTH_IN_SYMBOLS + CH_WIDTH_IN_SYMBOLS,
    parameter NET_COUNTER_SECTION_WIDTH = (6 * COUNTER_WIDTH_IN_SYMBOLS) + 1,

    parameter TRACE_SYMBOL_WIDTH    = (1 + NUM_TS_SYMBOLS + 1 + TRACE_DATA_SECTION_WIDTH + NET_COUNTER_SECTION_WIDTH),
    parameter TRACE_DATA_WIDTH      = 8 * TRACE_SYMBOL_WIDTH,
    parameter TRACE_EMPTY_WIDTH     = $clog2(TRACE_SYMBOL_WIDTH)

) (
    input  wire                              clk,
    input  wire                              arst_n,

    // the IUT....
    input  wire                              iut_st_ready,
    input  wire                              iut_st_valid,
    input  wire                              iut_st_sop,
    input  wire                              iut_st_eop,
    input  wire         [MON_DATA_WIDTH-1:0] iut_st_data,
    input  wire  [EFF_MON_CHANNEL_WIDTH-1:0] iut_st_ch,
    input  wire    [EFF_MON_EMPTY_WIDTH-1:0] iut_st_empty,
    input  wire      [EFF_MON_ERR_WIDTH-1:0] iut_st_err,

    // av_st_trace output (WIDE)
    input  wire                              av_st_tr_ready,
    output wire                              av_st_tr_valid,
    output wire                              av_st_tr_sop,
    output wire                              av_st_tr_eop,
    output reg        [TRACE_DATA_WIDTH-1:0] av_st_tr_data,
    output reg       [TRACE_EMPTY_WIDTH-1:0] av_st_tr_empty,

    // CSR
    input  wire                             csr_s_write,
    input  wire                             csr_s_read,
    input  wire                       [3:0] csr_s_address,
    input  wire                      [31:0] csr_s_write_data,
    output reg                       [31:0] csr_s_readdata,

    output wire                             prot_err_x_trigger

);



                                                        // hdr     - TS               flags
localparam  LP_FIELD_START              = TRACE_DATA_WIDTH - 8 - (NUM_TS_SYMBOLS * 8) - 8;      // defines where the data or counter section starts.

// Empty constants
localparam  LP_NO_DATA_OR_COUNTER_EMPTY = NET_COUNTER_SECTION_WIDTH[TRACE_EMPTY_WIDTH : 0] + TRACE_DATA_SECTION_WIDTH[TRACE_EMPTY_WIDTH : 0];

localparam TRACE_COUNTER_SECTION_WIDTH  = NET_COUNTER_SECTION_WIDTH*8;

localparam LP_MOD_TS_WIDTH              = ((FULL_TS_LENGTH % 8) == 0) ? 8 :(FULL_TS_LENGTH % 8);
localparam LP_MOD_NUM_WORD_WIDTH        = (TAP_CAPTURED_WORDS) ?$clog2(TAP_CAPTURED_WORDS) : 1;


// CSR
(* dont_merge *) reg        csr_wr_op;
(* dont_merge *) reg        csr_rd_op;
(* dont_merge *) reg  [3:0] csr_addr;
(* dont_merge *) reg [31:0] csr_wdata;



// local copy of ready signal
wire iut_rl0_ready;

generate
    if (READY_LATENCY == 0) begin : RL_ZERO
        assign iut_rl0_ready = iut_st_ready |~USE_READY[0];
    end else begin : RL_NOT_ZERO
        reg [READY_LATENCY-1 : 0] rl_delay;
        always @(posedge clk or negedge arst_n) begin
            if (1'b0 == arst_n) begin
                rl_delay <= {READY_LATENCY{1'b0}};
            end else begin
                rl_delay                  <= rl_delay >> 1;
                rl_delay[READY_LATENCY-1] <= iut_st_ready;
            end
        end

        assign iut_rl0_ready = rl_delay[0] | ~USE_READY[0];

    end
endgenerate





reg        output_enable;

reg        send_counters;
reg        send_data_and_err;

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        csr_wr_op       <= 1'b0;
        csr_rd_op       <= 1'b0;
        csr_addr        <= 0;
        csr_wdata       <= 0;
        csr_s_readdata  <= {32{1'b0}};

        output_enable   <= WAKE_UP_RUNNING[0];

        send_counters        <= 1'b0;
        send_data_and_err    <= 1'b0;
    end else begin

        if (1'b1 == csr_wr_op) begin
            case (csr_addr)
                'd4:     begin output_enable         <= csr_wdata[0];
                               send_counters         <= csr_wdata[8];
                               send_data_and_err     <= csr_wdata[9];
                         end
                default: begin                                 end
            endcase
        end

        csr_s_readdata <= {32{1'b0}};
        if (1'b1 == csr_rd_op) begin
            case (csr_addr)
                'd0: begin
                        csr_s_readdata[31:28]  <= 4'h0;
                        csr_s_readdata[27:12]  <= TYPE_NUM[15:0];
                        csr_s_readdata[11]     <= 1'b0;
                        csr_s_readdata[10: 0]  <= MFGR_ID[ 10:0];
                     end
                'd1: begin
                        csr_s_readdata[ 0+:8]  <= FULL_TS_LENGTH[0+:8];
                        // room for short TS is supported.
                     end
                'd2: begin
                        csr_s_readdata[28+: 4]  <= MON_ERR_WIDTH    [0+:4];
                        csr_s_readdata[22+: 6]  <= MON_EMPTY_WIDTH  [0+:6];
                        csr_s_readdata[16+: 6]  <= MON_CHANNEL_WIDTH[0+:6];
                        csr_s_readdata[ 0+:16]  <= MON_DATA_WIDTH   [0+:16];
                     end
                'd3: begin
                        csr_s_readdata[0+:8]  <= COUNTER_WIDTHS[0+:8];
                        csr_s_readdata[8+:8]  <= TAP_CAPTURED_WORDS[0+:8];
                     end
                'd4: begin  //CONTROL
                        csr_s_readdata[0]  <= output_enable;
                        csr_s_readdata[8]  <= send_counters;
                        csr_s_readdata[9]  <= send_data_and_err;
                     end
                default: begin
                          end
            endcase
        end

        csr_wr_op <= csr_s_write;
        csr_rd_op <= csr_s_read;
        csr_addr  <= csr_s_address;
        csr_wdata <= csr_s_write_data;
    end
end


(* dont_merge *) reg [FULL_TS_LENGTH-1:0] int_ts;
reg [FULL_TS_LENGTH-1:0] sampled_eop_ts;

reg dropped_ouptut_event_message;
reg write_output;

reg [MON_DATA_WIDTH * TAP_CAPTURED_WORDS-1:0] sampled_data;
reg               [EFF_MON_CHANNEL_WIDTH-1:0] sampled_channel;
reg               [EFF_MON_EMPTY_WIDTH  -1:0] sampled_empty;
reg               [EFF_MON_ERR_WIDTH    -1:0] sampled_error;

reg was_in_packet;
reg in_packet;

reg [COUNTER_WIDTHS-1:0] ip_r_v;
reg [COUNTER_WIDTHS-1:0] ipnr_v;
reg [COUNTER_WIDTHS-1:0] ip_rnv;
reg [COUNTER_WIDTHS-1:0] ipnrnv;
reg                      overflow_r_v;
reg                      overflownr_v;
reg                      overflow_rnv;
reg                      overflownrnv;
reg [COUNTER_WIDTHS-1:0] ipg_r;
reg                      ipg_r_ovrflw;
reg [COUNTER_WIDTHS-1:0] ipg_v;
reg                      ipg_v_ovrflw;
reg [COUNTER_WIDTHS-1:0] sampled_ipg_r;
reg                      sampled_ipg_r_ovrflw;
reg [COUNTER_WIDTHS-1:0] sampled_ipg_v;
reg                      sampled_ipg_v_ovrflw;


// output driving and dropped mesasge detection



always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        write_output                 <= 1'b0;
        dropped_ouptut_event_message <= 1'b0;
    end else begin
        if ((write_output == 1'b1) ) begin
            dropped_ouptut_event_message <= ~av_st_tr_ready;
        end

        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (iut_st_eop == 1'b1)) begin
            write_output  <= output_enable;
        end else begin
            write_output <= 1'b0;
        end
    end
end

assign av_st_tr_valid = write_output;

// as we are sending a single packet per captured event we can just statically assign SOP and EOP
assign av_st_tr_sop = 1'b1;
assign av_st_tr_eop = 1'b1;





// Sample packet data channel etc...


always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sampled_channel              <= {EFF_MON_CHANNEL_WIDTH{1'b0}};
        sampled_empty                <= {EFF_MON_EMPTY_WIDTH{1'b0}};
        sampled_error                <= {EFF_MON_ERR_WIDTH{1'b0}};
    end else begin
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1)) begin
            if (iut_st_sop == 1'b1) begin
                sampled_channel <= iut_st_ch;
            end

            if (iut_st_eop == 1'b1) begin
                sampled_empty   <= iut_st_empty;
                sampled_error   <= iut_st_err;
            end
        end
    end
end


reg [TAP_CAPTURED_WORDS-1:0] capture_enable;
integer capt_word_count;

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sampled_data                 <= {(MON_DATA_WIDTH * TAP_CAPTURED_WORDS){1'b0}};
        capture_enable               <= {TAP_CAPTURED_WORDS{1'b0}};
    end else begin
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1)) begin
            if (iut_st_sop == 1'b1) begin
               sampled_data                                                             <= {(MON_DATA_WIDTH * TAP_CAPTURED_WORDS){1'b0}};
               sampled_data[(MON_DATA_WIDTH * TAP_CAPTURED_WORDS) -1 -:MON_DATA_WIDTH]  <= iut_st_data[MON_DATA_WIDTH-1 -: MON_DATA_WIDTH];
               capture_enable <= {TAP_CAPTURED_WORDS{1'b0}};
               if (TAP_CAPTURED_WORDS > 'd1) begin
                  capture_enable[TAP_CAPTURED_WORDS-2] <= 1'b1;
               end
            end else if (TAP_CAPTURED_WORDS > 'd1) begin
                    capture_enable <= capture_enable >> 1;

                    for (capt_word_count = 0; capt_word_count < TAP_CAPTURED_WORDS; capt_word_count = capt_word_count + 1) begin
                        if (capture_enable[capt_word_count] == 1'b1) begin
                            sampled_data[MON_DATA_WIDTH * capt_word_count +:MON_DATA_WIDTH]  <= iut_st_data[0 +: MON_DATA_WIDTH];
                        end
                    end
            end
        end
    end
end



always @(*) begin
    in_packet = was_in_packet | ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_sop));
end

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        was_in_packet <= 1'b0;
    end else begin
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_eop)) begin
            was_in_packet <= 1'b0;
        end else if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_sop)) begin
            was_in_packet <= 1'b1;
        end
    end
end




// in packet counters
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        ip_r_v       <= {COUNTER_WIDTHS{1'b0}};
        ipnr_v       <= {COUNTER_WIDTHS{1'b0}};
        ip_rnv       <= {COUNTER_WIDTHS{1'b0}};
        ipnrnv       <= {COUNTER_WIDTHS{1'b0}};
        overflow_r_v <= 1'b0;
        overflownr_v <= 1'b0;
        overflow_rnv <= 1'b0;
        overflownrnv <= 1'b0;
    end else begin
        if (was_in_packet) begin
            case ({iut_rl0_ready, iut_st_valid})
                2'b00 : begin
                            ipnrnv <= ipnrnv + 1'b1;
                            if (ipnrnv == {COUNTER_WIDTHS{1'b1}}) begin
                                overflownrnv <= 1'b1;
                            end
                        end
                2'b01 : begin
                            ipnr_v <= ipnr_v + 1'b1;
                            if (ipnr_v == {COUNTER_WIDTHS{1'b1}}) begin
                                overflownr_v <= 1'b1;
                            end
                        end
                2'b10 : begin
                            ip_rnv <= ip_rnv + 1'b1;
                            if (ip_rnv == {COUNTER_WIDTHS{1'b1}}) begin
                                overflow_rnv <= 1'b1;
                            end
                        end
                2'b11 : begin
                            ip_r_v <= ip_r_v + 1'b1;
                            if (ip_r_v == {COUNTER_WIDTHS{1'b1}}) begin
                                overflow_r_v <= 1'b1;
                            end
                        end
            endcase
        end else begin  // SOP or single word packet!
            overflow_r_v <= 1'b0;
            overflownr_v <= 1'b0;
            overflow_rnv <= 1'b0;
            overflownrnv <= 1'b0;

            ip_r_v       <= 'd1;
            ipnr_v       <= {COUNTER_WIDTHS{1'b0}};
            ip_rnv       <= {COUNTER_WIDTHS{1'b0}};
            ipnrnv       <= {COUNTER_WIDTHS{1'b0}};
        end

    end
end


// out of packet counters!
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        ipg_r           <= {COUNTER_WIDTHS{1'b0}};
        ipg_v           <= {COUNTER_WIDTHS{1'b0}};
        ipg_r_ovrflw    <= 1'b0;
        ipg_v_ovrflw    <= 1'b0;
    end else begin
        if (in_packet == 1'b0) begin
            if (iut_rl0_ready == 1'b1) begin
                ipg_r <= ipg_r + 1'b1;
                if (ipg_r == {COUNTER_WIDTHS{1'b1}}) begin
                    ipg_r_ovrflw <= 1'b1;
                end
            end
            if (iut_st_valid == 1'b1) begin
                ipg_v <= ipg_v + 1'b1;
                if (ipg_v == {COUNTER_WIDTHS{1'b1}}) begin
                    ipg_v_ovrflw <= 1'b1;
                end
            end
        end else begin
           ipg_r           <= {COUNTER_WIDTHS{1'b0}};
           ipg_v           <= {COUNTER_WIDTHS{1'b0}};
           ipg_r_ovrflw    <= 1'b0;
           ipg_v_ovrflw    <= 1'b0;
        end
    end
end



always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sampled_ipg_r           <= {COUNTER_WIDTHS{1'b0}};
        sampled_ipg_v           <= {COUNTER_WIDTHS{1'b0}};
        sampled_ipg_r_ovrflw    <= 1'b0;
        sampled_ipg_v_ovrflw    <= 1'b0;
    end else begin
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_sop)) begin
            sampled_ipg_r            <= ipg_r;
            sampled_ipg_v            <= ipg_v;
            sampled_ipg_r_ovrflw     <= ipg_r_ovrflw;
            sampled_ipg_v_ovrflw     <= ipg_v_ovrflw;
        end
    end
end


// Feature to be developed!
wire ipg_prot_err, first_word_prot_err, in_pacet_prot_err;
assign ipg_prot_err        = 1'b0;
assign in_pacet_prot_err   = 1'b0;
assign first_word_prot_err = 1'b0;



reg sampled_prot_err;
(* preserve *) reg int_prot_err_x_trigger;

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sampled_prot_err       <= 1'b0;
        int_prot_err_x_trigger <= 1'b0;

    end else begin
        int_prot_err_x_trigger <= 1'b0;

        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_sop)) begin
            sampled_prot_err <= ipg_prot_err | first_word_prot_err;
        end else if (in_packet == 1'b1) begin
            sampled_prot_err <= sampled_prot_err | in_pacet_prot_err;
        end
    end
end

assign prot_err_x_trigger = int_prot_err_x_trigger;




// internal TS and coutner sampling signals.

// sampling control for timestamps
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
       int_ts                   <= {FULL_TS_LENGTH{1'b0}};
       sampled_eop_ts           <= {FULL_TS_LENGTH{1'b0}};
    end else begin
        int_ts <= int_ts + 1'b1;

        if (   ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1))
            && (1'b1 == iut_st_sop)
           ) begin
            sampled_eop_ts <= int_ts;
        end
    end
end




// Pack the "sampled data" section
reg [(8*TRACE_DATA_SECTION_WIDTH)-1: 0] data_section;
always @(*) begin
    data_section = {(TRACE_DATA_SECTION_WIDTH*8){1'b0}};
    if (MON_DATA_WIDTH != 0)    data_section[ 0                                                                       +: MON_DATA_WIDTH * TAP_CAPTURED_WORDS] = sampled_data;
    if (MON_EMPTY_WIDTH != 0)   data_section[ DAT_WIDTH_IN_SYMBOLS                                                * 8 +: EFF_MON_EMPTY_WIDTH]                 = sampled_empty;
    if (MON_ERR_WIDTH != 0)     data_section[(DAT_WIDTH_IN_SYMBOLS + MTY_WIDTH_IN_SYMBOLS)                        * 8 +: EFF_MON_ERR_WIDTH]                   = sampled_error;
    if (MON_CHANNEL_WIDTH != 0) data_section[(DAT_WIDTH_IN_SYMBOLS + MTY_WIDTH_IN_SYMBOLS + ERR_WIDTH_IN_SYMBOLS) * 8 +: EFF_MON_CHANNEL_WIDTH]               = sampled_channel;
end

// pack the "counters" section
reg [NET_COUNTER_SECTION_WIDTH * 8 -1:0] counter_section;
always @(*) begin
    counter_section = {(NET_COUNTER_SECTION_WIDTH*8){1'b0}};

    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -8] = overflow_r_v;
    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -7] = overflownr_v;
    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -6] = overflow_rnv;
    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -5] = overflownrnv;
    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -4] = sampled_ipg_r_ovrflw;
    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -3] = sampled_ipg_v_ovrflw;

    counter_section[(NET_COUNTER_SECTION_WIDTH*8) -1] = sampled_prot_err;

    counter_section[(0* COUNTER_WIDTH_IN_SYMBOLS)*8 +:COUNTER_WIDTHS] = ip_r_v[0+:COUNTER_WIDTHS];  // big endian values!
    counter_section[(1* COUNTER_WIDTH_IN_SYMBOLS)*8 +:COUNTER_WIDTHS] = ipnr_v[0+:COUNTER_WIDTHS];  // big endian values!
    counter_section[(2* COUNTER_WIDTH_IN_SYMBOLS)*8 +:COUNTER_WIDTHS] = ip_rnv[0+:COUNTER_WIDTHS];  // big endian values!
    counter_section[(3* COUNTER_WIDTH_IN_SYMBOLS)*8 +:COUNTER_WIDTHS] = ipnrnv[0+:COUNTER_WIDTHS];  // big endian values!
    counter_section[(4* COUNTER_WIDTH_IN_SYMBOLS)*8 +:COUNTER_WIDTHS] = sampled_ipg_r   [0+:COUNTER_WIDTHS];  // big endian values!
    counter_section[(5* COUNTER_WIDTH_IN_SYMBOLS)*8 +:COUNTER_WIDTHS] = sampled_ipg_v   [0+:COUNTER_WIDTHS];  // big endian values!

end



// combinatorially set the output data
integer i;
always @(*) begin
    // default
    av_st_tr_data                        = {TRACE_DATA_WIDTH{1'b0}};
    // encapsulation
        //encapsulation encoding byte
        av_st_tr_data[TRACE_DATA_WIDTH-8+:8] = 'h80;                          //full TS no ED bits sent, no triggering or expansion bits set
        av_st_tr_data[TRACE_DATA_WIDTH-8]    = dropped_ouptut_event_message;   // set if we dropped previous message

        // insert the TS here!
        for (i = 0; i < NUM_TS_SYMBOLS; i = i + 1) begin
            if (i == NUM_TS_SYMBOLS -1) begin
                av_st_tr_data[TRACE_DATA_WIDTH-16- (8*i)+:LP_MOD_TS_WIDTH] = sampled_eop_ts[8*i +:LP_MOD_TS_WIDTH];
            end else begin
                av_st_tr_data[TRACE_DATA_WIDTH-16- (8*i)+:8] = sampled_eop_ts[8*i +:8];
            end
        end

    // User section packing
        // user header Byte, used to decode which fields are present
        av_st_tr_data[LP_FIELD_START+1] = send_data_and_err;  // bit 1
        av_st_tr_data[LP_FIELD_START]   = send_counters;      // bit 0


        // default data packing condition (pack both possible data sections)
        av_st_tr_data[LP_FIELD_START -1                               -: TRACE_DATA_SECTION_WIDTH*8]  = data_section[(TRACE_DATA_SECTION_WIDTH*8)-1-:TRACE_DATA_SECTION_WIDTH*8];
        av_st_tr_data[LP_FIELD_START -1 -(TRACE_DATA_SECTION_WIDTH*8) -: TRACE_COUNTER_SECTION_WIDTH] = counter_section[TRACE_COUNTER_SECTION_WIDTH-1-:TRACE_COUNTER_SECTION_WIDTH];

        // if we are not sending data then we re-align the counters to immediatey start after the user header byte
        if (1'b0 == send_data_and_err) begin
            av_st_tr_data[LP_FIELD_START -1 -: TRACE_COUNTER_SECTION_WIDTH]   = counter_section[TRACE_COUNTER_SECTION_WIDTH-1-: TRACE_COUNTER_SECTION_WIDTH];
        end
end


// comb set the output empty
always @(*) begin
    case ({send_counters, send_data_and_err})
        2'b00  : av_st_tr_empty = LP_NO_DATA_OR_COUNTER_EMPTY[TRACE_EMPTY_WIDTH -1: 0];
        2'b01  : av_st_tr_empty = COUNTER_WIDTH_IN_SYMBOLS[TRACE_EMPTY_WIDTH -1: 0];
        2'b10  : av_st_tr_empty = TRACE_DATA_SECTION_WIDTH[TRACE_EMPTY_WIDTH -1: 0];
        default: av_st_tr_empty = {TRACE_EMPTY_WIDTH{1'b0}};
    endcase
end

endmodule
`default_nettype wire
