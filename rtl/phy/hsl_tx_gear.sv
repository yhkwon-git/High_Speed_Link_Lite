`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_tx_gear
// Synchronous 2:1 gearbox, controller clock to the 2x PHY clock.
// clk_phy is phase-aligned with clk_ctrl (hsl_phy_clk, the PLL in silicon):
// its rising edges are E0, at the controller edge, and E1, half a controller
// period later. A word written on a controller edge is taken at the next E1,
// when it has settled, and leaves as two PHY beats: the low half from E1, the
// high half from the following E0. One word per controller clock, fixed
// latency, no handshake.
// E1 is found from a controller-clock toggle: compared with its value at the
// previous PHY edge, it has changed at E1 and not at E0.
// din/din_valid come from controller-clock flops and stay for the whole
// controller period; din_valid is high for one controller clock per word.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_tx_gear #(
  parameter int W = 40
) (
  input  wire            clk_ctrl,
  input  wire            clk_phy,
  input  wire            rst_n,
  input  wire  [W-1:0]   din,
  input  wire            din_valid,
  output logic [W/2-1:0] dout,
  output logic           dout_valid
);
  logic           ctog;   // clk_ctrl
  logic           ctog_q; // clk_phy
  logic [W/2-1:0] hi;
  logic           hi_v;

  wire mid = (ctog != ctog_q); // this PHY edge is E1

  always_ff @(posedge clk_ctrl or negedge rst_n) begin
    if (!rst_n) begin
      ctog <= 1'b0;
    end else begin
      ctog <= ~ctog;
    end
  end

  always_ff @(posedge clk_phy or negedge rst_n) begin
    if (!rst_n) begin
      ctog_q     <= 1'b0;
      dout       <= '0;
      dout_valid <= 1'b0;
      hi         <= '0;
      hi_v       <= 1'b0;
    end else begin
      ctog_q <= ctog;
      if (mid) begin
        dout       <= din_valid ? din[W/2-1:0] : '0;
        dout_valid <= din_valid;
        hi         <= din[W-1:W/2];
        hi_v       <= din_valid;
      end else begin
        dout       <= hi_v ? hi : '0;
        dout_valid <= hi_v;
        hi_v       <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
