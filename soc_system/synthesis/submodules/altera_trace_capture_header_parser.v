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
//  Header parser, the purpose of this module is to parse through the cell headers in capture mode (store and forward)
//    It has 2 effects:
//        Update cell header pointers so we can parse forwards in the read module
//        find the effective "start" of the buffer in capture mode.
module altera_trace_capture_header_parser #(
    parameter DEVICE_FAMILY            = "Cyclone IV GX",
    parameter ADDR_WIDTH               = 1,
    parameter DATA_WIDTH               = 1,
    parameter MAX_ADDR                 = 1,
    parameter MIN_ADDR                 = 1,
    parameter HEADER_LENGTH_WIDTH      = 8
) (
    input  wire                             clk,
    input  wire                             arst_n,

    input  wire                             enable,
    input  wire                             mode_is_fifo,
    output reg                              processing_done,
    input  wire                             sys_active,
    input  wire                             has_wrapped,
    input  wire                             pointer_update,
    input  wire   [HEADER_LENGTH_WIDTH-1:0] most_recent_length,
    input  wire            [ADDR_WIDTH-1:0] most_recent_wdata_addr,
    input  wire            [ADDR_WIDTH-1:0] most_recent_wheader_addr,
    
    output reg             [ADDR_WIDTH-1:0] start_ptr,
    output reg             [ADDR_WIDTH-1:0] end_ptr,    

    output reg             [ADDR_WIDTH-1:0] mm_addr,
    output reg                              mm_wr,
    output reg                              mm_rd,
    input  wire                             mm_ready,
    output reg             [DATA_WIDTH-1:0] mm_wdata,

    input  wire                             mm_rdv,
    input  wire            [DATA_WIDTH-1:0] mm_rdata
);


localparam HDR_LEN_OFST = DATA_WIDTH -HEADER_LENGTH_WIDTH;

localparam S_IDLE        = 3'b000;
localparam S_READ        = 3'b001;
localparam S_RD_WAIT     = 3'b010;
localparam S_PROC        = 3'b011;
localparam S_WR_ACK      = 3'b100;
localparam S_GEN_HDR_ADR = 3'b101;

reg          [ADDR_WIDTH-1:0] hdr_addr;
reg                     [2:0] state;
reg          [DATA_WIDTH-1:0] proc_data;
reg [HEADER_LENGTH_WIDTH-1:0] curr_length;




localparam MAX_DAT_IN_BUFF = {1'b0, MAX_ADDR[ADDR_WIDTH-1:0]} - {1'b0,MIN_ADDR[ADDR_WIDTH-1:0]};
reg [ADDR_WIDTH : 0] sum_dat_read;




reg header_addr_due_to_wrap;

always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        state                   <= S_IDLE;
        curr_length             <= 'd0;
        hdr_addr                <= MAX_ADDR[ADDR_WIDTH-1:0];
        mm_addr                 <= MAX_ADDR[ADDR_WIDTH-1:0];
        mm_wdata                <= {DATA_WIDTH{1'b0}};
        mm_rd                   <= 1'b0;
        mm_wr                   <= 1'b0;
        processing_done         <= 1'b0;
        sum_dat_read            <= 'h0;
        header_addr_due_to_wrap <= 1'b0;
        proc_data               <= {DATA_WIDTH{1'b0}};
    end else begin
        case (state)
            S_IDLE:    begin
                          mm_rd <= 1'b0;
                          mm_wr <= 1'b0;            
                           if ((1'b0 == mode_is_fifo) && (1'b1 == enable) && (1'b0 == processing_done)) begin
                               state        <= S_READ;
                               hdr_addr     <= most_recent_wheader_addr;
                               curr_length  <= most_recent_length;
                               sum_dat_read <= most_recent_length + 1'b1;
                           end
                       end
                       
            S_READ:    begin
            			   mm_wr <= 1'b0; 
                           mm_rd <= 1'b1;
                           mm_addr <= hdr_addr;
                           
                           if (mm_ready & mm_rd) begin
                               mm_rd <= 1'b0;
                               state <= S_RD_WAIT;
                           end
                           
                           if (mm_rdv == 1'b1) begin
                               state     <= S_PROC;
                               proc_data <= mm_rdata;
                           end
                       end
                       
            S_RD_WAIT: begin
                          mm_rd <= 1'b0;
                          mm_wr <= 1'b0;              
                           if (mm_rdv == 1'b1) begin
                               state     <= S_PROC;
                               proc_data <= mm_rdata;
                           end                          
                       end
                       
            S_PROC:    begin        
                            mm_wdata                                      <= proc_data;
                            mm_wdata[HDR_LEN_OFST +: HEADER_LENGTH_WIDTH] <= curr_length[0+: HEADER_LENGTH_WIDTH];
                            curr_length[0+: HEADER_LENGTH_WIDTH]          <= proc_data[HDR_LEN_OFST +: HEADER_LENGTH_WIDTH];
                            mm_wr <= 1'b1;
                            mm_rd <= 1'b0; 
							state <= S_WR_ACK;  							
                       end

            S_WR_ACK:  begin
            				if (1'b1 == mm_ready) begin
            					mm_wr <= 1'b0;
            					state <= S_GEN_HDR_ADR;
            					sum_dat_read <= sum_dat_read + curr_length + 1'b1;   
            					
            					if ((hdr_addr) >= (MIN_ADDR[ADDR_WIDTH-1:0] + curr_length + 1'b1)) begin
            						header_addr_due_to_wrap <= 1'b0;
            					end else begin
            						header_addr_due_to_wrap <= 1'b1;
            					end
            					
            				end
                       end
                       
            S_GEN_HDR_ADR :
            	       begin
            	       	     if (~header_addr_due_to_wrap) begin                 	       	     	 
            	       	     	 hdr_addr <= hdr_addr - (curr_length + 1'b1);
            	       	     end else begin
            	       	     	 hdr_addr <= hdr_addr + (MAX_ADDR[ADDR_WIDTH-1:0] - MIN_ADDR[ADDR_WIDTH-1:0]) - curr_length;            	       	     	 
            	       	     end
            	       	     
            	       	     if (   (1'b0 == has_wrapped) 
            	       	     	 && (header_addr_due_to_wrap == 1'b1)             	       	     	 
            	       	     	) begin    // does this force us to start from addr 0 ??
            	       	     	 state           <= S_IDLE;
            	       	     	 processing_done <= 1'b1;
            	       	     end else if (   (1'b1 == has_wrapped) 
            	       	                  && (sum_dat_read >= MAX_DAT_IN_BUFF[ADDR_WIDTH:0] )
            	       	                 ) begin
            	       	         state           <= S_IDLE;
            	       	         processing_done <= 1'b1;
            	       	     end else begin
                                 state       <= S_READ;    	       	     
            	       	     end  
            	       end
        endcase
        
    	if (enable == 1'b0) begin 
    		processing_done <= 1'b0; 
        end        
        
    end
end



// register ouptuts driven to next module!
always @(posedge clk or negedge arst_n) begin
    if (arst_n == 0) begin
        start_ptr <= MAX_ADDR[ADDR_WIDTH-1:0];
        end_ptr   <= MAX_ADDR[ADDR_WIDTH-1:0];
    end else begin
        if (1'b1 == mode_is_fifo) begin   // note that in fifo_mode this adds a cycle of delay before we get the right value!
            start_ptr <= MAX_ADDR[ADDR_WIDTH-1:0];
        end else if (state == S_GEN_HDR_ADR) begin
        	// deal with wraping of the start addr!
			if (mm_addr == MIN_ADDR[ADDR_WIDTH-1:0]) begin
				start_ptr <= MAX_ADDR[ADDR_WIDTH-1:0]; 
			end else begin	
				start_ptr <= mm_addr - 1'b1;
			end
        end
        
        if (1'b0 == sys_active) begin
        	end_ptr <= MAX_ADDR[ADDR_WIDTH-1:0];
        end else if (pointer_update) begin
        	end_ptr <= most_recent_wdata_addr;
        end
        
    end
end



endmodule
