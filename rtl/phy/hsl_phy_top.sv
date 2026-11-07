`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_phy_top
// Two datapaths share the DBI encoder, the payload mux and loopback:
//   bypass  (CTRL.phy_bypass): hsl_phy_tx / hsl_phy_rx frame each command on
//           the DQ pins in controller clocks, header beat included. Kept as a
//           low-speed test path.
//   mission (CTRL.phy_en, phy_bypass off): hsl_phy_mis puts commands on the
//           row / column CA pins and data on 1.6 GHz beats with WDQS, and
//           captures reads on RDQS through the Gray FIFO.
// With neither set the PHY does not take commands (ready = 0).
// CK leaves on pin_ck only in mission mode; the enable is taken on the falling
// PHY edge so the gated clock has no partial pulse (an ICG in silicon).
// Deskew stays tied off and is checked on its own instance.
//
// Parallel loopback: lb_hold keeps the last WR burst sent while loopback is
// on, as returned by the DFT loopback mux. A RD in loopback answers with it,
// so WR then RD reads the TX burst back without the channel model.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_top (
  input  wire                          clk,
  input  wire                          rst_n,
  input  wire                          cke,
  input  wire                          dbi_en,
  input  wire                          dbi_ac,
  input  wire                          phy_bypass,
  input  wire                          phy_en,
  input  wire                          repair_en,
  input  wire  [3:0]                   repair_lane,
  input  wire                          loopback,
  input  wire                          prbs_en,
  input  wire  [hsl_pkg::DATA_W-1:0]   prbs_data,

  input  wire                          valid,
  output logic                         ready,
  input  wire  [3:0]                   opc,
  input  wire  [hsl_pkg::BANK_W-1:0]   bank,
  input  wire  [hsl_pkg::ROW_W-1:0]    row,
  input  wire  [hsl_pkg::COL_W-1:0]    col,
  input  wire  [hsl_pkg::DATA_W-1:0]   wdata,

  output logic                         rsp_valid,
  output logic [hsl_pkg::DATA_W-1:0]   rsp_rdata,
  output logic [hsl_pkg::DATA_W-1:0]   obs_tx_data,

  input  wire  [hsl_pkg::DATA_W-1:0]   lb_rx_data,

  // bypass pins
  output logic                         pin_ck,
  output logic                         pin_cke,
  output logic [7:0]                   pin_ca,
  output logic [hsl_pkg::PIN_W-1:0]    pin_dq_o,
  output logic                         pin_dq_oe,
  output logic                         pin_dqs_o,
  input  wire  [hsl_pkg::PIN_W-1:0]    pin_dq_i,
  input  wire                          pin_dqs_i,

  // mission pins (toward the analog PHY and the DRAM)
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
  logic [DQ_W-1:0]   dbi_prev;
  logic [DQ_W-1:0]   mis_ac_prev;
  logic [DATA_W-1:0] dbi_word;
  logic [BL-1:0]     dbi_flags;
  logic [LANE_N-1:0] tx_sym;
  logic [LANE_N-1:0] rx_sym;
  logic              clk_phy;
  logic              ck_en;
  logic              rd_start;
  logic              tx_ready;
  logic              mis_on;
  logic              byp_rsp_valid;
  logic [DATA_W-1:0] byp_rsp_rdata;
  logic              mis_rsp_valid;
  logic [DATA_W-1:0] mis_rsp_rdata;
  logic [DQ_W-1:0]   deskew_q;
  logic              deskew_valid;
  logic [DATA_W-1:0] lb_hold;

  assign payload     = prbs_en ? prbs_data : wdata;
  assign obs_tx_data = payload; // compare point is before DBI and repair
  assign pin_cke     = cke;
  assign mis_on      = phy_en && !phy_bypass;
  assign ready       = phy_bypass ? tx_ready : mis_on;

  hsl_phy_clk u_phy_clk (
    .clk_ctrl (clk),
    .clk_phy  (clk_phy)
  );

  always_ff @(negedge clk_phy or negedge rst_n) begin
    if (!rst_n) begin
      ck_en <= 1'b0;
    end else begin
      ck_en <= mis_on;
    end
  end
  assign pin_ck = clk_phy & ck_en;

  // DBI-AC compares beat 0 with the UI before it on DQ: in the bypass framer
  // the WR header (col on DQ[COL_W-1:0], hsl_phy_tx S_WH); on the mission path
  // the last beat of a WR issued the clock before, or the idle bus (0).
  assign dbi_prev = phy_bypass ? {{(DQ_W-COL_W){1'b0}}, col} : mis_ac_prev;

  hsl_dbi u_dbi (
    .en   (dbi_en),
    .ac   (dbi_ac),
    .prev (dbi_prev),
    .din  (payload),
    .dout (dbi_word),
    .dbi  (dbi_flags)
  );

  // ---------------------------------------------------------------- bypass
  // Lane repair at the pin boundary, both directions and every symbol
  // (headers too, since this framer sends row and col on DQ).
  hsl_lane_shift u_shift (
    .en   (repair_en),
    .lane (repair_lane),
    .tx_l (tx_sym),
    .tx_p (pin_dq_o),
    .rx_p (pin_dq_i),
    .rx_l (rx_sym)
  );

  hsl_phy_tx u_tx (
    .clk         (clk),
    .rst_n       (rst_n),
    .cke         (cke),
    .phy_bypass  (phy_bypass),
    .valid       (valid),
    .ready       (tx_ready),
    .opc         (opc),
    .bank        (bank),
    .row         (row),
    .col         (col),
    .wdata       (dbi_word),
    .dbi_flags   (dbi_flags),
    .ca          (pin_ca),
    .sym_o       (tx_sym),
    .dq_oe       (pin_dq_oe),
    .dqs_o       (pin_dqs_o),
    .rd_start    (rd_start)
  );

  hsl_phy_rx u_rx (
    .clk       (clk),
    .rst_n     (rst_n),
    .rd_start  (rd_start),
    .sym_i     (rx_sym),
    .dqs_i     (pin_dqs_i),
    .lb_data   (lb_hold),
    .loopback  (loopback),
    .rsp_valid (byp_rsp_valid),
    .rsp_rdata (byp_rsp_rdata)
  );

  // ---------------------------------------------------------------- mission
  hsl_phy_mis u_mis (
    .clk         (clk),
    .clk_phy     (clk_phy),
    .rst_n       (rst_n),
    .fire        (valid && mis_on),
    .opc         (opc),
    .bank        (bank),
    .row         (row),
    .col         (col),
    .wdata       (dbi_word),
    .dbi_flags   (dbi_flags),
    .loopback    (loopback),
    .lb_data     (lb_hold),
    .repair_en   (repair_en),
    .repair_lane (repair_lane),
    .ac_prev     (mis_ac_prev),
    .rca         (pin_rca),
    .cca         (pin_cca),
    .tx_beat     (pin_tx_beat),
    .tx_dqs      (pin_tx_dqs),
    .tx_dv       (pin_tx_dv),
    .rdqs        (pin_rdqs),
    .rx_beat     (pin_rx_beat),
    .rx_dv       (pin_rx_dv),
    .rsp_valid   (mis_rsp_valid),
    .rsp_rdata   (mis_rsp_rdata)
  );

  assign rsp_valid = byp_rsp_valid | mis_rsp_valid;
  assign rsp_rdata = mis_rsp_valid ? mis_rsp_rdata : byp_rsp_rdata;

  // valid is already the scheduler's fire; ready is repeated for clarity.
  // lb_rx_data equals the WR payload (pre-DBI, pre-repair) while loopback is on.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lb_hold <= '0;
    end else if (valid && ready && loopback && (opc == OPC_WR)) begin
      lb_hold <= lb_rx_data;
    end
  end

  // Per-lane coarse deskew is not on a path yet (block test only).
  hsl_deskew u_deskew (
    .clk        (clk_phy),
    .rst_n      (rst_n),
    .din        (pin_dq_i[DQ_W-1:0]),
    .din_valid  (pin_dqs_i),
    .delay_sel  (3'd0),
    .dout       (deskew_q),
    .dout_valid (deskew_valid)
  );

  wire unused_path = ^{deskew_q, deskew_valid};
endmodule

`default_nettype wire
