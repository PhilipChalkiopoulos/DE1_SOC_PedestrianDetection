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


// module designed to retun values based for trace.
//    address used is variabel size (based on number of distilers.

`default_nettype none
module altera_trace_rom #(
    parameter NUM_REGS         = 2,
    parameter REG_VALUE_STRING = "FEDCBA9876543210",      // also used as default value
    parameter ADDR_WIDTH       = 2,
    parameter DATA_WIDTH       = 32,

    parameter DP_REG_VALUE_BITS = hex_string_to_vector(REG_VALUE_STRING)
)(
    input  wire                  clk,
    input  wire                  arst_n,
    input  wire                  rom_read,
    input  wire [ADDR_WIDTH-1:0] rom_address,
    output reg  [DATA_WIDTH-1:0] rom_readdata
);

function  [NUM_REGS * 32 -1 : 0] hex_string_to_vector( input [NUM_REGS * 64 -1 : 0] sting_val);
begin : func_inner
    reg [NUM_REGS * 32 -1 : 0] retval;
    reg [7:0] char;
    integer regnum;
    integer nibble_num;
    reg  [3:0] nibble_value;
    for (regnum = 0; regnum < NUM_REGS; regnum = regnum + 1) begin
        for (nibble_num = 0; nibble_num < 8; nibble_num = nibble_num + 1) begin
            char         = sting_val[(regnum * 64) + (nibble_num * 8) +: 8];
			nibble_value = 4'h0; // 4'hX;   // better default is it means software is OK and gets 0 instead of a compile-time generated value
			//lookup table below converts a 8 bit ASCI char into a hex nibble.
            case (char)
                "0" : begin nibble_value = 4'h0; end
                "1" : begin nibble_value = 4'h1; end
                "2" : begin nibble_value = 4'h2; end
                "3" : begin nibble_value = 4'h3; end
                "4" : begin nibble_value = 4'h4; end
                "5" : begin nibble_value = 4'h5; end
                "6" : begin nibble_value = 4'h6; end
                "7" : begin nibble_value = 4'h7; end
                "8" : begin nibble_value = 4'h8; end
                "9" : begin nibble_value = 4'h9; end
                "A" : begin nibble_value = 4'hA; end
                "B" : begin nibble_value = 4'hB; end
                "C" : begin nibble_value = 4'hC; end
                "D" : begin nibble_value = 4'hD; end
                "E" : begin nibble_value = 4'hE; end
                "F" : begin nibble_value = 4'hF; end
                default : begin
//synthesis translate_off
                    $error("function can not decode the ASCII for 0x:%2x", char);
//synthesis translate_on
                          end
            endcase
            retval[(regnum * 32) + (nibble_num * 4)+:4] = nibble_value[0+:4];
        end // nibble exteraction
    end
    hex_string_to_vector = retval;
    //return(retval);
end
endfunction


// TODO: are we better off making read_addr only update when rom_read == 1'b1  it may have toggle rate implications..
(* dont_merge *) reg [ADDR_WIDTH-1:0] read_addr;
(* dont_merge *) reg                  rom_read_1t;

always @(posedge clk or negedge arst_n) begin
    if (1'b0 == arst_n) begin
        read_addr    <= {ADDR_WIDTH{1'b0}};
        rom_readdata <= {DATA_WIDTH{1'b0}};
        rom_read_1t  <= 1'b0;
    end else begin
        if (rom_read_1t == 1'b1)begin
            rom_readdata[0+:DATA_WIDTH] <= DP_REG_VALUE_BITS[DATA_WIDTH * read_addr[ADDR_WIDTH -1:0] +:DATA_WIDTH];
        end else begin
        	rom_readdata <= {DATA_WIDTH{1'b0}};        
        end

        rom_read_1t <= rom_read;
        read_addr   <= rom_address;

    end
end

endmodule
`default_nettype wire