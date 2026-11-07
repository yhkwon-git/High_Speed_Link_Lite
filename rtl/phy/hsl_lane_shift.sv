`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_lane_shift
// Shift-based lane repair. The 9 logical lanes L = {DBI, DQ[7:0]} use the 10
// physical pins P = {RED, DBI, DQ[7:0]}. With a bad pin k (0-7 DQ, 8 DBI),
// lanes below k stay, lanes from k up move one pin toward RED, and pin k
// idles at 0:
//   P[i] = L[i]      i < k
//   P[k] = 0
//   P[i] = L[i-1]    i > k          (RED carries L[8])
// RX undoes it: L[i] = (i < k) ? P[i] : P[i+1].
// Every pin is a 2:1 mux between its own lane and the one below, so a lane
// never travels further than the next pin, and the spare sits at the end of
// the byte instead of being routed from every lane.
// en == 0 or lane >= 9: P = {0, L}.
// NSYM symbols (UIs) side by side share the setting: BL for a whole burst
// in the PHY, 1 in the block test. The far end must use the same setting.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_lane_shift #(
  parameter int NSYM = 1
) (
  input  wire                              en,
  input  wire  [3:0]                       lane,
  input  wire  [NSYM*hsl_pkg::LANE_N-1:0]  tx_l,
  output logic [NSYM*hsl_pkg::PIN_W-1:0]   tx_p,
  input  wire  [NSYM*hsl_pkg::PIN_W-1:0]   rx_p,
  output logic [NSYM*hsl_pkg::LANE_N-1:0]  rx_l
);
  import hsl_pkg::*;

  logic [3:0] k; // first pin that does not carry its own lane

  assign k = (en && (lane < 4'(LANE_N))) ? lane : 4'(PIN_W);

  genvar gs;
  genvar gi;
  generate
    for (gs = 0; gs < NSYM; gs = gs + 1) begin : g_sym
      for (gi = 0; gi < PIN_W; gi = gi + 1) begin : g_tx
        if (gi == 0) begin : g_first
          assign tx_p[gs*PIN_W + gi] = (k == 4'd0) ? 1'b0 : tx_l[gs*LANE_N + gi];
        end else if (gi == PIN_W - 1) begin : g_spare
          assign tx_p[gs*PIN_W + gi] = (k < 4'(gi)) ? tx_l[gs*LANE_N + gi - 1] : 1'b0;
        end else begin : g_mid
          assign tx_p[gs*PIN_W + gi] = (k > 4'(gi)) ? tx_l[gs*LANE_N + gi] :
                                       (k < 4'(gi)) ? tx_l[gs*LANE_N + gi - 1] : 1'b0;
        end
      end
      for (gi = 0; gi < LANE_N; gi = gi + 1) begin : g_rx
        assign rx_l[gs*LANE_N + gi] = (k > 4'(gi)) ? rx_p[gs*PIN_W + gi] : rx_p[gs*PIN_W + gi + 1];
      end
    end
  endgenerate
endmodule

`default_nettype wire
