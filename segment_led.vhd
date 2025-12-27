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

    --------------------------------------------------------------------
    -- 1. 扫描计数器, 用来确定当前点亮哪一位
    --------------------------------------------------------------------
    -- 根据系统时钟频率设置这个计数器的宽度和翻转点, 调整“刷新频率”
    -- 比如系统为 50MHz, 想要每位刷新频率在几百 Hz~1kHz 左右:
    --   计数到约 10^4~10^5 即可.
    --
    -- 这里用 16 位计数器, 在 50MHz 下计满(65535) 约 1.3ms, 4 位轮一遍约 5ms
    -- 也就是每位 ~200Hz, 可以接受.
    --------------------------------------------------------------------
    signal scan_cnt  : unsigned(15 downto 0);
    signal scan_digit: unsigned(1 downto 0); -- 当前正在显示第几位 0..3

    --------------------------------------------------------------------
    -- 2. 十进制拆分: value_in -> d3 d2 d1 d0 (千,百,十,个)
    -- 为简单起见, 在每个时钟周期都做一次组合逻辑拆分, 不做优化.
    -- 对于本项目数值不是很大, 一般没问题.
    --------------------------------------------------------------------
    signal d0, d1, d2, d3 : unsigned(3 downto 0); -- 每个十进制位 0~9

    --------------------------------------------------------------------
    -- 3. 当前选中的那个数字(0~9) 和它对应的 7 段编码
    --------------------------------------------------------------------
    signal current_digit : unsigned(3 downto 0);
    signal seg_pattern   : std_logic_vector(7 downto 0);

begin

    ----------------------------------------------------------------
    -- 拆分十进制的组合逻辑
    -- 注意: numeric_std 的除法与取模运算为无符号算术.
    ----------------------------------------------------------------
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

    ----------------------------------------------------------------
    -- 扫描计数器, 决定 scan_digit(当前点亮哪一位)
    ----------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                scan_cnt   <= (others => '0');
                scan_digit <= (others => '0');
            else
                scan_cnt <= scan_cnt + 1;
                if scan_cnt = to_unsigned(65535, scan_cnt'length) then  -- 2^16 - 1 -- yifan 此处quartus老是给报错，这句ai写的   -- 计数到最大值后翻转位号
                    scan_cnt   <= (others => '0');
                    scan_digit <= scan_digit + 1;   -- 0->1->2->3->0...
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------
    -- 根据 scan_digit 选择要显示的数字, 并生成 seg_sel
    ----------------------------------------------------------------
    process(scan_digit, d0, d1, d2, d3)
    begin
        -- 默认关闭所有位选, 后面再打开其中一位
        seg_sel <= "111111";  -- 假设 '1' 为关闭

        case scan_digit is
            when "00" =>   -- 显示个位
                current_digit <= d0;
                seg_sel(0)   <= '0';  -- 选通第 0 位(个位)
            when "01" =>   -- 显示十位
                current_digit <= d1;
                seg_sel(1)   <= '0';
            when "10" =>   -- 显示百位
                current_digit <= d2;
                seg_sel(2)   <= '0';
            when others => -- "11": 显示千位
                current_digit <= d3;
                seg_sel(3)   <= '0';
        end case;
    end process;

    ----------------------------------------------------------------
    -- 7 段编码 ROM
    -- current_digit 映射到 seg_pattern(7 downto 0)
    --
    -- 约定: seg_data(6 downto 0) = {g,f,e,d,c,b,a}, seg_data(7) = dp
    --       且“0 点亮, 1 熄灭”(共阳数码管低有效驱动).
    --
    -- 例如: 数字 0 -> a,b,c,d,e,f 亮, g,dp 灭:
    --       a,b,c,d,e,f,g,dp = 0,0,0,0,0,0,1,1
    --       => "11000000"
    -- 如果你的开发板是共阴/高有效, 只需要把这些码取反即可.
    ----------------------------------------------------------------
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

    -- 输出到端口
    seg_data <= seg_pattern;

end architecture;