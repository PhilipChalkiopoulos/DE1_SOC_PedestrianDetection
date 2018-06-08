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


// timestamp request generator module
//   this module is designed to toggle the timestamp request output (clk called async_ts_sync_clk) as a result of:
//     1/ periodic interval elapsing
//     2/ user request.


`timescale 1ps / 1ps
`default_nettype none
module altera_trace_ts_req_generator #(
    parameter COUNTER_WIDTH           = 32,
    parameter PRECOUNT_WIDTH          = 4,    // the pre-counter scales the coutner value by a multiplier
    parameter PERIODIC_TS_REQ_STARTUP = 3     //  e.g. a width of 1 means a multiply the periodic value by 2, width of 4 would be x16
) (                                           
    input  wire                        clk,
    input  wire                        arst_n,

    output wire                        async_ts_sync_clk,

// periodic interval controls
    input  wire [COUNTER_WIDTH-1 :0]   counter_rst_value,
    input  wire                        counter_en,

// manual toggle request
    input  wire                        toggle_output
);

//  the percoutner enable decides in which cycles the coutner can update!
wire                       precounter_out_enable;

// the main counter and toggle signal.
reg [COUNTER_WIDTH-1 : 0]  counter;
reg                        counter_toggle;


// make the reg internal and use a wire so we could embed an SDC constraint here!
//     constraint could be a set_max_skew or a max_delay/ min_delay constraint!  BUT: this could mess up same clock domain....
(* altera_attribute = {"-name SDC_STATEMENT \"set_max_delay -from [get_registers {*|altera_trace_ts_req_generator:capture_ts_generator|async_ts_sync_clk_reg}] -to [get_registers {*}] 4.0\"; -name SDC_STATEMENT \"set_min_delay -from [get_registers {*|altera_trace_ts_req_generator:capture_ts_generator|async_ts_sync_clk_reg}] -to [get_registers {*}] 0.0\""} *)
reg                        async_ts_sync_clk_reg;

assign                     async_ts_sync_clk = async_ts_sync_clk_reg;

// this generate is here for if we are using the precounter,
generate
    if (0 == PRECOUNT_WIDTH) begin : g_no_precounter
        assign precounter_out_enable = 1'b1;

    end else begin : g_precounter
        reg [PRECOUNT_WIDTH-1 : 0] precounter;
        reg                        precounter_out;


        always @(posedge clk or negedge arst_n) begin
            if (0 == arst_n) begin
                precounter     <= {PRECOUNT_WIDTH{1'b0}};
                precounter_out <= 1'b0;
            end else begin
                precounter_out <= 1'b0;
                if (1'b0 == counter_en) begin
                    precounter <= {PRECOUNT_WIDTH{1'b1}};
                end else begin
                    precounter <= precounter - 1'b1;
                    if (precounter == 'd1) begin
                        precounter_out <= 1'b1;
                    end
                end
            end
        end

        assign precounter_out_enable = precounter_out;
    end
endgenerate


// implement the coutner
   always @(posedge clk or negedge arst_n) begin
       if (0 == arst_n) begin
        counter        <= PERIODIC_TS_REQ_STARTUP[COUNTER_WIDTH-1:0];
        counter_toggle <= 1'b0;
       end else begin
          counter_toggle <= 1'b0;
          if ((1'b0 == counter_en)  || (counter_toggle == 1'b1)) begin
             counter <= counter_rst_value;
          end else if (precounter_out_enable == 1) begin
             if (counter < 2) begin  //i.e.  1 or 0
                counter_toggle <= 1'b1;
             end
             counter <= counter - 1'b1;
          end
       end
   end


// implement the output register!
   always @(posedge clk or negedge arst_n) begin
       if (0 == arst_n) begin
            async_ts_sync_clk_reg <= 1'b0;
       end else begin
            if (   (counter_toggle == 1'b1)
                || (toggle_output  == 1'b1)
               ) begin
               async_ts_sync_clk_reg <= ~async_ts_sync_clk_reg;
            end
// synthesis translate_off
            if (   (counter_toggle == 1'b1)
                && (toggle_output  == 1'b1)
               ) begin
               $fatal("Software should not be manually requesting timestamps when periodic service is enabled! TIMESTAMP NOT REQUESTED");
            end else if ((toggle_output == 1'b1) && (counter_en == 1'b1)) begin
               $error("Software should not be manually requesting timestamps when periodic service is enabled!");
            end

// synthesis translate_on
       end
   end


endmodule
