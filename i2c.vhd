-- Filename     : i2c.vhd
-- Author       : Vladimir Lavrov
-- Date         : 26.10.2020
-- Annotation   : I2C controller
-- Version      : 0.4
-- Mod.Data     : 21.09.2020
-- Note         : 
------------------------------------------------------
------------------------------------------------------
-- https://wavedrom.com/editor.html
-- {signal: [
--   {name: 'clk_stb', wave: 'xp..........................'},
--   {name: 'counter', wave: 'x22222222222222222222222222x', data: ['0', '1', '0', '1','2', '3', '0', '1','2', '3', '0', '1','2', '3', '0', '1','2', '3', '0', '1','2', '3', '0', '1','2', '3']},
--   {name: 'action',  wave: 'x2.3...5...6...7...8...9...x', data: ['start', 'bit write', 'slave ack', 'bit read',  'master ack','nack', 'stop']},
--   {name: 'scl',     wave: 'xx.l.H.l.H.l.H.l.H.l.H.l.H.x'},
--   {name: 'sda',     wave: 'xl.x3..xz..x...xl..xz..xl.zx'},
--   {},
--   {name: 'sequence write',  wave: 'x23..453...53...59x', data: ['start', 'slave_addr_7_bit', 'wr', 'ack', 'reg_addr_8_bit', 'ack','data_8_bit', 'ack', 'stop']},
--   {name: 'sequence read',   wave: 'x23..453...523..456.76.76|89x', data: ['start', 'slave_addr_7_bit', 'wr', 'ack', 'reg_addr_8_bit', 'ack','start', 'slave_addr_7_bit', 'rd','ack','data n','ack','data n-1','ack','data 0','nack','stop']}
-- ]}
------------------------------------------------------
------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity i2c is
    generic (
        I2C_BYTE_READ_LENGTH : integer := 10;
        CLK_CONST            : integer := 124 -- 50MHz/((CLK_CONST+1)*4)= 100 КHz F
    );
    port (
        clk : in std_logic;
        rst : in std_logic;

        run_stb        : in std_logic;
        read_not_write : in std_logic;
        chip_addr      : in std_logic_vector(6 downto 0);
        reg_addr       : in std_logic_vector(7 downto 0);
        data_in        : in std_logic_vector(7 downto 0);

        rdy_stb        : out std_logic;
        data_out       : out std_logic_vector(((I2C_BYTE_READ_LENGTH * 8) + 7) downto 0);
        busy           : out std_logic;
        error_detected : out std_logic;

        scl : inout std_logic;
        sda : inout std_logic
    );
end entity i2c;

architecture rtl of i2c is
    -- clk  
    --    constant CLK_CONST : integer := 31;--62;--138;--124;--199;               -- 50MHz/((CLK_CONST+1)*4)= 100 КHz 
    signal clk_stb : std_logic;                    -- two strobs re and fe
    signal clk_cnt : integer range 0 to CLK_CONST; -- counter for clk divider
    --i2c_
    constant I2C_WRITE_BIT : std_logic := '0';
    constant I2C_READ_BIT  : std_logic := '1';
    constant I2C_BIT_MAX   : integer   := 7;
    constant I2C_DATA_MAX  : integer   := 2;
    type i2c_fsm_statetype is (
        i2c_state_idle, i2c_state_start, i2c_state_write, i2c_state_ask,
        i2c_state_read, i2c_state_response, i2c_state_not_response, i2c_state_stop, i2c_state_stop_2); -- fsm
    signal i2c_fsm : i2c_fsm_statetype := i2c_state_idle;
    type i2c_write_array_type is array (0 to I2C_DATA_MAX) of std_logic_vector(I2C_BIT_MAX downto 0);
    type i2c_recieve_array_type is array (0 to I2C_BYTE_READ_LENGTH) of std_logic_vector(I2C_BIT_MAX downto 0);
    signal i2c_write_array    : i2c_write_array_type;
    signal i2c_recieve_array  : i2c_recieve_array_type;
    signal i2c_write_cnt      : integer range 0 to I2C_DATA_MAX;
    signal i2c_read_cnt       : integer range 0 to I2C_BYTE_READ_LENGTH;
    signal i2c_bit_cnt        : integer range 0 to I2C_BIT_MAX;
    signal i2c_clk_en         : std_logic;
    signal i2c_period_cnt     : integer range 0 to 3;
    signal i2c_read_not_write : std_logic;
    signal i2c_synch_scl      : std_logic_vector(1 downto 0);
    signal i2c_synch_sda      : std_logic_vector(1 downto 0);

begin

    I2C_PROC : process (clk, rst)
    begin
        if rst = '1' then
            i2c_fsm        <= i2c_state_idle;
            i2c_clk_en     <= '0';
            scl            <= 'Z';
            sda            <= 'Z';
            error_detected <= '0';
            busy           <= '0';
        elsif rising_edge(clk) then

            -- synch sda for comparing
            i2c_synch_sda(0) <= sda;
            i2c_synch_sda(1) <= i2c_synch_sda(0);

            -- synch scl for freezing
            i2c_synch_scl(0) <= scl;
            i2c_synch_scl(1) <= i2c_synch_scl(0);

            case i2c_fsm is

                when i2c_state_idle =>
                    if run_stb = '1' then
                        i2c_fsm            <= i2c_state_start;
                        busy               <= '1';
                        i2c_clk_en         <= '1';
                        i2c_write_array(0) <= chip_addr & I2C_WRITE_BIT;
                        i2c_write_array(1) <= reg_addr;
                        i2c_bit_cnt        <= I2C_BIT_MAX;
                        i2c_write_cnt      <= 0;
                        i2c_read_cnt       <= I2C_BYTE_READ_LENGTH;
                        if read_not_write = I2C_WRITE_BIT then
                            i2c_write_array(2) <= data_in;
                            i2c_read_not_write <= I2C_WRITE_BIT;
                        else
                            i2c_write_array(2) <= chip_addr & I2C_READ_BIT;
                            i2c_read_not_write <= I2C_READ_BIT;
                        end if;
                    else
                        i2c_clk_en <= '0';
                        busy       <= '0';
                    end if;
                    scl            <= 'Z';
                    sda            <= 'Z';
                    error_detected <= '0';
                    rdy_stb        <= '0';
                    i2c_period_cnt <= 2;

                when i2c_state_start =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then
                            i2c_period_cnt <= 2;
                            sda            <= 'Z';
                        elsif i2c_period_cnt = 2 then
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then
                            i2c_period_cnt <= 0;
                            sda            <= '0';
                            i2c_fsm        <= i2c_state_write;
                        end if;
                    end if;

                when i2c_state_write =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then -- set sda
                            i2c_period_cnt <= 2;
                            if i2c_write_array(i2c_write_cnt)(i2c_bit_cnt) = '0' then
                                sda <= '0';
                            else
                                sda <= '1';
                            end if;
                        elsif i2c_period_cnt = 2 then -- relax scl
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then --
                            i2c_period_cnt <= 0;
                            if i2c_bit_cnt = 0 then
                                i2c_bit_cnt <= I2C_BIT_MAX;
                                i2c_fsm     <= i2c_state_ask;
                            else
                                i2c_bit_cnt <= i2c_bit_cnt - 1;
                            end if;
                        end if;
                    end if;

                when i2c_state_ask =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then -- relax sda
                            i2c_period_cnt <= 2;
                            sda            <= 'Z';
                        elsif i2c_period_cnt = 2 then -- relax scl
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then -- wait one period
                            i2c_period_cnt <= 0;
                            if i2c_synch_sda(1) = '1' then
                                error_detected <= '1';
                                i2c_fsm        <= i2c_state_stop;
                            elsif i2c_read_not_write = I2C_READ_BIT and i2c_write_cnt = 1 then
                                i2c_fsm       <= i2c_state_stop_2;
                                i2c_write_cnt <= i2c_write_cnt + 1;
                            elsif i2c_read_not_write = I2C_READ_BIT and i2c_write_cnt = I2C_DATA_MAX then
                                i2c_fsm       <= i2c_state_read;
                                i2c_write_cnt <= 0;
                            elsif i2c_read_not_write = I2C_WRITE_BIT and i2c_write_cnt = I2C_DATA_MAX then
                                i2c_fsm       <= i2c_state_stop;
                                i2c_write_cnt <= 0;
                            else
                                i2c_fsm       <= i2c_state_write;
                                i2c_write_cnt <= i2c_write_cnt + 1;
                            end if;
                        end if;
                    end if;

                when i2c_state_stop_2 =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then -- set sda
                            i2c_period_cnt <= 2;
                            sda            <= '0';
                        elsif i2c_period_cnt = 2 then -- relax scl
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then -- wait one period
                            i2c_period_cnt <= 0;
                            sda            <= 'Z';
                            i2c_fsm       <= i2c_state_start;
                        end if;
                    end if;

                when i2c_state_read =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then -- relax sda
                            i2c_period_cnt <= 2;
                            sda            <= 'Z';
                        elsif i2c_period_cnt = 2 then -- relax scl write bit
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then -- wait one period
                            i2c_period_cnt                               <= 0;
                            i2c_recieve_array(i2c_read_cnt)(i2c_bit_cnt) <= i2c_synch_sda(1);
                            if i2c_bit_cnt = 0 then
                                i2c_bit_cnt <= I2C_BIT_MAX;
                                if i2c_read_cnt = 0 then
                                    i2c_fsm      <= i2c_state_not_response;
                                    i2c_read_cnt <= I2C_BYTE_READ_LENGTH;
                                else
                                    i2c_fsm      <= i2c_state_response;
                                    i2c_read_cnt <= i2c_read_cnt - 1;
                                end if;
                            else
                                i2c_bit_cnt <= i2c_bit_cnt - 1;
                            end if;
                        end if;
                    end if;

                when i2c_state_response =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then -- pull down sda
                            i2c_period_cnt <= 2;
                            sda            <= '0';
                        elsif i2c_period_cnt = 2 then -- relax scl write bit
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then -- wait one period
                            i2c_period_cnt <= 0;
                            i2c_fsm        <= i2c_state_read;
                        end if;
                    end if;

                when i2c_state_not_response =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then --not pull down sda
                            i2c_period_cnt <= 2;
                            sda            <= 'Z';
                        elsif i2c_period_cnt = 2 then -- relax scl
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                            if i2c_synch_sda(1) = '0' then
                                error_detected <= '1';
                                i2c_fsm        <= i2c_state_stop;
                            end if;
                        elsif i2c_period_cnt = 3 then -- wait one period
                            i2c_period_cnt <= 0;
                            i2c_fsm        <= i2c_state_stop;
                        end if;
                    end if;

                when i2c_state_stop =>
                    if clk_stb = '1' then
                        if i2c_period_cnt = 0 then -- scl pull down
                            i2c_period_cnt <= 1;
                            scl            <= '0';
                        elsif i2c_period_cnt = 1 then -- set sda
                            i2c_period_cnt <= 2;
                            sda            <= '0';
                        elsif i2c_period_cnt = 2 then -- relax scl
                            i2c_period_cnt <= 3;
                            scl            <= 'Z';
                        elsif i2c_period_cnt = 3 then --
                            i2c_period_cnt <= 0;
                            sda            <= 'Z';
                            i2c_fsm        <= i2c_state_idle;
                            rdy_stb        <= '1';
                            for i in I2C_BYTE_READ_LENGTH downto 0 loop
                                data_out((((I2C_BYTE_READ_LENGTH - i) * 8) + 7) downto ((I2C_BYTE_READ_LENGTH - i) * 8)) <= i2c_recieve_array(I2C_BYTE_READ_LENGTH - i);
                            end loop;
                        end if;
                    end if;

                when others =>
                    i2c_fsm <= i2c_state_idle;
            end case;
        end if;
    end process I2C_PROC;

    -- clock divider process 
    CLK_PROC : process (clk, rst)
    begin
        if rst = '1' then
            clk_cnt <= 0;
            clk_stb <= '0';
        elsif rising_edge(clk) then

            if not ((i2c_period_cnt = 3) and (i2c_synch_scl(1) = '0')) then
                if i2c_clk_en = '1' then
                    if clk_cnt = CLK_CONST then
                        clk_cnt <= 0;
                        clk_stb <= '1';
                    else
                        clk_cnt <= clk_cnt + 1;
                        clk_stb <= '0';
                    end if;
                else
                    clk_cnt <= 0;
                    clk_stb <= '0';
                end if;
            end if;
        end if;
    end process CLK_PROC;

end architecture rtl;