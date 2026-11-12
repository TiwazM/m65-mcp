-- mcp_ram: a simple dual-port RAM (one clock, one write port, one
-- registered read port), its own entity so that synthesis infers block RAM
-- cleanly: the MCP's program memory. It starts as zeros.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mcp_ram is
  generic (
    AW    : integer;                 -- address bits
    DW    : integer;                 -- data bits
    STYLE : string := "block"
    );
  port (
    clock : in  std_logic;
    we    : in  std_logic;
    waddr : in  unsigned(AW - 1 downto 0);
    wdata : in  std_logic_vector(DW - 1 downto 0);
    raddr : in  unsigned(AW - 1 downto 0);
    rdata : out std_logic_vector(DW - 1 downto 0)
    );
end mcp_ram;

architecture rtl of mcp_ram is
  type ram_t is array (0 to 2**AW - 1) of std_logic_vector(DW - 1 downto 0);
  signal ram : ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of ram : signal is STYLE;
begin
  process (clock)
  begin
    if rising_edge(clock) then
      if we = '1' then
        ram(to_integer(waddr)) <= wdata;
      end if;
      rdata <= ram(to_integer(raddr));
    end if;
  end process;
end rtl;
