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
//   Module whoose purpose is to handle reading data out of the storage subsystem
//   and provide send it out on a debug pipe compatiable interface.
//
//      It requires that the cells be in order, A pointer to the first header
//      and indication fo how far to read...
//
//      When operating in 'realtime' mode it behaves as the read side of a fifo, reading up to the write pointer.
//      when operating in store and forward mode it reads from a start address to the end address. This may require that the buffer be parsed to find the start of the buffer!
//
//      Credit based flowcontrol is used on the read interfaces. this means that software can throttle the pactised stream of cells as required.
//
//      The interface should be able to pack multiple cells into a single packet, the packet hasa  maximum size determined by a parameter.
//
//
//      Thus is must be aware of:
//          mode of operation,
//          most revently written write pointer
//
//     the used interfaces are:
//          clk and reset
//          av_st_debug pipe out
//          read command issuing AV_ST compliant interface
//          read result interface  (RDV && readdata)
//          @for awareness@ interfaces:    write pointer, mode ......
//                                         read pointer (for write logic!)


// TODO:   COMMENTS

module altera_trace_capture_rd_control #(
    parameter DEVICE_FAMILY            = "Cyclone IV GX",
    parameter ADDR_WIDTH               = 1,
    parameter DATA_WIDTH               = 1,
    parameter TRACE_EMPTY_WIDTH        = 1,
    parameter MAX_ADDR                 = 1,
    parameter MIN_ADDR                 = 1,
    parameter BUFF_DEPTH_WIDTH         = 1,

    parameter HEADER_LENGTH_WIDTH      = 8,
    parameter MAX_PACKET_SIZE_WORDS    = 0,    // words
    parameter CREDIT_WIDTH             = 16,
    parameter MAX_CELL_SIZE            = 32      // words
) (
    input  wire                             clk,
    input  wire                             arst_n,

    output reg             [ADDR_WIDTH-1:0] rd_addr,
    output reg                              rd_addr_valid,
    input  wire                             rd_addr_ready,
    output reg                              rd_burstlen,

    input  wire                             rdv,
    input  wire            [DATA_WIDTH-1:0] readdata,

    input  wire                             dbg_ready,
    output wire                             dbg_valid,
    output reg                              dbg_sop,
    output reg                              dbg_eop,
    output wire            [DATA_WIDTH-1:0] dbg_data,
    output reg      [TRACE_EMPTY_WIDTH-1:0] dbg_empty,

    input  wire            [ADDR_WIDTH-1:0] first_hdr_ptr,         // first pointer to read when starting up (CAPTURE_MODE)
    input  wire            [ADDR_WIDTH-1:0] wr_ptr,                // FIFO_MODE:    most recently written location
                                                                   // CAPTURE_MODE: value tor ead up to!
    output reg             [ADDR_WIDTH-1:0] rd_ptr,

    input  wire                             read_enable,
    output reg                              read_empty,
    output wire        [BUFF_DEPTH_WIDTH:0] read_fill_level,

    input  wire                             single_cell_pkt,      // forces the output to only pack a single cell into a av_st debug packet,

    input  wire                             credit_update,
    input  wire                             clear_credits,
    input  wire          [CREDIT_WIDTH-1:0] credits_to_add,
    output wire          [CREDIT_WIDTH-1:0] num_credits

);


localparam MAX_ADDR_SUB_ONE = MAX_ADDR -1'd1;


wire                            fifo_empty;
reg  [HEADER_LENGTH_WIDTH -1:0] length_to_read;

reg                            almost_full;
reg         [ADDR_WIDTH -1 :0] buff_fill_level;
wire                           incr_counter;
wire                           counter_change;
wire                           decr_counter;
reg                            have_credits;


wire [BUFF_DEPTH_WIDTH-1:0] rd_fifo_fill_lvl;
wire                        rd_fifo_full;
// Single clock FIFO, Timing is not ideal as I'm using it in showahead mode!
//   this may therfore require a plpeline stage immediately after it!
//       Should we write and use a better SC_FIFO ??
    scfifo #(
         .intended_device_family  (DEVICE_FAMILY)
        ,.lpm_type                ("scfifo")
        ,.lpm_width               (DATA_WIDTH)
        ,.lpm_numwords            (1 << BUFF_DEPTH_WIDTH)
        ,.lpm_widthu              (BUFF_DEPTH_WIDTH)
        ,.almost_empty_value      (2)
        ,.almost_full_value       (8)
        ,.add_ram_output_register ("ON")
        ,.lpm_showahead           ("ON")
        ,.overflow_checking       ("OFF")
        ,.underflow_checking      ("OFF")
        ,.use_eab                 ("ON")
    )rd_fifo(
         .clock                   (clk)
        ,.aclr                    (~arst_n)
        ,.usedw                   (read_fill_level[BUFF_DEPTH_WIDTH-1:0])
        ,.full                    (read_fill_level[BUFF_DEPTH_WIDTH])
        ,.almost_full             ()
        ,.wrreq                   (rdv & read_enable)
        ,.data                    (readdata)
        ,.empty                   (fifo_empty)
        ,.almost_empty            ()
        ,.rdreq                   (dbg_ready & dbg_valid)
        ,.q                       (dbg_data)
// synopsys translate_off
        ,.sclr ()
// synopsys translate_on
    );


assign dbg_valid = have_credits & ~fifo_empty;


reg   [TRACE_EMPTY_WIDTH-1:0]  empty_value;
wire next_end_of_cell_is_eop;

generate if (MAX_PACKET_SIZE_WORDS != 0) begin : multiple_cells_per_packet
    localparam WORDS_REM_WIDTH = $clog2(MAX_PACKET_SIZE_WORDS);
    reg [WORDS_REM_WIDTH-1:0] packet_words_remaining;

    reg next_end_of_cell_is_eop_reg;
    always @(posedge clk or negedge arst_n) begin
        if (arst_n == 0) begin
            packet_words_remaining  <= 'h0;
            next_end_of_cell_is_eop_reg <= 1'b0;
        end else begin
            if ((dbg_ready == 1'b1) && (1'b1 == dbg_valid)) begin
                if (dbg_sop == 1'b1) begin
                    packet_words_remaining         <= MAX_PACKET_SIZE_WORDS[WORDS_REM_WIDTH-1:0] - 1'b1;
                    next_end_of_cell_is_eop_reg    <= 1'b0;
                end else begin  // debug eop == 1'b1;
                    packet_words_remaining <= packet_words_remaining -1'b1;
                end

                if (packet_words_remaining < MAX_CELL_SIZE[WORDS_REM_WIDTH-1:0] + 1'b1) begin
                    next_end_of_cell_is_eop_reg  <= ~dbg_sop;
                end
            end

            if (single_cell_pkt) begin
                next_end_of_cell_is_eop_reg <= 1'b1;
            end

        end
    end

    assign next_end_of_cell_is_eop = next_end_of_cell_is_eop_reg;

end else begin : g_single_cell_per_packet
    assign next_end_of_cell_is_eop = 1'b1;
end
endgenerate


// note that this only uses inofmramtion about what is in the FIFO and now what is pending from the memory...  i.e. it is what we have available instantly!
//     otherwise we would use buff_fill_level which takes account of the level in the buffer and what is pending..
reg rd_fifo_has_low_fill;
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
         rd_fifo_has_low_fill <= 1'b0;
    end else begin
        if (read_fill_level > 'h4) begin
            rd_fifo_has_low_fill <= 1'b0;
        end else begin
            rd_fifo_has_low_fill <= 1'b1;
        end
    end
end


// here we are using wouldbe_?op and dbg_?op 
// in this case the woulbbe sop and eop indicate cell boundaries and where boundaries would be if we were sending a singel cell per packet.
// the db_sop and eop are the actual output signals.
reg wouldbe_eop;
reg wouldbe_sop;

wire [HEADER_LENGTH_WIDTH-1:0] extracted_length;
assign extracted_length =  dbg_data[ DATA_WIDTH -HEADER_LENGTH_WIDTH +: HEADER_LENGTH_WIDTH];

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        dbg_sop        <= 1'b1;
        dbg_eop        <= 1'b0;
    end else begin
        if ((dbg_ready == 1'b1) && (1'b1 == dbg_valid)) begin
            dbg_sop     <= dbg_eop;

            if (  ((wouldbe_eop == 1'b0) && (wouldbe_sop == 1'b0) && (length_to_read < 'd2) )
                ||((wouldbe_eop == 1'b0) && (wouldbe_sop == 1'b1) && ({(HEADER_LENGTH_WIDTH -1){1'b0}} == extracted_length[HEADER_LENGTH_WIDTH-1:1]))
               ) begin
                dbg_eop   <= next_end_of_cell_is_eop | rd_fifo_has_low_fill;
            end else begin
                dbg_eop     <= 1'b0;
            end
        end
    end
end


always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        wouldbe_sop    <= 1'b1;
        wouldbe_eop    <= 1'b0;
    end else begin
        if ((dbg_ready == 1'b1) && (1'b1 == dbg_valid)) begin
           wouldbe_sop <= wouldbe_eop;

            if (  ((wouldbe_eop == 1'b0) && (wouldbe_sop == 1'b0) && (length_to_read < 'd2) )
                ||((wouldbe_eop == 1'b0) && (wouldbe_sop == 1'b1) && ({(HEADER_LENGTH_WIDTH-1){1'b0}} == extracted_length[HEADER_LENGTH_WIDTH-1:1]))
               ) begin
                wouldbe_eop <= 1'b1;
            end else begin  // debug eop == 1'b1;
                wouldbe_eop <= 1'b0;
            end
        end
    end
end


// DRive Empty....   NOTE: currently we are always sending cells aligned to word boundaries so this is irrelevent OTHERWISE, 
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        empty_value    <= {TRACE_EMPTY_WIDTH{1'b0}};
        dbg_empty      <= {TRACE_EMPTY_WIDTH{1'b0}};
    end else begin
        if ((dbg_ready == 1'b1) && (1'b1 == dbg_valid)) begin
            if (dbg_sop == 1'b1) begin
                // select EMPTY value from MS PPD.
                // extract num_ppd
                // choose value from ehrader adn convert to an empty value.
                // but this needsa few more params!
                empty_value <= 'd0;
            end else if ((dbg_eop == 1'b0) && (length_to_read < 'd2)) begin
                dbg_empty <= empty_value;
            end else begin  // debug eop == 1'b1;
                dbg_empty <= {TRACE_EMPTY_WIDTH{1'b0}};
            end
        end
    end
end


// extract the ammount of data to read per cell from the cell header.
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        length_to_read <= {HEADER_LENGTH_WIDTH{1'b0}};
    end else begin
        if ((dbg_ready == 1'b1) && (1'b1 == dbg_valid)) begin
            if (wouldbe_sop == 1'b1) begin	
                length_to_read[0+: HEADER_LENGTH_WIDTH] <=  extracted_length -1'b1;
            end else begin   //            end else if (wouldbe_eop == 1'b0) begin

                length_to_read <= length_to_read -1'b1;
            end
        end
    end
end






reg rd_addr_is_max;



wire [ADDR_WIDTH -1 : 0] next_rd_addr;
assign next_rd_addr = rd_addr_is_max ? MIN_ADDR[ADDR_WIDTH-1:0] : rd_addr +1'b1;

reg next_addr_is_none_left_to_read;
reg this_addr_is_none_left_to_read;
reg read_addr_changed_last_cycle;

wire pointers_different;
assign pointers_different = (read_addr_changed_last_cycle == 1'b1) ? ~next_addr_is_none_left_to_read : ~this_addr_is_none_left_to_read;

// process to generate addresses and control range of reading...
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        rd_addr        <= MAX_ADDR[ADDR_WIDTH-1:0];
        rd_ptr         <= MAX_ADDR[ADDR_WIDTH-1:0];
        rd_addr_valid  <= 1'b0;
        rd_burstlen    <= 1'b1;
        rd_addr_is_max <= 1'b0;

        next_addr_is_none_left_to_read  <= 1'b1;
        this_addr_is_none_left_to_read  <= 1'b1;
        read_addr_changed_last_cycle    <= 1'b0;

    end else begin
        rd_addr_valid <= 1'b0;
        rd_burstlen   <= 1'b1;

        read_addr_changed_last_cycle <= 1'b0;

        // TODO: decide if this is better???
        //next_addr_is_none_left_to_read <= (next_rd_addr[ADDR_WIDTH-1:0] == wr_ptr[ADDR_WIDTH-1:0]);
        next_addr_is_none_left_to_read <= (rd_addr_is_max) ?  (MIN_ADDR[ADDR_WIDTH-1:0] == wr_ptr[ADDR_WIDTH-1:0]) : ((rd_addr[ADDR_WIDTH-1:0] + 1'b1) == wr_ptr[ADDR_WIDTH-1:0]);


        this_addr_is_none_left_to_read <= (rd_addr[ADDR_WIDTH-1:0]      == wr_ptr[ADDR_WIDTH-1:0]);


        if (rd_addr[ADDR_WIDTH-1:0] == MAX_ADDR[ADDR_WIDTH-1:0]) begin
            rd_addr_is_max <= 1'b1;
        end else begin
            rd_addr_is_max <= 1'b0;
        end
        if (read_enable == 1'b0) begin
            rd_addr <= first_hdr_ptr;
        end else if ((1'b1 == pointers_different) && (almost_full == 1'b0) ) begin
            rd_addr_valid <= 1'b1;
            if (rd_addr_valid != 1'b1) begin
                 rd_addr         <= next_rd_addr;
                 read_addr_changed_last_cycle <= 1'b1;
                 if (rd_addr[ADDR_WIDTH-1:0] == MAX_ADDR_SUB_ONE[ADDR_WIDTH-1:0]) begin
                    rd_addr_is_max <= 1'b1;
                 end else begin
                    rd_addr_is_max <= 1'b0;
                 end
            end
        end

        if ((rd_addr_ready == 1'b1) && (rd_addr_valid == 1'b1))begin
            rd_ptr <= rd_addr;
            if ((1'b1 == pointers_different) && (almost_full == 1'b0)) begin
                rd_addr_valid                <= 1'b1;
                rd_addr                      <= next_rd_addr;
                read_addr_changed_last_cycle <= 1'b1;

                if (rd_addr[ADDR_WIDTH-1:0] == MAX_ADDR_SUB_ONE[ADDR_WIDTH-1:0]) begin
                    rd_addr_is_max <= 1'b1;
                end else begin
                    rd_addr_is_max <= 1'b0;
                end
            end
        end
    end
end



assign incr_counter   = rd_addr_ready & rd_addr_valid;
assign decr_counter   = dbg_ready & dbg_valid;
assign counter_change = incr_counter ^ decr_counter;


// fill level management!
// counter to check total number of issued reads versus read_out_reads
// I.E. this ensures that there is space in the read buffer for all returning reads!
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        buff_fill_level  <= {ADDR_WIDTH{1'b0}};
        almost_full      <= 1'b0;
        read_empty       <= 1'b1;
    end else begin
        if (counter_change == 1'b1) begin
            if (incr_counter == 1'b1) begin
                buff_fill_level <= buff_fill_level + 1'b1;
            end else begin
                buff_fill_level <= buff_fill_level - 1'b1;
            end
        end

        if (buff_fill_level >= ((1 << BUFF_DEPTH_WIDTH) -2)) begin
            almost_full <= 1'b1;
        end else begin
            almost_full <= 1'b0;
        end

        if (buff_fill_level == 'h0) begin
            read_empty <= 1'b1;
        end else begin
            read_empty <= 1'b0;
        end
    end
end






// **************************************************************************
// ** Credit counters...
// **************************************************************************

reg pending_clear_credits;
reg pending_add_credits;



(* keep = 1 *) wire [CREDIT_WIDTH-1 : 0] credit_add_value;
assign credit_add_value = ((dbg_ready == 1'b1) && (1'b1 == dbg_valid) && (dbg_eop == 1'b1))? {CREDIT_WIDTH{1'b1}} : credits_to_add;


(* altera_attribute = "-name FORCE_SYNCH_CLEAR ON -to *altera_trace_capture_rd_control:*|int_num_credits"*)  reg [CREDIT_WIDTH-1 :0] int_num_credits;

// Logic to handle tracking the number of credits, it's function is slightly obscure; becasue it is written to ensure that it meets timing and properly infers CLK_EN, SCLR and mux...
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        int_num_credits           <= {CREDIT_WIDTH{1'b0}};
        have_credits          <= 1'b0;
        pending_clear_credits <= 1'b0;
        pending_add_credits   <= 1'b0;
    end else begin
        pending_add_credits   <= pending_add_credits   || (credit_update &~clear_credits);
        pending_clear_credits <= pending_clear_credits || clear_credits;

      if (((dbg_ready == 1'b1) && (1'b1 == dbg_valid)) || (pending_clear_credits == 1'b1) || (pending_add_credits == 1'b1)) begin
          if (   ((1'b0 == dbg_valid) && (pending_clear_credits == 1'b1) && (dbg_sop == 1'b1))
               ||((1'b1 == dbg_valid) && (pending_clear_credits == 1'b1) && (dbg_ready == 1'b1) && (dbg_eop == 1'b1))
             ) begin  // sclr
                    int_num_credits       <= {CREDIT_WIDTH{1'b0}};
                    pending_clear_credits <= 1'b0;
                    have_credits          <= 1'b0;
          end else if ((dbg_ready == 1'b1) && (1'b1 == dbg_valid) && (dbg_eop == 1'b1)) begin
                 //int_num_credits <= int_num_credits - 1'b1;
                 int_num_credits <= int_num_credits + credit_add_value ;
                 if (int_num_credits < 'd2) begin
                     have_credits <= 1'b0;
                 end else begin
                     have_credits <= 1'b1;
                 end
          end else if (pending_add_credits == 1'b1) begin
                 //int_num_credits           <= int_num_credits + credits_to_add;
                 int_num_credits       <= int_num_credits + credit_add_value;
                 pending_add_credits   <= 1'b0;
                 have_credits          <= |credits_to_add;
// synthesis translate_off
                  if (credits_to_add == 'd0) begin
                      $fatal("Shouldn't add 0 credits!");
                  end
// synthesis translate_on
            end
        end
    end
end

assign num_credits = int_num_credits;






endmodule
