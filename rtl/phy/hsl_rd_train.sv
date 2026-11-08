`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_rd_train
// Read leveling per DQ lane against an analog delay line that stays outside
// the digital: rx_dly carries one code per lane, and the channel model plays
// the delay line and the sampler.
//
// Sweep: every lane gets the same code c = 0 .. RX_DLY_MAX in turn. At each
// code one lane BIST run (16 PRBS7 words written, then read back) says which
// lanes read back clean. Per lane the longest run of clean codes is kept, and the lane is set
// to the middle of it, lo + (len - 1) / 2. ok means every lane found a run of
// at least RX_EYE_MIN codes; a lane without one still gets the middle of the
// best run it saw (or code 0 if it never read clean). Before the first run
// every lane sits at RX_DLY_DEF.
//
// The BIST goes through the controller, so training runs in MISSION with
// the PHY on (CTRL.phy_en) and the host quiet, after any lane repair. A start
// while the request port is closed (open = 0) is refused: done and refused go
// high, ok reads 0, and the codes and the eye readback keep the last run's
// values (it would otherwise wait for a BIST that never runs). Read direction only; write leveling is not
// modeled.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_rd_train (
  input  wire                                        clk,
  input  wire                                        rst_n,
  input  wire                                        start,
  input  wire                                        open,      // the request port is open
  output logic                                       refused,   // the last start found it closed

  output logic                                       bist_start,
  input  wire                                        bist_busy,
  input  wire  [hsl_pkg::DQ_W-1:0]                   bist_lane_err,

  output logic [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rx_dly,
  output logic                                       busy,
  output logic                                       done,
  output logic                                       ok,
  output logic [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] win_lo,
  output logic [hsl_pkg::DQ_W*6-1:0]                 win_len
);
  import hsl_pkg::*;

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_KICK = 3'd1; // BIST start pulse
  localparam logic [2:0] S_WAIT = 3'd2; // BIST running
  localparam logic [2:0] S_STEP = 3'd3; // fold the result, next code
  localparam logic [2:0] S_FIN  = 3'd4; // set every lane to its center

  logic [2:0]          st;
  logic [RX_DLY_W-1:0] code;
  logic                seen_busy;
  logic [RX_DLY_W-1:0] cur_lo   [0:DQ_W-1];
  logic [5:0]          cur_len  [0:DQ_W-1];
  logic [RX_DLY_W-1:0] best_lo  [0:DQ_W-1];
  logic [5:0]          best_len [0:DQ_W-1];
  logic [RX_DLY_W-1:0] trained  [0:DQ_W-1];

  assign bist_start = (st == S_KICK);

  integer oi;
  always_comb begin
    for (oi = 0; oi < DQ_W; oi = oi + 1) begin
      rx_dly[oi*RX_DLY_W +: RX_DLY_W] = busy ? code : trained[oi];
      win_lo[oi*RX_DLY_W +: RX_DLY_W] = best_lo[oi];
      win_len[oi*6 +: 6]              = best_len[oi];
    end
  end

  // Middle of the run, rounding down: lo + (len - 1) / 2.
  function automatic logic [RX_DLY_W-1:0] center(input logic [RX_DLY_W-1:0] lo,
                                                 input logic [5:0]          len);
    logic [5:0] half;
    begin
      half   = (len == 6'd0) ? 6'd0 : ((len - 6'd1) >> 1);
      center = lo + half[RX_DLY_W-1:0];
    end
  endfunction

  integer li;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st        <= S_IDLE;
      code      <= '0;
      seen_busy <= 1'b0;
      busy      <= 1'b0;
      done      <= 1'b0;
      ok        <= 1'b0;
      refused   <= 1'b0;
      for (li = 0; li < DQ_W; li = li + 1) begin
        cur_lo[li]   <= '0;
        cur_len[li]  <= '0;
        best_lo[li]  <= '0;
        best_len[li] <= '0;
        trained[li]  <= RX_DLY_DEF;
      end
    end else begin
      case (st)
        S_IDLE: begin
          if (start) begin
            st      <= open ? S_KICK : S_IDLE;
            code    <= '0;
            busy    <= open;
            done    <= !open;
            ok      <= 1'b0;
            refused <= !open;
            if (open) begin
              for (li = 0; li < DQ_W; li = li + 1) begin
                cur_len[li]  <= '0;
                best_lo[li]  <= '0;
                best_len[li] <= '0;
              end
            end
          end
        end
        S_KICK: begin
          seen_busy <= 1'b0;
          st        <= S_WAIT;
        end
        S_WAIT: begin
          // The BIST's done is sticky from the last run: wait for busy to
          // rise and then fall.
          if (bist_busy) begin
            seen_busy <= 1'b1;
          end else if (seen_busy) begin
            st <= S_STEP;
          end
        end
        S_STEP: begin
          for (li = 0; li < DQ_W; li = li + 1) begin
            if (!bist_lane_err[li]) begin
              if (cur_len[li] == 6'd0) begin
                cur_lo[li] <= code;
              end
              cur_len[li] <= cur_len[li] + 6'd1;
              if ((cur_len[li] + 6'd1) > best_len[li]) begin
                best_lo[li]  <= (cur_len[li] == 6'd0) ? code : cur_lo[li];
                best_len[li] <= cur_len[li] + 6'd1;
              end
            end else begin
              cur_len[li] <= '0;
            end
          end
          if (code == RX_DLY_MAX) begin
            st <= S_FIN;
          end else begin
            code <= code + 1'b1;
            st   <= S_KICK;
          end
        end
        S_FIN: begin
          ok <= 1'b1;
          for (li = 0; li < DQ_W; li = li + 1) begin
            trained[li] <= center(best_lo[li], best_len[li]);
            if (best_len[li] < RX_EYE_MIN) begin
              ok <= 1'b0;
            end
          end
          busy <= 1'b0;
          done <= 1'b1;
          st   <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
