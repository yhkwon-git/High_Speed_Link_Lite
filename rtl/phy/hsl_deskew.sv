`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_deskew
// Per-lane shift of 0..DESKEW_TAPS cycles. delay 0 is combinational.
// delay_sel is shared by every lane. Values above DESKEW_TAPS clamp.
// One tap on clk_phy is one PHY beat, which is DDR_BITS UI.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_deskew (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [hsl_pkg::DQ_W-1:0] din,
  input  logic                     din_valid,
  input  logic [2:0]               delay_sel,
  output logic [hsl_pkg::DQ_W-1:0] dout,
  output logic                     dout_valid
);
  import hsl_pkg::*;

  logic [DQ_W-1:0] sh [0:DESKEW_TAPS];
  logic            vh [0:DESKEW_TAPS];
  logic [2:0]      sel;
  integer          ti;

  assign sh[0] = din;
  assign vh[0] = din_valid;
  assign sel   = (delay_sel > 3'd4) ? 3'd4 : delay_sel;
  assign dout      = sh[sel];
  assign dout_valid = vh[sel];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ti = 1; ti <= DESKEW_TAPS; ti = ti + 1) begin
        sh[ti] <= '0;
        vh[ti] <= 1'b0;
      end
    end else begin
      for (ti = 1; ti <= DESKEW_TAPS; ti = ti + 1) begin
        sh[ti] <= sh[ti-1];
        vh[ti] <= vh[ti-1];
      end
    end
  end
endmodule

`default_nettype wire
