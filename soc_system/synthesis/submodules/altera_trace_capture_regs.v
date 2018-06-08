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




// TODO:
//        Add the ability to flush the read pipe and stop sending data back to the host.
//
//        do we add some error detection and readback for it?
//           e.g. current input channel (to detect lockup on input prior to this module)
//           input protocol err: e.g. empty != 0 if eop == 0

module altera_trace_capture_regs #(
   parameter CREDIT_WIDTH                            = 1,
   parameter CORE_REVISION                           = 0,
   parameter TRACE_DATA_WIDTH                        = 1,
   parameter TRACE_ADDR_WIDTH                        = 1,
   parameter NUM_PPD                                 = 1,
   parameter PACKET_LEN_BITS                         = 1,
   parameter TRACE_CHNL_WIDTH                        = 1,
   parameter MAX_OUT_PACKET_LENGTH                   = 1,
   parameter PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH      = 1,
   parameter PERIODIC_TS_SYNC_CLK_PRE_COUNTER_WIDTH  = 1,

   parameter WAKE_UP_MODE                            = "IDLE",   // IDLE, CAPTURE, FIFO
   parameter PERIODIC_TS_REQ_STARTUP                 = 0,        // 0 = periodic_ts, other value = periodic_ts_interval

   parameter RD_AND_WR_FILL_LVL_SIZE                 = 0,
// TODO: add these in:
   parameter DEBUG_READBACK                          = 1,
   parameter BUFFER_START_ADDR                       = 1,
   parameter BUFFER_SIZE                             = 1,
   parameter HDR_PTR_SIZE                            = 11
   
   // do we add state readback....
   // reacback for current input channel, to help diagnose if anything is happening......
   
   
) (
    input  wire clk,
    input  wire arst_n,

    input  wire                                          csr_s_write,
    input  wire                                          csr_s_read,
    input  wire                                    [5:0] csr_s_address,
    input  wire                                   [31:0] csr_s_write_data,
    output reg                                    [31:0] csr_s_readdata,


// CSR WDATA ouptuts
    // control reg
    output reg                                           mode,

//    output reg                                           enable_direct_store_mode,

    output reg                                           start,
    output reg                                           stop,
    output reg                                           trigger_en,
    output reg                                           enable_capture_output,    

    // timesync control
    output reg                                           ts_sync_clk_periodic_enable,
    output reg                                           ts_sync_clk_toggle_enable,
    output reg  [PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH-1:0] ts_sync_clk_periodic_count,

    // credit control
    output reg                                           credit_update,
    output reg                                           clear_read_credits,
    output reg                        [CREDIT_WIDTH-1:0] add_credits_value,

// CSR RDATA inputs
   // status register
    input  wire                                          system_active,
    input  wire                                          buffer_wrapped,
    input  wire                                          wr_control_en,
    input  wire                                          hdr_parse_en,
    input  wire                                          rd_control_en,
    input  wire                                          wr_pipe_empty,
    input  wire                                          read_empty,

// buffer FILL level information
    input  wire                [TRACE_ADDR_WIDTH -1 : 0] start_ptr,
    input  wire                [TRACE_ADDR_WIDTH -1 : 0] write_ptr,
    input  wire                [TRACE_ADDR_WIDTH -1 : 0] read_ptr,
    input  wire           [RD_AND_WR_FILL_LVL_SIZE  : 0] write_fill_level,
    input  wire           [RD_AND_WR_FILL_LVL_SIZE  : 0] read_fill_level,

    // credit info
    input  wire                       [CREDIT_WIDTH-1:0] current_num_credits,

    // triggering info
    output reg                [TRACE_ADDR_WIDTH -1 : 0] post_trigger_num_words,
    input  wire                                         trigger_condition_det,
    input  wire                                         post_trigger_buffering_complete,
    input  wire               [TRACE_ADDR_WIDTH -1 : 0] trigger_words_remaining,          // probably not used!
    
    output reg                                          force_single_cell_per_pkt,
    
    input  wire                                 [2 : 0] capture_state
);


// Register location definitions
localparam LP_VERSION_REG          = 'h00;
localparam LP_CONFIGURATRION_REG_1 = 'h04;
localparam LP_CONFIGURATRION_REG_2 = 'h08;
localparam LP_CONFIGURATRION_REG_3 = 'h0C;

localparam LP_CONFIGURATRION_REG_4 = 'h10;
localparam LP_CONFIGURATRION_REG_5 = 'h14;


localparam LP_CONTROL_REG          = 'h20;
localparam LP_TIMESYNC_CTRL_REG    = 'h24;
localparam LP_TIMESYNC_COUTNER_REG = 'h28;
localparam LP_CREDIT_CTRL_REG      = 'h30;
localparam LP_POST_TRIGGER_WRDS    = 'h34;

localparam LP_RD_PTR_REG           = 'h40;
localparam LP_WR_PTR_REG           = 'h44;
localparam LP_START_PTR_REG        = 'h48;

localparam LP_FILL_LVL_REG         = 'h4C;
localparam LP_TRIG_WRDS_REMAIN     = 'h50;


(* dont_merge *) reg                              csr_wr_op;
(* dont_merge *) reg                              csr_rd_op;
(* dont_merge *) reg                        [5:0] csr_addr;
(* dont_merge *) reg                       [31:0] csr_wdata;
// pipelining for control

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        csr_addr  <= {6{1'b0}};
        csr_wr_op <= 1'b0;
        csr_rd_op <= 1'b0;
        csr_wdata <= {32{1'b0}};
    end else begin
        csr_wr_op <= csr_s_write;
        csr_rd_op <= csr_s_read;
        csr_addr  <= csr_s_address;
        csr_wdata <= csr_s_write_data;
    end
end


// csr wdata
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        ts_sync_clk_toggle_enable   <= 1'b0;
        ts_sync_clk_periodic_enable <= |PERIODIC_TS_REQ_STARTUP[PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH-1:0];
        ts_sync_clk_periodic_count  <= PERIODIC_TS_REQ_STARTUP[PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH-1:0];

        credit_update               <= 1'b0;
        clear_read_credits          <= 1'b0;
        add_credits_value           <= {CREDIT_WIDTH{1'b0}};

        mode                        <= (WAKE_UP_MODE == "FIFO") ? 1'b1 : 1'b0;
        //enable_direct_store_mode    <= 1'b0;
        start                       <= (WAKE_UP_MODE != "IDLE")? 1'b1 : 1'b0;
        stop                        <= 1'b0;
        trigger_en                  <= 1'b0;
        enable_capture_output       <= 1'b0;

        post_trigger_num_words      <= {TRACE_ADDR_WIDTH{1'b0}};
        
        force_single_cell_per_pkt   <= 1'b0;
    end else begin
        // WC bits
        ts_sync_clk_toggle_enable   <= 1'b0;
        credit_update               <= 1'b0;
        clear_read_credits          <= 1'b0;
        start                       <= 1'b0;
        stop                        <= 1'b0;

        // write operation
        if (1'b1 == csr_wr_op) begin
            case (csr_addr[0+:5])

                LP_CONTROL_REG[2+:5]:
                     begin
                         if ((system_active == 1'b0) && (start == 1'b0)) begin
                             mode   <= csr_wdata[0];
                         end
                         trigger_en                 <= csr_wdata[1];
                         enable_capture_output      <= csr_wdata[2];                           
                         start                      <= csr_wdata[8];
                         stop                       <= csr_wdata[9];                        
                         
                         force_single_cell_per_pkt  <= csr_wdata[20];
                     end


                LP_TIMESYNC_CTRL_REG[2+:5]:
                    begin
                         ts_sync_clk_periodic_enable <= csr_wdata[0];
                         ts_sync_clk_toggle_enable   <= csr_wdata[1];
// synthesis translate_off
                         if (csr_wdata[0] & csr_wdata[1])
                             $error("Illegal write operation: Attmpting to toggle TS_CLK output and enable the periodic count simultaneousey!");
// synthesis translate_on
                     end


                LP_TIMESYNC_COUTNER_REG[2+:5]:
                     begin
                         ts_sync_clk_periodic_count <= csr_wdata[0+:PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH];
                     end


                LP_CREDIT_CTRL_REG[2+:5]:
                     begin
                          credit_update                       <= 1'b1;
                          clear_read_credits                  <= csr_wdata[31];
                          add_credits_value[0+: CREDIT_WIDTH] <= csr_wdata[0+: CREDIT_WIDTH];
                     end

                LP_POST_TRIGGER_WRDS[2+:5]:
                     begin
                         post_trigger_num_words[0+:TRACE_ADDR_WIDTH] <= csr_wdata[0+:TRACE_ADDR_WIDTH];
                     end

                default:
                     begin
// synthesis translate_off
                            $error("write to an undefined register");
// synthesis translate_on
                     end
            endcase
        end
    end
end




// CSR readdata
always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        csr_s_readdata              <= {32{1'b0}};
    end else begin
        if (1'b1 == csr_rd_op) begin
            csr_s_readdata <= {32{1'b0}};   //TODO: should this be default or clk_enabeled...
            case (csr_addr[0+:5])

                LP_VERSION_REG[2+:5]:
                     begin
                         csr_s_readdata[ 0+:8]  <= CORE_REVISION[0+:8];
                     end


                LP_CONFIGURATRION_REG_1[2+:5]:
                     begin
                         csr_s_readdata[ 0+:8]  <= TRACE_CHNL_WIDTH[   0+:8];
                         csr_s_readdata[ 8+:8]  <= PACKET_LEN_BITS[    0+:8];
                         csr_s_readdata[16+:8]  <= NUM_PPD[            0+:8];
                         csr_s_readdata[24+:8]  <= TRACE_DATA_WIDTH[   3+:8];
                     end


                LP_CONFIGURATRION_REG_2[2+:5]:
                     begin
                         csr_s_readdata[ 0+:8]  <= PERIODIC_TS_SYNC_CLK_PRE_COUNTER_WIDTH[0+:8];
                         csr_s_readdata[ 8+:8]  <= PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH[    0+:8];
                         csr_s_readdata[16+:8]  <= CREDIT_WIDTH[                          0+:8];
                         csr_s_readdata[24+:8]  <= MAX_OUT_PACKET_LENGTH[                 0+:8];
                     end


                LP_CONFIGURATRION_REG_3[2+:5]:
                     begin
                         csr_s_readdata[ 0+:8]  <= TRACE_ADDR_WIDTH[0+:8];
                         csr_s_readdata[ 8+:8]  <= RD_AND_WR_FILL_LVL_SIZE[0+:8];
                         csr_s_readdata[16]     <= (DEBUG_READBACK == 0) ? 1'b0 : 1'b1;
                     end


                LP_CONFIGURATRION_REG_4[2+:5]:
                     begin
                         csr_s_readdata[TRACE_ADDR_WIDTH-1:0] <= BUFFER_START_ADDR[TRACE_ADDR_WIDTH-1:0];
                     end


                LP_CONFIGURATRION_REG_5[2+:5]:
                     begin
                         csr_s_readdata[TRACE_ADDR_WIDTH:0] <= BUFFER_SIZE[TRACE_ADDR_WIDTH:0];
                     end

                     
                LP_CONTROL_REG[2+:5]:
                     begin
                         // control readback
                         csr_s_readdata[ 0]     <= mode;
                         csr_s_readdata[ 1]     <= trigger_en;
                         csr_s_readdata[ 2]     <= enable_capture_output;
                         // status readback

                         csr_s_readdata[14:12]  <= capture_state;
                         
                         csr_s_readdata[16]     <= system_active;
                         csr_s_readdata[17]     <= buffer_wrapped;
                         csr_s_readdata[18]     <= trigger_condition_det;
                         csr_s_readdata[19]     <= post_trigger_buffering_complete;

                         csr_s_readdata[20]     <= force_single_cell_per_pkt;
                         
                         csr_s_readdata[24]     <= wr_control_en;
                         csr_s_readdata[25]     <= hdr_parse_en;
                         csr_s_readdata[26]     <= rd_control_en;

                         csr_s_readdata[28]     <= wr_pipe_empty;
                         csr_s_readdata[29]     <= read_empty;
                     end


                LP_TIMESYNC_CTRL_REG[2+:5]:
                     begin
                         csr_s_readdata[0]      <= ts_sync_clk_periodic_enable;
                     end


                LP_TIMESYNC_COUTNER_REG[2+:5]:
                     begin
                         csr_s_readdata <= ts_sync_clk_periodic_count[0+:PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH];
                     end


                LP_CREDIT_CTRL_REG[2+:5]:
                     begin
                         if (DEBUG_READBACK == 1'b1) begin
                            csr_s_readdata[CREDIT_WIDTH-1:0]  <= current_num_credits[CREDIT_WIDTH-1:0];
                         end
                     end


                LP_POST_TRIGGER_WRDS[2+:5]:
                     begin
                         csr_s_readdata[0+:TRACE_ADDR_WIDTH] <= post_trigger_num_words[0+:TRACE_ADDR_WIDTH];
                     end


                LP_RD_PTR_REG[2+:5]:
                     begin
                         csr_s_readdata[TRACE_ADDR_WIDTH-1:0] <= read_ptr[TRACE_ADDR_WIDTH-1:0];
                     end


                LP_WR_PTR_REG[2+:5]:
                     begin
                         csr_s_readdata[TRACE_ADDR_WIDTH-1:0] <= write_ptr[TRACE_ADDR_WIDTH-1:0];
                     end


                LP_START_PTR_REG[2+:5]:
                     begin
                         csr_s_readdata[TRACE_ADDR_WIDTH-1:0] <= start_ptr[TRACE_ADDR_WIDTH-1:0];
                     end


                LP_FILL_LVL_REG[2+:5]:
                     begin
                         csr_s_readdata[ 0+:RD_AND_WR_FILL_LVL_SIZE+1] <= write_fill_level[ 0+:RD_AND_WR_FILL_LVL_SIZE+1];
                         csr_s_readdata[16+:RD_AND_WR_FILL_LVL_SIZE+1] <= read_fill_level [ 0+:RD_AND_WR_FILL_LVL_SIZE+1];
                     end

                     
                LP_TRIG_WRDS_REMAIN[2+:5]:
                     begin
                         csr_s_readdata[0+:TRACE_ADDR_WIDTH] <= trigger_words_remaining[0+:TRACE_ADDR_WIDTH];
                     end

                     
                default:
                     begin
                         csr_s_readdata <= {32{1'b0}};
// synthesis translate_off
                         $error("read from an undefined location: register 0x:%x", csr_addr);
// synthesis translate_on
                     end
            endcase
        end
     end
end


endmodule
