`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_lane_repair
// repair_en and repair_lane < DQ_W: DQ[repair_lane] is replaced by red_in.
// Lane numbers 8 and above leave the byte unchanged.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_lane_repair (
  input  logic [hsl_pkg::DQ_W-1:0] dq_in,
  input  logic                     dbi_in,
  input  logic                     red_in,
  input  logic                     repair_en,
  input  logic [3:0]               repair_lane,
  output logic [hsl_pkg::DQ_W-1:0] dq_out,
  output logic                     dbi_out
);
  import hsl_pkg::*;

  always_comb begin
    dq_out  = dq_in;
    dbi_out = dbi_in;
    if (repair_en && (repair_lane < 4'd8)) begin
      dq_out[repair_lane[2:0]] = red_in;
    end
  end
endmodule

`default_nettype wire
