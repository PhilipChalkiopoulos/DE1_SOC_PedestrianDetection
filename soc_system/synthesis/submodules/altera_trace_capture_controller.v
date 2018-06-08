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
//    1/TEXTART veiw of the system...
//    2/ describe interface behaviour and formats here as well.
(* altera_attribute = "-name IP_TOOL_NAME altera_trace_capture_controller; -name IP_TOOL_VERSION 15.1" *)
module altera_trace_capture_controller #(
    parameter DEVICE_FAMILY             = "Cyclone IV GX",
    parameter TRACE_DATA_WIDTH          = 64,
    parameter TRACE_SYMBOL_WIDTH        = 8,      // should probably be fixed!
    parameter TRACE_CHNL_WIDTH          = 2,

    parameter DEBUG_PIPE_WIDTH          = 8,
    parameter DEBUG_SYM_WIDTH           = 8,

    parameter ALIGNMENT_BOUNDARIES      = 0,     // 1 = aligned to 1 Byteboundaries,   2 = 2Byte boundaries,     4 = 4B boundaries...... , 0 == word boundaries...   (powers of 2!!!)

    parameter BUFF_LIMIT_LO             = 0,     // (word addresses)
    parameter BUFF_SIZE                 = 1024,  // (word addresses)
    parameter BUFF_ADDR_WIDTH           = 10,    //
    parameter BUFF_FIXED_RL             = 4,     // set to 0 if the buff doesn't have a fixed read latency.

    parameter PACKET_LEN_BITS           = 6,     // 6 is 64 bytes!   => 1 -> 64 bytes of valid data. if EOP flag set then EOP as well. 0 == 64!
    parameter NUM_PPD                   = 2,     // this is a function of header width..
    parameter WRITE_TIMING_IMPROVEMENTS = 1,

    parameter CREDIT_WIDTH              = 20,  // I.e. we can add 2^16 - 1 credits   a credit is a credit to send a packet on the receive side!!
    parameter DEBUG_READBACK            = 0,
    parameter MAX_OUT_PACKET_LENGTH     = 4096,  // size in BYTES of max packet

    parameter WAKE_UP_MODE              = "IDLE",   // IDLE, CAPTURE, FIFO
    parameter PERIODIC_TS_REQ_STARTUP   = 0,        // 0 = periodic_ts, other value = periodic_ts_interval

    // derived parameters
    parameter TRACE_SYM_PER_WORD = TRACE_DATA_WIDTH/TRACE_SYMBOL_WIDTH,
    parameter TRACE_EMPTY_WIDTH  = (TRACE_SYM_PER_WORD>1)? $clog2(TRACE_SYM_PER_WORD) : 1,
    parameter DEBUG_SYM_PER_WORD = DEBUG_PIPE_WIDTH / DEBUG_SYM_WIDTH,
    parameter DEBUG_EMPTY_WIDTH  = (DEBUG_SYM_PER_WORD > 1) ? $clog2(DEBUG_SYM_PER_WORD) : 1,

    parameter PPD_SIZE           = PACKET_LEN_BITS + TRACE_CHNL_WIDTH + 1



// USED BITS IN HEADER WORD =
//      num_PPD X PPD_IZE
//      NUM_PPD_USED = clog2(num_ppd)
//      SIZE (Bytes) = PACKET_LEN_BITS + clog2(num_ppd)  +1

) (
    input  wire clk,
    input  wire arst_n,

    output wire async_ts_sync_clk,

///// av_st_tr: distiller input
    output wire                         trace_packet_ready,
    input  wire                         trace_packet_valid,
    input  wire                         trace_packet_sop,
    input  wire                         trace_packet_eop,
    input  wire  [TRACE_DATA_WIDTH-1:0] trace_packet_data,
    input  wire  [TRACE_CHNL_WIDTH-1:0] trace_packet_chnl,
    input  wire [TRACE_EMPTY_WIDTH-1:0] trace_packet_empty,


// debug pipe output   // should match the size on the output  // first three are passed straight through
    input  wire                         dbg_out_ready,
    output wire                         dbg_out_valid,
    output wire  [TRACE_DATA_WIDTH-1:0] dbg_out_data,
    output wire                         dbg_out_sop,
    output wire                         dbg_out_eop,
    output wire [TRACE_EMPTY_WIDTH-1:0] dbg_out_empty,




    // MM master for trace data storage
    output reg                         stg_m_write,
    output reg                         stg_m_read,
    output reg   [BUFF_ADDR_WIDTH-1:0] stg_m_address,
    output reg  [TRACE_DATA_WIDTH-1:0] stg_m_write_data,
    input  wire                        stg_m_waitrequest,
    input  wire                        stg_m_read_data_valid,
    input  wire [TRACE_DATA_WIDTH-1:0] stg_m_readdata,


   // MM Slave for management (connect to xacto lite)...
    input  wire                        csr_s_write,
    input  wire                        csr_s_read,
    input  wire                  [5:0] csr_s_address,
    input  wire                 [31:0] csr_s_write_data,
    output wire                 [31:0] csr_s_readdata



);


localparam BUFF_LIMIT_HI                          = BUFF_LIMIT_LO + BUFF_SIZE -1;

localparam PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH     = 32;
localparam PERIODIC_TS_SYNC_CLK_PRE_COUNTER_WIDTH = 0;
localparam CORE_REVISION                          = 0;
localparam BUFF_FILL_LIMIT                        = BUFF_LIMIT_HI -4;
localparam WDATA_FIFO_ADDR_WIDTH                  = 6;
localparam HDR_PARSE_WIDTH                        = $clog2(NUM_PPD) + PACKET_LEN_BITS + 1;



localparam PP_SIZE_WORDS                          = ((1<< PACKET_LEN_BITS) + TRACE_SYM_PER_WORD -1)/TRACE_SYM_PER_WORD;
localparam MAX_CELL_SIZE_WORDS                    = 1 + (PP_SIZE_WORDS * NUM_PPD);

localparam MAX_PACKET_SIZE_WORDS                  = (MAX_OUT_PACKET_LENGTH + TRACE_SYM_PER_WORD -1) /TRACE_SYM_PER_WORD;


// wires for TS generation control
wire                                             ts_sync_clk_toggle_enable;
wire                                             ts_sync_clk_periodic_enable;
wire [PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH-1 : 0]  ts_sync_clk_periodic_count;


// general control bits from CSR
wire mode;
wire start;
wire stop;
wire trigger_en;

// capture_read module interface signals (credits)
wire                    credit_update;
wire                    clear_read_credits;
wire [CREDIT_WIDTH-1:0] add_credits_value;
wire [CREDIT_WIDTH-1:0] current_num_credits;

// write module to av_mm_storage_master if control && pipeline stage
reg                              wr_ready;
wire                             wr_valid;
wire       [BUFF_ADDR_WIDTH-1:0] wr_address;
wire      [TRACE_DATA_WIDTH-1:0] wr_data;
wire                             int_last_word_in_cell;
wire                             int_data_is_header;
wire                             int_wr_valid;
wire                             int_wr_ready;
wire       [BUFF_ADDR_WIDTH-1:0] int_wr_address;
wire      [TRACE_DATA_WIDTH-1:0] int_wr_data;
wire       [BUFF_ADDR_WIDTH-1:0] int_write_ptr;
wire       [BUFF_ADDR_WIDTH-1:0] int_mrw_header;
wire                             int_write_wrapped;
wire     [HDR_PARSE_WIDTH-1 : 0] mrw_length;
wire     [HDR_PARSE_WIDTH-1 : 0] int_mrw_length;
wire      [BUFF_ADDR_WIDTH -1:0] mrw_header;
wire                             last_word_in_cell;

// read module to av_mm_storage_master if control
reg                              rd_addr_ready;
wire                             rd_addr_valid;
wire       [BUFF_ADDR_WIDTH-1:0] rd_addr;

wire       [BUFF_ADDR_WIDTH-1:0] rd_ptr;

// state control stuff.
wire     [BUFF_ADDR_WIDTH -1 :0] write_ptr;
reg      [BUFF_ADDR_WIDTH -1 :0] buff_fill_level;

wire                             doing_write;
wire                             doing_read;
reg                              buff_almost_full;
wire                             write_wrapped;

// main SM control and main module interaction bits!
reg   wr_control_en;
reg   rd_control_en;
reg   hdr_parse_en;
wire  wr_control_triggered;
wire  wr_pipe_empty;
wire  read_empty;
wire  hdr_processing_done;

// main SM status / control
reg system_active;
reg mode_is_fifo;

// write module information
wire [WDATA_FIFO_ADDR_WIDTH : 0] wr_fifo_fill_lvl;

// proc to read
wire       [BUFF_ADDR_WIDTH-1:0] proc_start_ptr;
wire       [BUFF_ADDR_WIDTH-1:0] proc_end_ptr;

// wires and regs to handle header parser => av_mm_storage master IF
wire                             proc_wr;
wire                             proc_rd;
reg                              proc_rdy;
wire       [BUFF_ADDR_WIDTH-1:0] proc_addr;
wire      [TRACE_DATA_WIDTH-1:0] proc_wdata;
wire   [WDATA_FIFO_ADDR_WIDTH:0] read_fill_level;

wire                           wr_control_pre_trigger;
wire  [BUFF_ADDR_WIDTH -1 : 0] post_trigger_num_words;
wire  [BUFF_ADDR_WIDTH -1 : 0] trigger_num_words_remaining;


wire enable_capture_output;

wire force_single_cell_per_pkt;

reg [2:0] state;



// instantiate register block
altera_trace_capture_regs #(
    .CREDIT_WIDTH                            (CREDIT_WIDTH)
   ,.CORE_REVISION                           (CORE_REVISION)
   ,.TRACE_DATA_WIDTH                        (TRACE_DATA_WIDTH)
   ,.TRACE_ADDR_WIDTH                        (BUFF_ADDR_WIDTH)
   ,.NUM_PPD                                 (NUM_PPD)
   ,.PACKET_LEN_BITS                         (PACKET_LEN_BITS)
   ,.TRACE_CHNL_WIDTH                        (TRACE_CHNL_WIDTH)
   ,.MAX_OUT_PACKET_LENGTH                   (MAX_OUT_PACKET_LENGTH)
   ,.PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH      (PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH)
   ,.PERIODIC_TS_SYNC_CLK_PRE_COUNTER_WIDTH  (PERIODIC_TS_SYNC_CLK_PRE_COUNTER_WIDTH)
   ,.DEBUG_READBACK                          (DEBUG_READBACK)
   ,.BUFFER_START_ADDR                       (BUFF_LIMIT_LO)
   ,.BUFFER_SIZE                             (BUFF_SIZE)
   ,.HDR_PTR_SIZE                            (HDR_PARSE_WIDTH)
   ,.RD_AND_WR_FILL_LVL_SIZE                 (WDATA_FIFO_ADDR_WIDTH)
   ,.WAKE_UP_MODE                            (WAKE_UP_MODE)
   ,.PERIODIC_TS_REQ_STARTUP                 (PERIODIC_TS_REQ_STARTUP)
) csr (
    .clk                                     (clk)
   ,.arst_n                                  (arst_n)
   ,.csr_s_write                             (csr_s_write)
   ,.csr_s_read                              (csr_s_read)
   ,.csr_s_address                           (csr_s_address)
   ,.csr_s_write_data                        (csr_s_write_data)
   ,.csr_s_readdata                          (csr_s_readdata)
   ,.mode                                    (mode)

   ,.start                                   (start)
   ,.stop                                    (stop)
   ,.trigger_en                              (trigger_en)
   ,.enable_capture_output                   (enable_capture_output)

   ,.ts_sync_clk_periodic_enable             (ts_sync_clk_periodic_enable)
   ,.ts_sync_clk_toggle_enable               (ts_sync_clk_toggle_enable)
   ,.ts_sync_clk_periodic_count              (ts_sync_clk_periodic_count)

   ,.credit_update                           (credit_update)
   ,.clear_read_credits                      (clear_read_credits)
   ,.add_credits_value                       (add_credits_value)

   ,.system_active                           (system_active)
   ,.buffer_wrapped                          (write_wrapped)    // is this the wrong bit to use!
   ,.wr_control_en                           (wr_control_en)
   ,.hdr_parse_en                            (hdr_parse_en)
   ,.rd_control_en                           (rd_control_en)
   ,.wr_pipe_empty                           (wr_pipe_empty)
   ,.read_empty                              (read_empty)

   ,.start_ptr                               (proc_start_ptr)
   ,.write_ptr                               (proc_end_ptr)
   ,.read_ptr                                (rd_ptr)
   ,.write_fill_level                        (wr_fifo_fill_lvl)
   ,.read_fill_level                         (read_fill_level)

   ,.current_num_credits                     (current_num_credits)

   ,.post_trigger_num_words                  (post_trigger_num_words)
   ,.trigger_condition_det                   (wr_control_pre_trigger)
   ,.post_trigger_buffering_complete         (wr_control_triggered)
   ,.trigger_words_remaining                 (trigger_num_words_remaining)
   ,.force_single_cell_per_pkt               (force_single_cell_per_pkt)
   ,.capture_state                           (state)
);



// Trace sync request generator
altera_trace_ts_req_generator #(
      .COUNTER_WIDTH           (PERIODIC_TS_SYNC_CLK_COUNTER_WIDTH)
     ,.PRECOUNT_WIDTH          (0)
     ,.PERIODIC_TS_REQ_STARTUP (PERIODIC_TS_REQ_STARTUP)
)capture_ts_generator (
      .clk                (clk)
     ,.arst_n             (arst_n)
     ,.async_ts_sync_clk  (async_ts_sync_clk)
     ,.counter_rst_value  (ts_sync_clk_periodic_count)
     ,.counter_en         (ts_sync_clk_periodic_enable)
     ,.toggle_output      (ts_sync_clk_toggle_enable)
);



// Write control module.
//   Takes trace data in, segmentises it, and provides control to write the data into the store.
altera_trace_capture_wr_control #(
        .DEVICE_FAMILY            (DEVICE_FAMILY)
       ,.ADDR_WIDTH               (BUFF_ADDR_WIDTH)
       ,.DATA_WIDTH               (TRACE_DATA_WIDTH)
       ,.MAX_ADDR                 (BUFF_LIMIT_HI)
       ,.MIN_ADDR                 (BUFF_LIMIT_LO)
       ,.PPD_IN_HDR               (NUM_PPD)
       ,.PPD_LEN                  (PACKET_LEN_BITS)
       ,.CH_WIDTH                 (TRACE_CHNL_WIDTH)
       ,.ST_SYMBOL_WIDTH          (8)
       ,.MTY_WIDTH                (TRACE_EMPTY_WIDTH)
       ,.INT_ALIGNMENT_BOUNDAIES  (0)
       ,.WDATA_FIFO_ADDR_WIDTH    (WDATA_FIFO_ADDR_WIDTH)
       ,.HEADER_LENGTH_WIDTH      (HDR_PARSE_WIDTH)
) wr_ctrl (
        .clk                      (clk)
       ,.arst_n                   (arst_n)
       ,.trace_packet_ready       (trace_packet_ready)
       ,.trace_packet_valid       (trace_packet_valid)
       ,.trace_packet_sop         (trace_packet_sop)
       ,.trace_packet_eop         (trace_packet_eop)
       ,.trace_packet_data        (trace_packet_data)
       ,.trace_packet_chnl        (trace_packet_chnl)
       ,.trace_packet_empty       (trace_packet_empty)
       ,.wr_valid                 (int_wr_valid)
       ,.wr_ready                 (int_wr_ready)
       ,.wr_address               (int_wr_address)
       ,.wr_data                  (int_wr_data)
       ,.wr_fill_lvl              (wr_fifo_fill_lvl)
       ,.last_data_in_cell        (int_last_word_in_cell)
       ,.data_is_header           (int_data_is_header)
       ,.enable                   (wr_control_en)
       ,.fifo_mode                (mode_is_fifo)
       ,.wr_ptr_out               (int_write_ptr)
       ,.wr_last_hdr              (int_mrw_header)
       ,.last_hdr_real_size       (int_mrw_length)
       ,.write_wrapped            (int_write_wrapped)
       ,.trigger_enable           (trigger_en)
       ,.post_trigger_words       (post_trigger_num_words)
       ,.triggered                (wr_control_pre_trigger)
       ,.trigger_stop             (wr_control_triggered)
       ,.trigger_words_remaining  (trigger_num_words_remaining)
);


// optional module for timing improvement between the write path and the AV_MM_STORAGE_MASTER
generate
if (1 == WRITE_TIMING_IMPROVEMENTS) begin : g_write_timing_improver
    altera_trace_wr_control_pl_stage #(
        .ADDR_WIDTH (BUFF_ADDR_WIDTH)
       ,.DATA_WIDTH (TRACE_DATA_WIDTH)
       ,.MAX_ADDR   (BUFF_LIMIT_HI)
    )altera_trace_wr_control_pl_stage(
        .clk                    (clk)
       ,.arst_n                 (arst_n)
       ,.in_ready               (int_wr_ready)
       ,.in_valid               (int_wr_valid)
       ,.in_address             (int_wr_address)
       ,.in_data                (int_wr_data)
       ,.in_last_word_in_cell   (int_last_word_in_cell)
       ,.in_data_is_header      (int_data_is_header)
       ,.in_write_wrapped       (int_write_wrapped)
       ,.out_ready              (wr_ready)
       ,.out_valid              (wr_valid)
       ,.out_address            (wr_address)
       ,.out_data               (wr_data)
       ,.out_ptr_out            (write_ptr)
       ,.out_last_hdr           (mrw_header)
       ,.out_write_wrapped      (write_wrapped)
       ,.out_last_word_in_cell  (last_word_in_cell)
    );



end else begin : g_no_write_timing_improver
    assign int_wr_ready      = wr_ready;
    assign wr_valid          = int_wr_valid;
    assign wr_address        = int_wr_address;
    assign wr_data           = int_wr_data;
    assign write_ptr         = int_write_ptr;
    assign mrw_header        = int_mrw_header;
    assign write_wrapped     = int_write_wrapped;
    assign last_word_in_cell = int_last_word_in_cell;
end
endgenerate


assign mrw_length    = int_mrw_length;

assign wr_pipe_empty = (wr_fifo_fill_lvl == 'd0) ? ~(wr_valid | int_wr_valid) : 1'b0;



//read control module
// reads data out of the store in order.
altera_trace_capture_rd_control #(
        .DEVICE_FAMILY         (DEVICE_FAMILY)
       ,.ADDR_WIDTH            (BUFF_ADDR_WIDTH)
       ,.DATA_WIDTH            (TRACE_DATA_WIDTH)
       ,.TRACE_EMPTY_WIDTH     (TRACE_EMPTY_WIDTH)
       ,.MAX_ADDR              (BUFF_LIMIT_HI)
       ,.MIN_ADDR              (BUFF_LIMIT_LO)
       ,.BUFF_DEPTH_WIDTH      (WDATA_FIFO_ADDR_WIDTH)
       ,.HEADER_LENGTH_WIDTH   (HDR_PARSE_WIDTH)
       ,.MAX_PACKET_SIZE_WORDS (MAX_PACKET_SIZE_WORDS)
       ,.CREDIT_WIDTH          (CREDIT_WIDTH)
       ,.MAX_CELL_SIZE         (MAX_CELL_SIZE_WORDS)
) rd_ctrl(
        .clk                 (clk)
       ,.arst_n              (arst_n)
       ,.rd_addr             (rd_addr)
       ,.rd_addr_valid       (rd_addr_valid)
       ,.rd_addr_ready       (rd_addr_ready)
       ,.rd_burstlen         ()
       ,.rdv                 (stg_m_read_data_valid)
       ,.readdata            (stg_m_readdata)
       ,.dbg_ready           (dbg_out_ready)
       ,.dbg_valid           (dbg_out_valid)
       ,.dbg_sop             (dbg_out_sop)
       ,.dbg_eop             (dbg_out_eop)
       ,.dbg_data            (dbg_out_data)
       ,.dbg_empty           (dbg_out_empty)
       ,.first_hdr_ptr       (proc_start_ptr)
       ,.wr_ptr              (proc_end_ptr)
       ,.rd_ptr              (rd_ptr)
       ,.read_enable         (rd_control_en)
       ,.read_empty          (read_empty)
       ,.read_fill_level     (read_fill_level)
       ,.single_cell_pkt     (force_single_cell_per_pkt)
       ,.credit_update       (credit_update)
       ,.clear_credits       (clear_read_credits)
       ,.credits_to_add      (add_credits_value)
       ,.num_credits         (current_num_credits)
);





// header parsing block, it's purpose is to read the contents of the memory in store and forward mode, 
//  adjusting the value stored so that we can process the headers forwards. 
// It also provides the new START_ADDR for the read module for when the bufer has wrapped.
altera_trace_capture_header_parser #(
       .DEVICE_FAMILY            (DEVICE_FAMILY)
      ,.ADDR_WIDTH               (BUFF_ADDR_WIDTH)
      ,.DATA_WIDTH               (TRACE_DATA_WIDTH)
      ,.MAX_ADDR                 (BUFF_LIMIT_HI)
      ,.MIN_ADDR                 (BUFF_LIMIT_LO)
      ,.HEADER_LENGTH_WIDTH      (HDR_PARSE_WIDTH)
) hdr_parse (
       .clk                      (clk)
      ,.arst_n                   (arst_n)
      ,.enable                   (hdr_parse_en)
      ,.mode_is_fifo             (mode_is_fifo)
      ,.processing_done          (hdr_processing_done)
      ,.sys_active               (system_active)
      ,.has_wrapped              (int_write_wrapped)
      ,.pointer_update           (wr_valid & wr_ready & last_word_in_cell)
      ,.most_recent_length       (mrw_length)
      ,.most_recent_wdata_addr   (write_ptr)
      ,.most_recent_wheader_addr (mrw_header)
      ,.start_ptr                (proc_start_ptr)
      ,.end_ptr                  (proc_end_ptr)
      ,.mm_addr                  (proc_addr)
      ,.mm_wr                    (proc_wr)
      ,.mm_rd                    (proc_rd)
      ,.mm_ready                 (proc_rdy)
      ,.mm_wdata                 (proc_wdata)
      ,.mm_rdv                   (stg_m_read_data_valid)
      ,.mm_rdata                 (stg_m_readdata)
);






// always block takes a command from the read or write control blocks.
//   NOTE: this may need adjusting for efficient DDR style bursting behaviour! 
//          especially if the controller is not doing singles-> burst operation merging
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        stg_m_write       <= 0;
        stg_m_read        <= 0;
        stg_m_address     <= 0;
        stg_m_write_data  <= 0;
    end else begin
        if (   ((stg_m_waitrequest == 1'b0) && ((stg_m_write == 1'b1) || (stg_m_read == 1'b1)))  // command has compelted get next command!
            || (                                (stg_m_write == 1'b0) && (stg_m_read == 1'b0) )  // no pending command
           ) begin
            stg_m_read        <= 1'b0;
            stg_m_write       <= 1'b0;
            if (rd_addr_valid == 1'b1) begin
                stg_m_read        <= 1'b1;
                stg_m_address     <= rd_addr;
            end else if ((wr_valid == 1'b1) && (buff_almost_full == 1'b0)) begin
                stg_m_write       <= 1'b1;
                stg_m_address     <= wr_address;
                stg_m_write_data  <= wr_data;
            end else if ((1'b1 == proc_wr) || (1'b1 == proc_rd) ) begin
                stg_m_read       <= proc_rd;
                stg_m_write      <= proc_wr;
                stg_m_address    <= proc_addr;
                stg_m_write_data <= proc_wdata;
            end
        end
    end
end

// combinatorial feedback for the av_st RL) style readna nd write requesting interfaces from the read and write controller modules
always @(*) begin
    wr_ready          = 1'b0;
    rd_addr_ready     = 1'b0;
    proc_rdy          = 1'b0;

    if (   ((stg_m_waitrequest == 1'b0) && ((stg_m_write == 1'b1) || (stg_m_read == 1'b1)))  // command has compelted get next command!
        || (                                (stg_m_write == 1'b0) && (stg_m_read == 1'b0) )  // no pending command
       ) begin
        if (rd_addr_valid == 1'b1) begin
            rd_addr_ready     = 1'b1;
        end else if ((wr_valid == 1'b1) && (buff_almost_full == 1'b0)) begin
            wr_ready          = 1'b1;
        end else if ((1'b1 == proc_wr) || (1'b1 == proc_rd) ) begin
            proc_rdy          = 1'b1;
        end
    end
end




assign doing_write    = stg_m_write & ~stg_m_waitrequest;
assign doing_read     = stg_m_read  & ~stg_m_waitrequest;




// NOTE: rather than using the read level in the write SM to stop writing, I can do it from here, which removes that constraint from the write SM.
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        buff_fill_level  <= {BUFF_ADDR_WIDTH{1'b0}};
        buff_almost_full <= 1'b0;
    end else begin
        if ((doing_write == 1'b1) || (doing_read == 1'b1)) begin
            if (doing_write == 1'b1) begin
                buff_fill_level <= buff_fill_level + 1'b1;
            end else begin
                buff_fill_level <= buff_fill_level - 1'b1;
            end
        end
        // how to clear buff_fill level
        if ((start == 1'b1) && (1'b1 == mode)) begin  // will this give me a sclr ??
            buff_fill_level <= 'h0;
        end

        if (buff_fill_level >= BUFF_FILL_LIMIT[BUFF_ADDR_WIDTH-1:0])
            buff_almost_full <= mode_is_fifo;
        else
            buff_almost_full <= 1'b0;
    end
end






// main state machine
//   it's purpose is to control sequencing of the blocks 
//   e.g. how we capture - process the read in capture mode 
//         or read and write simultaneousey for fifo mode!

localparam LP_STATE_IDLE               = 3'd0;
localparam LP_STATE_FIFO               = 3'd1;
localparam LP_STATE_CAPT_STORE         = 3'd2;
localparam LP_STATE_CAPT_REFORMAT      = 3'd3;
localparam LP_STATE_CAPT_READOUT       = 3'd4;
localparam LP_STATE_WR_FLUSHING        = 3'd5;
localparam LP_STATE_RD_FLUSHING        = 3'd6;
localparam LP_STATE_PAUSE_B4_RD_FLUSH  = 3'd7;

reg [2:0] count;
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        wr_control_en        <= 1'b0;
        rd_control_en        <= 1'b0;
        state                <= 'd0;
        count                <= 3'd0;
        mode_is_fifo         <= 1'b0;
        hdr_parse_en         <= 1'b0;
        system_active        <= 1'b0;
    end else begin
        count         <= 3'b111;
        hdr_parse_en  <= 1'b0;
        case (state)
            LP_STATE_FIFO : begin
                                wr_control_en <= 1'b1;

                                // implement a delay to make sure that the read side has time to adjust the pointers it is using
                                // as an effect of having changed mode...
                                if (count != 3'h0) begin
                                    count <= count -1'b1;
                                end else begin
                                    rd_control_en <= 1'b1;
                                end

                                if ((trigger_en & wr_control_triggered) | stop ) begin
                                    state         <= LP_STATE_WR_FLUSHING;
                                    wr_control_en <= 1'b0;
                                end
                            end

            LP_STATE_CAPT_STORE : begin
                                    if ((trigger_en & wr_control_triggered) | stop) begin
                                        state         <= LP_STATE_WR_FLUSHING;
                                        wr_control_en <= 1'b0;
                                    end
                                  end

            LP_STATE_CAPT_REFORMAT : begin
                                        wr_control_en <= 1'b0;
                                        rd_control_en <= 1'b0;
                                        hdr_parse_en  <= 1'b1;
                                        if (1'b1 == hdr_processing_done) begin
                                        	if (enable_capture_output == 1'b1) begin
                                        		state         <= LP_STATE_RD_FLUSHING;
                                        	end else begin
                                        	    state         <= LP_STATE_PAUSE_B4_RD_FLUSH;
                                        	end
                                        end
                                     end

            LP_STATE_PAUSE_B4_RD_FLUSH: begin
                                            if (enable_capture_output == 1'b1) begin
                                            	state         <= LP_STATE_RD_FLUSHING;
                                            end            
                                        end

            LP_STATE_WR_FLUSHING: begin
                                      count <= count -1'b1;
                                      rd_control_en <= mode_is_fifo;
                                      if ((wr_pipe_empty == 1'b1) && (count == 'd0))begin
                                          if (mode_is_fifo == 1'b1) begin
                                              state         <= LP_STATE_RD_FLUSHING;
                                          end else begin
                                              state         <= LP_STATE_CAPT_REFORMAT;
                                          end
                                      end
                                  end

            LP_STATE_RD_FLUSHING : begin
                                      wr_control_en <= 1'b0;
                                      rd_control_en <= 1'b1;
                                      count         <= count -1'b1;
                                      if ((read_empty == 1'b1) && (count == 'd0))begin
                                          state         <= LP_STATE_IDLE;
                                          rd_control_en <= 1'b0;
                                      end
                                   end

            // & LP_STATE_IDLE
            default: begin
                        system_active <= 1'b0;
                        if (start == 1'b1) begin
                            wr_control_en <= 1'b1;
                            system_active <= 1'b1;
                            if (mode == 1'b1) begin
                                state                <= LP_STATE_FIFO;
                                mode_is_fifo         <= 1'b1;
                            end else begin
                                state                <= LP_STATE_CAPT_STORE;
                                mode_is_fifo         <= 1'b0;
                            end

                        end
                     end  // begin
        endcase
    end
end

endmodule
`default_nettype wire
