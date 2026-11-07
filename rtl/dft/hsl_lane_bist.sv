`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_lane_bist
// Lane test through the memory controller's request port:
//   write LB_BURSTS PRBS7 words to columns 0..15 of one DRAM bank and row,
//   wait until the controller's queues are empty (every write has gone to the
//   DRAM, so no read is answered from the write queue), read them back and
//   compare. A DQ lane is flagged when any of its BL beats differs, and the
//   flags are sticky for the run. err_bursts counts reads with any mismatch.
// The controller answers writes at once (posted); those answers come first
// and are only counted. Bank timing, refresh and the bus turnaround stay with
// the controller.
// Start with the host quiet, loopback off and the PHY on; the top holds the
// host port while busy. DBI lane faults do not show with DBI off: the two
// inversions cancel. This engine diagnoses the 8 DQ lanes.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_lane_bist (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        start,
  input  wire  [hsl_pkg::BANK_W-1:0] bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  row,
  input  wire                        q_empty,

  output logic                       busy,
  output logic                       req_valid,
  input  wire                        req_ready,
  output logic                       req_write,
  output logic [hsl_pkg::ADDR_W-1:0] req_addr,
  output logic [hsl_pkg::DATA_W-1:0] req_wdata,
  input  wire                        rsp_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] rsp_rdata,

  output logic                       done,
  output logic [hsl_pkg::DQ_W-1:0]   lane_err,
  output logic [4:0]                 err_bursts
);
  import hsl_pkg::*;

  localparam logic [1:0] P_WR    = 2'd0;
  localparam logic [1:0] P_DRAIN = 2'd1;
  localparam logic [1:0] P_RD    = 2'd2;
  localparam logic [1:0] P_WAIT  = 2'd3;
  localparam logic [6:0] SEED    = 7'h2D;
  localparam logic [5:0] N_RSP   = 6'(2 * LB_BURSTS);

  logic [1:0]        phase;
  logic [4:0]        idx;
  logic [5:0]        nrsp;
  logic [BANK_W-1:0] bank_r;
  logic [ROW_W-1:0]  row_r;
  logic [DATA_W-1:0] wr_word;
  logic [DATA_W-1:0] exp_word;
  logic              unused_bit_wr;
  logic              unused_bit_exp;

  wire fire     = req_valid && req_ready;
  wire take_rsp = busy && rsp_valid;
  wire rd_rsp   = take_rsp && (nrsp >= 6'(LB_BURSTS)); // past the write answers

  assign req_valid = busy && ((phase == P_WR) || (phase == P_RD));
  assign req_write = (phase == P_WR);
  assign req_addr  = host_addr(bank_r, row_r, idx[COL_W-1:0]);
  assign req_wdata = wr_word;

  // One PRBS7 word per write, and the same sequence again for the reads.
  hsl_prbs u_wr_prbs (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (fire && req_write),
    .load       (start && !busy),
    .seed       (SEED),
    .bit_o      (unused_bit_wr),
    .parallel_o (wr_word)
  );

  hsl_prbs u_exp_prbs (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (rd_rsp),
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
      phase      <= P_WR;
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
        phase      <= P_WR;
        idx        <= '0;
        nrsp       <= '0;
        bank_r     <= bank;
        row_r      <= row;
        lane_err   <= '0;
        err_bursts <= '0;
      end
    end else begin
      if (fire) begin
        if (idx == 5'(LB_BURSTS - 1)) begin
          idx   <= '0;
          phase <= req_write ? P_DRAIN : P_WAIT;
        end else begin
          idx <= idx + 5'd1;
        end
      end
      if ((phase == P_DRAIN) && q_empty) begin
        phase <= P_RD;
      end
      if (take_rsp) begin
        nrsp <= nrsp + 6'd1;
      end
      if (rd_rsp) begin
        lane_err <= lane_err | fold(rsp_rdata ^ exp_word);
        if (rsp_rdata != exp_word) begin
          err_bursts <= err_bursts + 5'd1;
        end
      end
      // Every request sent and answered.
      if ((phase == P_WAIT) && (nrsp == N_RSP)) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

  wire unused_bits = unused_bit_wr ^ unused_bit_exp;
endmodule

`default_nettype wire
