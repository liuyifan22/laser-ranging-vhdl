-- TODO:
-- Implement PC UART
-- 检查几条通路：按B键会发生什么（已经检查）
-- 按A键会发生什么
-- 长按A键会发生什么

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity music is
    port(
        clk     : in  std_logic;
        reset   : in  std_logic;  -- active high
        key2    : in  std_logic; 
		key3    : in  std_logic;
		key4    : in  std_logic;
        tx_ccd  : out std_logic;
        rx_ccd  : in  std_logic;
        tx_pc   : out std_logic;
        rx_pc   : in  std_logic;
        seg_data: out std_logic_vector(7 downto 0);
        seg_sel : out std_logic_vector(5 downto 0)
    );
end entity;

architecture bhav of music is
    ----------------------------------------------------------------
    -- 3x clock for CCD UART
    ----------------------------------------------------------------
    signal clk3x   : std_logic;
    signal clk3xcnt: unsigned(1 downto 0);

    ----------------------------------------------------------------
    -- CCD interactor interface
    ----------------------------------------------------------------
    signal single_measure     : std_logic;
    signal continuous_measure : std_logic;
    signal laser_center       : unsigned(11 downto 0);
    signal frame_refreshed    : std_logic;
    signal enable_ccd_interact: std_logic;
	 signal single_measure_clk: unsigned(7 downto 0);
    ----------------------------------------------------------------
    -- Distance value for display and PC output
    ----------------------------------------------------------------
    signal show_raw_mode  : std_logic; -- 1=Show Laser Center, 0=Show Distance
    signal led_value      : unsigned(15 downto 0);
    signal distance_value : unsigned(15 downto 0);
	signal laser_center_50 : unsigned(11 downto 0); -- 请注意！ 这里实际上是 1m。后面那个是2m
	signal laser_center_100 : unsigned(11 downto 0);

    -- fixed-point parameters
    constant SCALE_BITS : integer := 10;  -- 2^10 = 1024

    -- 需要设计的常数
    signal a_const_int : integer;    -- = a_real * 2^SCALE_BITS
    signal k_const_int : integer;  -- = k_real * 2^SCALE_BITS 
	constant a_const_int_init : integer := 2382797;    -- = a_real * 2^SCALE_BITS
    constant k_const_int_init : integer := 721807;  -- = k_real * 2^SCALE_BITS 

    ----------------------------------------------------------------
    -- Button signals (active low on board): key2=A, key3=B, key4=C
    ----------------------------------------------------------------
    signal keyA_raw, keyB_raw, keyC_raw : std_logic; -- fpga  的输入管脚
    -- simple synchronised versions
    signal keyA_sync, keyB_sync, keyC_sync : std_logic; -- 与时钟时序同步后的信号
    signal keyA_prev, keyB_prev, keyC_prev : std_logic; -- 上一时钟周期的同步信号，用来找到上升沿和下降沿

    -- long-press detection for A
    signal keyA_press_cnt : unsigned(23 downto 0);  -- adjust width for time。此处按下来超过0.5秒就认为是长按
    signal keyA_long      : std_logic;
    signal keyA_event     : std_logic;  -- one-clock pulse when press released
    signal keyA_long_mode : std_logic;  -- 1 = continuous mode，激活连续测量

    -- calibration flags
    signal calib_req_50 : std_logic; -- 此处是校准请求信号，即将距离设置为50cm后下令我们开始校准
    signal calib_req_100: std_logic;
    signal frame_prev   : std_logic;

    -- store calibration measurements (distance in "cm" units)
    signal calib_50  : unsigned(15 downto 0); -- 此处是50cm下测得的信号，用了我们内置的参数，需要手动解耦合计算
    signal calib_100 : unsigned(15 downto 0);

    ----------------------------------------------------------------
    -- UART to PC: we will send distance_value in ASCII when new frame
    ----------------------------------------------------------------
    signal pc_tx_enable   : std_logic;
    signal pc_tx_start    : std_logic;
    signal pc_tx_byte     : unsigned(7 downto 0);
    signal pc_tx_done     : std_logic;
    signal pc_tx_prev_done: std_logic;
    signal pc_tx_busy     : std_logic;
    signal pc_send_step   : unsigned(2 downto 0);  -- state for sending "XXXX\r\n"
    signal pc_digits      : unsigned(15 downto 0); -- copy of distance_value
    signal pc_d0, pc_d1, pc_d2, pc_d3 : unsigned(3 downto 0);
    signal A_press, A_release, B_press, C_press : std_logic;

begin
    ----------------------------------------------------------------
    -- Map board pins for keys (here: use key2, key3, key4 as A,B,C)
    -- In top-level .tcl they are named key2/key3/key4; here we
    -- just connect them logically. If your entity port names differ,
    -- adapt this.
    ----------------------------------------------------------------
    keyA_raw <= key2;  -- Button A
    keyB_raw <= key3;  -- Button B
    keyC_raw <= key4;  -- Button C

    ----------------------------------------------------------------
    -- 3x clock generation
    ----------------------------------------------------------------
    clk3x <= '1' when clk3xcnt = "10" else '0'; -- yifan：注：你的三倍时钟被换掉了
    process(clk)
    begin
        if rising_edge(clk) then
            if clk3xcnt = "10" then
                clk3xcnt <= "00";
            else
                clk3xcnt <= clk3xcnt + 1;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- CCD interactor
    ----------------------------------------------------------------
    my_ccd_interactor: entity work.CCD_interactor
        port map(
            clk                => clk3x,
            enable             => enable_ccd_interact,
            rx                 => rx_ccd,
            tx                 => tx_ccd,
            single_measure     => single_measure,
            continuous_measure => continuous_measure,
            laser_center       => laser_center,
            frame_refreshed    => frame_refreshed
        );

    enable_ccd_interact <= reset; -- always enabled when not in reset

    ----------------------------------------------------------------
    -- Synchronise and edge-detect keys (active low)
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' then
                keyA_sync <= '1';
                keyB_sync <= '1';
                keyC_sync <= '1';
                keyA_prev <= '1';
                keyB_prev <= '1';
                keyC_prev <= '1';
            else
                keyA_sync <= keyA_raw;
                keyB_sync <= keyB_raw;
                keyC_sync <= keyC_raw;
                keyA_prev <= keyA_sync;
                keyB_prev <= keyB_sync;
                keyC_prev <= keyC_sync;
            end if;
        end if;
    end process;

    -- Press/release events for A/B/C
    -- For active-low key: press = 1->0, release = 0->1
    
    A_press   <= '1' when (keyA_prev = '1' and keyA_sync = '0') else '0';
    A_release <= '1' when (keyA_prev = '0' and keyA_sync = '1') else '0';
    B_press   <= '1' when (keyB_prev = '1' and keyB_sync = '0') else '0';
    C_press   <= '1' when (keyC_prev = '1' and keyC_sync = '0') else '0';

	 single_measure<= '0' when single_measure_clk=x"00" else '1';
    ----------------------------------------------------------------
    -- Button A Logic & Single Measure Generation
    -- Combined to fix race conditions and logic conflicts
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' then
                keyA_press_cnt <= (others => '0');
                keyA_long      <= '0';
                keyA_long_mode <= '0';
                single_measure_clk<=x"00";
                continuous_measure <= '0';
                show_raw_mode  <= '0'; -- Default to distance
            else
                -- Default auto-reset signals
                if single_measure_clk/=x"00" then
						  single_measure_clk<=single_measure_clk-1;
					 end if;

                -- 1. Handle Button A Press/Release
                if keyA_sync = '0' then  -- pressed
                    if keyA_press_cnt /= x"FFFFFF" then -- Prevent wrap around
                        keyA_press_cnt <= keyA_press_cnt + 1;
                    end if;
                    -- Threshold for long press (approx 0.5s at 50MHz)
                    if keyA_press_cnt = to_unsigned(50_000_000, 24) then
                        keyA_long <= '1';
                    end if;
                else  -- released (keyA_sync = '1')
                    if keyA_prev = '0' then -- Rising edge of key (Release event)
                        if keyA_long = '1' then
                            -- Long press action: Toggle Continuous Mode
                            keyA_long_mode <= not keyA_long_mode;
                            show_raw_mode  <= '0'; -- Switch back to distance display
                        else
                            -- Short press action: Single Measure
                            single_measure_clk<=x"FF";
                            show_raw_mode  <= '0'; -- Switch back to distance display
                        end if;
                    end if;
                    
                    -- Reset counters on release
                    keyA_press_cnt <= (others => '0');
                    keyA_long      <= '0';
                end if;

                -- 2. Handle Continuous Mode
                if keyA_long_mode = '1' then
                    continuous_measure <= '1';
                else
                    continuous_measure <= '0';
                end if;

                -- 3. Handle B and C (Calibration Buttons)
                if B_press = '1' or C_press = '1' then
                    single_measure_clk <= x"FF";
                    show_raw_mode  <= '1'; -- Show raw laser center
                    continuous_measure <= '0'; -- Disable continuous mode
                end if;

            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Calibration requests: latch distance after next frame
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' then
                calib_req_50 <= '0';
                calib_req_100<= '0';
                calib_50     <= (others => '0');
                calib_100    <= (others => '0');
                frame_prev   <= '0';
				laser_center_50 <= to_unsigned(0,12);
                laser_center_100 <= to_unsigned(0,12);
					 
            else
                frame_prev <= frame_refreshed;

                -- On B/C press, request calibration on next frame
                if B_press = '1' then
                    calib_req_50 <= '1'; -- 我们在标定B
                end if;
                if C_press = '1' then
                    calib_req_100 <= '1';
                end if;

                -- Detect rising edge of frame_refreshed
                if frame_prev = '0' and frame_refreshed = '1' then
                    if calib_req_50 = '1' then
                        calib_50     <= distance_value;
                        calib_req_50 <= '0';
                        laser_center_50 <= laser_center;
                    end if;
                    if calib_req_100 = '1' then
                        calib_100     <= distance_value;
                        calib_req_100 <= '0';
                        laser_center_100 <= laser_center;
                    end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- Calibration computation: update a_const_int and k_const_int
    -- 若laser_center_50和laser_center_100均非零，则更新a和k
    -- a_const_int = (2*laser_center_100 - laser_center_50) * 1024
    -- k_const_int = 2* (laser_center_100 - laser_center_50) * 1024

    ----------------------------------------------------------------
    process(clk)
        variable lc50_int  : integer;
        variable lc100_int : integer;
        variable a_tmp     : integer;
        variable k_tmp     : integer;
    begin
        if rising_edge(clk) then
            if reset = '0' then
                -- 回到初始标定参数
                a_const_int <= a_const_int_init;
                k_const_int <= k_const_int_init;
            else
                -- 只在两个标定点都非零时更新
                if (laser_center_50 /= 0) and (laser_center_100 /= 0) then
                    lc50_int  := to_integer(laser_center_50);
                    lc100_int := to_integer(laser_center_100);

                    -- 计算 a_const_int 和 k_const_int
                    a_tmp := (2 * lc100_int - lc50_int) * (2 ** SCALE_BITS);
                    k_tmp := 2 * (lc100_int - lc50_int) * (2 ** SCALE_BITS);

                    -- 简单保护：只在计算结果为正时更新
                    if (a_tmp > 0) and (k_tmp > 0) then
                        a_const_int <= a_tmp;
                        k_const_int <= k_tmp;
                    end if;
                end if;
            end if;
        end if;
    end process;





    ----------------------------------------------------------------
    -- Distance computation: distance = k_const / (laser_center - a_const)
    -- 计算距离，里面有“固定小数点”的处理
    -- 注：固定点小数会除掉，这样做只是为了k和a的精度可以设置得更好
    ----------------------------------------------------------------
    process(clk)
        -- 使用 integer 做中间计算, 更方便除法
        variable lc_int      : integer;
        variable denom_int   : integer;
        variable numerator   : integer;
        variable dist_scaled : integer;
    begin
        if rising_edge(clk) then
            if reset = '0' then
                distance_value <= (others => '0');
            else
                lc_int := to_integer(laser_center);  -- 0 to 4095
					 if lc_int >= 4095 then
					     distance_value <= to_unsigned(9000, 16);
					 
					 else
						  denom_int := a_const_int - (lc_int * (2 ** SCALE_BITS));

						  if denom_int <= 0 then
							   distance_value <= to_unsigned(7000, 16);
						  else
							   -- numerator   := k_const_int * (2 ** SCALE_BITS);
							   numerator   := k_const_int*1000;
							   dist_scaled := numerator / denom_int;

							   if dist_scaled < 0 then
								    distance_value <= to_unsigned(6000, 16);
							   elsif dist_scaled > 9999 then
									 distance_value <= to_unsigned(9999, 16);
							   else
									 distance_value <= to_unsigned(dist_scaled, 16);
							   end if;
					     end if;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- 7-seg display: segment_led entity
    ----------------------------------------------------------------
    process(clk)
	 begin
        if rising_edge(clk) then
            if frame_prev='0' and frame_refreshed='1' then 
					if show_raw_mode = '1' then
						led_value <= resize(laser_center, 16);
					else 
						led_value <= distance_value;
					end if;
            end if;
        end if;
    end process;
    -- yifan 注意在按下BC时，显示的是laser_center，否则显示distance_value

    my_segment_led: entity work.segment_led
        port map(
            clk      => clk,
            reset    => reset,
            value_in => led_value, -- Connected to multiplexed signal
            seg_data => seg_data,
            seg_sel  => seg_sel
        );

end architecture;
