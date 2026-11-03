`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_phy_clk
// Behavioral 2x clock. PHY period is hsl_pkg::PHY_PERIOD_PS (625 ps).
// Each rising controller edge produces two PHY periods. The analog PLL that
// replaces this block is outside the repo; the SDC describes that intent.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_clk (
  input  wire  clk_ctrl,
  output logic clk_phy
);
`ifdef SYNTHESIS
  // Empty shell for synthesis. The PLL macro that drives clk_phy is outside
  // this repo; syn/constraints declares the generated clock on this pin.
`else
  initial clk_phy = 1'b0;

  // PHY_PERIOD_PS/2 = 312.5 ps, exact with the 100 fs time precision.
  // Three timed phases, then the fourth low phase lasts until the next
  // rising controller edge, so clk_phy re-aligns every controller period.
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
`endif
endmodule

`default_nettype wire
