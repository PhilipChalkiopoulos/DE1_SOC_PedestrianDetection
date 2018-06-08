-- soc_system_alt_vip_mix_0_tb.vhd


library IEEE;
library altera;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use altera.alt_cusp151_package.all;

entity soc_system_alt_vip_mix_0_tb is
end entity soc_system_alt_vip_mix_0_tb;

architecture rtl of soc_system_alt_vip_mix_0_tb is
	component alt_cusp151_clock_reset is
		port (
			clock : out std_logic;
			reset : out std_logic
		);
	end component alt_cusp151_clock_reset;

	component soc_system_alt_vip_mix_0 is
		generic (
			PARAMETERISATION         : string := "<mixerParams><MIX_NAME>mixer</MIX_NAME><MIX_ALPHA_ENABLED>true</MIX_ALPHA_ENABLED><MIX_ALPHA_BPS>8</MIX_ALPHA_BPS><MIX_CHANNELS_IN_SEQ>3</MIX_CHANNELS_IN_SEQ><MIX_CHANNELS_IN_PAR>1</MIX_CHANNELS_IN_PAR><MIX_BPS>8</MIX_BPS><MIX_NUM_LAYERS>2</MIX_NUM_LAYERS><MIX_RUNTIME_MAX_WIDTH>1024</MIX_RUNTIME_MAX_WIDTH><MIX_RUNTIME_MAX_HEIGHT>768</MIX_RUNTIME_MAX_HEIGHT></mixerParams>";
			AUTO_DEVICE_FAMILY       : string := "";
			AUTO_CONTROL_CLOCKS_SAME : string := "0"
		);
		port (
			clock                 : in  std_logic                     := 'X';
			control_av_address    : in  std_logic_vector(5 downto 0)  := (others => 'X');
			control_av_chipselect : in  std_logic                     := 'X';
			control_av_readdata   : out std_logic_vector(15 downto 0);
			control_av_write      : in  std_logic                     := 'X';
			control_av_writedata  : in  std_logic_vector(15 downto 0) := (others => 'X');
			din_0_data            : in  std_logic_vector(23 downto 0) := (others => 'X');
			din_0_endofpacket     : in  std_logic                     := 'X';
			din_0_ready           : out std_logic;
			din_0_startofpacket   : in  std_logic                     := 'X';
			din_0_valid           : in  std_logic                     := 'X';
			din_1_data            : in  std_logic_vector(23 downto 0) := (others => 'X');
			din_1_endofpacket     : in  std_logic                     := 'X';
			din_1_ready           : out std_logic;
			din_1_startofpacket   : in  std_logic                     := 'X';
			din_1_valid           : in  std_logic                     := 'X';
			din_2_data            : in  std_logic_vector(23 downto 0) := (others => 'X');
			din_2_endofpacket     : in  std_logic                     := 'X';
			din_2_ready           : out std_logic;
			din_2_startofpacket   : in  std_logic                     := 'X';
			din_2_valid           : in  std_logic                     := 'X';
			dout_data             : out std_logic_vector(23 downto 0);
			dout_endofpacket      : out std_logic;
			dout_ready            : in  std_logic                     := 'X';
			dout_startofpacket    : out std_logic;
			dout_valid            : out std_logic;
			reset                 : in  std_logic                     := 'X'
		);
	end component soc_system_alt_vip_mix_0;

	signal dut_din_0_ready   : std_logic;                    -- dut:din_0_ready -> din_0_tester:data
	signal din_0_tester_q    : std_logic_vector(0 downto 0); -- din_0_tester:q -> dut:din_0_valid
	signal builtin_1_w1_q    : std_logic_vector(0 downto 0); -- ["1", builtin_1_w1:q, "1", "1", "1"] -> [din_0_tester:ena, din_1_tester:ena, din_2_tester:ena, dut:dout_ready]
	signal dut_din_1_ready   : std_logic;                    -- dut:din_1_ready -> din_1_tester:data
	signal din_1_tester_q    : std_logic_vector(0 downto 0); -- din_1_tester:q -> dut:din_1_valid
	signal dut_din_2_ready   : std_logic;                    -- dut:din_2_ready -> din_2_tester:data
	signal din_2_tester_q    : std_logic_vector(0 downto 0); -- din_2_tester:q -> dut:din_2_valid
	signal clocksource_clock : std_logic;                    -- clocksource:clock -> [dut:clock, din_0_tester:clock, din_1_tester:clock, din_2_tester:clock]
	signal clocksource_reset : std_logic;                    -- clocksource:reset -> [din_0_tester:reset, din_1_tester:reset, din_2_tester:reset]

begin

	builtin_1_w1_q <= "1";

	clocksource : component alt_cusp151_clock_reset
		port map (
			clock => clocksource_clock, -- clock.clk
			reset => clocksource_reset  --      .reset
		);

	dut : component soc_system_alt_vip_mix_0
		generic map (
			PARAMETERISATION         => "<mixerParams><MIX_NAME>mixer</MIX_NAME><MIX_ALPHA_ENABLED>false</MIX_ALPHA_ENABLED><MIX_ALPHA_BPS>8</MIX_ALPHA_BPS><MIX_CHANNELS_IN_SEQ>1</MIX_CHANNELS_IN_SEQ><MIX_CHANNELS_IN_PAR>3</MIX_CHANNELS_IN_PAR><MIX_BPS>8</MIX_BPS><MIX_NUM_LAYERS>3</MIX_NUM_LAYERS><MIX_RUNTIME_MAX_WIDTH>1024</MIX_RUNTIME_MAX_WIDTH><MIX_RUNTIME_MAX_HEIGHT>768</MIX_RUNTIME_MAX_HEIGHT></mixerParams>",
			AUTO_DEVICE_FAMILY       => "Cyclone V",
			AUTO_CONTROL_CLOCKS_SAME => "0"
		)
		port map (
			clock                 => clocksource_clock, --   clock.clk
			reset                 => open,              --   reset.reset
			din_0_ready           => dut_din_0_ready,   --   din_0.ready
			din_0_valid           => din_0_tester_q(0), --        .valid
			din_0_data            => open,              --        .data
			din_0_startofpacket   => open,              --        .startofpacket
			din_0_endofpacket     => open,              --        .endofpacket
			din_1_ready           => dut_din_1_ready,   --   din_1.ready
			din_1_valid           => din_1_tester_q(0), --        .valid
			din_1_data            => open,              --        .data
			din_1_startofpacket   => open,              --        .startofpacket
			din_1_endofpacket     => open,              --        .endofpacket
			din_2_ready           => dut_din_2_ready,   --   din_2.ready
			din_2_valid           => din_2_tester_q(0), --        .valid
			din_2_data            => open,              --        .data
			din_2_startofpacket   => open,              --        .startofpacket
			din_2_endofpacket     => open,              --        .endofpacket
			dout_ready            => '1',               --    dout.ready
			dout_valid            => open,              --        .valid
			dout_data             => open,              --        .data
			dout_startofpacket    => open,              --        .startofpacket
			dout_endofpacket      => open,              --        .endofpacket
			control_av_chipselect => open,              -- control.chipselect
			control_av_write      => open,              --        .write
			control_av_address    => open,              --        .address
			control_av_writedata  => open,              --        .writedata
			control_av_readdata   => open               --        .readdata
		);

	din_0_tester : process (clocksource_clock, clocksource_reset)
	begin
		if clocksource_reset = '1' then
			din_0_tester_q(0) <= '0';
		elsif clocksource_clock'EVENT and clocksource_clock = '1' and builtin_1_w1_q(0) = '1' then
			din_0_tester_q(0) <= dut_din_0_ready;
		end if;
	end process;

	din_1_tester : process (clocksource_clock, clocksource_reset)
	begin
		if clocksource_reset = '1' then
			din_1_tester_q(0) <= '0';
		elsif clocksource_clock'EVENT and clocksource_clock = '1' and builtin_1_w1_q(0) = '1' then
			din_1_tester_q(0) <= dut_din_1_ready;
		end if;
	end process;

	din_2_tester : process (clocksource_clock, clocksource_reset)
	begin
		if clocksource_reset = '1' then
			din_2_tester_q(0) <= '0';
		elsif clocksource_clock'EVENT and clocksource_clock = '1' and builtin_1_w1_q(0) = '1' then
			din_2_tester_q(0) <= dut_din_2_ready;
		end if;
	end process;

end architecture rtl; -- of soc_system_alt_vip_mix_0_tb
