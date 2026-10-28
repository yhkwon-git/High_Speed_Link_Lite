`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_training_fsm
// Digital sequence for link bring-up.
//
//   RESET -> CKE -> MRS -> ZQCAL -> WRLVL -> RDLVL -> DESKEW -> WRTRAIN -> MISSION
//
// CKE, MRS, and WRTRAIN advance after one controller clock.
// ZQCAL, WRLVL, RDLVL, and DESKEW wait until the matching done pulse.
// train_wait is retained at the port so the CSR field still has a home;
// the dwell counter it used to feed is gone.
//
// train_bypass forces MISSION. Deasserting bypass does not leave MISSION.
// soft reset (rst_n) wins over bypass.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_training_fsm (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       train_bypass,
  input  logic       train_start,
  input  logic [7:0] train_wait,
  input  logic       zq_done,
  input  logic       wrlvl_done,
  input  logic       rdlvl_done,
  input  logic       deskew_done,
  output logic [3:0] train_state,
  output logic       train_done,
  output logic       mission_mode,
  output logic       cke
);
  import hsl_pkg::*;

  logic [3:0] state;

  assign train_state  = state;
  assign train_done   = (state == TR_MISSION);
  assign mission_mode = train_done;
  assign cke          = (state != TR_RESET);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= TR_RESET;
    end else if (train_bypass) begin
      state <= TR_MISSION;
    end else begin
      case (state)
        TR_RESET:   if (train_start) state <= TR_CKE;
        TR_CKE:     state <= TR_MRS;
        TR_MRS:     state <= TR_ZQCAL;
        TR_ZQCAL:   if (zq_done) state <= TR_WRLVL;
        TR_WRLVL:   if (wrlvl_done) state <= TR_RDLVL;
        TR_RDLVL:   if (rdlvl_done) state <= TR_DESKEW;
        TR_DESKEW:  if (deskew_done) state <= TR_WRTRAIN;
        TR_WRTRAIN: state <= TR_MISSION;
        TR_MISSION: state <= TR_MISSION;
        default:    state <= TR_RESET;
      endcase
    end
  end

  wire unused_wait = |train_wait;
endmodule

`default_nettype wire
