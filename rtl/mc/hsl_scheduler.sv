`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_scheduler
// In-order issue of the queue head.
//
// The head is popped only when it is legal and the PHY takes it.
// tCCD spaces column commands. tWTR spaces a read after a write.
// Per-bank legality comes from bank_open / bank_ready and is not re-timed here.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_scheduler (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic [hsl_pkg::BANK_N-1:0] bank_open,
  input  logic [hsl_pkg::BANK_N-1:0] bank_ready,
  input  logic [31:0]                timing0,
  input  logic [31:0]                timing1,
  input  logic                       req_valid,
  output logic                       req_ready,
  input  logic [3:0]                 req_opc,
  input  logic [hsl_pkg::BANK_W-1:0] req_bank,
  output logic                       issue_valid,
  input  logic                       issue_ready,
  output logic [3:0]                 issue_opc,
  output logic [hsl_pkg::BANK_W-1:0] issue_bank
);
  import hsl_pkg::*;

  logic [7:0] ccd_cnt;
  logic [7:0] wtr_cnt;

  wire [7:0] t_ccd = timing0[31:24];
  wire [7:0] t_wtr = timing1[7:0];
  wire ccd_ok = (ccd_cnt == 8'd0);
  wire wtr_ok = (wtr_cnt == 8'd0);

  wire act_ok = !bank_open[req_bank] && bank_ready[req_bank];
  wire col_ok = bank_open[req_bank] && bank_ready[req_bank];

  logic head_ok;
  always_comb begin
    head_ok = 1'b0;
    if (req_valid) begin
      case (req_opc)
        OPC_NOP: head_ok = 1'b1;
        OPC_ACT: head_ok = act_ok;
        OPC_PRE: head_ok = col_ok;
        OPC_RD:  head_ok = col_ok && ccd_ok && wtr_ok;
        OPC_WR:  head_ok = col_ok && ccd_ok;
        default: head_ok = 1'b0;
      endcase
    end
  end

  assign req_ready   = head_ok && issue_ready;
  assign issue_valid = req_valid && req_ready;
  assign issue_opc   = req_opc;
  assign issue_bank  = req_bank;

  wire col_fire = issue_valid && ((issue_opc == OPC_RD) || (issue_opc == OPC_WR));
  wire wr_fire  = issue_valid && (issue_opc == OPC_WR);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ccd_cnt <= 8'd0;
      wtr_cnt <= 8'd0;
    end else begin
      if (col_fire) begin
        ccd_cnt <= (t_ccd <= 8'd1) ? 8'd0 : (t_ccd - 8'd1);
      end else if (ccd_cnt != 8'd0) begin
        ccd_cnt <= ccd_cnt - 8'd1;
      end
      if (wr_fire) begin
        wtr_cnt <= (t_wtr <= 8'd1) ? 8'd0 : (t_wtr - 8'd1);
      end else if (wtr_cnt != 8'd0) begin
        wtr_cnt <= wtr_cnt - 8'd1;
      end
    end
  end
endmodule

`default_nettype wire
