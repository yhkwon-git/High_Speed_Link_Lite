# HSL Lite constraints: controller clock, 2x PHY clock, forwarded CK, RDQS.
# Periods match docs/02_architecture.md, hsl_pkg, and docs/e12_clocks.md.
# Not an HBM pin-timing deck, and not signed off in a timing tool.

set ctrl_period 1.25
set phy_period  0.625

create_clock -name clk -period $ctrl_period [get_ports clk]

# Behavioral 2x in hsl_phy_clk. The analog PLL is outside this repo.
# Source is the controller port. multiply_by 2 => 0.625 ns, rising edges on
# every controller edge (E0) and half a period later (E1). The TX gear takes
# controller-clock data on E1, so clk -> clk_phy is a half-period path.
create_generated_clock -name clk_phy \
  -source [get_ports clk] \
  -multiply_by 2 \
  [get_pins u_phy/u_phy_clk/clk_phy]

# CK to the DRAM: clk_phy through the clock gate (ck_en taken on the falling
# PHY edge), forwarded on pin_ck in mission mode.
create_generated_clock -name ck_out \
  -source [get_pins u_phy/u_phy_clk/clk_phy] \
  -divide_by 1 \
  [get_ports pin_ck]

# RDQS from the DRAM: CK plus tDQSCK, so same period with an unknown phase
# against clk_phy. Read beats are captured on it and leave its domain only
# through the Gray FIFO in hsl_phy_mis; those paths are bounded at the end of
# this file. No asynchronous clock group: it would turn them into false paths,
# which take precedence over set_max_delay.
create_clock -name rdqs -period $phy_period [get_ports pin_rdqs]

# Raw reset is asynchronously asserted. Deassert is synchronized in hsl_rst_sync.
# A blanket false path skips recovery/removal on that synchronizer.
# A real deck would constrain the synchronizer cell and still check recovery.
set_false_path -from [get_ports rst_n]

# RDQS-domain reset (hsl_phy_mis/u_rst_rdqs): asserted asynchronously with the
# controller-clock reset, released by two RDQS flops. Only the assertion path
# into those two flops is left untimed; the capture flops and the FIFO's write
# side they release are timed against rdqs (recovery and removal).
set_false_path -to [get_pins {u_phy/u_mis/u_rst_rdqs/sync_r*_reg/RN}]

# Pre-layout: the synchronized reset (and soft_rst, which joins it) reaches
# every flop's reset pin, about 4,650 of them (3d596a4). Like a clock tree, it is
# built in place and route; until then synthesis treats it as an ideal
# network. OpenSTA 3.1 accepts this command but does not apply it, so
# syn/sta_chip.sh buffers the tree instead (syn/fanout_buffer.py). Unbuffered,
# one gate drives every load and its delay is read far off the cell tables.
set_ideal_network [get_pins {u_rst/rst_no u_csr/soft_rst u_phy/u_mis/u_rst_rdqs/rst_no}]

# 40% of the controller period. The old 4.0 ns belonged to the 10 ns smoke clock.
# The 1500 port inputs go to 2-flop synchronizers (hsl_w1500); WRCK is slow
# and sampled in clk, so they are timed as ordinary inputs to the first flop.
set_input_delay -clock clk 0.5 [get_ports {
  cfg_we
  cfg_addr
  cfg_wdata
  req_valid
  req_write
  req_addr
  req_wdata
  rsp_ready
  fz_rdata
  wrck
  wrstn
  selectwir
  shiftwr
  capturewr
  updatewr
  wsi
}]

set_output_delay -clock clk 0.5 [get_ports {
  cfg_rdata
  req_ready
  rsp_valid
  rsp_rdata
  rsp_err
  pin_cke
  pin_rca
  pin_cca
  rx_dly_code
  rep_tab
  fz_addr
  fz_rd
  fz_pgm
  fz_wdata
  wso
}]

# CTRL and REMAP settings that steer the write data (PRBS payload, DBI rule,
# lane repair) change only with the controller idle, and traffic follows
# several clocks later (docs/03). Their paths into the TX word register get two
# clocks. Data pins only: the reset pins keep their single-cycle recovery.
set_multicycle_path 2 -setup -from [get_cells u_csr/*] -to [get_pins u_phy/u_mis/tx_word*/D]
set_multicycle_path 1 -hold  -from [get_cells u_csr/*] -to [get_pins u_phy/u_mis/tx_word*/D]

# Mission beats (data and ECC pins) leave on clk_phy toward the analog
# serializer, and read beats arrive with RDQS. 40% of the PHY period on each side.
set_output_delay -clock clk_phy 0.25 [get_ports {
  pin_tx_beat
  pin_tx_ecc
  pin_tx_dqs
  pin_tx_dv
}]
set_input_delay -clock rdqs 0.25 [get_ports {
  pin_rx_beat
  pin_rx_ecc
  pin_rx_dv
}]

# Read FIFO crossings (hsl_phy_mis/u_rx_fifo), RDQS <-> controller clock.
# Gray pointers: source-domain Gray flop -> first synchronizer flop, bounded
# to the faster period so the bits of one Gray step arrive within one period
# of each other. Not false paths.
#   wgray (rdqs) -> wptr_g_s1 (clk)
#   rgray (clk)  -> rptr_g_s1 (rdqs)
# The bound names the source clock and the sink flops, not the source cells:
# the Gray MSB equals the binary MSB, so synthesis keeps one flop for both
# (wbin[2], rbin[2]) and a wgray*/rgray* cell pattern misses that bit.
set_max_delay $phy_period \
  -from [get_clocks rdqs] \
  -to   [get_cells u_phy/u_mis/u_rx_fifo/wptr_g_s1*]

set_max_delay $phy_period \
  -from [get_clocks clk] \
  -to   [get_cells u_phy/u_mis/u_rx_fifo/rptr_g_s1*]

# FIFO data: written on RDQS, read in the controller clock only after the
# write pointer has crossed two synchronizer flops, so one controller period
# is a safe bound.
set_max_delay $ctrl_period \
  -from [get_cells u_phy/u_mis/u_rx_fifo/mem*] \
  -to   [get_clocks clk]
