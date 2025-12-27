-- rx

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- clk为18x波特率频率的时钟信号
-- 通信协议：8数据位，无校验位，1停止位
entity uart_receiver is
	port(
		clk: in std_logic;
		rx: in std_logic;
		enable: in std_logic; -- 初始请设为0；请确保接收数据时全程处于1
		output_byte: out unsigned(7 downto 0);
		done: out std_logic
			-- 上升沿表示有新数据就绪。检测到起始位时拉低，接收1byte完毕后拉高
			-- 初始值不定，需要靠先disable来设为0
	);

end entity;

architecture behav of uart_receiver is
	signal buf: unsigned(8 downto 0);
	signal cnt: unsigned(7 downto 0);
	signal started: std_logic;
begin
	process(clk)
	begin
		if (clk'event and clk='1') then
			if enable='0' then
				done<='0';
				started<='0';
				buf<=b"111_111_111";
			end if;
			if enable='1' then
				buf<=buf(7 downto 0) & rx;
				if started='0' then
					if buf(8 downto 6)="111" and buf(5 downto 0)="000000" then
						started<='1';
						cnt<=x"00";
						done<='0';
					end if;
				else -- if started
					cnt<=cnt+1;
					if cnt=to_unsigned(19,8) then
						output_byte(0)<=rx;
					elsif cnt=to_unsigned(37,8) then
						output_byte(1)<=rx;
					elsif cnt=to_unsigned(55,8) then
						output_byte(2)<=rx;
					elsif cnt=to_unsigned(73,8) then
						output_byte(3)<=rx;
					elsif cnt=to_unsigned(91,8) then
						output_byte(4)<=rx;
					elsif cnt=to_unsigned(109,8) then
						output_byte(5)<=rx;
					elsif cnt=to_unsigned(127,8) then
						output_byte(6)<=rx;
					elsif cnt=to_unsigned(145,8) then
						output_byte(7)<=rx;
					elsif cnt=to_unsigned(146,8) then
						started<='0';
						done<='1';
					end if;
				end if;
			end if;
		end if;
	end process;

end architecture;
