`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_base_die_lite
// Study top for one base-die channel slice.
//
// Reset:
//   pin rst_n -> hsl_rst_sync -> rst_sync_n
//   CSR resets from rst_sync_n only
//   every other block resets from rst_sync_n & ~soft_rst
//
// Live after E12: CSR, training FSM, reset tree, queue, scheduler, bank FSMs,
// phy_bypass framer to the channel model, DBI, lane repair, PRBS compare.
// Tied off in the chip: gearbox din_valid, FIFO wr_en/rd_en, deskew output.
// Those blocks are exercised by their own instances in tb_hsl_blocks.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_base_die_lite (
  input  wire                            clk,
  input  wire                            rst_n,

  input  wire                            cfg_we,
  input  wire  [7:0]                     cfg_addr,
  input  wire  [31:0]                    cfg_wdata,
  output logic [31:0]                    cfg_rdata,

  input  wire                            cmd_valid,
  output logic                           cmd_ready,
  input  wire  [3:0]                     cmd_opc,
  input  wire  [hsl_pkg::BANK_W-1:0]     cmd_bank,
  input  wire  [hsl_pkg::ROW_W-1:0]      cmd_row,
  input  wire  [hsl_pkg::COL_W-1:0]      cmd_col,
  input  wire  [hsl_pkg::DATA_W-1:0]     cmd_wdata,
  output logic                           rsp_valid,
  output logic [hsl_pkg::DATA_W-1:0]     rsp_rdata,
  output logic                           rsp_err,

  output logic                           pin_ck,
  output logic                           pin_cke,
  output logic [7:0]                     pin_ca,
  output logic [hsl_pkg::PIN_W-1:0]      pin_dq_o,
  output logic                           pin_dq_oe,
  output logic                           pin_dqs_o,
  input  wire  [hsl_pkg::PIN_W-1:0]      pin_dq_i,
  input  wire                            pin_dqs_i
);
  logic rst_sync_n;
  logic rst_logic_n;

  logic soft_rst, train_bypass, loopback, prbs_en, dbi_en, phy_bypass;
  logic train_start, zq_done, wrlvl_done, rdlvl_done, deskew_done;
  logic repair_en, err_clear;
  logic [hsl_pkg::DATA_W-1:0] prbs_data;
  logic [7:0] train_wait;
  logic [3:0] repair_lane;
  logic [31:0] timing0, timing1;
  logic [3:0] train_state;
  logic train_done, mission_mode, cke;
  logic [15:0] err_cnt;

  logic phy_valid, phy_ready, phy_rsp_valid;
  logic [3:0] phy_opc;
  logic [hsl_pkg::BANK_W-1:0] phy_bank;
  logic [hsl_pkg::ROW_W-1:0] phy_row;
  logic [hsl_pkg::COL_W-1:0] phy_col;
  logic [hsl_pkg::DATA_W-1:0] phy_wdata, phy_rsp_rdata;
  logic [hsl_pkg::DATA_W-1:0] obs_tx_data, lb_rx_data;

  hsl_rst_sync u_rst (
    .clk    (clk),
    .rst_ni (rst_n),
    .rst_no (rst_sync_n)
  );

  assign rst_logic_n = rst_sync_n & ~soft_rst;

  hsl_csr u_csr (
    .clk          (clk),
    .rst_n        (rst_sync_n),
    .cfg_we       (cfg_we),
    .cfg_addr     (cfg_addr),
    .cfg_wdata    (cfg_wdata),
    .cfg_rdata    (cfg_rdata),
    .soft_rst     (soft_rst),
    .train_bypass (train_bypass),
    .loopback     (loopback),
    .prbs_en      (prbs_en),
    .dbi_en       (dbi_en),
    .phy_bypass   (phy_bypass),
    .train_start  (train_start),
    .zq_done      (zq_done),
    .wrlvl_done   (wrlvl_done),
    .rdlvl_done   (rdlvl_done),
    .deskew_done  (deskew_done),
    .train_wait   (train_wait),
    .repair_en    (repair_en),
    .repair_lane  (repair_lane),
    .err_clear    (err_clear),
    .timing0      (timing0),
    .timing1      (timing1),
    .train_state  (train_state),
    .train_done   (train_done),
    .mission_mode (mission_mode),
    .err_cnt      (err_cnt)
  );

  hsl_training_fsm u_fsm (
    .clk          (clk),
    .rst_n        (rst_logic_n),
    .train_bypass (train_bypass),
    .train_start  (train_start),
    .train_wait   (train_wait),
    .zq_done      (zq_done),
    .wrlvl_done   (wrlvl_done),
    .rdlvl_done   (rdlvl_done),
    .deskew_done  (deskew_done),
    .train_state  (train_state),
    .train_done   (train_done),
    .mission_mode (mission_mode),
    .cke          (cke)
  );

  hsl_mc_top u_mc (
    .clk           (clk),
    .rst_n         (rst_logic_n),
    .mission_mode  (mission_mode),
    .timing0       (timing0),
    .timing1       (timing1),
    .cmd_valid     (cmd_valid),
    .cmd_ready     (cmd_ready),
    .cmd_opc       (cmd_opc),
    .cmd_bank      (cmd_bank),
    .cmd_row       (cmd_row),
    .cmd_col       (cmd_col),
    .cmd_wdata     (cmd_wdata),
    .rsp_valid     (rsp_valid),
    .rsp_rdata     (rsp_rdata),
    .rsp_err       (rsp_err),
    .phy_valid     (phy_valid),
    .phy_ready     (phy_ready),
    .phy_opc       (phy_opc),
    .phy_bank      (phy_bank),
    .phy_row       (phy_row),
    .phy_col       (phy_col),
    .phy_wdata     (phy_wdata),
    .phy_rsp_valid (phy_rsp_valid),
    .phy_rsp_rdata (phy_rsp_rdata)
  );

  hsl_dft_top u_dft (
    .clk       (clk),
    .rst_n     (rst_logic_n),
    .loopback  (loopback),
    .prbs_en   (prbs_en),
    .err_clear (err_clear),
    .tx_valid  (phy_valid),
    .tx_data   (obs_tx_data),
    .rx_data   (lb_rx_data),
    .prbs_data (prbs_data),
    .err_cnt   (err_cnt)
  );

  hsl_phy_top u_phy (
    .clk         (clk),
    .rst_n       (rst_logic_n),
    .cke         (cke),
    .dbi_en      (dbi_en),
    .phy_bypass  (phy_bypass),
    .repair_en   (repair_en),
    .repair_lane (repair_lane),
    .loopback    (loopback),
    .prbs_en     (prbs_en),
    .prbs_data   (prbs_data),
    .valid       (phy_valid),
    .ready       (phy_ready),
    .opc         (phy_opc),
    .bank        (phy_bank),
    .row         (phy_row),
    .col         (phy_col),
    .wdata       (phy_wdata),
    .rsp_valid   (phy_rsp_valid),
    .rsp_rdata   (phy_rsp_rdata),
    .obs_tx_data (obs_tx_data),
    .lb_rx_data  (lb_rx_data),
    .pin_ck      (pin_ck),
    .pin_cke     (pin_cke),
    .pin_ca      (pin_ca),
    .pin_dq_o    (pin_dq_o),
    .pin_dq_oe   (pin_dq_oe),
    .pin_dqs_o   (pin_dqs_o),
    .pin_dq_i    (pin_dq_i),
    .pin_dqs_i   (pin_dqs_i)
  );
endmodule

`default_nettype wire
