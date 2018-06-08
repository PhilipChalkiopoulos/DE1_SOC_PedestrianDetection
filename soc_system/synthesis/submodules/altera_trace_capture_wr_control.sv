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


//    The write controller is responsible for formatting adn writing cells into the store.
//       each cell consists of a header and one or more packet parts.
//
//       the header indicates teh total size of the cell (current or last mode depndant)
//       and contains a number of Packet Part Descriptors PPD
//       a count value to indicate how many of the PPD contain valid data
//              (note we cant work this out from the PPD as having a length of 0 is not expressable! noor do we wnat to 'reserve' a distiller ID)
//
//       each PPD contains the following info:
//                length of the packet part in bytes   (0 = 2^n  as we can not have a packet part of size 0!)     however it a PPD is unused then the lenght should be set to 0!
//                if that packet part is the end of packet (for re-assembly)
//                the source distiller (channel) the packet part came from (reassembly)
//
//
//
//              General structure:
//
//
//                                                _____________
//          __________________                       |         |                  __________________
//         |                  |                      |   data  |                 |                  |
//         |                  |                      |  fifo   |                 |                  |
//         |                  |                   ___|_________|                 |                  |
//         |                  |        ______________                            |                  |
//         |   segment data   |       |              |                           | write controller |
//         |                  |       |  create cell |       _____________       |                  |
//         |                  |       |    headers   |          |         |      |                  |
//         |                  |       |              |          | header  |      |                  |
//         |                  |       |              |          |  fifo   |      |                  |
//         |__________________|       |______________|       ___|_________|      |__________________|
//
//
//
//   TODO
//       1/ write wrapped needs to handle start  / stop conditions and get reset!



module altera_trace_capture_wr_control #(
    parameter DEVICE_FAMILY            = "Cyclone IV GX",
    parameter ADDR_WIDTH               = 8,
    parameter DATA_WIDTH               = 64,
    parameter MAX_ADDR                 = 255,
    parameter MIN_ADDR                 = 0,
    parameter PPD_IN_HDR               = 4,
    parameter PPD_LEN                  = 6,
    parameter CH_WIDTH                 = 1,
    parameter ST_SYMBOL_WIDTH          = 8,
    parameter MTY_WIDTH                = 3,
    parameter INT_ALIGNMENT_BOUNDAIES  = 0,        // 0 = word, 1 = Byte, 2 = 2 Byte, 3 = 4 Byte, 4 = 8 Byte
    parameter WDATA_FIFO_ADDR_WIDTH    = 4,
    parameter HEADER_LENGTH_WIDTH      = $clog2(CH_WIDTH) + 1 + PPD_LEN,

    // derived_params
    parameter PPD_WIDTH                = 1 + PPD_LEN + CH_WIDTH

) (
    input  wire                             clk,
    input  wire                             arst_n,

    output reg                              trace_packet_ready,
    input  wire                             trace_packet_valid,
    input  wire                             trace_packet_sop,
    input  wire                             trace_packet_eop,
    input  wire            [DATA_WIDTH-1:0] trace_packet_data,
    input  wire              [CH_WIDTH-1:0] trace_packet_chnl,
    input  wire             [MTY_WIDTH-1:0] trace_packet_empty,

    input  wire                             wr_ready,
    output reg                              wr_valid,
    output reg             [ADDR_WIDTH-1:0] wr_address,
    output reg             [DATA_WIDTH-1:0] wr_data,
    output wire  [WDATA_FIFO_ADDR_WIDTH :0] wr_fill_lvl,    // wdata   ?do we need it?

    output wire                             last_data_in_cell,
    output wire                             data_is_header,

    input  wire                             enable,
    input  wire                             fifo_mode,
    output reg             [ADDR_WIDTH-1:0] wr_ptr_out,
    output reg             [ADDR_WIDTH-1:0] wr_last_hdr,
    output wire   [HEADER_LENGTH_WIDTH-1:0] last_hdr_real_size,
    output reg                              write_wrapped,

    input  wire                             trigger_enable,
    input  wire            [ADDR_WIDTH-1:0] post_trigger_words,
    output reg                              triggered,               // indicates that a trigger has been seen and we are, counting...
    output reg                              trigger_stop,            // indicates that we have hit the post-trigger threshold.
    output wire            [ADDR_WIDTH-1:0] trigger_words_remaining
);

localparam NUM_PPD_WIDTH      = $clog2(PPD_IN_HDR + 1);
localparam HEADER_LENGTH_OFST = DATA_WIDTH- HEADER_LENGTH_WIDTH;


    wire                  segmentised_ready;
    wire                  segmentised_valid;
    wire                  segmentised_eop;
    wire                  segmentised_sop;
    wire [DATA_WIDTH-1:0] segmentised_data;
    wire   [CH_WIDTH-1:0] segmentised_chnl;
    wire  [MTY_WIDTH-1:0] segmentised_empty;
    wire                  segment_eo;
    wire                  segment_new;
    wire    [PPD_LEN-1:0] segment_len;
    wire                  segmentised_cond_valid;




wire wdata_out_full;
wire   [DATA_WIDTH-1 :0] wdata_fifo_rdata;
wire                     wdata_fifo_read;
wire                     wdata_fifo_empty;

wire fifo_write;
wire   [DATA_WIDTH-1 :0] hdr_fifo_rdata;
wire                     hdr_fifo_read;
wire                     hdr_fifo_empty;

bit [HEADER_LENGTH_WIDTH-1:0] to_read_length;
bit                           to_read_length_is_zero;
bit                           writing_header;
bit [HEADER_LENGTH_WIDTH-1:0] last_read_length;



    wire                  re_aligned_ready;
    wire                  re_aligned_valid;
    wire [DATA_WIDTH-1:0] re_aligned_data;



// PPD Structure
typedef struct packed unsigned {
    bit                is_eop;
    bit [CH_WIDTH-1:0] channel;
    bit  [PPD_LEN-1:0] length;
} StructPPD;


StructPPD            [PPD_IN_HDR -1: 0]       ppd_arry ;
//synthesis translate_off
StructPPD            [PPD_IN_HDR -1: 0]       written_ppd_arry ;
//synthesis translate_on


bit [HEADER_LENGTH_WIDTH-1:0] curr_length;   //TODO: check SIZING!
bit                           eop_marked;
bit       [NUM_PPD_WIDTH-1:0] ppd_num;
wire      [NUM_PPD_WIDTH-1:0] next_ppd_num;

reg [DATA_WIDTH-1:0] header_wdata;
reg                  header_write;

reg   ppd_changed;
reg   segment_update;
reg   ppd_flush;


reg in_packet_part;

wire [WDATA_FIFO_ADDR_WIDTH-1:0] fill_level_int;
wire segment_trigger;

// segmentiser, will break up incoming avalon stream into packet parts.
//     i.e. large packets into smaller packet parts,
//     & detect packet part change on change of channel.
//    it aslo has a pipelined input for fmax!
altera_trace_capture_segmentiser #(
    .DATA_WIDTH            (DATA_WIDTH)
   ,.SYMBOL_WIDTH          (ST_SYMBOL_WIDTH)
   ,.MTY_WIDTH             (MTY_WIDTH)
   ,.CHANNEL_WIDTH         (CH_WIDTH)
   ,.SEGMENT_LENGTH_WIDTH  (PPD_LEN)
)segment(
    .clk                  (clk)
   ,.arst_n               (arst_n)

   ,.in_ready             (trace_packet_ready)
   ,.in_valid             (trace_packet_valid)
   ,.in_sop               (trace_packet_sop)
   ,.in_eop               (trace_packet_eop)
   ,.in_data              (trace_packet_data)
   ,.in_mty               (trace_packet_empty)
   ,.in_chnl              (trace_packet_chnl)

   ,.out_ready            (segmentised_ready)
   ,.out_valid            (segmentised_valid)
   ,.out_sop              (segmentised_sop)
   ,.out_eop              (segmentised_eop)
   ,.out_data             (segmentised_data)
   ,.out_mty              (segmentised_empty)
   ,.out_chnl             (segmentised_chnl)

   ,.new_segment          (segment_new)
   ,.segment_length       (segment_len)
   ,.eo_segment           (segment_eo)
   ,.trigger_det          (segment_trigger)
);



// the in packet part signal is used to ensure that in response to enable we only get data at suitable packet boundaries!,
// if the write control is not enabled then we will discard the data on the input
always_ff @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        in_packet_part <= 1'b0;
    end else begin
        if ((segmentised_ready == 1'b1) && (segmentised_valid == 1'b1)) begin
             if ((segment_new == 1'b1) && (enable == 1'b1)) begin
                 in_packet_part <= 1'b1;
             end else if ((enable == 1'b0) && (segment_eo == 1'b1)) begin
                 in_packet_part <= 1'b0;
             end
        end else if ((segmentised_valid == 1'b0) && (enable == 1'b0)) begin
            in_packet_part <= 1'b0;
        end
    end
end

assign segmentised_cond_valid = segmentised_valid & (in_packet_part | (enable & segment_new));

assign next_ppd_num = (({1'b0, ppd_num} + 1'b1 ) == PPD_IN_HDR[NUM_PPD_WIDTH:0]) ? {NUM_PPD_WIDTH{1'b0}} : ppd_num + 1'b1;



reg ppd_used;
// This block's purpose is to update and pack the PPD structures internally.
always_ff @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        for(int i = 0; i<PPD_IN_HDR; i++) begin
            ppd_arry[i] <= {(1+ PPD_LEN + CH_WIDTH){1'b0}};  // this should be the same as PPD_SIZE!
        end
        ppd_num          <= {NUM_PPD_WIDTH{1'b0}};
        eop_marked       <= 1'b1;
        ppd_changed      <= 1'b0;
        segment_update   <= 1'b0;
        ppd_flush        <= 1'b0;
        ppd_used         <= 1'b0;
    end else begin
        ppd_changed      <= 1'b0;
        segment_update   <= 1'b0;
        ppd_flush        <= 1'b0;
        if (   (1'b1 == segmentised_ready)
             &&(1'b1 == segmentised_cond_valid)
            )begin
            segment_update   <= 1'b1;

            if (segment_eo == 1'b1) begin
                eop_marked  <= 1'b1;
            end else if (segment_new == 1'b1) begin
                eop_marked  <= 1'b0;
            end

            ppd_used <= 1'b1;
            
            if (  ((segment_new == 1'b1) && (eop_marked  == 1'b0) && (ppd_used == 1'b1))
                ||((segment_eo == 1'b1)  && (eop_marked  == 1'b0))
                ||((segment_new == 1'b1) && (segment_eo == 1'b1))
               )begin
                ppd_num     <= next_ppd_num;
                ppd_changed <= 1'b1;
                ppd_used    <= 1'b0;
            end

  
            
            if ((segment_new == 1'b1) && (eop_marked  == 1'b0) && (ppd_used == 1'b1)) begin  // insert into a new PPD!
                ppd_arry[next_ppd_num].length  <= segment_len;
                ppd_arry[next_ppd_num].is_eop  <= segmentised_eop;
                ppd_arry[next_ppd_num].channel <= segmentised_chnl;
                ppd_used <= 1'b1;
            end else begin
                ppd_arry[ppd_num].length  <= segment_len;
                ppd_arry[ppd_num].is_eop  <= segmentised_eop;
                ppd_arry[ppd_num].channel <= segmentised_chnl;
            end
        end else if (   (in_packet_part == 1'b0) 
                     && (ppd_flush == 1'b0)
        			 //&& (enable == 0)
                     && (  ((ppd_used == 1'b1) && (ppd_num == 0))
                         | (ppd_num != 0)
                        ) 
                    ) begin
            segment_update   <= 1'b1;
            ppd_flush        <= 1'b1;       

        end else if (ppd_flush == 1'b1) begin
            ppd_num  <= 'd0;
            ppd_used <= 1'b0;                
        end

    end
end


// This blocks purpose is to write a header into the header fifo.
always_ff @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        curr_length      <= 'd0;
        header_write     <= 1'b0;
        header_wdata     <= {DATA_WIDTH{1'b0}};
//synthesis translate_off
        for(int i = 0; i<PPD_IN_HDR; i++) begin
            written_ppd_arry[i] <= {(1+ PPD_LEN + CH_WIDTH){1'b0}};  // this should be the same as PPD_SIZE!
        end
//synthesis translate_on
    end else begin
        header_write <= 1'b0;
        if (1'b1 == segment_update) begin
            curr_length <= curr_length + 1'b1;

            if (((1'b1 == ppd_changed) && (ppd_num == 'd0)) || (ppd_flush == 1'b1)) begin

                header_write <= 1'b1;
                header_wdata <= {DATA_WIDTH{1'b0}};

                // insert num_ppd
                if (ppd_num == 'd0) begin   // this handles the data flushing condition!
                    header_wdata[0+: NUM_PPD_WIDTH] <= PPD_IN_HDR[0+: NUM_PPD_WIDTH];
                end else begin
                    header_wdata[0+: NUM_PPD_WIDTH] <= ppd_num;
                end

                //  DODGY FLushing Stuff.
                if ((ppd_flush == 1'b1)) begin
                	if (1'b0 == ppd_used) begin
                		header_wdata[0+: NUM_PPD_WIDTH] <= ppd_num;
					end else begin
						header_wdata[0+: NUM_PPD_WIDTH] <= ppd_num + 1'b1;					
					end
                end
                
                // insert PPD's
                for(int i = 0; i<PPD_IN_HDR; i++) begin
                    header_wdata[(PPD_WIDTH * i) + NUM_PPD_WIDTH +: PPD_WIDTH] <= ppd_arry[i];
//synthesis translate_off
                    written_ppd_arry[i]                                        <= ppd_arry[i];
//synthesis translate_on
                end

                // reset current length for next header
                curr_length <= 'd0;

                // insert number of words of header.
                header_wdata[HEADER_LENGTH_OFST +: HEADER_LENGTH_WIDTH] <= curr_length[0 +: HEADER_LENGTH_WIDTH] + {{(HEADER_LENGTH_WIDTH-1){1'b0}}, ~ppd_flush};
            end
        end
    end
end



// generate loop to enable us to add in better packet part packing later on.
generate
if (INT_ALIGNMENT_BOUNDAIES == 0) begin: align_to_word_boundaries
    assign segmentised_ready = re_aligned_ready;
    assign re_aligned_valid  = segmentised_cond_valid;
    assign re_aligned_data   = segmentised_data;
end else begin: generate_packet_part_repacking
    assign segmentised_ready = re_aligned_ready;
    assign re_aligned_valid  = segmentised_cond_valid;
    assign re_aligned_data   = segmentised_data;

    initial begin
        $display("mode not yet supported, treating alignemtns as though it was: INT_ALIGNMENT_BOUNDAIES = 0");
        $display("NOTE: this will also need to 'update' the headers for their new lenght and EOP");
        $stop();
    end
end
endgenerate



//synthesis translate_off
always @(posedge clk) begin
	if (arst_n == 1'b1) begin
		if (header_write == 1'b1) begin
			if (header_wdata[0+: NUM_PPD_WIDTH] == 'd0) begin
				$display("can write a num_ppd of 0!");
				$stop();
			end
		end
	end
end
//synthesis translate_on



assign re_aligned_ready = ~wdata_out_full;
assign fifo_write       = re_aligned_ready & re_aligned_valid;



// SCFIFO for WDATA.
    scfifo #(
         .intended_device_family  (DEVICE_FAMILY)
        ,.lpm_type                ("scfifo")
        ,.lpm_width               (DATA_WIDTH)
        ,.lpm_numwords            (1 << WDATA_FIFO_ADDR_WIDTH)
        ,.lpm_widthu              (WDATA_FIFO_ADDR_WIDTH)
        ,.almost_empty_value      (2)
        ,.almost_full_value       (8)
        ,.add_ram_output_register ("ON")
        ,.lpm_showahead           ("ON")
        ,.overflow_checking       ("OFF")
        ,.underflow_checking      ("OFF")
        ,.use_eab                 ("ON")
    )wdata_sc_fifo(
         .clock                   (clk)
        ,.aclr                    (~arst_n)
        ,.usedw                   (fill_level_int)    // DODGY place to supply this from!
        ,.full                    (wdata_out_full)
        ,.almost_full             ()
        ,.wrreq                   (fifo_write)
        ,.data                    (re_aligned_data)
        ,.empty                   (wdata_fifo_empty)
        ,.almost_empty            ()
        ,.rdreq                   (wdata_fifo_read)
        ,.q                       (wdata_fifo_rdata)
//synthesis translate_off
        ,.sclr ()
//synthesis translate_on
    );

    assign wr_fill_lvl = {wdata_out_full, fill_level_int};


//// Header FIFO  : note that this is timing critical!
    scfifo #(
         .intended_device_family  (DEVICE_FAMILY)
        ,.lpm_type                ("scfifo")
        ,.lpm_width               (DATA_WIDTH)
        ,.lpm_numwords            (1 << WDATA_FIFO_ADDR_WIDTH)
        ,.lpm_widthu              (WDATA_FIFO_ADDR_WIDTH)
        ,.almost_empty_value      (2)
        ,.almost_full_value       (8)
        ,.add_ram_output_register ("ON")
        ,.lpm_showahead           ("ON")
        ,.overflow_checking       ("OFF")
        ,.underflow_checking      ("OFF")
        ,.use_eab                 ("ON")
    )hdr_sc_fifo(
         .clock                   (clk)
        ,.aclr                    (~arst_n)
        ,.usedw                   ()
        ,.full                    ()
        ,.almost_full             ()
        ,.wrreq                   (header_write)
        ,.data                    (header_wdata)
        ,.empty                   (hdr_fifo_empty)
        ,.almost_empty            ()
        ,.rdreq                   (hdr_fifo_read)
        ,.q                       (hdr_fifo_rdata)
//synthesis translate_off
        ,.sclr ()
//synthesis translate_on
    );



reg last_enable_value;
reg reset_wr_addr;

always_ff @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        last_enable_value <= 1'b0;
        reset_wr_addr     <= 1'b0;
    end else begin
        last_enable_value <= enable;
        reset_wr_addr     <= enable &~ last_enable_value;
    end
end

// write state machine.
//   when header fifo is not empty, get a header, read the indicated ammount of data from the write data fifo
//  NOTE: to support the different modes, we may need to be able to delay the length feild to the next cell header,
//        this means we can parse backwards and dont need to structure it as a double lniked list.
always_ff @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        wr_valid               <= 1'b0;
        wr_address             <= MIN_ADDR[ADDR_WIDTH-1:0];
        wr_data                <= {DATA_WIDTH{1'b0}};
        to_read_length         <= {HEADER_LENGTH_WIDTH{1'b0}};
        wr_ptr_out             <= MAX_ADDR[ADDR_WIDTH-1:0];
        to_read_length_is_zero <= 1'b1;
        writing_header         <= 1'b0;
        wr_last_hdr            <= {ADDR_WIDTH{1'b0}};
        write_wrapped          <= 1'b0;
        last_read_length       <= 'd0;
    end else begin

        if ((1'b1 == wr_ready) && (1'b1 == wr_valid)) begin
            wr_valid       <= 1'b0;
            writing_header <= 1'b0;

            if (wr_address == MAX_ADDR[ADDR_WIDTH-1:0]) begin
                wr_address    <= MIN_ADDR[ADDR_WIDTH-1:0];
                write_wrapped <= 1'b1;
            end else begin
                wr_address <= wr_address + 1'b1;
            end

            if (writing_header == 1'b1) begin
                wr_last_hdr <= wr_address;
            end

            if (to_read_length_is_zero == 1'b1) begin
                if (hdr_fifo_empty == 1'b0) begin
                    wr_data                <= hdr_fifo_rdata;
                    to_read_length         <= hdr_fifo_rdata[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH];
                    last_read_length       <= hdr_fifo_rdata[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH];
                    to_read_length_is_zero <= ~|hdr_fifo_rdata[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH];
                    wr_valid               <= 1'b1;
                    writing_header         <= 1'b1;

                    if (fifo_mode == 1'b0) begin
                        wr_data[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH] <= last_read_length[0+: HEADER_LENGTH_WIDTH];
                    end
                end
                wr_ptr_out     <= wr_address;
            end else begin
                if (wdata_fifo_empty == 1'b0) begin
                    wr_valid       <= 1'b1;
                    wr_data        <= wdata_fifo_rdata;
                    to_read_length <= to_read_length -1'b1;

                    if (to_read_length < 'd2) begin
                        to_read_length_is_zero <= 1'b1;
                    end else begin
                        to_read_length_is_zero <= 1'b0;
                    end
                end
            end
        end else if (1'b0 == wr_valid) begin
            writing_header         <= 1'b0;
            if (to_read_length_is_zero == 1'b1) begin
                if (hdr_fifo_empty == 1'b0) begin
                    wr_data                <= hdr_fifo_rdata;
                    to_read_length         <= hdr_fifo_rdata[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH];
                    last_read_length       <= hdr_fifo_rdata[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH];
                    to_read_length_is_zero <= ~|hdr_fifo_rdata[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH];
                    wr_valid               <= 1'b1;
                    writing_header         <= 1'b1;

                    if (fifo_mode == 1'b0) begin
                        wr_data[HEADER_LENGTH_OFST+: HEADER_LENGTH_WIDTH] <= last_read_length[0+: HEADER_LENGTH_WIDTH];
                    end
                end else begin
                    to_read_length         <= to_read_length;
                end

            end else begin
                if (wdata_fifo_empty == 1'b0) begin
                    wr_valid       <= 1'b1;
                    wr_data        <= wdata_fifo_rdata;
                    to_read_length <= to_read_length -1'b1;

                    if (to_read_length < 'd2) begin
                        to_read_length_is_zero <= 1'b1;
                    end else begin
                        to_read_length_is_zero <= 1'b0;
                    end
                end
            end
        end

        if (reset_wr_addr) begin
            wr_address    <= MIN_ADDR[ADDR_WIDTH-1:0];
            write_wrapped <= 1'b0;
        end
    end
end


assign last_data_in_cell = wr_valid & to_read_length_is_zero;
assign data_is_header    = writing_header;

// generate write and read signals for the FIFOS combinatorially, although simpler it means we may need the pipelining stage later!
assign wdata_fifo_read = ( ((1'b1 == wr_ready) && (1'b1 == wr_valid) && (to_read_length_is_zero != 1'b1))                             || ((1'b0 == wr_valid) && (to_read_length_is_zero != 1'b1) && (wdata_fifo_empty == 1'b0)) )? 1'b1 : 1'b0;
assign hdr_fifo_read   = ( ((1'b1 == wr_ready) && (1'b1 == wr_valid) && (to_read_length_is_zero == 1'b1) && (hdr_fifo_empty == 1'b0)) || ((1'b0 == wr_valid) && (to_read_length_is_zero == 1'b1) && (hdr_fifo_empty == 1'b0)) )? 1'b1 : 1'b0;


assign last_hdr_real_size = last_read_length;


// Triggering
// if writing is enabeled, & triggering is enabeled, on receipt of a trigger:
//      0/ assert triggered    (we can see that we are waiting for buff to empty.
//      1/ wait for EOP on that channel
//      2/ wait for post_trigger_words to elapse (stored words)
//      3/ assert & hold trigger_stop
//      4/ reset on enable being deasserted

reg [ADDR_WIDTH-1:0] trigger_count;
reg                  stored_channel;
reg                  trigger_packet_complete;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
        triggered     <= 1'b0;
        trigger_stop  <= 1'b0;
        trigger_count <= {ADDR_WIDTH{1'b0}};
    end else begin
        if (enable & ~last_enable_value) begin
             triggered               <= 1'b0;
             trigger_stop            <= 1'b0;
             trigger_count           <= post_trigger_words;
        end else begin
            if (triggered & ~trigger_stop) begin

                if (header_write & fifo_write) begin
                    trigger_count <= trigger_count - 2'b10;
                end else if (header_write ^ fifo_write) begin
                    trigger_count <= trigger_count - 2'b01;
                end

                if ('h2 >= trigger_count) begin
                    trigger_stop <= trigger_enable;
                end
            end

            if (trigger_packet_complete) begin
                triggered <= 1'b1;
            end
            
            if (enable == 1'b0) begin
            	trigger_stop <= 1'b0;
            end

        end
    end
end

reg                  pending_trigger;
reg   [CH_WIDTH-1:0] pending_trigger_channel;
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
        trigger_packet_complete  <= 1'b0;
        pending_trigger          <= 1'b0;
        pending_trigger_channel  <= {CH_WIDTH{1'b0}};
    end else begin
        if ((enable == 1'b0) || (trigger_enable == 1'b0)) begin
            trigger_packet_complete  <= 1'b0;
            pending_trigger          <= 1'b0;
        end else if (segmentised_ready & segmentised_valid) begin
            if (pending_trigger) begin
                if (pending_trigger_channel == segmentised_chnl) begin
                    trigger_packet_complete <= segmentised_eop;
                end
            end else if (segment_trigger) begin
                if (segmentised_eop) begin
                    trigger_packet_complete <= 1'b1;
                end else begin
                    pending_trigger         <= 1'b1;
                    pending_trigger_channel <= segmentised_chnl;
                end
            end
        end
    end
end


assign trigger_words_remaining = trigger_count;



endmodule
