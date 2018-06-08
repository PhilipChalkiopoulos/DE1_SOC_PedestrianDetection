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


// This component is designed to capture avalon streaming video data,
//   First we identify av_st_video data packets (of a specific channel if channel is used)
//   The module extracts and sends pixels from the current frame to the host. on sampling a pixel we choose the "gap" to the enxt sampled pixel, this may be 0 (i.e. the next pixel)
//
//   the retuend packet format is as follows:
//     ENCAP
//        hdr_byte  1B
//              flags get set for packet ERR : pixels dropped on prev packet
//              >=1 packet frop... normal menaing but in this case we drop an entire AV_ST video data packet!
//        TS        ?? Bytes derived from FULL_TS_LENGTH
//     USER_DATA
//        prbs_value                  :   32 bits   (30 used)  even though PRBS is PRBS23!
//        Min value                   :   16 bits   (14 used)
//        1st_pixel_number in frame   :   16 bits   (14 used)
//        frame_num                   :   1 B %128
//        pixels....
//
//
//
//  sample rate control:
//       in steady state:
//          imagine a stream of pixels, when a pixel is sampled, an algorithm determines when the next pixel that is chosen.
//          The number of the next pixel is chosen as an offset from the current pixel.
//
//          next_pixel_number <= current_pixel_number + min_value + masked_prbs_value + 1;
//
//          This also means we choose a random pixel for the start of a frame.
//          A second mode should be available. we will use the frame number %128 to shoose the first pixel, that means we hase something repeatable for direct comapirsons between monitros.
//
//          When a frame finishes, if a sample was 'missed', the min value will increment. if frame_number%128 == 0 and no pixels were dropped, then we can decrement the min value.
//          Software can write to the PRBS value and the min value causing the current hardware values to be over-written.


`timescale 1ps / 1ps
`default_nettype none
module altera_trace_av_st_video_pixel_grabber_monitor #(
    parameter DEVICE_FAMILY         = "Cyclone IV GX",
    parameter MON_NUM_PIXELS        = 3,
    parameter MON_PIXEL_WIDTH       = 8,
//    parameter MON_CHANNEL_WIDTH     = 0,

    parameter FULL_TS_LENGTH        = 32,     // Full resolution timestamp bitwidth // should be a multiple of 8 bits!
    parameter WAKE_UP_RUNNING       = 0,      // SORT of supported, but how do we control the enabl bits?

    parameter USE_READY             = 1,      // indicates if we should be using the AV_ST ready signal
    parameter MON_READY_LATENCY     = 0,

    parameter MAX_COUNT_WIDTH       = 14,

    parameter MFGR_ID               = 110,
    parameter TYPE_NUM              = 272,

    parameter BUFF_ADDR_WIDTH       = 10,

    parameter TRACE_OUT_SYM_WIDTH   = 4,
// derived parameters.  note symbols here refers to (8 bit) AV_ST_TRACE event packet symbols and not symbols in the input word
    parameter DATA_PORT_WIDTH        = MON_NUM_PIXELS * MON_PIXEL_WIDTH,
    parameter TRACE_OUT_DATA_WIDTH   = TRACE_OUT_SYM_WIDTH * 8,
    parameter TRACE_OUT_EMPTY_WIDTH  = $clog2(TRACE_OUT_SYM_WIDTH)

) (
    input  wire                              clk,
    input  wire                              arst_n,

    // the IUT....
    input  wire                              iut_st_ready,
    input  wire                              iut_st_valid,
    input  wire                              iut_st_sop,
    input  wire                              iut_st_eop,
    input  wire        [DATA_PORT_WIDTH-1:0] iut_st_data,


    // av_st_trace output (WIDE)
    input  wire                              av_st_tr_ready,
    output wire                              av_st_tr_valid,
    output wire                              av_st_tr_sop,
    output wire                              av_st_tr_eop,
    output wire   [TRACE_OUT_DATA_WIDTH-1:0] av_st_tr_data,
    output wire  [TRACE_OUT_EMPTY_WIDTH-1:0] av_st_tr_empty,

    // CSR
    input  wire                             csr_s_write,
    input  wire                             csr_s_read,
    input  wire                       [3:0] csr_s_address,
    input  wire                      [31:0] csr_s_write_data,
    output reg                       [31:0] csr_s_readdata

);


localparam NUM_TS_SYMBOLS     = (FULL_TS_LENGTH + 7)/8;


// header before pixel is:  1 + timestamp      + lfsr + min + count + framenum  + height, width & interlacing
//                          1 + TS_SYMS        + 4    + 2   + 2     + 1
localparam LP_HEADER_WIDTH = 1 + NUM_TS_SYMBOLS + 4 +  2     + 2     + 1        +5;

localparam LP_MOD_TS_WIDTH = ((FULL_TS_LENGTH % 8) == 0) ? 8 : (FULL_TS_LENGTH % 8);

localparam LP_SYM_COUNT_WIDTH = $clog2((9/MON_NUM_PIXELS) + 1);


// ready latency Adjustment to map everything to RL0!
wire iut_rl0_ready;

generate
    if (MON_READY_LATENCY == 0) begin : RL_ZERO
        assign iut_rl0_ready = iut_st_ready |~USE_READY[0];
    end else begin : RL_NOT_ZERO
        reg [MON_READY_LATENCY-1 : 0] rl_delay;
        always @(posedge clk or negedge arst_n) begin
            if (1'b0 == arst_n) begin
                rl_delay <= {MON_READY_LATENCY{1'b0}};
            end else begin
                rl_delay                      <= rl_delay >> 1;
                rl_delay[MON_READY_LATENCY-1] <= iut_st_ready;
            end
        end

        assign iut_rl0_ready = rl_delay[0] | ~USE_READY[0];

    end
endgenerate




// CSR
(* dont_merge *) reg        csr_wr_op;
(* dont_merge *) reg        csr_rd_op;
(* dont_merge *) reg  [3:0] csr_addr;
(* dont_merge *) reg [31:0] csr_wdata;

reg        output_enable;



reg   [MAX_COUNT_WIDTH-1:0] lfsr_mask;
reg   [MAX_COUNT_WIDTH-1:0] count_min_value;
reg                   [1:0] sample_timing_extension;

reg                       new_min_val_avail;
reg [MAX_COUNT_WIDTH-1:0] new_min_sample_gap;


reg        dropped_output_event_message;
reg        dropped_pixel_in_last_packet;
reg        was_image_packet;
reg        was_sop;
wire [6:0] frame_number;


reg                          is_control_packet;
reg [LP_SYM_COUNT_WIDTH-1:0] control_packet_sym_count;
reg                   [15:0] extracted_width;
reg                   [15:0] extracted_height;
reg                   [ 3:0] extracted_interlacing;


reg [MON_NUM_PIXELS * MON_PIXEL_WIDTH -1 : 0] sample_data;
reg                                           sample_valid;
reg                                           sample_was_eop;

reg                                           write_sample;
reg                                           write_sample_eop;

reg no_sample_flush;
reg have_sampled_in_video_packet;


wire header_write_busy;
reg  dropped_pixel_in_this_packet;
reg  valid_sample_aligned;

wire   try_to_sample_this_delayed_data;

wire discard_data;


reg [DATA_PORT_WIDTH-1:0] delayed_iut_st_data;
reg                       delayed_iut_st_eop;
wire                      valid_sample_data;



wire                [30:0] sampled_lfsr;
wire [MAX_COUNT_WIDTH-1:0] sampled_min_value;
wire [MAX_COUNT_WIDTH-1:0] sampled_count_value;
wire [MAX_COUNT_WIDTH-1:0] sampled_lfsr_mask;
wire                 [6:0] sampled_frame_number;
wire  [FULL_TS_LENGTH-1:0] sampled_ts;

wire sample_now;
wire header_write;
reg  sample_now_aligned;



reg                        [7:0] encap_header_byte = 'h80;
reg  [(NUM_TS_SYMBOLS * 8) -1:0] encap_ts_data;
wire                      [31:0] header_ready_sampled_lfsr;
wire                      [15:0] header_ready_sampled_min_value;
wire                      [15:0] header_ready_sampled_count_value;
wire                       [7:0] header_ready_sampled_frame_number;
wire  [LP_HEADER_WIDTH *8 -1 :0] header_data;

wire sample_buff_full;



reg [3:0] num_csr_writes;

// CSR write
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        csr_wr_op       <= 1'b0;
        csr_rd_op       <= 1'b0;
        csr_addr        <= 0;
        csr_wdata       <= 0;

        output_enable   <= WAKE_UP_RUNNING[0];

        lfsr_mask        <= 'd0;
        count_min_value  <= 'd0;  // a prime number

        sample_timing_extension <= 'd0;
        num_csr_writes          <= 'd0;
    end else begin

        csr_wr_op <= csr_s_write;
        csr_rd_op <= csr_s_read;
        csr_addr  <= csr_s_address;
        csr_wdata <= csr_s_write_data;

 //CONCEPT: dynamic adjustment of min sampling value absed on backpressure...
        //if ((iut_rl0_ready == 1'b1) && (iut_st_valid == 1'b1) && (iut_st_eop == 1'b1)) begin
        //  end else if ((dropped_pixel_in_last_packet == 1'b1) && (was_image_packet== 1'b1)) begin
        //      if (count_min_value != {12{1'b1}}) begin
        //          count_min_value <= count_min_value + 'd1;
        //      end
        //  end else if (frame_number == 0) begin
        //          count_min_value <= count_min_value - 1'b1;
        //  end
        //end

        if (1'b1 == csr_wr_op) begin
            num_csr_writes <= num_csr_writes + 1'b1;
            case (csr_addr)
                'd4:     begin
                               output_enable           <= csr_wdata[0];
                               sample_timing_extension <= csr_wdata[9:8];
                         end

                'd5:     begin
                               lfsr_mask      [0+:MAX_COUNT_WIDTH] <= csr_wdata[0  +:MAX_COUNT_WIDTH];
                               count_min_value[0+:MAX_COUNT_WIDTH] <= csr_wdata[16 +:MAX_COUNT_WIDTH];
                         end

                default: begin       end
            endcase
        end
    end
end



// CSR read
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        csr_s_readdata  <= {32{1'b0}};
    end else begin
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
                       csr_s_readdata[ 0+:8]  <= MON_NUM_PIXELS   [0+:8];
                       csr_s_readdata[ 8+:8]  <= MON_PIXEL_WIDTH  [0+:8];
                       csr_s_readdata[16+:8]  <= MAX_COUNT_WIDTH  [0+:8];
                    end
               'd4: begin  //CONTROL
                        csr_s_readdata[0]   <= output_enable;
                        csr_s_readdata[9:8] <= sample_timing_extension;
                    end

               'd5: begin
                       csr_s_readdata[ 0+:MAX_COUNT_WIDTH] <= lfsr_mask       [0+:MAX_COUNT_WIDTH];
                       csr_s_readdata[16+:MAX_COUNT_WIDTH] <= count_min_value [0+:MAX_COUNT_WIDTH];
                    end
                default: begin
                          end
            endcase
        end
    end
end





// ***************************************************************************
// ** grab info from each control packet...
// ***************************************************************************
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        is_control_packet <= 1'b0;
    end else begin
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_eop)) begin
            is_control_packet <= 1'b0;
        end else if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_sop) && (4'hf == iut_st_data[3:0]) && (output_enable == 1'b1)) begin
            is_control_packet <= 1'b1;
        end
    end
end



always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        control_packet_sym_count <= {LP_SYM_COUNT_WIDTH{1'b0}};
    end else begin
        if (is_control_packet == 1'b0) begin
            control_packet_sym_count <= {LP_SYM_COUNT_WIDTH{1'b0}};
        end else begin
            if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (control_packet_sym_count != {LP_SYM_COUNT_WIDTH{1'b1}})) begin
                control_packet_sym_count <= control_packet_sym_count + 1'b1;
            end
        end
    end
end



// avalon streaming video packets protocol:
// if LSB nibble of first word is F => control, 0 => data.
//  if control then for the next ? symbols, extract a nubble for the LSB of each symbol this forms the wollowing feilds
//   Pixel width  [15:0]
//   pixel height [15:0]
//
// 1   width[15:12]
// 2   width[11:8]
// 3   width[7:4]
// 4   width[3:0]
// 5   height[15:12]
// 6   height[11:8]
// 7   height[7:4]
// 8   height[3:0]
// 9   interlacing[3:0]

//we should extract this for each control packet.. NOTE, only the control packet immediatey preceeding the data has the corect size!


always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        extracted_width       <= {16{1'b0}};
        extracted_height      <= {16{1'b0}};
        extracted_interlacing <=  {4{1'b0}};
    end else begin
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (control_packet_sym_count != {LP_SYM_COUNT_WIDTH{1'b1}}) && (is_control_packet == 1'b1)) begin : update
            integer i;
            for (i = 0; i < MON_NUM_PIXELS; i = i + 1) begin
                if (((control_packet_sym_count *MON_NUM_PIXELS) +i) < 9) begin
                      case  ((control_packet_sym_count *MON_NUM_PIXELS) +i)
                       'd0: begin  extracted_width[15:12] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd1: begin  extracted_width[11: 8] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd2: begin  extracted_width[ 7: 4] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd3: begin  extracted_width[ 3: 0] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd4: begin extracted_height[15:12] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd5: begin extracted_height[11: 8] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd6: begin extracted_height[ 7: 4] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd7: begin extracted_height[ 3: 0] <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                       'd8: begin extracted_interlacing   <= iut_st_data[MON_PIXEL_WIDTH*i +: 4]; end
                      endcase
                end
            end
        end
    end
end


// ***************************************************************************
// ** Detect and decode each data packet...
// ***************************************************************************

// work out if it is the start of an av_st_video data packet and assert was_image_packet for the duration.
// NOTE we wont detect 1 word packets!!!!
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        was_image_packet <= 1'b0;
        was_sop          <= 1'b0;
    end else begin
        was_sop          <= 1'b0;
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_eop)) begin
            was_image_packet <= 1'b0;
        end else if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1) && (1'b1 == iut_st_sop) && (4'h0 == iut_st_data[3:0]) && (output_enable == 1'b1)) begin
            was_image_packet <= 1'b1;
            was_sop          <= 1'b1;
        end
    end
end



always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        delayed_iut_st_data  <= {DATA_PORT_WIDTH{1'b0}};
        delayed_iut_st_eop   <= 1'b0;
        sample_now_aligned   <= 1'b0;
        valid_sample_aligned <= 1'b0;
    end else begin
        delayed_iut_st_eop <= iut_st_eop & iut_st_valid & iut_rl0_ready;
        if ((iut_st_valid == 1'b1) && (iut_rl0_ready == 1'b1)) begin
            delayed_iut_st_data <= iut_st_data;
        end
        sample_now_aligned    <= sample_now;
        valid_sample_aligned  <= valid_sample_data;
    end
end

assign valid_sample_data = was_image_packet & iut_rl0_ready & iut_st_valid;



// instantiate sample controller,  it deals with the sampling and randomised generation of when to sample as well as sampling the header values!
altera_trace_av_st_video_pxl_grab_smplr #(
      .MON_NUM_PIXELS    (MON_NUM_PIXELS)
     ,.MON_PIXEL_WIDTH   (MON_PIXEL_WIDTH)
     ,.FULL_TS_LENGTH    (FULL_TS_LENGTH)
     ,.MAX_LFSR_STEP     (MAX_COUNT_WIDTH)
) smplr_ctrl (
      .clk                     (clk)
     ,.arst_n                  (arst_n)
     ,.lfsr_mask               (lfsr_mask)
     ,.count_min_value         (count_min_value)
     ,.image_data_valid        (valid_sample_data)
     ,.image_data_start        (was_sop)
     ,.sample_timing_extension (sample_timing_extension)
     ,.sample_now              (sample_now)
     ,.sampled_ts              (sampled_ts)
     ,.frame_number            (sampled_frame_number)
     ,.sampled_count_value     (sampled_count_value)
     ,.sampled_min_value       (sampled_min_value)
     ,.sampled_lfsr_mask       (sampled_lfsr_mask)
     ,.sampled_lfsr_value      (sampled_lfsr)
     ,.sampled_values_updated  (header_write)
);




// ****************************************************************************
// **  Build the Header
// ****************************************************************************
// Build the header Byte
always @(*) begin
    // default
        encap_header_byte    = 'h80;                          // full TS no ED bits sent, no triggering or expansion bits set
        encap_header_byte[0] = dropped_output_event_message;  // set if we dropped previous message
        encap_header_byte[1] = dropped_pixel_in_last_packet;  // set if we dropped pixels off the end of the last packet
end


// Build the Timestamp
integer i;
always @(*) begin
        encap_ts_data = {(NUM_TS_SYMBOLS * 8) {1'b0}};
        // iner loop for the packing!
        for (i = 0; i < NUM_TS_SYMBOLS; i = i + 1) begin
            if (i == NUM_TS_SYMBOLS -1) begin
                encap_ts_data[(NUM_TS_SYMBOLS-(i+1))*8+:LP_MOD_TS_WIDTH] = sampled_ts[8*i +:LP_MOD_TS_WIDTH];
            end else begin
                encap_ts_data[(NUM_TS_SYMBOLS-i-1)*8+:8]                 = sampled_ts[8*i +:8];
            end
        end
end


// header before pixel is:  1 + timestamp      + lfsr + min + count + framenum  + height, width & interlacing
//                          1 + TS_SYMS        + 4    + 2   + 2     + 1
//localparam LP_HEADER_WIDTH = 1 + NUM_TS_SYMBOLS + 4 +  2     + 2     + 1        +5;

assign header_ready_sampled_lfsr         = {1'b1,{31{1'b0}}} | sampled_lfsr;
assign header_ready_sampled_min_value    = {16{1'b0}} | sampled_min_value;
assign header_ready_sampled_count_value  = {16{1'b0}} | sampled_count_value;
assign header_ready_sampled_frame_number = {8{1'b0}}  | sampled_frame_number;



// group all the header data into a single word.
assign header_data = {encap_header_byte,                     // 1Byte
                      encap_ts_data,                         // NUM_TS_SYMBOLS Bytes
                      header_ready_sampled_lfsr,             // 4 Bytes     LFSR is 31 bits..
                      header_ready_sampled_min_value,        // 2 Bytes     sampled_min_value    is 14 bits
                      header_ready_sampled_count_value,      // 2 Bytes     sampled_count_value  is 14 bits
                      header_ready_sampled_frame_number,     // 1 Byte
                      extracted_width,                       // 2 Bytes
                      extracted_height,                      // 2 Bytes
//                      {4{1'b0}}, extracted_interlacing       // 1 Bytes
                      num_csr_writes[3:0], extracted_interlacing[3:0]
                     };






// ****************************************************************************
// ** Control samplind and End of packet ready for the output module
// ****************************************************************************
// data reassembly module must flush whenever we see valid

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        have_sampled_in_video_packet   <= 1'b0;
        no_sample_flush                <= 1'b0;
    end else begin

 //       no_sample_flush <= (valid_sample_data & iut_st_eop & ~have_sampled_in_video_packet) | (no_sample_flush & header_write);
        no_sample_flush <= (valid_sample_aligned & delayed_iut_st_eop & ~have_sampled_in_video_packet) | (no_sample_flush & header_write);
		
		if (valid_sample_aligned & delayed_iut_st_eop & discard_data & have_sampled_in_video_packet) begin
			no_sample_flush <= 1'b1;
		end

        if (valid_sample_aligned & delayed_iut_st_eop) begin
            have_sampled_in_video_packet   <= 1'b0;
        end else if (sample_now_aligned & valid_sample_aligned) begin
            have_sampled_in_video_packet   <= 1'b1;
        end
    end
end





assign try_to_sample_this_delayed_data = valid_sample_aligned & sample_now_aligned;

wire set_dropped_output_event_message = (header_write_busy & header_write);
wire clear_dropped_output_event_message = (header_write & ~header_write_busy);
// Compute a "p1" version of dropped_output_event_message, so discard_data
// can deassert at the proper time. The p1 signal could be used in the
// register assignment below, but that might prevent synthesis from inferring
// a tidy set/reset structure. For now, maintain the p1 signal and register
// assignment in parallel.
wire p1_dropped_output_event_message =
  set_dropped_output_event_message ? 1'b1 :
  clear_dropped_output_event_message ? 1'b0 :
  dropped_output_event_message;

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        dropped_output_event_message   <= 1'b0;
    end else begin
        if (set_dropped_output_event_message) begin
            dropped_output_event_message <= 1'b1;
        end else if (clear_dropped_output_event_message) begin
            dropped_output_event_message <= 1'b0;
        end
    end
end


// now deal with storing and forwarding the sampled pixel values!!   this is wrong and oversimplified
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        dropped_pixel_in_last_packet <= 1'b0;
    end else begin
        if (sample_buff_full & write_sample) begin
            dropped_pixel_in_last_packet <= 1'b1;
        end else if (header_write & dropped_pixel_in_last_packet & ~header_write_busy) begin
            dropped_pixel_in_last_packet <= 1'b0;
        end
    end
end


// now deal with storing and forwarding the sampled pixel values!!   this is wrong and oversimplified
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        dropped_pixel_in_this_packet <= 1'b0;
    end else begin
        if (valid_sample_aligned & delayed_iut_st_eop) begin
            dropped_pixel_in_this_packet <= 1'b0;
        end else if (sample_buff_full & write_sample) begin
            dropped_pixel_in_this_packet <= 1'b1;
        end
    end
end






assign discard_data = (header_write_busy & header_write) |  p1_dropped_output_event_message;

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sample_data      <= {(MON_NUM_PIXELS * MON_PIXEL_WIDTH ){1'b0}};
        sample_valid     <= 1'b0;
        sample_was_eop   <= 1'b0;
    end else begin
    // flowcontrol
        if (write_sample | (sample_valid & delayed_iut_st_eop & valid_sample_aligned)) begin
            if (sample_buff_full) begin
                sample_was_eop <= 1'b1;    // this is for if we fail we still try to keep writing but, we will make it the end of packet
                sample_valid   <= 1'b1;
            end else begin
                sample_valid   <= 1'b0;
                sample_was_eop <= 1'b0;
            end
        end else if (sample_valid & delayed_iut_st_eop & ~write_sample) begin
            sample_was_eop <= 1'b1;
        end
        // new data
        if ((try_to_sample_this_delayed_data == 1'b1) && (sample_buff_full == 1'b0) && (discard_data == 1'b0)) begin
            sample_data    <= delayed_iut_st_data;
            //sample_data    <= iut_st_data;
            sample_valid   <= ~dropped_pixel_in_this_packet;
            sample_was_eop <= delayed_iut_st_eop & ~dropped_pixel_in_this_packet;
        end
    end
end




always @(*) begin
    if (sample_was_eop) begin
        write_sample = 1'b1;
    end else if (sample_valid & try_to_sample_this_delayed_data) begin
        write_sample = 1'b1;
    end else if (sample_valid & delayed_iut_st_eop) begin
        write_sample = 1'b1;
    end else begin
        write_sample = 1'b0;
    end
end


always @(*) begin
    if (sample_was_eop == 1'b1) begin
        write_sample_eop = 1'b1;
    end else if (sample_valid & delayed_iut_st_eop & valid_sample_aligned & (~sample_now_aligned)) begin
        write_sample_eop = 1'b1;
    end else if (try_to_sample_this_delayed_data & sample_valid & sample_buff_full) begin
        write_sample_eop = 1'b1;
    end else begin
        write_sample_eop = 1'b0;
    end
end


localparam LP_HEADER_SYM_WIDTH = $clog2(LP_HEADER_WIDTH+1) ;
// ****************************************************************************
// ** Implement the output module
// ****************************************************************************
// This module takes and serialises the header and all pixel packets as appropriate.
altera_trace_av_st_vpg_output #(
     .DEVICE_FAMILY       (DEVICE_FAMILY)
    ,.HEADER_SIZE         (LP_HEADER_WIDTH * 8)
    ,.SAMPLE_SIZE         (DATA_PORT_WIDTH)
    ,.TRACE_OUT_SYM_WIDTH (TRACE_OUT_SYM_WIDTH)
    ,.BUFF_ADDR_WIDTH     (BUFF_ADDR_WIDTH)
) output_packet (
     .clk                 (clk)
    ,.arst_n              (arst_n)
    ,.header_data         (header_data)
    ,.header_syms         (LP_HEADER_WIDTH[LP_HEADER_SYM_WIDTH-1:0])
    ,.header_write        (header_write)
    ,.header_write_busy   (header_write_busy)
    ,.no_sample_flush     (no_sample_flush)
    ,.sample_data         (sample_data)
    ,.sample_write        (write_sample)
    ,.sample_is_eop       (write_sample_eop)
    ,.sample_buff_full    (sample_buff_full)
    ,.av_st_tr_ready      (av_st_tr_ready)
    ,.av_st_tr_valid      (av_st_tr_valid)
    ,.av_st_tr_sop        (av_st_tr_sop)
    ,.av_st_tr_eop        (av_st_tr_eop)
    ,.av_st_tr_data       (av_st_tr_data)
    ,.av_st_tr_empty      (av_st_tr_empty)
);




endmodule
`default_nettype wire
