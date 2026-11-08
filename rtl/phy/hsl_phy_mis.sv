`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_phy_mis
// PHY datapath behind the controller's DFI-style interface (on = CTRL.phy_en).
//
// Command: each controller clock the row command (ACT, PRE, PREA, REF, REFPB)
//          and the column command (RD, WR, with auto-precharge) leave on their
//          own CA pins, one clock later, with the controller's dram_cmd_e
//          codes. DQ carries data only.
// Write:   the burst comes with wrdata_en, WL clocks after its WR. After DBI it
//          goes through the lane shift (all BL symbols) into the TX gear and
//          leaves as two PHY beats of DDR_BITS UI with a WDQS pattern, so the
//          data keeps its WL distance from the WR on the pins (plus half a
//          clock in the gear).
// Read:    the DRAM side sends two beats with RDQS (CK delayed by tDQSCK).
//          They are captured on RDQS, cross to the controller clock through the
//          Gray FIFO, and are unshifted and DBI-decoded into rddata_valid /
//          rddata. The latency is not fixed; the controller counts reads in
//          flight on rddata_valid and only needs the order kept.
// Loopback answers a RD with lb_data and sends no CA for it.
// ECC (hsl_ecc): the check bits of each burst go out on the two ECC pins
// (tx_ecc, beside the data beats, through the same gear) and come back with
// the read beats (rx_ecc, through the same FIFO). They are not under DBI or
// lane repair. The check bits come from the raw word registered with the TX
// word, in the half clock before the gear takes it (E1), so the encoder is not
// on the controller's write data path. Read returns pass a register stage
// before the decoder (one clock of read latency). A RD tracking FIFO pairs
// each read return with the host
// address of its RD (bank, the bank's open row, column) for the error log.
// Loopback reads bypass ECC.
//
// ac_prev is the DBI-AC reference for write data in this clock: the last byte
// of the write data of the clock before (its beats follow directly), or 0,
// the idle bus.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_mis (
  input  wire                          clk,
  input  wire                          clk_phy,
  input  wire                          rst_n,
  input  wire                          on,

  input  dram_pkg::dram_cmd_e          rcmd,
  input  wire  [hsl_pkg::BANK_W-1:0]   rbank,
  input  wire  [hsl_pkg::ROW_W-1:0]    row,
  input  dram_pkg::dram_cmd_e          ccmd,
  input  wire  [hsl_pkg::BANK_W-1:0]   cbank,
  input  wire  [hsl_pkg::COL_W-1:0]    col,
  input  wire                          ap,
  input  wire                          wrdata_en,
  input  wire  [hsl_pkg::DATA_W-1:0]   wdata,
  input  wire  [hsl_pkg::DATA_W-1:0]   wraw,       // the same word before DBI
  input  wire  [hsl_pkg::BL-1:0]       dbi_flags,
  input  wire                          loopback,
  input  wire  [hsl_pkg::DATA_W-1:0]   lb_data,
  input  wire                          repair_en,
  input  wire  [3:0]                   repair_lane,
  output logic [hsl_pkg::DQ_W-1:0]     ac_prev,

  output logic [hsl_pkg::RCA_W-1:0]    rca,
  output logic [hsl_pkg::CCA_W-1:0]    cca,
  output logic [hsl_pkg::BEAT_W-1:0]   tx_beat,
  output logic [hsl_pkg::DDR_BITS-1:0] tx_dqs,
  output logic [2*hsl_pkg::DDR_BITS-1:0] tx_ecc,   // 2 ECC pins x DDR_BITS UI
  output logic                         tx_dv,
  input  wire                          rdqs,
  input  wire  [hsl_pkg::BEAT_W-1:0]   rx_beat,
  input  wire  [2*hsl_pkg::DDR_BITS-1:0] rx_ecc,
  input  wire                          rx_dv,

  output logic                         rddata_valid,
  output logic [hsl_pkg::DATA_W-1:0]   rddata,

  input  wire                          ecc_en,
  input  wire                          ecc_inj_arm,
  input  wire  [31:0]                  ecc_inj_dmask,
  input  wire  [6:0]                   ecc_inj_cmask,
  input  wire                          ecc_st_start,
  input  wire                          ecc_clear,
  output logic                         ecc_inj_pend,
  output logic                         ecc_st_busy,
  output logic                         ecc_st_done,
  output logic                         ecc_st_pass,
  output logic [6:0]                   ecc_st_fails,
  output logic [15:0]                  ecc_ce_cnt,
  output logic [15:0]                  ecc_ue_cnt,
  output logic                         ecc_log_v,
  output logic                         ecc_log_ue,
  output logic [6:0]                   ecc_log_syn,
  output logic [hsl_pkg::ADDR_W-1:0]   ecc_log_addr
);
  import hsl_pkg::*;
  import dram_pkg::*;

  logic [BL*LANE_N-1:0]  tx_sym;   // {DBI, DQ} per beat, beat 0 low
  logic [WORD_PW-1:0]    tx_pins;
  logic [WORD_PW-1:0]    tx_word;
  logic                  tx_wv;
  logic                  last_wr;
  logic [DQ_W-1:0]       last_byte;
  logic                  half;
  logic [BEAT_W-1:0]     rx_lo;
  logic [WORD_PW+7:0]    fifo_rdata;   // {ECC 8, data pins 40}
  logic                  fifo_empty;
  logic                  fifo_full;
  logic [BL*LANE_N-1:0]  rx_sym;
  logic [DATA_W-1:0]     rx_word;
  logic [DATA_W-1:0]     tx_dflip;   // ECC error injection
  logic [7:0]            tx_chk;     // from tx_raw, in the half clock before E1
  logic [DATA_W-1:0]     tx_raw;     // the raw word, registered with tx_word
  logic [BL*LANE_N-1:0]  fl_sym;     // injected data flips, as lanes
  logic [WORD_PW-1:0]    fl_pins;    // ... and as pins (same lane shift)
  logic [WORD_PW-1:0]    tx_flip;    // registered with tx_word
  logic [BL*LANE_N-1:0]  fl_unused;
  logic                  s1_v;       // read return stage before the decoder
  logic                  s1_lb;
  logic [DATA_W-1:0]     s1_word;
  logic [7:0]            s1_chk;
  logic [ADDR_W-1:0]     s1_addr;
  logic [2*DDR_BITS-1:0] rx_lo_e;
  logic [WORD_PW+7:0]    rx_burst;   // {ECC 8, data pins 40}, written next RDQS edge
  logic                  rx_wr;
  logic                  lb_rd_q;    // a loopback RD, answered from here
  logic                  st_load;
  logic [DATA_W-1:0]     st_word;
  logic [7:0]            st_chk;
  logic [DATA_W-1:0]     rx_fix;
  logic                  rx_pop;
  logic [ROW_W-1:0]      open_row [0:BANK_N-1];
  logic [ADDR_W-1:0]     rdq [0:7];  // RD tracking: host address per RD in flight
  logic [2:0]            rdq_w;
  logic [2:0]            rdq_r;

  wire lb_rd = on && loopback && (ccmd == CMD_RD);

  integer bi;
  always_comb begin
    for (bi = 0; bi < BL; bi = bi + 1) begin
      tx_sym[bi*LANE_N +: LANE_N] = {dbi_flags[bi], wdata[bi*DQ_W +: DQ_W]};
      fl_sym[bi*LANE_N +: LANE_N] = {1'b0, tx_dflip[bi*DQ_W +: DQ_W]};
      rx_word[bi*DQ_W +: DQ_W]    = rx_sym[bi*LANE_N + DQ_W] ? ~rx_sym[bi*LANE_N +: DQ_W]
                                                             : rx_sym[bi*LANE_N +: DQ_W];
    end
  end

  assign ac_prev = last_wr ? last_byte : '0;

  hsl_lane_shift #(.NSYM(BL)) u_shift (
    .en   (repair_en),
    .lane (repair_lane),
    .tx_l (tx_sym),
    .tx_p (tx_pins),
    .rx_p (fifo_rdata[WORD_PW-1:0]),
    .rx_l (rx_sym)
  );

  // Injected data flips take the same lane shift as the data; a flipped data
  // bit is a flipped pin bit whether or not DBI inverted its byte. They are
  // applied after the TX word register, off the controller's write data path.
  hsl_lane_shift #(.NSYM(BL)) u_shift_fl (
    .en   (repair_en),
    .lane (repair_lane),
    .tx_l (fl_sym),
    .tx_p (fl_pins),
    .rx_p ('0),
    .rx_l (fl_unused)
  );

  // Commands and write data, one controller clock each.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rca       <= {CMD_NOP, {(RCA_W-3){1'b0}}};
      cca       <= {CMD_NOP, {(CCA_W-3){1'b0}}};
      tx_word   <= '0;
      tx_raw    <= '0;
      tx_flip   <= '0;
      tx_wv     <= 1'b0;
      last_wr   <= 1'b0;
      last_byte <= '0;
    end else begin
      rca     <= {CMD_NOP, {(RCA_W-3){1'b0}}};
      cca     <= {CMD_NOP, {(CCA_W-3){1'b0}}};
      tx_wv   <= 1'b0;
      last_wr <= 1'b0;
      if (on) begin
        if (rcmd != CMD_NOP) begin
          rca <= {rcmd, rbank, row};
        end
        if ((ccmd != CMD_NOP) && !lb_rd) begin
          cca <= {ccmd, cbank, col, ap};
        end
        if (wrdata_en) begin
          tx_word   <= tx_pins;
          tx_raw    <= wraw;
          tx_flip   <= fl_pins;
          tx_wv     <= 1'b1;
          last_wr   <= 1'b1;
          last_byte <= wdata[DATA_W-1 -: DQ_W];
        end
      end
    end
  end

  // Data and ECC beats share the gear: beat 0 = {ECC UI 0-1, data UI 0-1}.
  hsl_tx_gear #(.W(WORD_PW + 8)) u_gear (
    .clk_ctrl   (clk),
    .clk_phy    (clk_phy),
    .rst_n      (rst_n),
    .din        ({tx_chk[7:4], tx_word[WORD_PW-1:BEAT_W] ^ tx_flip[WORD_PW-1:BEAT_W],
                  tx_chk[3:0], tx_word[BEAT_W-1:0] ^ tx_flip[BEAT_W-1:0]}),
    .din_valid  (tx_wv),
    .dout       ({tx_ecc, tx_beat}),
    .dout_valid (tx_dv)
  );

  // WDQS toggles once per UI while data is out: high in UI 0, low in UI 1.
  assign tx_dqs = tx_dv ? {{(DDR_BITS-1){1'b0}}, 1'b1} : '0;

  // RDQS-domain reset: asserted with rst_n, released by two RDQS flops, so the
  // capture flops and the FIFO's write side leave reset on their own clock.
  // RDQS follows CK, which is gated by phy_en: while the PHY is off the RDQS
  // domain stays in reset, and it is released two RDQS edges after CK starts.
  logic rst_rdqs_n;
  hsl_rst_sync u_rst_rdqs (
    .clk    (rdqs),
    .rst_ni (rst_n),
    .rst_no (rst_rdqs_n)
  );

  // RDQS domain: two beats make a burst.
  // The burst is written into the FIFO one RDQS edge after its second beat,
  // from registers (the write enable straight from pin_rx_dv, after its input
  // delay, did not reach all 48 bits of every entry in time).
  always_ff @(posedge rdqs or negedge rst_rdqs_n) begin
    if (!rst_rdqs_n) begin
      half    <= 1'b0;
      rx_lo   <= '0;
      rx_lo_e <= '0;
      rx_burst <= '0;
      rx_wr    <= 1'b0;
    end else begin
      rx_wr <= rx_dv && half;
      if (rx_dv) begin
        half <= ~half;
        if (!half) begin
          rx_lo   <= rx_beat;
          rx_lo_e <= rx_ecc;
        end else begin
          rx_burst <= {rx_ecc, rx_lo_e, rx_beat, rx_lo};
        end
      end
    end
  end

  hsl_cdc_fifo #(
    .WIDTH      (WORD_PW + 8),
    .SAME_CLOCK (0)
  ) u_rx_fifo (
    .clk_w    (rdqs),
    .clk_r    (clk),
    .rst_w_n  (rst_rdqs_n),
    .rst_r_n  (rst_n),
    .wr_en    (rx_wr),
    .wr_data  (rx_burst),
    .wr_full  (fifo_full),
    .rd_en    (rx_pop),
    .rd_data  (fifo_rdata),
    .rd_empty (fifo_empty)
  );

  // Read returns: stage 1 registers the word, its check bits and its RD
  // address (a loopback answer too); stage 2 decodes. The decoder right after
  // the FIFO, unshift and DBI missed the controller clock.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lb_rd_q      <= 1'b0;
      s1_v         <= 1'b0;
      s1_lb        <= 1'b0;
      s1_word      <= '0;
      s1_chk       <= '0;
      s1_addr      <= '0;
      rddata_valid <= 1'b0;
      rddata       <= '0;
    end else begin
      lb_rd_q <= lb_rd;
      s1_v    <= lb_rd_q || rx_pop;
      s1_lb   <= lb_rd_q;
      if (st_load) begin
        s1_word <= st_word;
        s1_chk  <= st_chk;
      end else if (lb_rd_q) begin
        s1_word <= lb_data;
      end else if (rx_pop) begin
        s1_word <= rx_word;
        s1_chk  <= fifo_rdata[WORD_PW +: 8];
        s1_addr <= rdq[rdq_r];
      end
      rddata_valid <= s1_v;
      if (s1_v) begin
        rddata <= s1_lb ? s1_word : rx_fix;
      end
    end
  end

  // A loopback answer and a FIFO return never meet: loopback runs with no RD
  // to the pins in flight (docs/03). The FIFO is held while one is answered.
  assign rx_pop = !fifo_empty && !lb_rd_q;

  // RD tracking, from the CA registers (not the controller's command outputs,
  // which sit at the end of its scheduler path): a RD on the pins pushes its
  // host address; each read return pops one (returns come in RD order).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rdq_w <= '0;
      rdq_r <= '0;
      for (int b = 0; b < BANK_N; b++) open_row[b] <= '0;
      for (int k = 0; k < 8; k++) rdq[k] <= '0;
    end else begin
      if (rca[RCA_W-1 -: 3] == 3'(CMD_ACT)) begin
        open_row[rca[ROW_W +: BANK_W]] <= rca[ROW_W-1:0];
      end
      if (cca[CCA_W-1 -: 3] == 3'(CMD_RD)) begin
        rdq[rdq_w] <= host_addr(cca[COL_W+1 +: BANK_W], open_row[cca[COL_W+1 +: BANK_W]],
                                cca[1 +: COL_W]);
        rdq_w      <= rdq_w + 3'd1;
      end
      if (rx_pop) rdq_r <= rdq_r + 3'd1;
    end
  end

  hsl_ecc u_ecc (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (ecc_en),
    .inj_arm   (ecc_inj_arm),
    .inj_dmask (ecc_inj_dmask),
    .inj_cmask (ecc_inj_cmask),
    .st_start  (ecc_st_start),
    .clear     (ecc_clear),
    .wr_go     (on && wrdata_en),
    .wraw      (tx_raw),
    .tx_dflip  (tx_dflip),
    .tx_chk    (tx_chk),
    .rx_go     (s1_v && !s1_lb),
    .rx_raw    (s1_word),
    .rx_chk    (s1_chk),
    .rx_addr   (s1_addr),
    .rx_fix    (rx_fix),
    .st_load   (st_load),
    .st_word   (st_word),
    .st_chk    (st_chk),
    .inj_pend  (ecc_inj_pend),
    .st_busy   (ecc_st_busy),
    .st_done   (ecc_st_done),
    .st_pass   (ecc_st_pass),
    .st_fails  (ecc_st_fails),
    .ce_cnt    (ecc_ce_cnt),
    .ue_cnt    (ecc_ue_cnt),
    .log_v     (ecc_log_v),
    .log_ue    (ecc_log_ue),
    .log_syn   (ecc_log_syn),
    .log_addr  (ecc_log_addr)
  );

  wire unused_full = ^{fifo_full, fl_unused};
endmodule

`default_nettype wire
