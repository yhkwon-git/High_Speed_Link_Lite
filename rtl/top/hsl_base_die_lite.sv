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
// Memory controller: Mini DRAM Controller v4 (mem_ctrl in rtl/mc/, the same
// files as that repo). The host port takes word-addressed reads and writes and
// answers each one in request order; writes are answered when accepted
// (posted). Its DFI-style DRAM side goes straight to the PHY: a row command
// bus and a column command bus every clock, write data WL clocks after its WR,
// and read data back on rddata_valid with whatever latency the PHY has.
//
// Live: CSR, training FSM, reset tree, controller, PHY (DBI, lane repair, CA
// pins, TX gear with WDQS, RDQS capture, Gray FIFO), lane BIST, read
// leveling, PRBS compare. Tied off in the chip: deskew (block test only).
//
// The request port is open in mission mode with the PHY on (CTRL.phy_en):
// only then do commands reach the pins, and a read sent with the PHY off
// would never be answered. Change phy_en or loopback with the controller idle.
//
// Test engines (lane BIST, MBIST): while one runs it owns the request port.
// req_ready and rsp_valid to the host are held at 0 and the engine takes every
// response, so start it with the host quiet and every response taken.
//
// Repair: hsl_bira allocates spare rows and columns from the MBIST fail log;
// the repair table (rep_tab) goes to the array, where the spares are. After
// reset the table is loaded from the fuses (fz_*, SECDED-protected words).
//
// Read leveling (hsl_rd_train) sweeps the per-lane delay codes on rx_dly_code,
// which go to the analog delay lines outside this block, and runs the lane
// BIST at each code.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_base_die_lite (
  input  wire                            clk,
  input  wire                            rst_n,

  input  wire                            cfg_we,
  input  wire  [7:0]                     cfg_addr,
  input  wire  [31:0]                    cfg_wdata,
  output logic [31:0]                    cfg_rdata,

  // Host request port (mem_ctrl): word address, posted writes, in-order
  // responses.
  input  wire                            req_valid,
  output logic                           req_ready,
  input  wire                            req_write,
  input  wire  [hsl_pkg::ADDR_W-1:0]     req_addr,
  input  wire  [hsl_pkg::DATA_W-1:0]     req_wdata,
  output logic                           rsp_valid,
  input  wire                            rsp_ready,
  output logic [hsl_pkg::DATA_W-1:0]     rsp_rdata,
  output logic                           rsp_err,

  // Pins: CK, row / column CA, PHY beats with WDQS, RDQS capture.
  output logic                           pin_ck,
  output logic                           pin_cke,
  output logic [hsl_pkg::RCA_W-1:0]      pin_rca,
  output logic [hsl_pkg::CCA_W-1:0]      pin_cca,
  output logic [hsl_pkg::BEAT_W-1:0]     pin_tx_beat,
  output logic [hsl_pkg::DDR_BITS-1:0]   pin_tx_dqs,
  output logic                           pin_tx_dv,
  input  wire                            pin_rdqs,
  input  wire  [hsl_pkg::BEAT_W-1:0]     pin_rx_beat,
  input  wire                            pin_rx_dv,

  // One read delay-line code per DQ lane, to the analog PHY.
  output logic [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rx_dly_code,

  // Repair table toward the array's spare rows and columns, and the fuse port.
  output logic [hsl_pkg::RT_N*hsl_pkg::RT_W-1:0]      rep_tab,
  output logic [1:0]                                 fz_addr,
  output logic                                       fz_rd,
  input  wire  [hsl_pkg::FZ_W-1:0]                   fz_rdata,
  output logic                                       fz_pgm,
  output logic [hsl_pkg::FZ_W-1:0]                   fz_wdata,

  // ECC pins: the check bits of each burst, beside the data beats.
  output logic [2*hsl_pkg::DDR_BITS-1:0]             pin_tx_ecc,
  input  wire  [2*hsl_pkg::DDR_BITS-1:0]             pin_rx_ecc
);
  logic rst_sync_n;
  logic rst_logic_n;

  logic soft_rst, train_bypass, loopback, prbs_en, dbi_en, dbi_ac, phy_en;
  logic train_start, zq_done, wrlvl_done, rdlvl_done, deskew_done;
  logic repair_en, err_clear;
  logic [hsl_pkg::DATA_W-1:0] prbs_data;
  logic [7:0] train_wait;
  logic [3:0] repair_lane;
  logic [3:0] train_state;
  logic train_done, mission_mode, cke;
  logic [15:0] err_cnt;

  // Controller request port, after the host / BIST mux.
  logic                        port_open;
  logic                        mc_req_valid, mc_req_ready, mc_req_write;
  logic [hsl_pkg::ADDR_W-1:0]  mc_req_addr;
  logic [hsl_pkg::DATA_W-1:0]  mc_req_wdata;
  logic                        mc_rsp_valid, mc_rsp_ready, mc_rsp_err;
  logic [hsl_pkg::DATA_W-1:0]  mc_rsp_rdata;
  logic                        mc_q_empty;

  // DFI-style controller <-> PHY.
  dram_pkg::dram_cmd_e         dfi_rcmd, dfi_ccmd;
  logic [hsl_pkg::BANK_W-1:0]  dfi_rbank, dfi_cbank;
  logic [hsl_pkg::ROW_W-1:0]   dfi_row;
  logic [hsl_pkg::COL_W-1:0]   dfi_col;
  logic                        dfi_ap;
  logic                        dfi_wrdata_en, dfi_rddata_valid;
  logic [hsl_pkg::DATA_W-1:0]  dfi_wrdata, dfi_rddata;

  logic lb_start, lb_busy, lb_done;
  logic [1:0] lb_bank;
  logic [7:0] lb_row;
  logic                        tp_busy, tp_req_valid, tp_req_write;
  logic [hsl_pkg::ADDR_W-1:0]  tp_req_addr;
  logic [hsl_pkg::DATA_W-1:0]  tp_req_wdata;
  logic mb_start, mb_busy, mb_done, mb_log_ovf;
  logic [1:0] mb_algo, mb_bank;
  logic [7:0] mb_row0, mb_log_entry;
  logic [3:0] mb_nrows_m1, mb_log_sel;
  logic [2:0] mb_ncl;
  logic [15:0] mb_fail_cnt;
  logic [hsl_pkg::ADDR_W-1:0] mb_first_addr;
  logic [hsl_pkg::DATA_W-1:0] mb_first_bits;
  logic [4:0] mb_log_n;
  logic br_start, br_apply, rp_clear, fz_program, fz_load;
  logic br_busy, br_done, br_ok, fz_busy, fz_loaded;
  logic [1:0] br_rows, br_cols;
  logic [3:0] fz_ce, fz_ue;
  logic [hsl_pkg::RT_N-1:0] fz_drop;
  logic ecc_en, ecc_inj_arm, ecc_st_start, ecc_clear;
  logic [31:0] ecc_inj_dmask;
  logic [6:0] ecc_inj_cmask, ecc_st_fails, ecc_log_syn;
  logic ecc_inj_pend, ecc_st_busy, ecc_st_done, ecc_st_pass, ecc_log_v, ecc_log_ue;
  logic [15:0] ecc_ce_cnt, ecc_ue_cnt;
  logic [hsl_pkg::ADDR_W-1:0] ecc_log_addr;
  logic [7:0] lb_lane_err;
  logic [4:0] lb_err_bursts;
  logic rt_start, rt_bist_start, rt_busy, rt_done, rt_ok;
  logic [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rt_lo;
  logic [hsl_pkg::DQ_W*6-1:0] rt_len;
  logic obs_tx_valid;
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
    .dbi_ac       (dbi_ac),
    .phy_en       (phy_en),
    .train_start  (train_start),
    .zq_done      (zq_done),
    .wrlvl_done   (wrlvl_done),
    .rdlvl_done   (rdlvl_done),
    .deskew_done  (deskew_done),
    .train_wait   (train_wait),
    .repair_en    (repair_en),
    .repair_lane  (repair_lane),
    .err_clear    (err_clear),
    .lb_start     (lb_start),
    .lb_bank      (lb_bank),
    .lb_row       (lb_row),
    .rt_start     (rt_start),
    .train_state  (train_state),
    .train_done   (train_done),
    .mission_mode (mission_mode),
    .err_cnt      (err_cnt),
    .lb_busy      (lb_busy),
    .lb_done      (lb_done),
    .lb_lane_err  (lb_lane_err),
    .lb_err_bursts(lb_err_bursts),
    .rt_busy      (rt_busy),
    .rt_done      (rt_done),
    .rt_ok        (rt_ok),
    .rt_code      (rx_dly_code),
    .rt_lo        (rt_lo),
    .rt_len       (rt_len),
    .mb_start     (mb_start),
    .mb_algo      (mb_algo),
    .mb_bank      (mb_bank),
    .mb_row0      (mb_row0),
    .mb_nrows_m1  (mb_nrows_m1),
    .mb_ncl       (mb_ncl),
    .mb_log_sel   (mb_log_sel),
    .mb_busy      (mb_busy),
    .mb_done      (mb_done),
    .mb_fail_cnt  (mb_fail_cnt),
    .mb_first_addr(mb_first_addr),
    .mb_first_bits(mb_first_bits),
    .mb_log_n     (mb_log_n),
    .mb_log_ovf   (mb_log_ovf),
    .mb_log_entry (mb_log_entry),
    .br_start     (br_start),
    .br_apply     (br_apply),
    .rp_clear     (rp_clear),
    .fz_program   (fz_program),
    .fz_load      (fz_load),
    .br_busy      (br_busy),
    .br_done      (br_done),
    .br_ok        (br_ok),
    .br_rows      (br_rows),
    .br_cols      (br_cols),
    .rep_tab      (rep_tab),
    .fz_busy      (fz_busy),
    .fz_loaded    (fz_loaded),
    .fz_ce        (fz_ce),
    .fz_ue        (fz_ue),
    .fz_drop      (fz_drop),
    .ecc_en       (ecc_en),
    .ecc_inj_arm  (ecc_inj_arm),
    .ecc_inj_dmask(ecc_inj_dmask),
    .ecc_inj_cmask(ecc_inj_cmask),
    .ecc_st_start (ecc_st_start),
    .ecc_clear    (ecc_clear),
    .ecc_inj_pend (ecc_inj_pend),
    .ecc_st_busy  (ecc_st_busy),
    .ecc_st_done  (ecc_st_done),
    .ecc_st_pass  (ecc_st_pass),
    .ecc_st_fails (ecc_st_fails),
    .ecc_ce_cnt   (ecc_ce_cnt),
    .ecc_ue_cnt   (ecc_ue_cnt),
    .ecc_log_v    (ecc_log_v),
    .ecc_log_ue   (ecc_log_ue),
    .ecc_log_syn  (ecc_log_syn),
    .ecc_log_addr (ecc_log_addr)
  );

  hsl_rd_train u_rd_train (
    .clk           (clk),
    .rst_n         (rst_logic_n),
    .start         (rt_start),
    .bist_start    (rt_bist_start),
    .bist_busy     (lb_busy),
    .bist_lane_err (lb_lane_err),
    .rx_dly        (rx_dly_code),
    .busy          (rt_busy),
    .done          (rt_done),
    .ok            (rt_ok),
    .win_lo        (rt_lo),
    .win_len       (rt_len)
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

  // The request port belongs to a test engine (lane BIST or MBIST) while one
  // runs, to the host otherwise.
  assign port_open    = mission_mode && phy_en;
  assign mc_req_valid = port_open && (tp_busy ? tp_req_valid : req_valid);
  assign mc_req_write = tp_busy ? tp_req_write : req_write;
  assign mc_req_addr  = tp_busy ? tp_req_addr  : req_addr;
  assign mc_req_wdata = tp_busy ? tp_req_wdata : req_wdata;
  assign mc_rsp_ready = tp_busy ? 1'b1 : rsp_ready;
  assign req_ready    = port_open && !tp_busy && mc_req_ready;
  assign rsp_valid    = mc_rsp_valid && !tp_busy;
  assign rsp_rdata    = mc_rsp_rdata;
  assign rsp_err      = mc_rsp_err;

  mem_ctrl #(
    .ADDR_MAP (hsl_pkg::MC_ADDR_MAP)
  ) u_mc (
    .clk             (clk),
    .rst_n           (rst_logic_n),
    .req_valid       (mc_req_valid),
    .req_ready       (mc_req_ready),
    .req_write       (mc_req_write),
    .req_addr        (mc_req_addr),
    .req_wdata       (mc_req_wdata),
    .rsp_valid       (mc_rsp_valid),
    .rsp_ready       (mc_rsp_ready),
    .rsp_rdata       (mc_rsp_rdata),
    .rsp_err         (mc_rsp_err),
    .dram_rcmd       (dfi_rcmd),
    .dram_rbank      (dfi_rbank),
    .dram_row        (dfi_row),
    .dram_ccmd       (dfi_ccmd),
    .dram_cbank      (dfi_cbank),
    .dram_col        (dfi_col),
    .dram_ap         (dfi_ap),
    .dram_wdata_en   (dfi_wrdata_en),
    .dram_wdata      (dfi_wrdata),
    .dram_data_valid (dfi_rddata_valid),
    .dram_rdata      (dfi_rddata),
    .q_empty         (mc_q_empty)
  );

  hsl_dft_top u_dft (
    .clk           (clk),
    .rst_n         (rst_logic_n),
    .loopback      (loopback),
    .prbs_en       (prbs_en),
    .err_clear     (err_clear),
    .tx_valid      (obs_tx_valid),
    .tx_data       (obs_tx_data),
    .rx_data       (lb_rx_data),
    .prbs_data     (prbs_data),
    .err_cnt       (err_cnt),
    .q_empty       (mc_q_empty),
    .tp_busy       (tp_busy),
    .tp_req_valid  (tp_req_valid),
    .tp_req_ready  (port_open && mc_req_ready),
    .tp_req_write  (tp_req_write),
    .tp_req_addr   (tp_req_addr),
    .tp_req_wdata  (tp_req_wdata),
    .tp_rsp_valid  (mc_rsp_valid),
    .tp_rsp_rdata  (mc_rsp_rdata),
    .lb_start      (lb_start | rt_bist_start),
    .lb_bank       (lb_bank),
    .lb_row        (lb_row),
    .lb_busy       (lb_busy),
    .lb_done       (lb_done),
    .lb_lane_err   (lb_lane_err),
    .lb_err_bursts (lb_err_bursts),
    .mb_start      (mb_start),
    .mb_algo       (mb_algo),
    .mb_bank       (mb_bank),
    .mb_row0       (mb_row0),
    .mb_nrows_m1   (mb_nrows_m1),
    .mb_ncl        (mb_ncl),
    .mb_log_sel    (mb_log_sel),
    .mb_busy       (mb_busy),
    .mb_done       (mb_done),
    .mb_fail_cnt   (mb_fail_cnt),
    .mb_first_addr (mb_first_addr),
    .mb_first_bits (mb_first_bits),
    .mb_log_n      (mb_log_n),
    .mb_log_ovf    (mb_log_ovf),
    .mb_log_entry  (mb_log_entry),
    .br_start      (br_start),
    .br_apply      (br_apply),
    .rp_clear      (rp_clear),
    .fz_program    (fz_program),
    .fz_load       (fz_load),
    .br_busy       (br_busy),
    .br_done       (br_done),
    .br_ok         (br_ok),
    .br_rows       (br_rows),
    .br_cols       (br_cols),
    .rep_tab       (rep_tab),
    .fz_addr       (fz_addr),
    .fz_rd         (fz_rd),
    .fz_rdata      (fz_rdata),
    .fz_pgm        (fz_pgm),
    .fz_wdata      (fz_wdata),
    .fz_busy       (fz_busy),
    .fz_loaded     (fz_loaded),
    .fz_ce         (fz_ce),
    .fz_ue         (fz_ue),
    .fz_drop       (fz_drop)
  );

  hsl_phy_top u_phy (
    .clk          (clk),
    .rst_n        (rst_logic_n),
    .cke          (cke),
    .dbi_en       (dbi_en),
    .dbi_ac       (dbi_ac),
    .phy_en       (phy_en),
    .repair_en    (repair_en),
    .repair_lane  (repair_lane),
    .loopback     (loopback),
    .prbs_en      (prbs_en),
    .prbs_data    (prbs_data),
    .rcmd         (dfi_rcmd),
    .rbank        (dfi_rbank),
    .row          (dfi_row),
    .ccmd         (dfi_ccmd),
    .cbank        (dfi_cbank),
    .col          (dfi_col),
    .ap           (dfi_ap),
    .wrdata_en    (dfi_wrdata_en),
    .wrdata       (dfi_wrdata),
    .rddata_valid (dfi_rddata_valid),
    .rddata       (dfi_rddata),
    .obs_tx_valid (obs_tx_valid),
    .obs_tx_data  (obs_tx_data),
    .lb_rx_data   (lb_rx_data),
    .pin_ck       (pin_ck),
    .pin_cke      (pin_cke),
    .pin_rca      (pin_rca),
    .pin_cca      (pin_cca),
    .pin_tx_beat  (pin_tx_beat),
    .pin_tx_dqs   (pin_tx_dqs),
    .pin_tx_dv    (pin_tx_dv),
    .pin_rdqs     (pin_rdqs),
    .pin_rx_beat  (pin_rx_beat),
    .pin_rx_dv    (pin_rx_dv),
    .pin_tx_ecc   (pin_tx_ecc),
    .pin_rx_ecc   (pin_rx_ecc),
    .ecc_en       (ecc_en),
    .ecc_inj_arm  (ecc_inj_arm),
    .ecc_inj_dmask(ecc_inj_dmask),
    .ecc_inj_cmask(ecc_inj_cmask),
    .ecc_st_start (ecc_st_start),
    .ecc_clear    (ecc_clear),
    .ecc_inj_pend (ecc_inj_pend),
    .ecc_st_busy  (ecc_st_busy),
    .ecc_st_done  (ecc_st_done),
    .ecc_st_pass  (ecc_st_pass),
    .ecc_st_fails (ecc_st_fails),
    .ecc_ce_cnt   (ecc_ce_cnt),
    .ecc_ue_cnt   (ecc_ue_cnt),
    .ecc_log_v    (ecc_log_v),
    .ecc_log_ue   (ecc_log_ue),
    .ecc_log_syn  (ecc_log_syn),
    .ecc_log_addr (ecc_log_addr)
  );
endmodule

`default_nettype wire
