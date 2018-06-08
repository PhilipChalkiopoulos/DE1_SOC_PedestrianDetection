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


// altera message_level level1
// (C) 2001-2013 Altera Corporation. All rights reserved.
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

 
// $Id: //acds/rel/13.1/ip/.../avalon-st_multiplexer.sv.terp#1 $
// $Revision: #1 $
// $Date: 2013/09/09 $
// $Author: dmunday $


// --------------------------------------------------------------------------------
//| Avalon Streaming Multiplexer
// --------------------------------------------------------------------------------


`timescale 1ns / 100ps
// ------------------------------------------
// Generation parameters:
//   output_name:        soc_system_trace_system_0_tracesys_capture_mux0
//   use_packets:        true
//   use_empty:          1
//   empty_width:        2
//   data_width:         32
//   channel_width:      3
//   error_width:        0
//   num_inputs:         5
//   inChWidth:          0
//   selectWidth:        3
//   selectBits:         3-1:0
//   channelSelectBits:  3-1:0
//   inPayloadMap:       in0_data,in0_startofpacket,in0_endofpacket,in0_empty in1_data,in1_startofpacket,in1_endofpacket,in1_empty in2_data,in2_startofpacket,in2_endofpacket,in2_empty in3_data,in3_startofpacket,in3_endofpacket,in3_empty in4_data,in4_startofpacket,in4_endofpacket,in4_empty
//   outPayloadMap:      out_data,out_startofpacket,out_endofpacket,out_empty
//   inPayloadWidth:     36
//   use_packet_scheduling: true
//   schedulingSize:        2
//   schedulingSizeInBits:     1   
//   
// ------------------------------------------


module soc_system_trace_system_0_tracesys_capture_mux0 (     
// Interface: out
 output reg     [3-1: 0] out_channel,
 output reg              out_valid,
 input                   out_ready,
 output reg    [32-1: 0] out_data,
 output reg              out_startofpacket,
 output reg              out_endofpacket,
 output reg    [2-1 : 0] out_empty,

// Interface: in0
 input           in0_valid,
 output reg      in0_ready,
 input [32-1: 0] in0_data,
           
 input           in0_startofpacket,
 input           in0_endofpacket, 
 input [2-1: 0]  in0_empty,
// Interface: in1
 input           in1_valid,
 output reg      in1_ready,
 input [32-1: 0] in1_data,
           
 input           in1_startofpacket,
 input           in1_endofpacket, 
 input [2-1: 0]  in1_empty,
// Interface: in2
 input           in2_valid,
 output reg      in2_ready,
 input [32-1: 0] in2_data,
           
 input           in2_startofpacket,
 input           in2_endofpacket, 
 input [2-1: 0]  in2_empty,
// Interface: in3
 input           in3_valid,
 output reg      in3_ready,
 input [32-1: 0] in3_data,
           
 input           in3_startofpacket,
 input           in3_endofpacket, 
 input [2-1: 0]  in3_empty,
// Interface: in4
 input           in4_valid,
 output reg      in4_ready,
 input [32-1: 0] in4_data,
           
 input           in4_startofpacket,
 input           in4_endofpacket, 
 input [2-1: 0]  in4_empty,
  // Interface: clk
 input              clk,
 // Interface: reset
 input              reset_n

/*AUTOARG*/);

   // ---------------------------------------------------------------------
   //| Signal Declarations
   // ---------------------------------------------------------------------
   reg [36 -1:0]      in0_payload;
   reg [36 -1:0]      in1_payload;
   reg [36 -1:0]      in2_payload;
   reg [36 -1:0]      in3_payload;
   reg [36 -1:0]      in4_payload;
 
   reg [3-1:0]        decision = 0;
   reg [3-1:0]        select = 0;   
   reg                selected_endofpacket = 0;
   reg                selected_valid;
   wire               out_valid_wire;
   wire               selected_ready;
   reg   [36 -1 :0]   selected_payload;  
   reg                packet_in_progress;
   wire [3-1:0]       out_select;   
   wire [36 - 1:0]    out_payload;

   // ---------------------------------------------------------------------
   //| Input Mapping
   // ---------------------------------------------------------------------
   always @* begin
     in0_payload = {in0_data,in0_startofpacket,in0_endofpacket,in0_empty};
     in1_payload = {in1_data,in1_startofpacket,in1_endofpacket,in1_empty};
     in2_payload = {in2_data,in2_startofpacket,in2_endofpacket,in2_empty};
     in3_payload = {in3_data,in3_startofpacket,in3_endofpacket,in3_empty};
     in4_payload = {in4_data,in4_startofpacket,in4_endofpacket,in4_empty};
   end
   
   // ---------------------------------------------------------------------
   //| Scheduling Algorithm
   // ---------------------------------------------------------------------
   always @* begin
         
      decision = 0;
      case(select) 
         0 : begin
            if (in0_valid) decision = 0;
            if (in4_valid) decision = 4;
            if (in3_valid) decision = 3;
            if (in2_valid) decision = 2;
            if (in1_valid) decision = 1;
         end  
         1 : begin
            if (in1_valid) decision = 1;
            if (in0_valid) decision = 0;
            if (in4_valid) decision = 4;
            if (in3_valid) decision = 3;
            if (in2_valid) decision = 2;
         end  
         2 : begin
            if (in2_valid) decision = 2;
            if (in1_valid) decision = 1;
            if (in0_valid) decision = 0;
            if (in4_valid) decision = 4;
            if (in3_valid) decision = 3;
         end  
         3 : begin
            if (in3_valid) decision = 3;
            if (in2_valid) decision = 2;
            if (in1_valid) decision = 1;
            if (in0_valid) decision = 0;
            if (in4_valid) decision = 4;
         end  
         4 : begin
            if (in4_valid) decision = 4;
            if (in3_valid) decision = 3;
            if (in2_valid) decision = 2;
            if (in1_valid) decision = 1;
            if (in0_valid) decision = 0;
         end  
         default : begin // Same as '0', should never get used.
            if (in0_valid) decision = 0;
            if (in4_valid) decision = 4;
            if (in3_valid) decision = 3;
            if (in2_valid) decision = 2;
            if (in1_valid) decision = 1;
         end  
      endcase   
   end

   // ---------------------------------------------------------------------
   //| Capture Decision
   // ---------------------------------------------------------------------
   always @ (negedge reset_n, posedge clk) begin
      if (!reset_n) begin
         select <= 0;
         packet_in_progress <= 0;
      end else begin
         if (!selected_valid && !packet_in_progress) begin
            select <= decision;
         end else begin
            packet_in_progress <= 1;
         end
         if (selected_endofpacket && selected_valid && selected_ready) begin
            select <= decision;
            packet_in_progress <= 0;
         end
      end
   end



   // ---------------------------------------------------------------------
   //| Mux
   // ---------------------------------------------------------------------
   always @* begin
      case(select) 
         0 : begin
            selected_payload = in0_payload;         
            selected_valid   = in0_valid;
            selected_endofpacket = in0_endofpacket;
         end  
         1 : begin
            selected_payload = in1_payload;         
            selected_valid   = in1_valid;
            selected_endofpacket = in1_endofpacket;
         end  
         2 : begin
            selected_payload = in2_payload;         
            selected_valid   = in2_valid;
            selected_endofpacket = in2_endofpacket;
         end  
         3 : begin
            selected_payload = in3_payload;         
            selected_valid   = in3_valid;
            selected_endofpacket = in3_endofpacket;
         end  
         4 : begin
            selected_payload = in4_payload;         
            selected_valid   = in4_valid;
            selected_endofpacket = in4_endofpacket;
         end  
         default : begin
            selected_payload = in0_payload;         
            selected_valid = in0_valid;
            selected_endofpacket = in0_endofpacket;
         end
      endcase

   end

   // ---------------------------------------------------------------------
   //| Back Pressure
   // ---------------------------------------------------------------------
   always @* begin
      in0_ready <= ~in0_valid;
      in1_ready <= ~in1_valid;
      in2_ready <= ~in2_valid;
      in3_ready <= ~in3_valid;
      in4_ready <= ~in4_valid;
      case(select)
      0 : in0_ready <= selected_ready;
      1 : in1_ready <= selected_ready;
      2 : in2_ready <= selected_ready;
      3 : in3_ready <= selected_ready;
      4 : in4_ready <= selected_ready;
      default : in0_ready <= selected_ready;

endcase // case (select)
end // always @ *

   // ---------------------------------------------------------------------
   //| output Pipeline
   // ---------------------------------------------------------------------
   soc_system_trace_system_0_tracesys_capture_mux0_1stage_pipeline  #( .PAYLOAD_WIDTH( 36 + 3 ) ) outpipe
              ( .clk      (clk ),
                .reset_n  (reset_n  ),
                .in_ready ( selected_ready ),
                .in_valid ( selected_valid ),
                .in_payload ({select,selected_payload}),
                .out_ready(out_ready ),
                .out_valid(out_valid_wire),
                .out_payload({out_select,out_payload}) );


   // ---------------------------------------------------------------------
   //| Output Mapping
   // ---------------------------------------------------------------------
   always @* begin
      out_valid   = out_valid_wire;
      out_channel[3-1:0] = out_select;
      {out_data,out_startofpacket,out_endofpacket,out_empty} = out_payload;
   end
endmodule //

//  --------------------------------------------------------------------------------
// | single buffered pipeline stage
//  --------------------------------------------------------------------------------
module soc_system_trace_system_0_tracesys_capture_mux0_1stage_pipeline
  #( parameter PAYLOAD_WIDTH = 8 )
    ( input                             clk,
         input                          reset_n,
         output reg                     in_ready,
         input                          in_valid,
         input      [PAYLOAD_WIDTH-1:0] in_payload,
         input                          out_ready,
         output reg                     out_valid,
         output reg [PAYLOAD_WIDTH-1:0] out_payload
      );
   reg                                  in_ready1;


   always @* begin
      in_ready = out_ready || ~out_valid;
      //     in_ready = in_ready1;
      //     if (!out_ready)
      //       in_ready = 0;
   end
   always @ (negedge reset_n, posedge clk) begin
      if (!reset_n) begin
         in_ready1 <= 0;
         out_valid <= 0;
         out_payload <= 0;
      end else begin
         in_ready1 <= out_ready || !out_valid;
         if (in_valid) begin
            out_valid <= 1;
         end else if (out_ready) begin
            out_valid <= 0;
         end
         if(in_valid && in_ready) begin
            out_payload <= in_payload;
         end
      end // else: !if(!reset_n)
   end // always @ (negedge reset_n, posedge clk)

endmodule //

