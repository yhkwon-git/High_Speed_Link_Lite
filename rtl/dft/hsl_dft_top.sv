`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_dft_top
// Parallel loopback compare. When prbs_en is set, each write burst the PHY
// sends (tx_valid) is checked against the PRBS word. loopback selects the TX beat; otherwise the
// expected pin return is 0 in this study hook, so a mismatch counts.
// Pin-level loopback is not this block.
// Two test engines share one request port toward the controller (tp_*):
// hsl_lane_bist checks the link per DQ lane, hsl_mbist runs March tests on the
// DRAM array. One runs at a time. A start that comes while the other engine
// runs, or in the same clock as its start, is held and goes when that engine
// is done; the lane BIST goes first. Read leveling waits for a lane BIST run
// it kicked, so its start must not be dropped. tp_busy hands the port to them.
// An engine started while the port is closed (tp_open = 0) refuses the start
// (refused, done) instead of waiting forever for req_ready.
// hsl_bira turns the MBIST fail log into a spare row / column allocation, and
// hsl_repair keeps the repair table (toward the array) and the fuses.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_dft_top (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        loopback,
  input  wire                        prbs_en,
  input  wire                        err_clear,
  input  wire                        tx_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] tx_data,
  output logic [hsl_pkg::DATA_W-1:0] rx_data,
  output logic [hsl_pkg::DATA_W-1:0] prbs_data,
  output logic [15:0]                err_cnt,

  // Test request port toward the controller.
  input  wire                        q_empty,
  input  wire                        tp_open,     // the request port is open (MISSION, phy_en)
  output logic                       tp_busy,
  output logic                       tp_req_valid,
  input  wire                        tp_req_ready,
  output logic                       tp_req_write,
  output logic [hsl_pkg::ADDR_W-1:0] tp_req_addr,
  output logic [hsl_pkg::DATA_W-1:0] tp_req_wdata,
  input  wire                        tp_rsp_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] tp_rsp_rdata,

  input  wire                        lb_start,
  input  wire  [hsl_pkg::BANK_W-1:0] lb_bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  lb_row,
  output logic                       lb_busy,
  output logic                       lb_refused,
  output logic                       lb_done,
  output logic [hsl_pkg::DQ_W-1:0]   lb_lane_err,
  output logic [4:0]                 lb_err_bursts,

  input  wire                        mb_start,
  input  wire  [1:0]                 mb_algo,
  input  wire  [hsl_pkg::BANK_W-1:0] mb_bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  mb_row0,
  input  wire  [3:0]                 mb_nrows_m1,
  input  wire  [2:0]                 mb_ncl,
  input  wire  [3:0]                 mb_log_sel,
  output logic                       mb_busy,
  output logic                       mb_refused,
  output logic                       mb_done,
  output logic [15:0]                mb_fail_cnt,
  output logic [hsl_pkg::ADDR_W-1:0] mb_first_addr,
  output logic [hsl_pkg::DATA_W-1:0] mb_first_bits,
  output logic [4:0]                 mb_log_n,
  output logic                       mb_log_ovf,
  output logic [7:0]                 mb_log_entry,

  // Repair
  input  wire                        br_start,
  input  wire                        br_apply,
  input  wire                        rp_clear,
  input  wire                        fz_program,
  input  wire                        fz_load,
  output logic                       br_busy,
  output logic                       br_done,
  output logic                       br_ok,
  output logic [1:0]                 br_rows,
  output logic [1:0]                 br_cols,
  output logic [hsl_pkg::RT_N*hsl_pkg::RT_W-1:0] rep_tab,
  output logic [1:0]                 fz_addr,
  output logic                       fz_rd,
  input  wire  [hsl_pkg::FZ_W-1:0]   fz_rdata,
  output logic                       fz_pgm,
  output logic [hsl_pkg::FZ_W-1:0]   fz_wdata,
  output logic                       fz_busy,
  output logic                       fz_loaded,
  output logic [3:0]                 fz_ce,
  output logic [3:0]                 fz_ue,
  output logic [hsl_pkg::RT_N-1:0]   fz_drop
);
  import hsl_pkg::*;

  logic prbs_bit;
  logic [DATA_W-1:0] got;
  logic              lb_req_valid, lb_req_write;
  logic [ADDR_W-1:0] lb_req_addr;
  logic [DATA_W-1:0] lb_req_wdata;
  logic              mb_req_valid, mb_req_write;
  logic [ADDR_W-1:0] mb_req_addr;
  logic [DATA_W-1:0] mb_req_wdata;
  logic [MB_LOG_N*8-1:0] mb_log_keys;
  logic [BANK_W-1:0]     mb_rg_bank;
  logic [ROW_W-1:0]      mb_rg_row0;
  logic [SPR_N-1:0]      rr_en;
  logic [SPR_N*4-1:0]    rr_roff;
  logic [SPC_N-1:0]      cr_en;
  logic [SPC_N*4-1:0]    cr_col;
  logic              lb_hold, mb_hold;   // a start waiting for the port
  logic              lb_go, mb_go;

  assign lb_go = (lb_start || lb_hold) && !mb_busy;
  assign mb_go = (mb_start || mb_hold) && !lb_busy && !lb_go;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lb_hold <= 1'b0;
      mb_hold <= 1'b0;
    end else begin
      lb_hold <= (lb_start || lb_hold) && !lb_go;
      mb_hold <= (mb_start || mb_hold) && !mb_go;
    end
  end

  assign tp_busy      = lb_busy || mb_busy;
  assign tp_req_valid = lb_busy ? lb_req_valid : mb_req_valid;
  assign tp_req_write = lb_busy ? lb_req_write : mb_req_write;
  assign tp_req_addr  = lb_busy ? lb_req_addr  : mb_req_addr;
  assign tp_req_wdata = lb_busy ? lb_req_wdata : mb_req_wdata;

  // REG_OUT: the word leaves a register; it feeds the DBI-AC encoder in the
  // PHY, and the unrolled XOR network in front of it missed 800 MHz in STA.
  hsl_prbs #(.REG_OUT(1'b1)) u_prbs (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (prbs_en),
    .load       (1'b0),
    .seed       (7'h5A),
    .bit_o      (prbs_bit),
    .parallel_o (prbs_data)
  );

  hsl_loopback #(.WIDTH(DATA_W)) u_lb (
    .loopback (loopback),
    .from_tx  (tx_data),
    .from_pin ('0),
    .to_rx    (rx_data)
  );

  assign got = rx_data; // hsl_loopback output: tx_data, or 0 from the pin hook

  hsl_err_cnt u_err (
    .clk         (clk),
    .rst_n       (rst_n),
    .clear       (err_clear),
    .event_valid (prbs_en && tx_valid),
    .event_err   (prbs_en && tx_valid && (got != prbs_data)),
    .count       (err_cnt)
  );

  hsl_lane_bist u_lane_bist (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (lb_go),
    .bank       (lb_bank),
    .row        (lb_row),
    .q_empty    (q_empty),
    .open       (tp_open),
    .busy       (lb_busy),
    .refused    (lb_refused),
    .req_valid  (lb_req_valid),
    .req_ready  (tp_req_ready),
    .req_write  (lb_req_write),
    .req_addr   (lb_req_addr),
    .req_wdata  (lb_req_wdata),
    .rsp_valid  (tp_rsp_valid && lb_busy),
    .rsp_rdata  (tp_rsp_rdata),
    .done       (lb_done),
    .lane_err   (lb_lane_err),
    .err_bursts (lb_err_bursts)
  );

  hsl_mbist #(.LOG_N(MB_LOG_N)) u_mbist (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (mb_go),
    .algo       (mb_algo),
    .bank       (mb_bank),
    .row0       (mb_row0),
    .nrows_m1   (mb_nrows_m1),
    .ncols_log2 (mb_ncl),
    .q_empty    (q_empty),
    .open       (tp_open),
    .busy       (mb_busy),
    .refused    (mb_refused),
    .req_valid  (mb_req_valid),
    .req_ready  (tp_req_ready),
    .req_write  (mb_req_write),
    .req_addr   (mb_req_addr),
    .req_wdata  (mb_req_wdata),
    .rsp_valid  (tp_rsp_valid && mb_busy),
    .rsp_rdata  (tp_rsp_rdata),
    .done       (mb_done),
    .fail_cnt   (mb_fail_cnt),
    .first_addr (mb_first_addr),
    .first_bits (mb_first_bits),
    .log_n      (mb_log_n),
    .log_ovf    (mb_log_ovf),
    .log_sel    (mb_log_sel),
    .log_entry  (mb_log_entry),
    .log_keys   (mb_log_keys),
    .rg_bank    (mb_rg_bank),
    .rg_row0    (mb_rg_row0)
  );

  // Analysis of the last MBIST run; not while it runs. A refused MBIST start
  // left no log to analyze: BIRA reports it as not repairable, like an
  // overflowed log.
  hsl_bira #(.LOG_N(MB_LOG_N), .SPR(SPR_N), .SPC(SPC_N)) u_bira (
    .clk      (clk),
    .rst_n    (rst_n),
    .start    (br_start && !mb_busy),
    .log_n    (mb_log_n),
    .log_ovf  (mb_log_ovf || mb_refused),
    .log_keys (mb_log_keys),
    .col_ok   (mb_rg_row0[3:0] == 4'h0),
    .busy     (br_busy),
    .done     (br_done),
    .ok       (br_ok),
    .rr_en    (rr_en),
    .rr_roff  (rr_roff),
    .cr_en    (cr_en),
    .cr_col   (cr_col)
  );

  always_comb begin
    br_rows = '0;
    br_cols = '0;
    for (int s = 0; s < SPR_N; s++) br_rows = br_rows + {1'b0, rr_en[s]};
    for (int s = 0; s < SPC_N; s++) br_cols = br_cols + {1'b0, cr_en[s]};
  end

  hsl_repair #(.SPR(SPR_N), .SPC(SPC_N)) u_repair (
    .clk        (clk),
    .rst_n      (rst_n),
    .apply      (br_apply),
    .clear      (rp_clear),
    .fz_program (fz_program),
    .fz_load    (fz_load),
    .bira_done  (br_done),
    .bira_ok    (br_ok),
    .rr_en      (rr_en),
    .rr_roff    (rr_roff),
    .cr_en      (cr_en),
    .cr_col     (cr_col),
    .rg_bank    (mb_rg_bank),
    .rg_row0    (mb_rg_row0),
    .rep_tab    (rep_tab),
    .fz_addr    (fz_addr),
    .fz_rd      (fz_rd),
    .fz_rdata   (fz_rdata),
    .fz_pgm     (fz_pgm),
    .fz_wdata   (fz_wdata),
    .fz_busy    (fz_busy),
    .fz_loaded  (fz_loaded),
    .fz_ce      (fz_ce),
    .fz_ue      (fz_ue),
    .fz_drop    (fz_drop)
  );

  wire unused_bit = prbs_bit;
endmodule

`default_nettype wire
