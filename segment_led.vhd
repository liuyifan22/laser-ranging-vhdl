library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- 7段数码管驱动模块
-- 假设:
--  1) 开发板上有6位数码管, 对应 seg_sel(5 downto 0)
--  2) 每位为“位选”信号(通常是低有效, 具体要看原理图):
--       seg_sel(i) = '0' 选通该位; '1' 关闭该位
--  3) seg_data(7 downto 0) 为段选(常见为 a,b,c,d,e,f,g,dp),
--     其中每一位高/低是否点亮, 也取决于是否“共阳/共阴”,
--     这里先假设 “0 点亮, 1 熄灭”(共阳数码管, 段选为低有效)。
--
-- 输入 value_in 为 0~9999 的整数.
-- 本模块将其拆成 4 个十进制数字, 周期性扫描显示在低 4 位数码管上:
--   seg_sel(0) : 个位
--   seg_sel(1) : 十位
--   seg_sel(2) : 百位
--   seg_sel(3) : 千位
--   seg_sel(4..5) : 关闭
--
-- 使用方法:
--   1) 在顶层把 “距离” 或 laser_center 扩展到 16 位作为 value_in 接到本模块.
--   2) 把 seg_data、seg_sel 连接到开发板管脚(在 tcl 中已经定义).

entity segment_led is
    port(
        clk      : in  std_logic;                 -- 扫描用时钟, 建议使用系统主时钟(例如 50MHz)
        reset    : in  std_logic;                 -- 同步复位, 高有效
        value_in : in  unsigned(15 downto 0);     -- 需要显示的数值(0~9999)
        seg_data : out std_logic_vector(7 downto 0); -- 段选输出
        seg_sel  : out std_logic_vector(5 downto 0)  -- 位选输出
    );
end entity;

architecture rtl of segment_led is
    signal scan_cnt  : unsigned(15 downto 0);
    signal scan_digit: unsigned(1 downto 0); -- 当前正在显示第几位 0..3
    signal d0, d1, d2, d3 : unsigned(3 downto 0); -- 每个十进制位 0~9

    signal current_digit : unsigned(3 downto 0);
    signal seg_pattern   : std_logic_vector(7 downto 0);

begin

    process(value_in)
        variable tmp : unsigned(15 downto 0);
    begin
        -- 限制范围在 0~9999, 超出部分截断
        if value_in > to_unsigned(9999, 16) then
            tmp := to_unsigned(9999, 16);
        else
            tmp := value_in;
        end if;

        -- d0: 个位
        d0 <= resize(unsigned(to_unsigned(to_integer(tmp mod 10), 4)), 4);

        -- d1: 十位
        d1 <= resize(unsigned(to_unsigned(to_integer((tmp / 10)   mod 10), 4)), 4);

        -- d2: 百位
        d2 <= resize(unsigned(to_unsigned(to_integer((tmp / 100)  mod 10), 4)), 4);

        -- d3: 千位
        d3 <= resize(unsigned(to_unsigned(to_integer((tmp / 1000) mod 10), 4)), 4);
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '0' then
                scan_cnt   <= (others => '0');
                scan_digit <= (others => '0');
            else
                scan_cnt <= scan_cnt + 1;
                if scan_cnt = to_unsigned(65535, scan_cnt'length) then 
                    scan_cnt   <= (others => '0');
                    scan_digit <= scan_digit + 1;   -- 0->1->2->3->0...
                end if;
            end if;
        end if;
    end process;

    process(scan_digit, d0, d1, d2, d3)
    begin
        seg_sel <= "111111"; 

        case scan_digit is
            when "00" =>   -- 显示个位
                current_digit <= d0;
                seg_sel(5)   <= '0'; 
            when "01" =>   -- 显示十位
                current_digit <= d1;
                seg_sel(4)   <= '0';
            when "10" =>   -- 显示百位
                current_digit <= d2;
                seg_sel(3)   <= '0';
            when others => -- "11": 显示千位
                current_digit <= d3;
                seg_sel(2)   <= '0';
        end case;
    end process;

    process(current_digit)
    begin
        case current_digit is
            when "0000" => seg_pattern <= "11000000"; -- 0
            when "0001" => seg_pattern <= "11111001"; -- 1
            when "0010" => seg_pattern <= "10100100"; -- 2
            when "0011" => seg_pattern <= "10110000"; -- 3
            when "0100" => seg_pattern <= "10011001"; -- 4
            when "0101" => seg_pattern <= "10010010"; -- 5
            when "0110" => seg_pattern <= "10000010"; -- 6
            when "0111" => seg_pattern <= "11111000"; -- 7
            when "1000" => seg_pattern <= "10000000"; -- 8
            when "1001" => seg_pattern <= "10010000"; -- 9
            when others => seg_pattern <= "11111111"; -- 其它: 全灭
        end case;
    end process;

    seg_data <= seg_pattern;

end architecture;