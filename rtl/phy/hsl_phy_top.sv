`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_phy_top
// PHY digital behind the controller's DFI-style interface: DBI, the payload
// mux (PRBS for the DFT compare), parallel loopback, CK forwarding, and the
// datapath in hsl_phy_mis (CA pins, TX gear with WDQS, RDQS capture, Gray
// FIFO, lane repair).
// CK leaves on pin_ck only with CTRL.phy_en; the enable is taken on the
// falling PHY edge so the gated clock has no partial pulse (an ICG in
// silicon).
//
// Parallel loopback: lb_hold keeps the last write burst sent while loopback is
// on, as returned by the DFT loopback mux. A RD in loopback answers with it,
// so a write then a read return the TX burst without the channel model.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_top (
  input  wire                          clk,
  input  wire                          rst_n,
  input  wire                          cke,
  input  wire                          dbi_en,
  input  wire                          dbi_ac,
  input  wire                          phy_en,
  input  wire                          repair_en,
  input  wire  [3:0]                   repair_lane,
  input  wire                          loopback,
  input  wire                          prbs_en,
  input  wire  [hsl_pkg::DATA_W-1:0]   prbs_data,

  // DFI-style, from the controller
  input  dram_pkg::dram_cmd_e          rcmd,
  input  wire  [hsl_pkg::BANK_W-1:0]   rbank,
  input  wire  [hsl_pkg::ROW_W-1:0]    row,
  input  dram_pkg::dram_cmd_e          ccmd,
  input  wire  [hsl_pkg::BANK_W-1:0]   cbank,
  input  wire  [hsl_pkg::COL_W-1:0]    col,
  input  wire                          ap,
  input  wire                          wrdata_en,
  input  wire  [hsl_pkg::DATA_W-1:0]   wrdata,
  output logic                         rddata_valid,
  output logic [hsl_pkg::DATA_W-1:0]   rddata,

  output logic                         obs_tx_valid,
  output logic [hsl_pkg::DATA_W-1:0]   obs_tx_data,
  input  wire  [hsl_pkg::DATA_W-1:0]   lb_rx_data,

  output logic                         pin_ck,
  output logic                         pin_cke,
  output logic [hsl_pkg::RCA_W-1:0]    pin_rca,
  output logic [hsl_pkg::CCA_W-1:0]    pin_cca,
  output logic [hsl_pkg::BEAT_W-1:0]   pin_tx_beat,
  output logic [hsl_pkg::DDR_BITS-1:0] pin_tx_dqs,
  output logic                         pin_tx_dv,
  input  wire                          pin_rdqs,
  input  wire  [hsl_pkg::BEAT_W-1:0]   pin_rx_beat,
  input  wire                          pin_rx_dv
);
  import hsl_pkg::*;

  logic [DATA_W-1:0] payload;
  logic [DQ_W-1:0]   ac_prev;
  logic [DATA_W-1:0] dbi_word;
  logic [BL-1:0]     dbi_flags;
  logic              clk_phy;
  logic              ck_en;
  logic [DATA_W-1:0] lb_hold;

  assign payload      = prbs_en ? prbs_data : wrdata;
  assign obs_tx_valid = phy_en && wrdata_en;
  assign obs_tx_data  = payload; // compare point is before DBI and repair
  assign pin_cke      = cke;

  hsl_phy_clk u_phy_clk (
    .clk_ctrl (clk),
    .clk_phy  (clk_phy)
  );

  // The enable flop of the clock gate, taken on the falling PHY edge. Like the
  // latch in an ICG cell it has no reset; phy_en itself resets to 0. With a
  // reset, the release (launched on the controller clock) has half a PHY period
  // to reach it, and the chip STA showed that is too short for recovery.
  always_ff @(negedge clk_phy) begin
    ck_en <= phy_en;
  end
  assign pin_ck = clk_phy & ck_en;

  // DBI-AC compares beat 0 with the UI before it on DQ: the last beat of the
  // write data of the clock before, or the idle bus (0).
  hsl_dbi u_dbi (
    .en   (dbi_en),
    .ac   (dbi_ac),
    .prev (ac_prev),
    .din  (payload),
    .dout (dbi_word),
    .dbi  (dbi_flags)
  );

  hsl_phy_mis u_mis (
    .clk          (clk),
    .clk_phy      (clk_phy),
    .rst_n        (rst_n),
    .on           (phy_en),
    .rcmd         (rcmd),
    .rbank        (rbank),
    .row          (row),
    .ccmd         (ccmd),
    .cbank        (cbank),
    .col          (col),
    .ap           (ap),
    .wrdata_en    (wrdata_en),
    .wdata        (dbi_word),
    .dbi_flags    (dbi_flags),
    .loopback     (loopback),
    .lb_data      (lb_hold),
    .repair_en    (repair_en),
    .repair_lane  (repair_lane),
    .ac_prev      (ac_prev),
    .rca          (pin_rca),
    .cca          (pin_cca),
    .tx_beat      (pin_tx_beat),
    .tx_dqs       (pin_tx_dqs),
    .tx_dv        (pin_tx_dv),
    .rdqs         (pin_rdqs),
    .rx_beat      (pin_rx_beat),
    .rx_dv        (pin_rx_dv),
    .rddata_valid (rddata_valid),
    .rddata       (rddata)
  );

  // lb_rx_data equals the write payload (pre-DBI, pre-repair) while loopback
  // is on.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lb_hold <= '0;
    end else if (phy_en && wrdata_en && loopback) begin
      lb_hold <= lb_rx_data;
    end
  end
endmodule

`default_nettype wire
