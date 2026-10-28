`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_phy_clk
// Behavioral 2x clock. PHY period is hsl_pkg::PHY_PERIOD_PS (625 ps).
// Each controller edge produces two PHY periods. The analog PLL that
// replaces this block is outside the repo; the SDC describes that intent.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_clk (
  input  logic clk_ctrl,
  output logic clk_phy
);
  initial clk_phy = 1'b0;

  // PHY_PERIOD_PS/2 = 312.5 ps. Two highs and two lows per controller edge.
  always begin
    @(posedge clk_ctrl);
    clk_phy = 1'b1;
    #312.5ps;
    clk_phy = 1'b0;
    #312.5ps;
    clk_phy = 1'b1;
    #312.5ps;
    clk_phy = 1'b0;
  end
endmodule

`default_nettype wire
