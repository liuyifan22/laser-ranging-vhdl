-- tx


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- clk为18x波特率频率的时钟信号
-- 通信协议：8数据位，无校验位，1停止位
entity uart_transmitter is
	port(
		clk: in std_logic;
		tx: out std_logic; -- idle high
		enable: in std_logic; -- 0时重置
		start: in std_logic; -- 识别到start信号上升沿后开始传输；仅传输一次
		output_byte: in unsigned(7 downto 0); -- 需要保持传输过程中output_byte稳定
		done: out std_logic
			-- 上升沿表示该字节发送完成。接收到enable上升沿后拉低，传输完毕后拉高
			-- 初始值不定，需要靠先disable来设为1
	);

end entity;

architecture behav of uart_transmitter is
	signal cnt: unsigned(7 downto 0);
	signal working: std_logic;
	signal prev_start: std_logic; -- 用于判断start的上升沿
begin
	process(clk)
	begin
		if (clk'event and clk='1') then
			prev_start<=start;
		end if;
	end process;

	done<= not working;

	process(clk)
	begin
		if (clk'event and clk='1') then
			if enable='0' then
				tx<='1';
				working<='0';
			end if;
			if enable='1' then
				if working='0' then -- 寻找start上升沿
					if prev_start='0' and start='1' then
						working<='1';
						cnt<=x"00";
						tx<='0';
					end if;
				else -- started
					cnt<=cnt+1;
					if cnt=to_unsigned(18,8) then
						tx<=output_byte(0);
					elsif cnt=to_unsigned(36,8) then
						tx<=output_byte(1);
					elsif cnt=to_unsigned(54,8) then
						tx<=output_byte(2);
					elsif cnt=to_unsigned(72,8) then
						tx<=output_byte(3);
					elsif cnt=to_unsigned(90,8) then
						tx<=output_byte(4);
					elsif cnt=to_unsigned(108,8) then
						tx<=output_byte(5);
					elsif cnt=to_unsigned(126,8) then
						tx<=output_byte(6);
					elsif cnt=to_unsigned(144,8) then
						tx<=output_byte(7);
					elsif cnt=to_unsigned(162,8) then
						tx<='1';
					elsif cnt=to_unsigned(180,8) then
						working<='0';
					end if;
				end if;
			end if;
		end if;
	
	end process;

end architecture;
