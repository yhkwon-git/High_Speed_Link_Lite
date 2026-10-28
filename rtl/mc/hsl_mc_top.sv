`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_mc_top
// Host command -> queue -> in-order scheduler -> PHY burst.
// mission_mode gates the push. ready==0 never drops a beat.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_mc_top (
  input  logic                           clk,
  input  logic                           rst_n,
  input  logic                           mission_mode,
  input  logic [31:0]                    timing0,
  input  logic [31:0]                    timing1,

  input  logic                           cmd_valid,
  output logic                           cmd_ready,
  input  logic [3:0]                     cmd_opc,
  input  logic [hsl_pkg::BANK_W-1:0]     cmd_bank,
  input  logic [hsl_pkg::ROW_W-1:0]      cmd_row,
  input  logic [hsl_pkg::COL_W-1:0]      cmd_col,
  input  logic [hsl_pkg::DATA_W-1:0]     cmd_wdata,
  output logic                           rsp_valid,
  output logic [hsl_pkg::DATA_W-1:0]     rsp_rdata,
  output logic                           rsp_err,

  output logic                           phy_valid,
  input  logic                           phy_ready,
  output logic [3:0]                     phy_opc,
  output logic [hsl_pkg::BANK_W-1:0]     phy_bank,
  output logic [hsl_pkg::ROW_W-1:0]      phy_row,
  output logic [hsl_pkg::COL_W-1:0]      phy_col,
  output logic [hsl_pkg::DATA_W-1:0]     phy_wdata,
  input  logic                           phy_rsp_valid,
  input  logic [hsl_pkg::DATA_W-1:0]     phy_rsp_rdata
);
  import hsl_pkg::*;

  logic q_push_ready;
  logic q_pop_valid;
  logic [3:0] q_pop_opc;
  logic [BANK_W-1:0] q_pop_bank;
  logic [ROW_W-1:0] q_pop_row;
  logic [COL_W-1:0] q_pop_col;
  logic [DATA_W-1:0] q_pop_wdata;

  logic sched_req_ready;
  logic issue_valid;
  logic [3:0] issue_opc;
  logic [BANK_W-1:0] issue_bank;
  logic [BANK_N-1:0] bank_open;
  logic [BANK_N-1:0] bank_ready;

  assign cmd_ready = mission_mode & q_push_ready;

  hsl_cmd_queue u_queue (
    .clk        (clk),
    .rst_n      (rst_n),
    .push_valid (cmd_valid & mission_mode),
    .push_ready (q_push_ready),
    .push_opc   (cmd_opc),
    .push_bank  (cmd_bank),
    .push_row   (cmd_row),
    .push_col   (cmd_col),
    .push_wdata (cmd_wdata),
    .pop_valid  (q_pop_valid),
    .pop_ready  (sched_req_ready),
    .pop_opc    (q_pop_opc),
    .pop_bank   (q_pop_bank),
    .pop_row    (q_pop_row),
    .pop_col    (q_pop_col),
    .pop_wdata  (q_pop_wdata),
    .empty      (),
    .full       ()
  );

  hsl_scheduler u_sched (
    .clk         (clk),
    .rst_n       (rst_n),
    .bank_open   (bank_open),
    .bank_ready  (bank_ready),
    .timing0     (timing0),
    .timing1     (timing1),
    .req_valid   (q_pop_valid),
    .req_ready   (sched_req_ready),
    .req_opc     (q_pop_opc),
    .req_bank    (q_pop_bank),
    .issue_valid (issue_valid),
    .issue_ready (phy_ready),
    .issue_opc   (issue_opc),
    .issue_bank  (issue_bank)
  );

  generate
    for (genvar gi = 0; gi < BANK_N; gi++) begin : g_bank
      hsl_bank_fsm u_bank (
        .clk       (clk),
        .rst_n     (rst_n),
        .bank_id   (BANK_W'(gi)),
        .act_req   (issue_valid && (q_pop_opc == OPC_ACT) && (q_pop_bank == BANK_W'(gi))),
        .pre_req   (issue_valid && (q_pop_opc == OPC_PRE) && (q_pop_bank == BANK_W'(gi))),
        .rd_req    (issue_valid && (q_pop_opc == OPC_RD)  && (q_pop_bank == BANK_W'(gi))),
        .wr_req    (issue_valid && (q_pop_opc == OPC_WR)  && (q_pop_bank == BANK_W'(gi))),
        .timing0   (timing0),
        .timing1   (timing1),
        .is_open   (bank_open[gi]),
        .timing_ok (bank_ready[gi])
      );
    end
  endgenerate

  // In-order: the PHY flit is the queue head.
  assign phy_valid = issue_valid;
  assign phy_opc   = q_pop_opc;
  assign phy_bank  = q_pop_bank;
  assign phy_row   = q_pop_row;
  assign phy_col   = q_pop_col;
  assign phy_wdata = q_pop_wdata;

  assign rsp_valid = phy_rsp_valid;
  assign rsp_rdata = phy_rsp_rdata;
  assign rsp_err   = 1'b0;

  wire unused_issue = ^{issue_opc, issue_bank};
endmodule

`default_nettype wire
