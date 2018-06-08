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


//  Transacto-lite.
//  Small 32-bit Avalon MM Master, driven from debug pipe interface
//  designed to be Small & fast.
//
//
//   Protocol
//      DATA STREAM
//          The 1st 2 Bytes are common to read and write commands
//
//            byte     bit(s)      feild
//              1       7:6         opcode
//              1        5          Reserved
//              1       4:0         word_addr[12:8]
//              2       7:0         word_addr[7:0]
//
//
//      OPCODES
//                0b:10    write
//                0b:00    read
//
//      The initial address for a transaction is in word_addr. note it increments (with wrapping) after each mm_xaction
//
//
//      READ operations
//          The read command has an 3rd byte, this byte contains the number of reads to perform
//          Each read command performed on the MM interface will result in 4 Bytes being returned on the streaming debug out port.
//          The total length of the returned packet should be 4Bytes * the number of reads requested.
//          Errors can be flagged on the responding interface by returning a packet which does not have a length in bytes which is a multiple of 4.
//
//      WRITE operations
//          after the initial 2 Bytes 4 bytes of write data are sent. If a single write is wanted then a a 6 byte pacekt is sent.
//                                                                    for 2 writes then a 10 Byte packet should be sent
//          Acknowledgement of the last write is returned with a single byte packet of length 1.
//                  A value of 0x00 indicates sucsessful writes.
//
//
//      ERRORS
//          No error conditions are currently handled!
//
//
//
//
//      EXAMPLES:
//          this module receives a packet with 10 bytes: (0x81, 0xff, 0x00, 0x01, 0x02, 0x03, 0x10, 0x11, 0x12, 0x13)
//              the response packet should contain: 1 byte 0x01
//              there should have been 2 MM writes:
//                      addr 0x1ff  wdata: 0x03020100
//                      addr 0x000  wdata: 0x13121110       // NOTE ADDR WRAPPING!
//
//          This module receives a packet with 3 bytes (0xC3, 0x12, 0x02)
//              A response packet should be sent with 8 bytes of data
//              2 MM reads should have been initiated to addresses 0x312 & 0x313
//
//
//
//
//State machine  concept
//
//              IDLE
//
//              ADDR
//
//     wdata               rdlen
//
//     wdata_wait          rd
//
//     ack                 rd_wait
//
//
//
//
//   prioritization of design goals
//              SIZE
//              FMAX        (as otherwise a CDC may be required! defeating size goal).
//                                  S4GX230PCIE devkit: 400 Mhz min   500 MHz Stretch (arbitrary) goal! C2 speedgrade
//                                  C4 BemicroSDK     : 200 Mhz min   247 MHz stretch (RAM LIMIT)   C7 speedgrade
//              THROUGHPUT  (& protocol efficiency)
//
//
//
//  TODO:
//      ERRORS: what do we indicate....
//      enable port and flushing etc...
//      Byte enable support & extended addressing
//
//
//
//
//
//      This module:
//          State maching Synthesis...  SPR:397376
//               There are feedback paths I'm not expecting around the state machine!!    this also increases the LE count!
//               WORKAROUND 1/ set global setting for MUX_RESYNTHESIS to OFF
//                           2/ manually encode 1-hot state machine reg by reg!


`timescale 1ps / 1ps
`default_nettype none

module altera_trace_transacto_lite #(
    parameter ADDR_WIDTH            = 10,    // \         (word address!)
    parameter DEBUG_PIPE_WIDTH      = 8,     //  >     fixed for initial release
    parameter DATA_WIDTH            = 32,    // /
    parameter USE_RDV               = 1,

    // derived parameters
    parameter DATA_SYMBOLS_PER_WORD = DATA_WIDTH/8,
    parameter NUM_SYMBOLS_WIDTH     = $clog2(DATA_SYMBOLS_PER_WORD)
) (
    input  wire                         clk,
    input  wire                         arst_n,


    input  wire                         enable,
// debug pipe interfaces...
    output reg                          dbg_in_ready,
    input  wire                         dbg_in_valid,
    input  wire                         dbg_in_sop,
    input  wire                         dbg_in_eop,
    input  wire  [DEBUG_PIPE_WIDTH-1:0] dbg_in_data,

    input  wire                         dbg_out_ready,
    output reg                          dbg_out_valid,
    output reg                          dbg_out_sop,
    output reg                          dbg_out_eop,
    output wire  [DEBUG_PIPE_WIDTH-1:0] dbg_out_data,

//  Avalon MM interface
    output reg                          master_write,
    output reg                          master_read,
    output reg         [ADDR_WIDTH-1:0] master_address,
    output reg         [DATA_WIDTH-1:0] master_write_data,
    input  wire                         master_waitrequest,
    input  wire                         master_read_data_valid,   // is this strictly necessary?  TODO: does removing it have a beneficial hw size impact??
    input  wire        [DATA_WIDTH-1:0] master_readdata
);


localparam S_IDLE      = 3'd0;
localparam S_ADDR      = 3'd1;
localparam S_RDLEN     = 3'd2;
localparam S_R_WAIT    = 3'd3;
localparam S_RDATA     = 3'd4;
localparam S_WDATA     = 3'd5;
localparam S_WWAIT     = 3'd6;
localparam S_WACK      = 3'd7;

`define DBG_IN_READY_SPEEDUP 1



localparam  LP_READ_CNT_WIDTH = 8;
localparam  LP_ONE            = {32{1'b0}} | 'h1;

reg [2:0]                   state;
reg [LP_READ_CNT_WIDTH-1:0] read_cnt;
reg                         cmd_was_rd;
reg                         end_of_writes;

reg [NUM_SYMBOLS_WIDTH-1:0] data_phase_count;



reg read_cnt_is_zero;


always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        cmd_was_rd        <= 1'b0;
        end_of_writes     <= 1'b0;
    end else begin
        if(    (state == S_IDLE)
            && (dbg_in_valid == 1)
            && (dbg_in_sop == 1)
//          && (dbg_in_data[7] == 1)
           )begin
                cmd_was_rd <= ~dbg_in_data[7];
        end

        if (state == S_WDATA) begin
            if ((dbg_in_valid == 1'b1) && (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}})) begin
                end_of_writes     <= dbg_in_eop;
            end
        end
    end
end

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        // debug in IF
        dbg_in_ready      <= 1'b0;
    end else begin   // (posedge clk)
        case(state)
`ifndef DBG_IN_READY_SPEEDUP
 // these state goes to S_IDLE, therfore I can loose these cases for an efficiency hit!
           S_RDATA: begin
                        if ((dbg_out_ready == 1'b1 ) && (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}}) && (dbg_out_eop == 1'b1)) begin
                            dbg_in_ready   <= 1'b1;
                        end else begin
                            dbg_in_ready   <= 1'b0;
                        end
                     end

           S_WACK: begin
                            if ((dbg_out_ready == 1'b1) && (dbg_out_valid == 1'b1))begin
                                dbg_in_ready  <= 1'b1;
                            end else begin
                                dbg_in_ready  <= 1'b0;
                            end
                        end
`endif

           S_WDATA:  begin  // can change
                        if ((dbg_in_valid == 1'b1) && (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}})) begin
                            dbg_in_ready  <= 1'b0;   // change to w_wait
                        end else begin
                            dbg_in_ready <= 1'b1;
                        end
                     end

           S_RDLEN: begin
                        if (dbg_in_valid == 1) begin
                            dbg_in_ready   <= 1'b0;
                        end else begin
                            dbg_in_ready   <= 1'b1;
                        end
                    end

           S_IDLE: begin   // === idle  && address!!!!
                dbg_in_ready <= 1'b1;
           end

           S_ADDR: begin
                dbg_in_ready <= 1'b1;
           end

         // Fold S_R_WAIT & S_WWAIT into a default case.
         default: begin dbg_in_ready <= 1'b0; end
        endcase
    end
end




// if waitrewuest == 0 at any time then...
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
         master_read       <= 1'b0;
    end else begin
        if ((S_RDLEN == state) || (S_R_WAIT == state) || (S_RDATA == state)) begin
            if (S_R_WAIT == state) begin
                    master_read <= master_read & master_waitrequest;
            end else if (S_RDLEN == state) begin
                    master_read <= dbg_in_valid;
            end else begin
                    if ((dbg_out_ready == 1'b1 ) && (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}}) && (dbg_out_eop == 1'b0)) begin
                         master_read     <= 1'b1;
                    end else begin
                         master_read     <= 1'b0;
                    end
            end
        end else begin
            master_read       <= 1'b0;
        end
    end
end



always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
         master_write       <= 1'b0;
    end else begin
        if ((S_WDATA == state) || (S_WWAIT == state) ) begin
            if (state == S_WWAIT) begin
                master_write <= master_waitrequest;
            end else begin   //  (S_WDATA == state)
                 if ((dbg_in_valid == 1'b1) && (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}})) begin
                     master_write      <= 1'b1;
                 end else begin
                     master_write      <= 1'b0;
                 end
            end
        end else begin
            master_write       <= 1'b0;
        end
    end
end


always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        // internal regs
        state             <= S_IDLE;
        //debug out if
        dbg_out_sop       <= 1'b0;
        dbg_out_eop       <= 1'b0;
        dbg_out_valid     <= 1'b0;
    end else begin   // (posedge clk)
        case(state)
            S_ADDR: begin
                        if (dbg_in_valid == 1) begin
                            if (cmd_was_rd == 1) begin
                                state <= S_RDLEN;
                            end else begin
                                state <= S_WDATA;
                            end
                        end
                    end

            S_RDLEN: begin
                        if (dbg_in_valid == 1) begin
                            state          <= S_R_WAIT;
                            dbg_out_sop    <= 1'b1;
                        end
                     end

            S_R_WAIT: begin
                        dbg_out_eop <= 1'b0;
                        if (master_waitrequest == 0) begin
                            if (0 == USE_RDV) begin
                               state           <= S_RDATA;
                               dbg_out_valid   <= 1'b1;
                            end
                        end
                        if ((master_read_data_valid == 1'b1) && (1 == USE_RDV)) begin
                            state           <= S_RDATA;
                            dbg_out_valid   <= 1'b1;
                        end
                      end

            S_RDATA: begin
                        dbg_out_valid   <= 1'b1;

                        if (dbg_out_ready == 1'b1 ) begin
                            dbg_out_sop         <= 1'b0;
                            if (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}}) begin
                                dbg_out_valid   <= 1'b0;
                                if (dbg_out_eop == 1'b1) begin
                                    state          <= S_IDLE;
                                end else begin
                                    state          <= S_R_WAIT;
                                end
                            end

                            if ((read_cnt_is_zero == 1'b1) && (data_phase_count == LP_ONE[NUM_SYMBOLS_WIDTH-1:0]) )begin
                                dbg_out_eop <= 1'b1;
                            end else begin
                                dbg_out_eop <= 1'b0;
                            end
                        end
                     end


            S_WDATA: begin
                        if (dbg_in_valid == 1'b1) begin
                            if (data_phase_count == {NUM_SYMBOLS_WIDTH{1'b0}}) begin
                               state             <= S_WWAIT;
                            end
                        end
                     end

            S_WWAIT: begin
                        if (master_waitrequest == 0) begin
                            if (end_of_writes == 1'b1) begin
                                state         <= S_WACK;
                            end else begin
                                state         <= S_WDATA;
                            end
                        end
                     end

            S_WACK: begin
                            dbg_out_sop   <= 1'b1;
                            dbg_out_eop   <= 1'b1;
                            dbg_out_valid <= 1'b1;
                            if ((dbg_out_ready == 1'b1) && (dbg_out_valid == 1'b1))begin
                                dbg_out_valid <= 1'b0;
                                state         <= S_IDLE;
                            end
                    end

            default: begin   // === idle!!!!
                if (   (dbg_in_valid == 1'b1)
                	&& (dbg_in_ready == 1'b1)          // needed becaue of
                    && (dbg_in_sop   == 1'b1)
                   ) begin
                        state      <= S_ADDR;
                end
             end
        endcase
    end
end



always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        read_cnt <= 'd0;
        read_cnt_is_zero <= 1'b0;
    end else begin
        // done a re-balance between enable and datapath for fmax
        if (   ((master_read_data_valid == 1'b1) && (1 == USE_RDV))
            || ((master_waitrequest == 1'b0) && (0 == USE_RDV))
            || ((S_RDLEN  == state) && (dbg_in_valid == 1'b1))
            ) begin
            if ((S_RDLEN != state)) begin
                read_cnt        <= read_cnt - (S_R_WAIT == state);
            end else begin
                read_cnt       <= dbg_in_data[0+:LP_READ_CNT_WIDTH];
            end
        end

        if (read_cnt == 'd0) begin
            read_cnt_is_zero <= 1'b1;
        end else begin
            read_cnt_is_zero <= 1'b0;
        end
    end
end




(*keep = 1 *) wire [DATA_WIDTH-1:0] master_wdata_alt_ip;
assign master_wdata_alt_ip = (state == S_WDATA)?  {dbg_in_data, master_write_data[8+:(DATA_WIDTH-8)]} : master_write_data;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        master_write_data <= {DATA_WIDTH{1'b0}};
    end else begin
        if (    (S_R_WAIT == state)
             ||((state == S_WDATA) && (dbg_in_valid == 1'b1))
             ||((S_RDATA == state))
           ) begin
              if (S_R_WAIT == state) begin
                  master_write_data <= master_readdata;
              end else begin
                  if ((S_RDATA == state) && (dbg_out_ready == 1'b1)) begin
                      master_write_data <= {master_write_data[0+:8], master_write_data[8+:(DATA_WIDTH-8)]};
                  end else begin
                      master_write_data <= master_wdata_alt_ip;
                  end
              end
        end
    end
end




(* altera_attribute = "-name FORCE_SYNCH_CLEAR ON"*) reg [DEBUG_PIPE_WIDTH-1:0] dbg_out_data_reg;

(* keep = 1 *) wire dbg_out_data_clken;
assign dbg_out_data_clken = ((S_RDATA == state) || (S_R_WAIT == state) || (S_WACK == state)) ? 1'b1 : 1'b0;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        dbg_out_data_reg      <= {8{1'b0}};
    end else begin
      if (dbg_out_data_clken) begin  // clen
          if (state == S_WACK) begin // SCLR
                dbg_out_data_reg  <= {8{1'b0}};
          end else if (S_R_WAIT == state) begin   // sload
                dbg_out_data_reg  <= master_readdata[0 +:8];
          end else if (dbg_out_ready == 1'b1) begin
              dbg_out_data_reg <= master_write_data[8 +:8];
          end else begin
            dbg_out_data_reg <= dbg_out_data_reg;
          end
      end
    end
end

assign dbg_out_data = dbg_out_data_reg;




wire data_phase_count_dec;
assign data_phase_count_dec = (state == S_WDATA) ? dbg_in_valid : dbg_out_ready;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        data_phase_count <= {NUM_SYMBOLS_WIDTH{1'b0}};
    end else begin
        if ((state == S_WDATA) || (state == S_RDATA)) begin
            data_phase_count <= data_phase_count - data_phase_count_dec;
        end else begin
            data_phase_count <= {NUM_SYMBOLS_WIDTH{1'b1}};
        end
    end
end



reg incr_master_addr;
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        incr_master_addr <= 1'b0;
    end else begin
        if (    ((S_RDATA == state) && (data_phase_count == LP_ONE[NUM_SYMBOLS_WIDTH-1:0]) && (dbg_out_ready == 1'b1 ))
             || ((state == S_WWAIT)  && (master_waitrequest == 0))
           ) begin
                incr_master_addr <= 1'b1;
        end else begin
                incr_master_addr <= 1'b0;
        end
    end
end


wire [ADDR_WIDTH-1:0] addr_add_one;
assign addr_add_one = master_address + 1'b1;

localparam SAFE_ADDR_WIDTH_SUB8 = (ADDR_WIDTH > 8) ? (ADDR_WIDTH -8) : 1;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        master_address    <= {ADDR_WIDTH{1'b0}};
    end else begin
        if (ADDR_WIDTH > 8) begin
            if ((dbg_in_valid == 1) && (state == S_IDLE )) begin
                master_address[ADDR_WIDTH-1 -: SAFE_ADDR_WIDTH_SUB8]      <= dbg_in_data [0 +: SAFE_ADDR_WIDTH_SUB8];
            end else begin
                if (incr_master_addr == 1)
                    master_address[ADDR_WIDTH-1 -: SAFE_ADDR_WIDTH_SUB8]  <= addr_add_one[ADDR_WIDTH-1 -: SAFE_ADDR_WIDTH_SUB8];
            end
        end

        if ((dbg_in_valid == 1) && (state == S_ADDR)) begin
            master_address[0+:((ADDR_WIDTH>8) ? 8 : ADDR_WIDTH)]     <= dbg_in_data [0 +: ((ADDR_WIDTH>8) ? 8 : ADDR_WIDTH)];
        end else begin
            if (incr_master_addr == 1)
                master_address[0+:((ADDR_WIDTH>8) ? 8 : ADDR_WIDTH)] <= addr_add_one[0+:((ADDR_WIDTH>8) ? 8 : ADDR_WIDTH)];
        end

    end
end




endmodule
`default_nettype wire
