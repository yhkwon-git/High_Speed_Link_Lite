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
// Loopback answers a RD with lb_data the next clock and sends no CA for it.
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
  output logic                         tx_dv,
  input  wire                          rdqs,
  input  wire  [hsl_pkg::BEAT_W-1:0]   rx_beat,
  input  wire                          rx_dv,

  output logic                         rddata_valid,
  output logic [hsl_pkg::DATA_W-1:0]   rddata
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
  logic [WORD_PW-1:0]    fifo_rdata;
  logic                  fifo_empty;
  logic                  fifo_full;
  logic [BL*LANE_N-1:0]  rx_sym;
  logic [DATA_W-1:0]     rx_word;

  wire lb_rd = on && loopback && (ccmd == CMD_RD);

  integer bi;
  always_comb begin
    for (bi = 0; bi < BL; bi = bi + 1) begin
      tx_sym[bi*LANE_N +: LANE_N] = {dbi_flags[bi], wdata[bi*DQ_W +: DQ_W]};
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
    .rx_p (fifo_rdata),
    .rx_l (rx_sym)
  );

  // Commands and write data, one controller clock each.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rca       <= {CMD_NOP, {(RCA_W-3){1'b0}}};
      cca       <= {CMD_NOP, {(CCA_W-3){1'b0}}};
      tx_word   <= '0;
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
          tx_wv     <= 1'b1;
          last_wr   <= 1'b1;
          last_byte <= wdata[DATA_W-1 -: DQ_W];
        end
      end
    end
  end

  hsl_tx_gear #(.W(WORD_PW)) u_gear (
    .clk_ctrl   (clk),
    .clk_phy    (clk_phy),
    .rst_n      (rst_n),
    .din        (tx_word),
    .din_valid  (tx_wv),
    .dout       (tx_beat),
    .dout_valid (tx_dv)
  );

  // WDQS toggles once per UI while data is out: high in UI 0, low in UI 1.
  assign tx_dqs = tx_dv ? {{(DDR_BITS-1){1'b0}}, 1'b1} : '0;

  // RDQS domain: two beats make a burst.
  always_ff @(posedge rdqs or negedge rst_n) begin
    if (!rst_n) begin
      half  <= 1'b0;
      rx_lo <= '0;
    end else if (rx_dv) begin
      half <= ~half;
      if (!half) begin
        rx_lo <= rx_beat;
      end
    end
  end

  hsl_cdc_fifo #(
    .WIDTH      (WORD_PW),
    .SAME_CLOCK (0)
  ) u_rx_fifo (
    .clk_w    (rdqs),
    .clk_r    (clk),
    .rst_n    (rst_n),
    .wr_en    (rx_dv && half),
    .wr_data  ({rx_beat, rx_lo}),
    .wr_full  (fifo_full),
    .rd_en    (!fifo_empty && !lb_rd),
    .rd_data  (fifo_rdata),
    .rd_empty (fifo_empty)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rddata_valid <= 1'b0;
      rddata       <= '0;
    end else begin
      rddata_valid <= 1'b0;
      if (lb_rd) begin
        rddata_valid <= 1'b1;
        rddata       <= lb_data;
      end else if (!fifo_empty) begin
        rddata_valid <= 1'b1;
        rddata       <= rx_word;
      end
    end
  end

  wire unused_full = fifo_full;
endmodule

`default_nettype wire
