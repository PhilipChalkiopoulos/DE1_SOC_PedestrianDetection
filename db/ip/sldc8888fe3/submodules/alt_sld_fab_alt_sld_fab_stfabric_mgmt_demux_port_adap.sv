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

 
// $Id: //acds/rel/13.1/ip/.../avalon-st_channel_adapter.sv.terp#1 $
// $Revision: #1 $
// $Date: 2013/09/09 $
// $Author: dmunday $

// --------------------------------------------------------------------------------
//| Avalon Streaming Channel Adapter
// --------------------------------------------------------------------------------

`timescale 1ns / 100ps

// ------------------------------------------
// Generation parameters:
//   output_name:         alt_sld_fab_alt_sld_fab_stfabric_mgmt_demux_port_adap
//   in_channel_width:    1
//   in_max_channel:      1
//   out_channel_width:   0
//   out_max_channel:     0
//   data_width:          1
//   error_width:         0
//   use_ready:           true
//   use_packets:         false
//   use_empty:           0
//   empty_width:         0

// ------------------------------------------


module alt_sld_fab_alt_sld_fab_stfabric_mgmt_demux_port_adap 
(
 // Interface: in
 output reg         in_ready,
 input              in_valid,
 input              in_data,
 input              in_channel,
 // Interface: out
 input               out_ready,
 output reg          out_valid,
 output reg          out_data,
  // Interface: clk
 input              clk,
 // Interface: reset
 input              reset_n
 
 
);

    reg out_channel;

   // ---------------------------------------------------------------------
   //| Payload Mapping
   // ---------------------------------------------------------------------
   always @* begin
      in_ready = out_ready;
      out_valid = in_valid;
      out_data = in_data;

      out_channel = in_channel; //TODO delete this to avoid Quartus warnings

      // Suppress channels that are higher than the destination's max_channel.
      if (in_channel > 0) begin
         out_valid = 0;
         // Simulation Message goes here.
      end
   end

endmodule

