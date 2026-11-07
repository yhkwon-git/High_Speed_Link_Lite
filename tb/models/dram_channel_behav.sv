`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// dram_channel_behav
// Samples the base-die pins on negedge clk. Protocol is the phy_bypass framer
// in hsl_phy_tx: ACT/PRE are one strobe, WR is a header plus BL beats, RD
// drives BL bytes back. Stores one burst per {bank, open row, col}.
//
// WR data is decoded by its DBI pin whatever the mode. RD data is encoded by
// mr_dbi_en / mr_dbi_ac, which stand in for the DRAM mode register (this
// framer has no MRS). The encoder below is the plain serial rule, written
// apart from rtl/phy/hsl_dbi.sv so it can check that block's RX side.
//
// Lane repair on the DRAM side: mr_repair_en / mr_repair_lane give the same
// shift as rtl/phy/hsl_lane_shift.sv (pin k idles, lanes from k up use the
// next pin, RED carries the last one). It is written again as loops here and
// applies to every symbol, headers included, in both directions.
//
// Read eye: rx_dly is the chip's delay-line code per DQ lane. Inside
// [eye_lo, eye_hi] a lane samples its own UI; before the window it samples
// the UI before, after the window the UI after (0 outside the burst, where the
// bus idles). This stands in for the analog delay line and sampler, in the
// logical lane domain (before the repair shift).
//
// Mission path (CTRL.phy_en): commands arrive on pin_rca / pin_cca, sampled on
// negedge clk like the bypass strobes. Write data arrives as two PHY beats
// right after the WR, sampled in the middle of each beat (negedge pin_ck);
// WDQS must toggle with them. RDQS is CK delayed by TDQSCK. Read data leaves
// RL_RDQS RDQS cycles after the RD, as two beats launched on the falling RDQS
// edge (the chip captures on the rising one). Errors on this path count in
// wdqs_err and mis_err; the testbench checks them.
// -----------------------------------------------------------------------------
`default_nettype none

module dram_channel_behav (
  input  wire                       clk,
  input  wire                       rst_n,
  input  wire                       pin_ck,
  input  wire                       pin_cke,
  input  wire  [7:0]                pin_ca,
  input  wire  [hsl_pkg::PIN_W-1:0] pin_dq_i,
  input  wire                       pin_dq_oe,
  input  wire                       pin_dqs_i,
  input  wire                       mr_dbi_en,
  input  wire                       mr_dbi_ac,
  input  wire                       mr_repair_en,
  input  wire  [3:0]                mr_repair_lane,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rx_dly,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] eye_lo,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] eye_hi,
  output logic [hsl_pkg::PIN_W-1:0] pin_dq_o,
  output logic                      pin_dqs_o,

  input  wire  [hsl_pkg::RCA_W-1:0]    pin_rca,
  input  wire  [hsl_pkg::CCA_W-1:0]    pin_cca,
  input  wire  [hsl_pkg::BEAT_W-1:0]   pin_tx_beat,
  input  wire  [hsl_pkg::DDR_BITS-1:0] pin_tx_dqs,
  input  wire                          pin_tx_dv,
  output logic                         pin_rdqs,
  output logic [hsl_pkg::BEAT_W-1:0]   pin_rx_beat,
  output logic                         pin_rx_dv
);
  import hsl_pkg::*;

  localparam logic [1:0] PH_IDLE = 2'd0;
  localparam logic [1:0] PH_CAP  = 2'd1;
  localparam logic [1:0] PH_DRV  = 2'd2;

  logic [1:0] phase;
  logic [2:0] beat;
  logic [BANK_W-1:0] b_cap;
  logic [COL_W-1:0]  c_cap;
  logic [7:0]        cap_b [0:BL-1];
  logic [DATA_W-1:0] rd_word;
  logic [BL-1:0]     rd_dbi;
  logic [ROW_W-1:0]  open_row [0:BANK_N-1];
  logic              open_v   [0:BANK_N-1];
  logic [DATA_W-1:0] mem [0:BANK_N-1][0:(1<<ROW_W)-1][0:(1<<COL_W)-1];

  localparam int RL_RDQS = 3; // RDQS cycles from the RD sample to the first beat
  localparam int QN      = 8;

  // Mission write path: two beats per burst, handed to the negedge clk block.
  logic               wcap_half;
  logic [BEAT_W-1:0]  wcap_lo;
  logic               wdone_tog;
  logic               wdone_seen;
  logic [WORD_PW-1:0] wdone_pins;
  logic [BANK_W-1:0]  wq_bank [0:QN-1];
  logic [COL_W-1:0]   wq_col  [0:QN-1];
  integer             wq_head;
  integer             wq_tail;
  integer             wdqs_err;
  integer             mis_err;
  // Mission read path: words queued on the RD, launched on RDQS.
  logic [DATA_W-1:0]  rq_word [0:QN-1];
  integer             rq_due  [0:QN-1];
  integer             rq_head;
  integer             rq_tail;
  integer             rcyc;
  logic               rx_phase;
  logic [BEAT_W-1:0]  rx_hi;
  logic               rx_last_dv;
  logic [DQ_W-1:0]    rx_last_byte;

  // Pins -> logical {DBI, DQ}: lane i is on pin i below the bad pin, on i+1 from it.
  function automatic logic [LANE_N-1:0] from_pins(
    input logic [PIN_W-1:0] p,
    input logic             en,
    input logic [3:0]       lane
  );
    integer i;
    integer k;
    begin
      k = (en && (lane < 4'(LANE_N))) ? int'(lane) : PIN_W;
      for (i = 0; i < LANE_N; i = i + 1) begin
        from_pins[i] = (i < k) ? p[i] : p[i+1];
      end
    end
  endfunction

  // Logical {DBI, DQ} -> pins; the bad pin and, without repair, RED stay 0.
  function automatic logic [PIN_W-1:0] to_pins(
    input logic [LANE_N-1:0] l,
    input logic              en,
    input logic [3:0]        lane
  );
    integer i;
    integer k;
    begin
      k = (en && (lane < 4'(LANE_N))) ? int'(lane) : PIN_W;
      to_pins = '0;
      for (i = 0; i < PIN_W; i = i + 1) begin
        if ((i < k) && (i < LANE_N)) begin
          to_pins[i] = l[i];
        end else if (i > k) begin
          to_pins[i] = l[i-1];
        end
      end
    end
  endfunction

  // What the chip's sampler reads on each lane for a burst, given its codes.
  function automatic logic [DATA_W-1:0] eye_apply(
    input logic [DATA_W-1:0]           w,
    input logic [DQ_W*RX_DLY_W-1:0]    code,
    input logic [DQ_W*RX_DLY_W-1:0]    lo,
    input logic [DQ_W*RX_DLY_W-1:0]    hi
  );
    integer b;
    integer p;
    integer src;
    begin
      eye_apply = '0;
      for (b = 0; b < BL; b = b + 1) begin
        for (p = 0; p < DQ_W; p = p + 1) begin
          if (code[p*RX_DLY_W +: RX_DLY_W] < lo[p*RX_DLY_W +: RX_DLY_W]) begin
            src = b - 1;
          end else if (code[p*RX_DLY_W +: RX_DLY_W] > hi[p*RX_DLY_W +: RX_DLY_W]) begin
            src = b + 1;
          end else begin
            src = b;
          end
          if ((src >= 0) && (src < BL)) begin
            eye_apply[b*DQ_W + p] = w[src*DQ_W + p];
          end
        end
      end
    end
  endfunction

  // Pins of a whole burst (BL symbols) -> logical word, DBI undone per beat.
  function automatic logic [DATA_W-1:0] burst_in(
    input logic [WORD_PW-1:0] pins,
    input logic               en,
    input logic [3:0]         lane
  );
    logic [LANE_N-1:0] l;
    integer b;
    begin
      for (b = 0; b < BL; b = b + 1) begin
        l = from_pins(pins[b*PIN_W +: PIN_W], en, lane);
        burst_in[b*DQ_W +: DQ_W] = l[DQ_W] ? ~l[DQ_W-1:0] : l[DQ_W-1:0];
      end
    end
  endfunction

  wire [LANE_N-1:0]  lin      = from_pins(pin_dq_i, mr_repair_en, mr_repair_lane);
  wire [LANE_N-1:0]  lout     = from_pins(pin_dq_o, mr_repair_en, mr_repair_lane);
  wire [3:0]         opc_pin  = pin_ca[3:0];
  wire [BANK_W-1:0]  bank_pin = pin_ca[5:4];
  wire [DQ_W-1:0]    dq_b     = lin[DQ_W-1:0];
  wire               dbi_b    = lin[DQ_W];
  wire [DQ_W-1:0]    logical  = dbi_b ? ~dq_b : dq_b;

  // {flags, bytes as sent}. last is the DQ byte in the UI before beat 0.
  function automatic logic [DATA_W+BL-1:0] dbi_encode(
    input logic [DATA_W-1:0] word,
    input logic [DQ_W-1:0]   last,
    input logic              en,
    input logic              ac
  );
    logic [DATA_W-1:0] enc;
    logic [BL-1:0]     flg;
    logic [DQ_W-1:0]   sent;
    logic [DQ_W-1:0]   cmp;
    integer            b;
    begin
      enc  = word;
      flg  = '0;
      sent = last;
      for (b = 0; b < BL; b = b + 1) begin
        cmp = ac ? (word[b*DQ_W +: DQ_W] ^ sent) : word[b*DQ_W +: DQ_W];
        if (en && ($countones(cmp) > DQ_W / 2)) begin
          enc[b*DQ_W +: DQ_W] = ~word[b*DQ_W +: DQ_W];
          flg[b] = 1'b1;
        end
        sent = enc[b*DQ_W +: DQ_W];
      end
      dbi_encode = {flg, enc};
    end
  endfunction

  integer bi;
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase     <= PH_IDLE;
      beat      <= '0;
      b_cap     <= '0;
      c_cap     <= '0;
      rd_word   <= '0;
      rd_dbi    <= '0;
      pin_dq_o  <= '0;
      pin_dqs_o <= 1'b0;
      for (bi = 0; bi < BANK_N; bi = bi + 1) begin
        open_v[bi]   <= 1'b0;
        open_row[bi] <= '0;
      end
      wdone_seen <= 1'b0;
      wq_head    <= 0;
      wq_tail    <= 0;
      rq_tail    <= 0;
      mis_err    <= 0;
    end else begin
      pin_dq_o  <= '0;
      pin_dqs_o <= 1'b0;
      // ---------------------------------------------------------- mission
      // A burst finished on the write beats: store it at the oldest WR.
      if (wdone_tog != wdone_seen) begin
        wdone_seen <= wdone_tog;
        if ((wq_head == wq_tail) || !open_v[wq_bank[wq_head % QN]]) begin
          mis_err <= mis_err + 1;
        end else begin
          mem[wq_bank[wq_head % QN]][open_row[wq_bank[wq_head % QN]]][wq_col[wq_head % QN]] <=
            burst_in(wdone_pins, mr_repair_en, mr_repair_lane);
        end
        if (wq_head != wq_tail) begin
          wq_head <= wq_head + 1;
        end
      end
      if (pin_cke && (pin_rca[RCA_W-1 -: 2] == RCMD_ACT)) begin
        open_v[pin_rca[ROW_W +: BANK_W]]   <= 1'b1;
        open_row[pin_rca[ROW_W +: BANK_W]] <= pin_rca[ROW_W-1:0];
      end else if (pin_cke && (pin_rca[RCA_W-1 -: 2] == RCMD_PRE)) begin
        open_v[pin_rca[ROW_W +: BANK_W]] <= 1'b0;
      end
      if (pin_cke && (pin_cca[CCA_W-1 -: 2] == CCMD_WR)) begin
        wq_bank[wq_tail % QN] <= pin_cca[COL_W +: BANK_W];
        wq_col[wq_tail % QN]  <= pin_cca[COL_W-1:0];
        wq_tail <= wq_tail + 1;
      end else if (pin_cke && (pin_cca[CCA_W-1 -: 2] == CCMD_RD)) begin
        if (!open_v[pin_cca[COL_W +: BANK_W]] || (rq_tail - rq_head >= QN)) begin
          mis_err <= mis_err + 1;
        end
        rq_word[rq_tail % QN] <= mem[pin_cca[COL_W +: BANK_W]][open_row[pin_cca[COL_W +: BANK_W]]]
                                    [pin_cca[COL_W-1:0]];
        rq_due[rq_tail % QN]  <= rcyc + RL_RDQS;
        rq_tail <= rq_tail + 1;
      end
      // ---------------------------------------------------------- bypass
      case (phase)
        PH_IDLE: begin
          if (pin_cke && pin_dqs_i) begin
            case (opc_pin)
              OPC_ACT: begin
                open_v[bank_pin]   <= 1'b1;
                open_row[bank_pin] <= dq_b;
              end
              OPC_PRE: begin
                open_v[bank_pin] <= 1'b0;
              end
              OPC_WR: begin
                phase <= PH_CAP;
                beat  <= '0;
                b_cap <= bank_pin;
                c_cap <= lin[COL_W-1:0];
              end
              OPC_RD: begin
                logic [DATA_W+BL-1:0] rd_enc;
                logic [DATA_W-1:0]    rd_eye;
                // pin_dq_o still holds the UI before this one (0 when idle).
                rd_enc    = dbi_encode(mem[bank_pin][open_row[bank_pin]][lin[COL_W-1:0]],
                                       lout[DQ_W-1:0], mr_dbi_en, mr_dbi_ac);
                rd_eye    = eye_apply(rd_enc[DATA_W-1:0], rx_dly, eye_lo, eye_hi);
                phase     <= PH_DRV;
                beat      <= 3'd1;
                rd_word   <= rd_eye;
                rd_dbi    <= rd_enc[DATA_W +: BL];
                pin_dq_o  <= to_pins({rd_enc[DATA_W], rd_eye[DQ_W-1:0]}, mr_repair_en, mr_repair_lane);
                pin_dqs_o <= 1'b1;
              end
              default: ;
            endcase
          end
        end
        PH_CAP: begin
          if (pin_cke && pin_dqs_i) begin
            cap_b[beat[1:0]] <= logical;
            if (beat == BL[2:0]-3'd1) begin
              phase <= PH_IDLE;
              if (open_v[b_cap]) begin
                mem[b_cap][open_row[b_cap]][c_cap] <= {
                  (beat == 3) ? logical : cap_b[3],
                  (beat == 2) ? logical : cap_b[2],
                  (beat == 1) ? logical : cap_b[1],
                  (beat == 0) ? logical : cap_b[0]
                };
              end
            end else begin
              beat <= beat + 1'b1;
            end
          end
        end
        PH_DRV: begin
          if (beat >= BL[2:0]) begin
            phase <= PH_IDLE;
          end else begin
            pin_dq_o  <= to_pins({rd_dbi[beat[1:0]], rd_word[beat*DQ_W +: DQ_W]}, mr_repair_en, mr_repair_lane);
            pin_dqs_o <= 1'b1;
            beat      <= beat + 1'b1;
          end
        end
        default: phase <= PH_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------ mission write
  always @(negedge pin_ck or negedge rst_n) begin
    if (!rst_n) begin
      wcap_half <= 1'b0;
      wcap_lo   <= '0;
      wdone_tog <= 1'b0;
      wdone_pins <= '0;
      wdqs_err  <= 0;
    end else if (pin_tx_dv) begin
      if (pin_tx_dqs !== {{(DDR_BITS-1){1'b0}}, 1'b1}) begin
        wdqs_err <= wdqs_err + 1;
      end
      if (!wcap_half) begin
        wcap_lo   <= pin_tx_beat;
        wcap_half <= 1'b1;
      end else begin
        wdone_pins <= {pin_tx_beat, wcap_lo};
        wdone_tog  <= ~wdone_tog;
        wcap_half  <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------ mission read
  localparam int TDQSCK_PS = 150;
  initial pin_rdqs = 1'b0;
  always begin
    @(posedge pin_ck);
    #150ps;
    pin_rdqs = 1'b1;
    #312.5ps;
    pin_rdqs = 1'b0;
  end

  always @(negedge pin_rdqs or negedge rst_n) begin
    if (!rst_n) begin
      rcyc         <= 0;
      rq_head      <= 0;
      rx_phase     <= 1'b0;
      rx_hi        <= '0;
      rx_last_dv   <= 1'b0;
      rx_last_byte <= '0;
      pin_rx_beat  <= '0;
      pin_rx_dv    <= 1'b0;
    end else begin
      rcyc        <= rcyc + 1;
      pin_rx_beat <= '0;
      pin_rx_dv   <= 1'b0;
      rx_last_dv  <= 1'b0;
      if (rx_phase) begin
        pin_rx_beat <= rx_hi;
        pin_rx_dv   <= 1'b1;
        rx_phase    <= 1'b0;
        rx_last_dv  <= 1'b1;
      end else if ((rq_head != rq_tail) && (rcyc >= rq_due[rq_head % QN])) begin
        logic [DATA_W+BL-1:0] enc;
        logic [DATA_W-1:0]    eyed;
        logic [WORD_PW-1:0]   pins;
        integer               b;
        // The UI before beat 0 is the last beat of a burst sent just before,
        // or the idle bus.
        enc  = dbi_encode(rq_word[rq_head % QN], rx_last_dv ? rx_last_byte : '0,
                          mr_dbi_en, mr_dbi_ac);
        eyed = eye_apply(enc[DATA_W-1:0], rx_dly, eye_lo, eye_hi);
        for (b = 0; b < BL; b = b + 1) begin
          pins[b*PIN_W +: PIN_W] = to_pins({enc[DATA_W + b], eyed[b*DQ_W +: DQ_W]},
                                           mr_repair_en, mr_repair_lane);
        end
        pin_rx_beat  <= pins[BEAT_W-1:0];
        pin_rx_dv    <= 1'b1;
        rx_hi        <= pins[WORD_PW-1:BEAT_W];
        rx_phase     <= 1'b1;
        rx_last_byte <= enc[DATA_W-1 -: DQ_W];
        rq_head      <= rq_head + 1;
      end
    end
  end

  wire unused_pins = ^{pin_dq_oe, TDQSCK_PS};
endmodule

`default_nettype wire
