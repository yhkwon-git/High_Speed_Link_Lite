`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_lane_bist
// Lane test through the memory controller's host port:
//   ACT, then LB_BURSTS times (WR col 0, RD col 0) with PRBS7 words, then PRE.
// Each read is compared with the word written just before it. A DQ lane is
// flagged when any of its BL beats differs, and the flags are sticky for the
// run. err_bursts counts reads with any mismatch.
//
// One column for every pair: in this framer the column (and the ACT row)
// travel on DQ, so a broken DQ lane also changes the address. Every command
// then sees the same wrong address, and the mismatch stays on the broken lane
// instead of spreading through aliased columns.
//
// Commands go through hsl_mc_top, so bank timing stays with the scheduler.
// Start with the host queue empty and loopback off. The top holds the host
// port while busy. DBI lane faults do not show with DBI off: the two
// inversions cancel. This engine diagnoses the 8 DQ lanes.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_lane_bist (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        start,
  input  wire  [hsl_pkg::BANK_W-1:0] bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  row,

  output logic                       busy,
  output logic                       cmd_valid,
  input  wire                        cmd_ready,
  output logic [3:0]                 cmd_opc,
  output logic [hsl_pkg::BANK_W-1:0] cmd_bank,
  output logic [hsl_pkg::ROW_W-1:0]  cmd_row,
  output logic [hsl_pkg::COL_W-1:0]  cmd_col,
  output logic [hsl_pkg::DATA_W-1:0] cmd_wdata,
  input  wire                        rsp_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] rsp_rdata,

  output logic                       done,
  output logic [hsl_pkg::DQ_W-1:0]   lane_err,
  output logic [4:0]                 err_bursts
);
  import hsl_pkg::*;

  // Command index: 0 ACT, odd WR, even RD, LAST PRE.
  localparam logic [5:0] LAST = 6'(2 * LB_BURSTS + 1);
  localparam logic [6:0] SEED = 7'h2D;

  logic [5:0]        idx;
  logic [4:0]        nrsp;
  logic [BANK_W-1:0] bank_r;
  logic [ROW_W-1:0]  row_r;
  logic [DATA_W-1:0] wr_word;
  logic [DATA_W-1:0] exp_word;
  logic              unused_bit_wr;
  logic              unused_bit_exp;

  wire fire     = cmd_valid && cmd_ready;
  wire is_wr    = (idx != 6'd0) && (idx != LAST) && idx[0];
  wire take_rsp = busy && rsp_valid;

  assign cmd_valid = busy && (idx <= LAST);
  assign cmd_opc   = (idx == 6'd0) ? OPC_ACT :
                     (idx == LAST) ? OPC_PRE :
                     idx[0]        ? OPC_WR  : OPC_RD;
  assign cmd_bank  = bank_r;
  assign cmd_row   = row_r;
  assign cmd_col   = '0;
  assign cmd_wdata = wr_word;

  // One PRBS7 word per WR, and the same sequence again for the reads.
  hsl_prbs u_wr_prbs (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (fire && is_wr),
    .load       (start && !busy),
    .seed       (SEED),
    .bit_o      (unused_bit_wr),
    .parallel_o (wr_word)
  );

  hsl_prbs u_exp_prbs (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (take_rsp),
    .load       (start && !busy),
    .seed       (SEED),
    .bit_o      (unused_bit_exp),
    .parallel_o (exp_word)
  );

  // A lane is bad when any of its beats differs: bit i of every beat.
  function automatic logic [DQ_W-1:0] fold(input logic [DATA_W-1:0] d);
    integer b;
    begin
      fold = '0;
      for (b = 0; b < BL; b = b + 1) begin
        fold = fold | d[b*DQ_W +: DQ_W];
      end
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy       <= 1'b0;
      done       <= 1'b0;
      idx        <= '0;
      nrsp       <= '0;
      bank_r     <= '0;
      row_r      <= '0;
      lane_err   <= '0;
      err_bursts <= '0;
    end else if (!busy) begin
      if (start) begin
        busy       <= 1'b1;
        done       <= 1'b0;
        idx        <= '0;
        nrsp       <= '0;
        bank_r     <= bank;
        row_r      <= row;
        lane_err   <= '0;
        err_bursts <= '0;
      end
    end else begin
      if (fire) begin
        idx <= idx + 6'd1;
      end
      if (take_rsp) begin
        nrsp     <= nrsp + 5'd1;
        lane_err <= lane_err | fold(rsp_rdata ^ exp_word);
        if (rsp_rdata != exp_word) begin
          err_bursts <= err_bursts + 5'd1;
        end
      end
      // Every command sent and every read answered.
      if ((idx > LAST) && (nrsp == 5'(LB_BURSTS))) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

  wire unused_bits = unused_bit_wr ^ unused_bit_exp;
endmodule

`default_nettype wire
