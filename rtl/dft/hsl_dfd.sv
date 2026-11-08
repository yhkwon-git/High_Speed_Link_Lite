`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_dfd
// Debug-for-design observation at the chip top.
//
// Trace buffer: DEPTH entries of 32 bits, written each controller clock that
// has a command on either CA bus or an event (ECC, PRBS, MBIST; read data is
// a flag, not a reason to write). With the bank filter on, only commands to
// that bank count, and the CA fields of other banks read as NOP:
//   [31:24] timestamp (controller clocks, low 8 bits)
//   [23:11] row CA {cmd, bank, row}
//   [10:6]  column CA {cmd, bank}
//   [5]     read data to the controller   [4] ECC corrected
//   [3]     ECC uncorrectable             [2] PRBS compare error
//   [1]     MBIST failing read            [0] this entry is the trigger
// arm clears it and starts recording into a ring. The first trigger after arm
// marks its entry, then post more entries are written and the buffer freezes.
// A trigger is taken only once DEPTH - 1 - post entries are in, so the part
// before it is always full. Triggers: 0 ECC
// uncorrectable, 1 ECC corrected, 2 PRBS error, 3 MBIST fail, 4 a command to
// the filter bank, 5 manual (man_trig). Events are seen as their counters
// counting up (the ECC ones a few clocks after the RD on the pins). The
// counters only count up or clear to 0, so a change to a non-zero value is an
// event and a clear (ECC clear, ERRCNT clear, an MBIST start) is not. A
// saturated counter (16'hFFFF) shows no further events.
// Counters: ACT, RD, WR and REFpb on the pins (16 bit, saturating; clear).
// MISR: 32-bit signature of the read data to the controller while misr_en:
// s <= {s[30:0], 1'b0} ^ (s[31] ? 32'h0040_0007 : 0) ^ data, from all ones.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_dfd #(
  parameter int DEPTH = 16
) (
  input  wire                        clk,
  input  wire                        rst_n,

  input  wire  [hsl_pkg::RCA_W-1:0]  rca,
  input  wire  [hsl_pkg::CCA_W-1:0]  cca,
  input  wire                        rd_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] rd_data,
  input  wire  [15:0]                ecc_ce_cnt,
  input  wire  [15:0]                ecc_ue_cnt,
  input  wire  [15:0]                prbs_err_cnt,
  input  wire  [15:0]                mb_fail_cnt,

  input  wire                        arm,
  input  wire  [2:0]                 trig_sel,
  input  wire  [3:0]                 post,
  input  wire  [1:0]                 flt_bank,
  input  wire                        flt_en,
  input  wire                        man_trig,
  input  wire  [3:0]                 rd_sel,
  input  wire                        cnt_clear,
  input  wire                        misr_en,

  output logic                       recording,
  output logic                       triggered,
  output logic                       frozen,
  output logic                       wrapped,
  output logic [3:0]                 wp,
  output logic [3:0]                 trig_pos,
  output logic [31:0]                rd_entry,
  output logic [15:0]                n_act,
  output logic [15:0]                n_rd,
  output logic [15:0]                n_wr,
  output logic [15:0]                n_refpb,
  output logic [31:0]                misr
);
  import hsl_pkg::*;

  localparam logic [2:0] C_ACT   = 3'd1;
  localparam logic [2:0] C_RD    = 3'd2;
  localparam logic [2:0] C_WR    = 3'd3;
  localparam logic [2:0] C_REFPB = 3'd7;

  logic [31:0] buf_q [0:DEPTH-1];
  logic [7:0]  ts;
  logic [15:0] ce_q;
  logic [15:0] ue_q;
  logic [15:0] pe_q;
  logic [15:0] mf_q;
  logic        ev_ce;
  logic        ev_ue;
  logic        ev_pe;
  logic        ev_mf;
  logic [2:0]  rcmd;
  logic [1:0]  rbank;
  logic [2:0]  ccmd;
  logic [1:0]  cbank;
  logic        cmd_in;     // a command that passes the filter
  logic        take;       // write an entry this clock
  logic        trig;
  logic [3:0]  post_left;
  logic [4:0]  filled;     // entries since arm, up to DEPTH
  logic [12:0] rca_f;      // CA fields as recorded (filtered)
  logic [4:0]  cca_f;

  assign rcmd  = rca[RCA_W-1 -: 3];
  assign rbank = rca[ROW_W +: BANK_W];
  assign ccmd  = cca[CCA_W-1 -: 3];
  assign cbank = cca[COL_W+1 +: BANK_W];

  assign ev_ce = (ecc_ce_cnt != ce_q) && (ecc_ce_cnt != '0);
  assign ev_ue = (ecc_ue_cnt != ue_q) && (ecc_ue_cnt != '0);
  assign ev_pe = (prbs_err_cnt != pe_q) && (prbs_err_cnt != '0);
  assign ev_mf = (mb_fail_cnt != mf_q) && (mb_fail_cnt != '0);

  assign cmd_in = ((rcmd != 3'd0) && (!flt_en || (rbank == flt_bank))) ||
                  ((ccmd != 3'd0) && (!flt_en || (cbank == flt_bank)));

  always_comb begin
    case (trig_sel)
      3'd0:    trig = ev_ue;
      3'd1:    trig = ev_ce;
      3'd2:    trig = ev_pe;
      3'd3:    trig = ev_mf;
      3'd4:    trig = ((rcmd != 3'd0) && (rbank == flt_bank)) || ((ccmd != 3'd0) && (cbank == flt_bank));
      default: trig = man_trig;
    endcase
  end

  assign rca_f = (flt_en && (rbank != flt_bank)) ? 13'h0 : rca;
  assign cca_f = (flt_en && (cbank != flt_bank)) ? 5'h0 : {ccmd, cbank};

  wire pre_full = ({1'b0, filled} >= (6'(DEPTH) - 6'd1 - {2'b00, post}));
  wire fire = recording && !triggered && trig && pre_full;
  assign take = recording && (cmd_in || ev_ce || ev_ue || ev_pe || ev_mf || fire);
  assign rd_entry = buf_q[rd_sel];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ts        <= '0;
      ce_q      <= '0;
      ue_q      <= '0;
      pe_q      <= '0;
      mf_q      <= '0;
      recording <= 1'b0;
      triggered <= 1'b0;
      frozen    <= 1'b0;
      wrapped   <= 1'b0;
      wp        <= '0;
      trig_pos  <= '0;
      post_left <= '0;
      filled    <= '0;
      n_act     <= '0;
      n_rd      <= '0;
      n_wr      <= '0;
      n_refpb   <= '0;
      misr      <= '1;
      for (int k = 0; k < DEPTH; k++) buf_q[k] <= '0;
    end else begin
      ts   <= ts + 8'd1;
      ce_q <= ecc_ce_cnt;
      ue_q <= ecc_ue_cnt;
      pe_q <= prbs_err_cnt;
      mf_q <= mb_fail_cnt;

      if (arm) begin
        recording <= 1'b1;
        triggered <= 1'b0;
        frozen    <= 1'b0;
        wrapped   <= 1'b0;
        wp        <= '0;
        trig_pos  <= '0;
        filled    <= '0;
      end else if (take) begin
        buf_q[wp] <= {ts, rca_f, cca_f, rd_valid, ev_ce, ev_ue, ev_pe, ev_mf, fire};
        wp        <= wp + 4'd1;
        if (filled != 5'(DEPTH)) filled <= filled + 5'd1;
        if (wp == 4'(DEPTH - 1)) wrapped <= 1'b1;
        if (fire) begin
          triggered <= 1'b1;
          trig_pos  <= wp;
          post_left <= post;
          if (post == 4'd0) begin
            recording <= 1'b0;
            frozen    <= 1'b1;
          end
        end else if (triggered) begin
          post_left <= post_left - 4'd1;
          if (post_left == 4'd1) begin
            recording <= 1'b0;
            frozen    <= 1'b1;
          end
        end
      end

      if (cnt_clear) begin
        n_act   <= '0;
        n_rd    <= '0;
        n_wr    <= '0;
        n_refpb <= '0;
      end else begin
        if ((rcmd == C_ACT) && (n_act != 16'hFFFF))     n_act   <= n_act + 16'd1;
        if ((rcmd == C_REFPB) && (n_refpb != 16'hFFFF)) n_refpb <= n_refpb + 16'd1;
        if ((ccmd == C_RD) && (n_rd != 16'hFFFF))       n_rd    <= n_rd + 16'd1;
        if ((ccmd == C_WR) && (n_wr != 16'hFFFF))       n_wr    <= n_wr + 16'd1;
      end

      if (!misr_en) begin
        misr <= '1;
      end else if (rd_valid) begin
        misr <= {misr[30:0], 1'b0} ^ (misr[31] ? 32'h0040_0007 : 32'h0) ^ rd_data;
      end
    end
  end
  wire unused_cca = ^cca[COL_W:0];   // column and auto-precharge: not traced
endmodule

`default_nettype wire
