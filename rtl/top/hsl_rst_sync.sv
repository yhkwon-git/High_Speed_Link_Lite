`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_rst_sync
// Async assert, synchronous deassert. Two flops, active-low.
//
// rst_no stays low until two rising edges after rst_ni is high.
// The raw pin is not a synchronous reset for the rest of the chip.
// See docs/05_pd_guide.md.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_rst_sync (
  input  logic clk,
  input  logic rst_ni,
  output logic rst_no
);
  logic [1:0] sync_r;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      sync_r <= 2'b00;
    end else begin
      sync_r <= {sync_r[0], 1'b1};
    end
  end

  assign rst_no = sync_r[1];
endmodule

`default_nettype wire
