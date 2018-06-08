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


// currently assumes HEADER_SIZE          == 128
// also assumes      TRACE_DATA_OUT_WIDTH == 32
// also asusmes      SAMPLE_SIZE          == 30

module altera_trace_av_st_vpg_output #(
    parameter DEVICE_FAMILY          = "null",
    parameter HEADER_SIZE            = 104,
    parameter SAMPLE_SIZE            = 30,
    parameter TRACE_OUT_SYM_WIDTH    = 4,
    parameter BUFF_ADDR_WIDTH        = 10,
    // derived params
    parameter TRACE_OUT_DATA_WIDTH   = TRACE_OUT_SYM_WIDTH * 8,
    parameter TRACE_OUT_EMPTY_WIDTH  = $clog2(TRACE_OUT_SYM_WIDTH),
    parameter MAX_SYMS_IN_HDR        = (HEADER_SIZE +7)/ 8,
    parameter HEADER_COUNT_WIDTH     = $clog2(MAX_SYMS_IN_HDR+1)
) (
    input  wire                              clk,
    input  wire                              arst_n,

    input  wire            [HEADER_SIZE-1:0] header_data,
    input  wire     [HEADER_COUNT_WIDTH-1:0] header_syms,
    input  wire                              header_write,
    input  wire                              no_sample_flush,
    output wire                              header_write_busy,

    input  wire            [SAMPLE_SIZE-1:0] sample_data,
    input  wire                              sample_write,
    input  wire                              sample_is_eop,
    output wire                              sample_buff_full,

    input  wire                              av_st_tr_ready,
    output reg                               av_st_tr_valid,
    output reg                               av_st_tr_sop,
    output reg                               av_st_tr_eop,
    output wire   [TRACE_OUT_DATA_WIDTH-1:0] av_st_tr_data,
    output reg   [TRACE_OUT_EMPTY_WIDTH-1:0] av_st_tr_empty
);

localparam LP_SYMS_IN_SAMPLE_SIZE = (SAMPLE_SIZE + 7) / 8;
localparam LP_LIMIT_FOR_ADDING   = MAX_SYMS_IN_HDR - TRACE_OUT_SYM_WIDTH;


 wire                              fifo_full;
 wire        [SAMPLE_SIZE-1:0]     fifo_out_data;
 wire                              fifo_out_eop;
 reg                               fifo_read;
 wire                              fifo_empty;

 assign sample_buff_full = fifo_full;


 // FIfo to hold pixel samples
    scfifo #(
         .intended_device_family  (DEVICE_FAMILY)
        ,.lpm_type                ("scfifo")
        ,.lpm_width               (SAMPLE_SIZE + 1)
        ,.lpm_numwords            (1 << BUFF_ADDR_WIDTH)
        ,.lpm_widthu              (BUFF_ADDR_WIDTH)
        ,.almost_empty_value      (2)
        ,.almost_full_value       (8)
        ,.add_ram_output_register ("ON")
        ,.lpm_showahead           ("ON")
        ,.overflow_checking       ("OFF")
        ,.underflow_checking      ("OFF")
        ,.use_eab                 ("ON")
    )pxl_smpl_fifo(
         .clock                   (clk)
        ,.aclr                    (~arst_n)
        ,.usedw                   ()
        ,.full                    (fifo_full)
        ,.almost_full             ()
        ,.wrreq                   (sample_write & ~fifo_full)
        ,.data                    ({sample_is_eop, sample_data})
        ,.empty                   (fifo_empty)
        ,.almost_empty            ()
        ,.rdreq                   (fifo_read)
        ,.q                       ({fifo_out_eop, fifo_out_data})
//synthesis translate_off
        ,.sclr ()
//synthesis translate_on
    );


reg [HEADER_SIZE-1:0]     stored_data;
reg                       header_valid;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
        header_valid <= 1'b0;
    end else begin
        if (header_valid == 1'b1) begin
            header_valid <= 1'b0;
        end else if (header_write ) begin
            header_valid <= 1'b1;
        end
    end
end

reg [1:0] state;
localparam STATE_IDL      = 2'b00;
localparam STATE_HDR_RDY  = 2'b01;
localparam STATE_DATA     = 2'b10;
localparam FINISH_SEND    = 2'b11;

reg   [HEADER_COUNT_WIDTH-1 : 0] syms_to_send;
wire [TRACE_OUT_EMPTY_WIDTH : 0] next_trace_empty_out;


assign next_trace_empty_out = TRACE_OUT_SYM_WIDTH[TRACE_OUT_EMPTY_WIDTH : 0] - syms_to_send[TRACE_OUT_EMPTY_WIDTH : 0];



// main SM process
// TODO tidy this and get it to 100% output bandwidth...
// it also needs timing optimisation
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
        state           <= 2'b00;
        av_st_tr_valid  <= 1'b0;
        av_st_tr_sop    <= 1'b0;
        av_st_tr_eop    <= 1'b0;
        av_st_tr_empty  <= 0;
    end else begin
        case (state)
          STATE_IDL:  begin
              if (header_write) begin
                state          <= STATE_HDR_RDY;
                av_st_tr_valid <= 1'b0;
                av_st_tr_sop   <= 1'b1;
                av_st_tr_empty  <= 0;
              end
          end

          STATE_HDR_RDY:  begin

             if (av_st_tr_valid & av_st_tr_ready) begin
                 av_st_tr_sop   <= 1'b0;
                 if (syms_to_send > 2* TRACE_OUT_SYM_WIDTH) begin
                    av_st_tr_valid <= 1'b1;
                 end else begin
                    av_st_tr_valid <= 1'b0;
                 end
             end else begin
                 if (syms_to_send > TRACE_OUT_SYM_WIDTH) begin
                    av_st_tr_valid <= 1'b1;
                 end else begin
                    av_st_tr_valid <= 1'b0;
                 end
             end

//             if ((no_sample_flush == 1'b1) || ( fifo_empty == 1'b0))begin
//                if (no_sample_flush == 1'b1) begin
//                   if (TRACE_OUT_SYM_WIDTH >=syms_to_send) begin
//                         av_st_tr_empty <= next_trace_empty_out[TRACE_OUT_EMPTY_WIDTH-1:0];
//                         av_st_tr_eop   <= 1'b1;
//                   end else begin
//                         av_st_tr_empty <= 'd0;
//                         av_st_tr_eop   <= 1'b0;
//                   end
//                   state          <= FINISH_SEND;
//                end else begin
//                   av_st_tr_eop   <= 1'b0;
//                   state          <= STATE_DATA;
//                end
//             end

            if (sample_write == 1'b1) begin
                   av_st_tr_eop   <= 1'b0;
                   state          <= STATE_DATA;
            end else if (no_sample_flush == 1'b1) begin
                if (TRACE_OUT_SYM_WIDTH >=syms_to_send) begin
                       av_st_tr_empty <= next_trace_empty_out[TRACE_OUT_EMPTY_WIDTH-1:0];
                       av_st_tr_eop   <= 1'b1;
                end else begin
                       av_st_tr_empty <= 'd0;
                       av_st_tr_eop   <= 1'b0;
                end
                state          <= FINISH_SEND;
            end

          end

          STATE_DATA: begin
             if (av_st_tr_valid & av_st_tr_ready) begin
                 av_st_tr_sop   <= 1'b0;
                 if (syms_to_send > 2* TRACE_OUT_SYM_WIDTH) begin
                    av_st_tr_valid <= 1'b1;
                 end else begin
                    av_st_tr_valid <= 1'b0;
                 end
             end else begin
                 if (syms_to_send > TRACE_OUT_SYM_WIDTH) begin
                    av_st_tr_valid <= 1'b1;
                 end else begin
                    av_st_tr_valid <= 1'b0;
                 end
             end


             if (fifo_read & fifo_out_eop) begin
                 state <= FINISH_SEND;
             end

          end

          FINISH_SEND : begin
              av_st_tr_valid <= 1'b1;
              if ((av_st_tr_ready == 1'b1) && (av_st_tr_valid == 1'b1))begin
                  av_st_tr_sop   <= 1'b0;

                  if (TRACE_OUT_SYM_WIDTH * 2  >= syms_to_send) begin
                      av_st_tr_empty <= next_trace_empty_out[TRACE_OUT_EMPTY_WIDTH-1:0];
                      av_st_tr_eop   <= 1'b1;
                  end

                  if (av_st_tr_eop == 1'b1) begin
                      av_st_tr_valid <= 1'b0;
                      state          <= STATE_IDL;
                      av_st_tr_eop   <= 1'b0;
                  end
              end else begin
                  if (TRACE_OUT_SYM_WIDTH >= syms_to_send) begin
                      av_st_tr_empty <= next_trace_empty_out[TRACE_OUT_EMPTY_WIDTH-1:0];
                      av_st_tr_eop   <= 1'b1;
                  end
              end
          end
       endcase
    end
end




always @(*) begin
    fifo_read = 0;
    if (fifo_empty == 0) begin
        if (LP_LIMIT_FOR_ADDING[HEADER_COUNT_WIDTH-1 : 0] >= syms_to_send [HEADER_COUNT_WIDTH-1 : 0]) begin
           //if (state == STATE_HDR_RDY) begin
           //    fifo_read = 1;
           //end else
            if (state == STATE_DATA) begin
                fifo_read = 1;
            end
   //   end else if (LP_LIMIT_FOR_ADDING[HEADER_COUNT_WIDTH-1 : 0] == syms_to_send [HEADER_COUNT_WIDTH-1 : 0]) begin

        end
    end

end



wire data_sload;
assign data_sload = header_write & (state == STATE_IDL);

reg [1:0] data_move_mode;

always @(*) begin
    data_move_mode = 2'b00;
    data_move_mode[0] = av_st_tr_valid & av_st_tr_ready;
    data_move_mode[1] = fifo_read;            // this ties into FIFO_READ...
end


wire update;
assign update = data_sload | (data_move_mode != 2'b00);

// let's simplify the datapath...
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 1'b0) begin
       stored_data    <= 'd0;
       syms_to_send   <= {HEADER_COUNT_WIDTH{1'b0}};
    end else begin
         if (update) begin
            if (data_sload) begin
                stored_data    <= header_data;
                syms_to_send   <= header_syms;
            end else begin
                case (data_move_mode)
                    2'b01: begin   // shift out
                           stored_data    <= stored_data << TRACE_OUT_DATA_WIDTH;
                           syms_to_send   <= syms_to_send - TRACE_OUT_SYM_WIDTH[TRACE_OUT_EMPTY_WIDTH:0];
                    end

                    2'b11: begin // shift_out and shift_in
                         syms_to_send <= syms_to_send + (LP_SYMS_IN_SAMPLE_SIZE[HEADER_COUNT_WIDTH-1:0] - TRACE_OUT_SYM_WIDTH[TRACE_OUT_EMPTY_WIDTH:0]);
                         stored_data  <= stored_data << TRACE_OUT_DATA_WIDTH;
                         stored_data[HEADER_SIZE - (8*(syms_to_send[HEADER_COUNT_WIDTH-1:0] - TRACE_OUT_SYM_WIDTH[TRACE_OUT_EMPTY_WIDTH:0])) +  -1-: LP_SYMS_IN_SAMPLE_SIZE * 8]
                             <= {(LP_SYMS_IN_SAMPLE_SIZE * 8){1'b0}} | fifo_out_data[SAMPLE_SIZE-1 -: SAMPLE_SIZE];
                    end

                    2'b10: begin // shift_in
                         syms_to_send <= syms_to_send + LP_SYMS_IN_SAMPLE_SIZE[HEADER_COUNT_WIDTH-1:0];
                         stored_data[HEADER_SIZE - (8*syms_to_send[HEADER_COUNT_WIDTH-1:0]) -1-: LP_SYMS_IN_SAMPLE_SIZE * 8]
                             <= {(LP_SYMS_IN_SAMPLE_SIZE * 8){1'b0}} | fifo_out_data[SAMPLE_SIZE-1 -: SAMPLE_SIZE];
                    end
                endcase
            end
       end
    end
end


assign av_st_tr_data[TRACE_OUT_DATA_WIDTH-1 -: TRACE_OUT_DATA_WIDTH]  = stored_data[HEADER_SIZE-1 -: TRACE_OUT_DATA_WIDTH];
assign header_write_busy = (STATE_IDL != state);


endmodule
