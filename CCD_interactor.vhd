library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- clk为18x波特率频率的时钟信号
-- 通信协议：8数据位，无校验位，1停止位

--输入：single_measure：（单个bit）上升沿激活一次测量
--输入：continuous_measure：（单个bit）为高电平时持续激活测量
--输出：laser_center：（12位的整数，实际取值范围为3~3650）光斑中心所处位置+2
	 -- 实际的像素是1~3648
--输出：frame_refreshed：（单个bit）上升沿表示已更新了新一帧的laser_center
	 -- 该上升沿会在接收完全部数据后产生。由于laser_center的值是实时更新，
	 -- 而CCD返回数据存在帧尾，故该上升沿在laser_center改变后一定时间产生。
	 -- 默认高电平，进入receiving状态时拉低，receiving状态结束时拉高。
	 -- 高电平至少会持续一个transmitting的时间

entity CCD_interactor is
	port(
		clk: in std_logic;
		enable: in std_logic;
		rx: in std_logic; -- from CCD
		tx: out std_logic; -- to CCD
		single_measure: in std_logic;
		continuous_measure: in std_logic;
		laser_center: out unsigned(11 downto 0);
		frame_refreshed: out std_logic
	);

end entity;

architecture behav of CCD_interactor is
	signal prev_single_measure: std_logic;
	signal transmitting: std_logic; -- 状态变量
	signal prev_transmitting: std_logic;
	signal receiving: std_logic; -- 状态变量
	signal prev_receiving: std_logic;
	
	signal enable_receiver: std_logic;
	signal enable_transmitter: std_logic;
	signal start_transmitter: std_logic;
	signal receive_byte: unsigned(7 downto 0);
	signal receive_done: std_logic;
	signal prev_receive_done: std_logic;
	signal transmit_byte: unsigned(7 downto 0);
	signal transmit_done: std_logic;
	signal prev_transmit_done: std_logic;
	
	signal cnt_t: unsigned(3 downto 0); -- to count transmitted bytes 
	signal cnt_r: unsigned(12 downto 0); -- to count received bytes
	signal cnt_timeout: unsigned (19 downto 0); -- to count time waited
	
	signal peak_value: unsigned(15 downto 0);
	signal peak_pos: unsigned(11 downto 0);
	type unsigned_array is array (0 to 7) of unsigned(15 downto 0);
	signal buf: unsigned_array;
	
begin
	laser_center<=peak_pos;
	ccd_receiver: entity work.uart_receiver port map(
		clk=>clk,
		rx=>rx,
		enable=>enable_receiver,
		output_byte=>receive_byte,
		done=>receive_done
	);
	ccd_transmitter: entity work.uart_transmitter port map(
		clk=>clk,
		tx=>tx,
		enable=>enable_transmitter,
		start=>start_transmitter,
		output_byte=>transmit_byte,
		done=>transmit_done
	);
	enable_receiver<=enable;
	enable_transmitter<=enable;
	-- 维护需要同步的上升/下降沿
	process(clk)
	begin
		if (clk'event and clk='1') then
			prev_transmit_done<=transmit_done;
			prev_receive_done<=receive_done;
			prev_single_measure<=single_measure;
			prev_transmitting<=transmitting;
			prev_receiving<=receiving;
		end if;
	end process;
	
	process(clk) -- 大状态转移
	begin
		if (clk'event and clk='1') then
		
			if enable='0' then
				frame_refreshed<='1';
				transmitting<='0';
				receiving<='0';
			end if;
			
			if enable='1' then
			
				if transmitting='0' and receiving='0' then -- 空闲
					frame_refreshed<='1';
					if (prev_single_measure='0' and single_measure='1') or continuous_measure='1' then
						transmitting<='1';
					end if;
				end if;
				
				if transmitting='1' then
					if cnt_t=7 then
						frame_refreshed<='0';
						transmitting<='0';
						receiving<='1';
					end if;
				end if;
				
				if receiving='1' then
					if cnt_timeout=x"FFFFF" or cnt_r=7301 then
						frame_refreshed<='1';
						receiving<='0';
					end if;
				end if;
				
			end if;
		end if;
	end process;
	
	
	-- 开始工作时先发送@c0080#@，对应ASCII为 64 99 48 48 56 48 35 64
	
	-- 状态机进程
	process(clk) -- transmit_done的下降沿代表传输开始
	variable buf_ave: unsigned(15 downto 0);
	begin
		if (clk'event and clk='1') then
		-- enable='0' reset
		--	if enable='0' then
		--		start_transmitter<='0';
		--	end if;
			
		-- enable='1' 正常工作
			if enable='1' then
			
				if transmitting='0' then
					start_transmitter<='0';
					cnt_t<=to_unsigned(0,4);
				end if;
				
				-- transmitting状态下工作
				if transmitting='1' then
				
					if prev_transmitting='0' then -- 刚进入状态，发送第一个字符
						start_transmitter<='1';
						transmit_byte<=to_unsigned(64,8);
					else -- 正常工作
					
						if transmit_done='0' then
							start_transmitter<='0';
						end if;
						
						if prev_transmit_done='0' and transmit_done='1' then
							cnt_t<=cnt_t+1;
							if cnt_t=0 then
								transmit_byte<=to_unsigned(99,8);
								start_transmitter<='1';
							elsif cnt_t=1 then
								transmit_byte<=to_unsigned(48,8);
								start_transmitter<='1';
							elsif cnt_t=2 then
								transmit_byte<=to_unsigned(48,8);
								start_transmitter<='1';
							elsif cnt_t=3 then
								transmit_byte<=to_unsigned(56,8);
								start_transmitter<='1';
							elsif cnt_t=4 then
								transmit_byte<=to_unsigned(48,8);
								start_transmitter<='1';
							elsif cnt_t=5 then
								transmit_byte<=to_unsigned(35,8);
								start_transmitter<='1';
							elsif cnt_t=6 then
								transmit_byte<=to_unsigned(64,8);
								start_transmitter<='1';
							end if;
						end if;
						
						
					end if;
				end if;
			
				if receiving='0' or (prev_receive_done='0' and receive_done='1') then
					cnt_timeout<=x"00000";
				else
					cnt_timeout<=cnt_timeout+1;
				end if;
				
				if cnt_timeout=x"FFFFF" then
					peak_pos<=x"FFF";
				end if;
				
				if receiving='0' then
					cnt_r<=to_unsigned(0,13);
					peak_value<=x"0000";
					peak_pos<=x"FFF";
					buf<= (others => (others => '0'));
				end if;
				
				if receiving='1' and (prev_receive_done='0' and receive_done='1') then
				
					cnt_r<=cnt_r+1;
					if cnt_r>=4 and cnt_r<7300 then -- 是有用信息
						if cnt_r(0)='0' then -- 是高8位
							buf(1 to 7)<=buf(0 to 6);
							buf(0)(15 downto 8)<=receive_byte;
						else -- 是低8位
							buf(0)(7 downto 0)<=receive_byte;
						end if;
					end if;
					if cnt_r(0)='0' and cnt_r>=6 and cnt_r<=7300 then
						buf_ave:=(buf(0)+buf(1)+buf(2)+buf(3)+buf(4)+buf(5)+buf(6)+buf(7)); -- sliding window average
						if buf_ave>peak_value then
							peak_value<=buf_ave;
							peak_pos<=cnt_r(12 downto 1); -- 如果要得到实际的像素序号，还要-2.
						end if;
					end if;
					
				end if;
			
			end if;
		end if;
	end process;


end architecture;
