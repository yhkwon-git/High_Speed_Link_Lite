# HSL Lite constraints after E7/E8.
# Periods match docs/02_architecture.md, hsl_pkg, and docs/e12_clocks.md.
# Not an HBM pin-timing deck, and not signed off in a timing tool.

set ctrl_period 1.25
set phy_period  0.625

create_clock -name clk -period $ctrl_period [get_ports clk]

# Behavioral 2x in hsl_phy_clk. The analog PLL is outside this repo.
# Source is the controller port. multiply_by 2 => 0.625 ns.
create_generated_clock -name clk_phy \
  -source [get_ports clk] \
  -multiply_by 2 \
  [get_pins u_phy/u_phy_clk/clk_phy]

# pin_ck is tied low. Do not declare a generated clock on it.

# Raw reset is asynchronously asserted. Deassert is synchronized in hsl_rst_sync.
# A blanket false path skips recovery/removal on that synchronizer.
# A real deck would constrain the synchronizer cell and still check recovery.
set_false_path -from [get_ports rst_n]

# 40% of the controller period. The old 4.0 ns belonged to the 10 ns smoke clock.
set_input_delay -clock clk 0.5 [get_ports {
  cfg_we
  cfg_addr
  cfg_wdata
  cmd_valid
  cmd_opc
  cmd_bank
  cmd_row
  cmd_col
  cmd_wdata
  pin_dq_i
  pin_dqs_i
}]

set_output_delay -clock clk 0.5 [get_ports {
  cfg_rdata
  cmd_ready
  rsp_valid
  rsp_rdata
  rsp_err
  pin_ck
  pin_cke
  pin_ca
  pin_dq_o
  pin_dq_oe
  pin_dqs_o
}]

# Gray-pointer synchronizers in hsl_cdc_fifo.
# One destination period. These paths are not false paths.
# wptr sync lives on clk (read). rptr sync lives on clk_phy (write).
set_max_delay $ctrl_period \
  -from [get_cells u_phy/u_fifo/wptr_g_s1*] \
  -to   [get_cells u_phy/u_fifo/wptr_g_s2*]

set_max_delay $phy_period \
  -from [get_cells u_phy/u_fifo/rptr_g_s1*] \
  -to   [get_cells u_phy/u_fifo/rptr_g_s2*]
