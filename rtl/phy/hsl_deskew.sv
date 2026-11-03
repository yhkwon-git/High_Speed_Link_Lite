`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_deskew
// Per-lane shift of 0..DESKEW_TAPS cycles. delay 0 is combinational.
// delay_sel is shared by every lane. Values above DESKEW_TAPS clamp.
// One tap on clk_phy is one PHY beat, which is DDR_BITS UI.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_deskew (
  input  wire                      clk,
  input  wire                      rst_n,
  input  wire  [hsl_pkg::DQ_W-1:0] din,
  input  wire                      din_valid,
  input  wire  [2:0]               delay_sel,
  output logic [hsl_pkg::DQ_W-1:0] dout,
  output logic                     dout_valid
);
  import hsl_pkg::*;

  // Tap 0 is din itself. sh[k] / vh[k] hold the input k cycles late.
  // The flop array starts at 1 so no variable is written by both a
  // continuous assignment and an always_ff (IEEE 1800 6.5).
  logic [DQ_W-1:0] sh [1:DESKEW_TAPS];
  logic            vh [1:DESKEW_TAPS];
  logic [2:0]      sel;
  integer          ti;

  assign sel = (delay_sel > 3'd4) ? 3'd4 : delay_sel;

  always_comb begin
    if (sel == 3'd0) begin
      dout       = din;
      dout_valid = din_valid;
    end else begin
      dout       = sh[sel];
      dout_valid = vh[sel];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (ti = 1; ti <= DESKEW_TAPS; ti = ti + 1) begin
        sh[ti] <= '0;
        vh[ti] <= 1'b0;
      end
    end else begin
      sh[1] <= din;
      vh[1] <= din_valid;
      for (ti = 2; ti <= DESKEW_TAPS; ti = ti + 1) begin
        sh[ti] <= sh[ti-1];
        vh[ti] <= vh[ti-1];
      end
    end
  end
endmodule

`default_nettype wire
