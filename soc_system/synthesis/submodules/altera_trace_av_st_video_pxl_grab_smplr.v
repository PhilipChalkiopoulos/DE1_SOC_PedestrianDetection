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
module altera_trace_av_st_video_pxl_grab_smplr #(
    parameter MON_NUM_PIXELS     = 1,
    parameter MON_PIXEL_WIDTH    = 30,

    parameter FULL_TS_LENGTH     = 40,     // Full resolution timestamp bitwidth // should be a multiple of 8 bits!
    parameter MAX_LFSR_STEP      = 12,

    // derived parameters
    parameter NUM_TS_SYMBOLS           = (FULL_TS_LENGTH    + 7)/8,
    parameter DAT_WIDTH_IN_SYMBOLS     = ((MON_PIXEL_WIDTH * MON_NUM_PIXELS) + 7)/8

) (
    input  wire                                          clk,
    input  wire                                          arst_n,

    input  wire                      [MAX_LFSR_STEP-1:0] lfsr_mask,
    input  wire                      [MAX_LFSR_STEP-1:0] count_min_value,

    input  wire                                          image_data_valid,
    input  wire                                          image_data_start,

    input  wire                                    [1:0] sample_timing_extension,

    output reg                                           sample_now,

    output reg                      [FULL_TS_LENGTH-1:0] sampled_ts,
    output reg                                     [6:0] frame_number,
    output reg                       [MAX_LFSR_STEP-1:0] sampled_count_value,
    output reg                       [MAX_LFSR_STEP-1:0] sampled_min_value,
    output reg                       [MAX_LFSR_STEP-1:0] sampled_lfsr_mask,
    output reg                                    [30:0] sampled_lfsr_value,
    output reg                                           sampled_values_updated

);





// Apply a dont mergeg attribute so that int_ts registers between differetn monitors are not merged! this should reduce spatial locality effects at the cost of some more registers.
(* dont_merge *) reg [FULL_TS_LENGTH-1:0] int_ts;


reg  [MAX_LFSR_STEP-1: 0] next_sample_count;
wire   [MAX_LFSR_STEP: 0] next_count_value;
wire             [30 : 0] lfsr_value;



reg lfsr_update_now;

// implement the LFSR generator...
// note we currently have no way of adjusting the PRBS pattern of loading an initialisation value.
altera_trace_av_st_vpg_lfsr_gen #(
     .LFSR_ADVANCE_SIZE (MAX_LFSR_STEP)
) lfsr (
     .clk               (clk)
    ,.arst_n            (arst_n)
    ,.prbs_23_n31_mode  (1'b1)
    ,.lfsr_load         (1'b0)
    ,.lfsr_load_val     ({31{1'b0}})
    ,.lfsr_advance      (image_data_valid & lfsr_update_now)
    ,.lfsr_val          (lfsr_value)
);


// NOTE: sizing so we get acarry out which we can use of overflow...
assign next_count_value = (lfsr_value[MAX_LFSR_STEP-1:0] & lfsr_mask[MAX_LFSR_STEP-1:0]) + count_min_value[MAX_LFSR_STEP-1:0];

// implement the next_sample count decrementing count.
// this counts how long untill we need to sample again..
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        next_sample_count <= 'd1;
    end else begin
        if (image_data_valid == 1'b1) begin  // CLKEN
            if ( (lfsr_update_now == 1'b1) && (next_count_value[MAX_LFSR_STEP] == 1'b1)) begin  // SLOAD   // sync preset
                next_sample_count <= {MAX_LFSR_STEP{1'b1}};
            end else begin
                if (lfsr_update_now == 1'b1) begin                                              // 2 input mux
                    next_sample_count <= next_count_value[MAX_LFSR_STEP-1:0];
                end else begin
                    next_sample_count <= next_sample_count - 1'b1;
                end
            end
        end
    end
end



always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        lfsr_update_now        <= 1'b0;
    end else begin
        if (image_data_valid == 1'b1) begin  //clken
            if (lfsr_update_now == 1'b1) begin
                if (   (next_count_value[MAX_LFSR_STEP] == 1'b0)                                                 // no overflow
                    && (count_min_value == 'd0)                                                                  //   These 2 lines form a 0-check but done in 2 paralell parts
                    && ((lfsr_value[MAX_LFSR_STEP-1:0] & lfsr_mask[MAX_LFSR_STEP-1:0]) == {MAX_LFSR_STEP{1'b0}}) //     rather than using next count value.
                   ) begin
                        lfsr_update_now <= 1'b1;
                end else begin
                    lfsr_update_now <= 1'b0;
                end
            end else begin
               if ('d0 == (next_sample_count >> 1) ) begin  // i.e. value is 0 or 1
                   lfsr_update_now <= 1'b1;
               end
            end
        end
    end
end





reg [1:0] samples_to_get;

//The sample now bit indicates that when it is asserted and a valus which can be sampled is availabe that it should be sampled.
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sample_now        <= 1'b0;
        samples_to_get    <= 2'b00;
    end else begin
        if (image_data_valid == 1'b1) begin  //clken
            if (sample_now == 1'b1) begin
                if (   (next_count_value[MAX_LFSR_STEP] == 1'b0)                                                 // no overflow
                    && (count_min_value == 'd0)                                                                  //   These 2 lines form a 0-check but done in 2 paralell parts
                    && ((lfsr_value[MAX_LFSR_STEP-1:0] & lfsr_mask[MAX_LFSR_STEP-1:0]) == {MAX_LFSR_STEP{1'b0}}) //     rather than using next count value.
                   ) begin
                        sample_now     <= 1'b1;
                        samples_to_get <= sample_timing_extension;
                end else begin
                    if (samples_to_get != 2'b00) begin
                        samples_to_get <= samples_to_get - 1'b1;
                    end else begin
                        sample_now <= 1'b0;
                    end
                end
            end else begin
               if ('d0 == (next_sample_count >> 1) ) begin  // i.e. value is 0 or 1
                   sample_now     <= 1'b1;
                   samples_to_get <= sample_timing_extension;
               end
            end
        end if (samples_to_get != sample_timing_extension) begin
            sample_now <= 1'b0;
        end
    end
end


// When we get the start of an image packet we need to stor a couple of values for the header.
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        sampled_count_value    <= {MAX_LFSR_STEP{1'b0}};
        sampled_min_value      <= {MAX_LFSR_STEP{1'b0}};
        sampled_lfsr_mask      <= {MAX_LFSR_STEP{1'b0}};
        sampled_lfsr_value     <= {31{1'b0}};
        frame_number           <= 0;
        sampled_values_updated <= 1'b0;
    end else begin
        sampled_values_updated <= 1'b0;
        if (image_data_start == 1'b1) begin
            sampled_count_value    <= next_sample_count;
            sampled_min_value      <= count_min_value;
            sampled_lfsr_mask      <= lfsr_mask;
            sampled_lfsr_value     <= lfsr_value;
            frame_number           <= frame_number + 1'b1;
            sampled_values_updated <= 1'b1;
        end
    end
end



// sampling control for timestamps
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
       sampled_ts           <= {FULL_TS_LENGTH{1'b0}};
    end else begin
        if (image_data_start == 1'b1) begin
            sampled_ts <= int_ts;
        end
    end
end


// Creation of the internal timestamp
// This slightly odd as we reset the TS to -1 instead of 0... this is so the timesamp aligns to that from the AV_ST monitor.
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
       int_ts <= {FULL_TS_LENGTH{1'b1}};
    end else begin
       int_ts <= int_ts + 1'b1;
    end
end

endmodule
`default_nettype wire
