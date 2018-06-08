-- soc_system_alt_vip_cpr_1_tb.vhd


library IEEE;
library altera;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use altera.alt_cusp151_package.all;

entity soc_system_alt_vip_cpr_1_tb is
end entity soc_system_alt_vip_cpr_1_tb;

architecture rtl of soc_system_alt_vip_cpr_1_tb is
	component alt_cusp151_clock_reset is
		port (
			clock : out std_logic;
			reset : out std_logic
		);
	end component alt_cusp151_clock_reset;

	component soc_system_alt_vip_cpr_1 is
		generic (
			DIN0_SYMBOLS_PER_BEAT  : integer := 3;
			DIN1_SYMBOLS_PER_BEAT  : integer := 3;
			DOUT0_SYMBOLS_PER_BEAT : integer := 1;
			DOUT1_SYMBOLS_PER_BEAT : integer := 3;
			DIN1_ENABLED           : integer := 0;
			DOUT1_ENABLED          : integer := 0;
			PARAMETERISATION       : string  := "<colourPatternRearrangerParams><CPR_NAME>Color Plane Sequencer</CPR_NAME><CPR_BPS>8</CPR_BPS><CPR_PORTS><INPUT_PORT><NAME>din0</NAME><STREAMING_DESCRIPTOR>[Y:Cb:Cr]</STREAMING_DESCRIPTOR><ENABLED>true</ENABLED></INPUT_PORT><INPUT_PORT><NAME>din1</NAME><STREAMING_DESCRIPTOR>[Channel]</STREAMING_DESCRIPTOR><ENABLED>false</ENABLED></INPUT_PORT><OUTPUT_PORT><NAME>dout0</NAME><STREAMING_DESCRIPTOR>[Y,Cb,Cr]</STREAMING_DESCRIPTOR><ENABLED>true</ENABLED><NON_IMAGE_PACKET_SOURCE>din0</NON_IMAGE_PACKET_SOURCE><HALVE_WIDTH>false</HALVE_WIDTH></OUTPUT_PORT><OUTPUT_PORT><NAME>dout1</NAME><STREAMING_DESCRIPTOR>[Channel]</STREAMING_DESCRIPTOR><ENABLED>false</ENABLED><NON_IMAGE_PACKET_SOURCE>din0</NON_IMAGE_PACKET_SOURCE><HALVE_WIDTH>false</HALVE_WIDTH></OUTPUT_PORT></CPR_PORTS><CPR_INPUT_2_PIXELS>false</CPR_INPUT_2_PIXELS></colourPatternRearrangerParams>";
			AUTO_DEVICE_FAMILY     : string  := ""
		);
		port (
			clock               : in  std_logic                     := 'X';
			din0_data           : in  std_logic_vector(23 downto 0) := (others => 'X');
			din0_endofpacket    : in  std_logic                     := 'X';
			din0_ready          : out std_logic;
			din0_startofpacket  : in  std_logic                     := 'X';
			din0_valid          : in  std_logic                     := 'X';
			dout0_data          : out std_logic_vector(23 downto 0);
			dout0_endofpacket   : out std_logic;
			dout0_ready         : in  std_logic                     := 'X';
			dout0_startofpacket : out std_logic;
			dout0_valid         : out std_logic;
			reset               : in  std_logic                     := 'X'
		);
	end component soc_system_alt_vip_cpr_1;

	signal dut_din0_ready    : std_logic;                    -- dut:din0_ready -> din0_tester:data
	signal din0_tester_q     : std_logic_vector(0 downto 0); -- din0_tester:q -> dut:din0_valid
	signal builtin_1_w1_q    : std_logic_vector(0 downto 0); -- ["1", builtin_1_w1:q, "1"] -> [din0_tester:ena, dut:dout0_ready]
	signal clocksource_clock : std_logic;                    -- clocksource:clock -> [dut:clock, din0_tester:clock]
	signal clocksource_reset : std_logic;                    -- clocksource:reset -> din0_tester:reset

begin

	builtin_1_w1_q <= "1";

	clocksource : component alt_cusp151_clock_reset
		port map (
			clock => clocksource_clock, -- clock.clk
			reset => clocksource_reset  --      .reset
		);

	dut : component soc_system_alt_vip_cpr_1
		generic map (
			DIN0_SYMBOLS_PER_BEAT  => 3,
			DIN1_SYMBOLS_PER_BEAT  => 0,
			DOUT0_SYMBOLS_PER_BEAT => 3,
			DOUT1_SYMBOLS_PER_BEAT => 0,
			DIN1_ENABLED           => 0,
			DOUT1_ENABLED          => 0,
			PARAMETERISATION       => "<colourPatternRearrangerParams><CPR_NAME>Color Plane Sequencer</CPR_NAME><CPR_BPS>8</CPR_BPS><CPR_PORTS><INPUT_PORT><NAME>din0</NAME><STREAMING_DESCRIPTOR>[R:G:B]</STREAMING_DESCRIPTOR><ENABLED>true</ENABLED></INPUT_PORT><INPUT_PORT><NAME>din1</NAME><STREAMING_DESCRIPTOR>[Channel]</STREAMING_DESCRIPTOR><ENABLED>false</ENABLED></INPUT_PORT><OUTPUT_PORT><NAME>dout0</NAME><STREAMING_DESCRIPTOR>[R:G:B]</STREAMING_DESCRIPTOR><ENABLED>true</ENABLED><NON_IMAGE_PACKET_SOURCE>din0</NON_IMAGE_PACKET_SOURCE><HALVE_WIDTH>false</HALVE_WIDTH></OUTPUT_PORT><OUTPUT_PORT><NAME>dout1</NAME><STREAMING_DESCRIPTOR>[Channel]</STREAMING_DESCRIPTOR><ENABLED>false</ENABLED><NON_IMAGE_PACKET_SOURCE>din0</NON_IMAGE_PACKET_SOURCE><HALVE_WIDTH>false</HALVE_WIDTH></OUTPUT_PORT></CPR_PORTS><CPR_INPUT_2_PIXELS>false</CPR_INPUT_2_PIXELS></colourPatternRearrangerParams>",
			AUTO_DEVICE_FAMILY     => "Cyclone V"
		)
		port map (
			clock               => clocksource_clock, -- clock.clk
			reset               => open,              -- reset.reset
			din0_ready          => dut_din0_ready,    --  din0.ready
			din0_valid          => din0_tester_q(0),  --      .valid
			din0_data           => open,              --      .data
			din0_startofpacket  => open,              --      .startofpacket
			din0_endofpacket    => open,              --      .endofpacket
			dout0_ready         => '1',               -- dout0.ready
			dout0_valid         => open,              --      .valid
			dout0_data          => open,              --      .data
			dout0_startofpacket => open,              --      .startofpacket
			dout0_endofpacket   => open               --      .endofpacket
		);

	din0_tester : process (clocksource_clock, clocksource_reset)
	begin
		if clocksource_reset = '1' then
			din0_tester_q(0) <= '0';
		elsif clocksource_clock'EVENT and clocksource_clock = '1' and builtin_1_w1_q(0) = '1' then
			din0_tester_q(0) <= dut_din0_ready;
		end if;
	end process;

end architecture rtl; -- of soc_system_alt_vip_cpr_1_tb
