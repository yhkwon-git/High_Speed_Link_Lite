`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_ecc
// SECDED (39,32) on the write and read data, with the check bits on the two
// ECC pins (8 bits per burst: the 7 check bits, bit 7 sent as 0).
//   TX: wr_go is the write burst's clock: an armed injection XORs inj_dmask
//       into its data (tx_dflip, same clock) and, one clock later with the
//       registered raw word on wraw, inj_cmask into its check bits (tx_chk).
//   RX: the read word and its check bits go through the decoder. With en the
//       corrected word goes on; a correctable error counts in ce_cnt, an
//       uncorrectable one in ue_cnt (both saturate), and the first one keeps
//       its host address (from the PHY's RD tracking), syndrome and type until
//       clear. Without en the raw word goes on and nothing is counted.
//   Self-test: st_start runs 78 codewords through the same decoder (the
//       datapath one): a fixed word with no error, each of the
//       39 single-bit errors, and the 38 adjacent double-bit errors, and
//       checks the corrected data and the ce / ue flags. Three stages: the
//       codeword is loaded into the PHY's read return registers (the
//       decoder's only input, no mux in front of it), the decoder's outputs
//       are registered, then checked. Run it with the PHY idle; st_fails counts the codewords the
//       decoder got wrong.
// Check bit order: chk[0] = code bit 0 (overall parity), chk[k+1] = code bit
// 2^k (hsl_secded_enc).
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_ecc (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        en,
  input  wire                        inj_arm,
  input  wire  [31:0]                inj_dmask,
  input  wire  [6:0]                 inj_cmask,
  input  wire                        st_start,
  input  wire                        clear,

  input  wire                        wr_go,
  input  wire  [31:0]                wraw,
  output logic [31:0]                tx_dflip,
  output logic [7:0]                 tx_chk,

  input  wire                        rx_go,
  input  wire  [31:0]                rx_raw,
  input  wire  [7:0]                 rx_chk,
  input  wire  [hsl_pkg::ADDR_W-1:0] rx_addr,
  output logic [31:0]                rx_fix,
  output logic                       st_load,    // self-test codeword into the
  output logic [31:0]                st_word,    // read return registers (rx_raw /
  output logic [7:0]                 st_chk,     // rx_chk next clock)

  output logic                       inj_pend,
  output logic                       st_busy,
  output logic                       st_done,
  output logic                       st_pass,
  output logic [6:0]                 st_fails,
  output logic [15:0]                ce_cnt,
  output logic [15:0]                ue_cnt,
  output logic                       log_v,
  output logic                       log_ue,
  output logic [6:0]                 log_syn,
  output logic [hsl_pkg::ADDR_W-1:0] log_addr
);
  localparam logic [31:0] ST_WORD = 32'hA5C3_96E1;

  logic [38:0] tx_c;
  logic [38:0] st_c;
  logic [38:0] rx_cw;
  logic [38:0] st_cw;
  logic [38:0] dec_in;
  logic [31:0] dec_d;
  logic        dec_ce;
  logic        dec_ue;
  logic [5:0]  dec_syn;
  logic        inj_go;
  logic [6:0]  cflip_q;   // check-bit flips for the burst registered last clock
  logic [6:0]  st_i;        // codeword being built
  logic        st_run;      // st_i still issuing
  logic [6:0]  st_i1;
  logic        st_v1;
  logic [31:0] st_d2;       // stage 2: registered decoder outputs
  logic        st_ce2;
  logic        st_ue2;
  logic [6:0]  st_i2;
  logic        st_v2;
  logic        st_ok;
  logic        cnt_go;      // the decoder's flags for a read return, registered
  logic        cnt_ce;
  logic        cnt_ue;
  logic [6:0]  cnt_syn;
  logic [hsl_pkg::ADDR_W-1:0] cnt_addr;
  int          j;
  int          k_st;

  hsl_secded_enc u_enc    (.d(wraw),    .c(tx_c));
  hsl_secded_enc u_enc_st (.d(ST_WORD), .c(st_c));   // a constant

  // TX
  assign inj_go   = inj_pend && wr_go;
  assign tx_dflip = inj_go ? inj_dmask : '0;
  assign tx_chk   = {1'b0, tx_c[32], tx_c[16], tx_c[8], tx_c[4], tx_c[2], tx_c[1], tx_c[0]} ^
                    {1'b0, cflip_q};

  // RX codeword: data at the non-power-of-2 positions, check bits at 0 and 2^k.
  always_comb begin
    rx_cw     = '0;
    rx_cw[0]  = rx_chk[0];
    rx_cw[1]  = rx_chk[1];
    rx_cw[2]  = rx_chk[2];
    rx_cw[4]  = rx_chk[3];
    rx_cw[8]  = rx_chk[4];
    rx_cw[16] = rx_chk[5];
    rx_cw[32] = rx_chk[6];
    j = 0;
    for (int p = 1; p < 39; p++) begin
      if ((p & (p - 1)) != 0) begin
        rx_cw[p] = rx_raw[j];
        j        = j + 1;
      end
    end
  end

  // Self-test codeword st_i: 0 clean, 1..39 bit st_i-1 flipped, 40..77 bits
  // st_i-40 and st_i-39 flipped.
  logic [5:0] st_a;
  logic [5:0] st_b;
  assign st_a = 6'((st_i <= 7'd39) ? (st_i - 7'd1) : (st_i - 7'd40));
  assign st_b = st_a + 6'd1;
  always_comb begin
    st_cw = st_c;
    if ((st_i >= 7'd1) && (st_i <= 7'd39)) begin
      st_cw[st_a] = ~st_c[st_a];
    end else if (st_i >= 7'd40) begin
      st_cw[st_a] = ~st_c[st_a];
      st_cw[st_b] = ~st_c[st_b];
    end
  end

  assign dec_in  = rx_cw;
  assign st_load = st_run;
  assign st_chk  = {1'b0, st_cw[32], st_cw[16], st_cw[8], st_cw[4], st_cw[2], st_cw[1], st_cw[0]};
  always_comb begin
    st_word = '0;
    k_st    = 0;
    for (int p = 1; p < 39; p++) begin
      if ((p & (p - 1)) != 0) begin
        st_word[k_st] = st_cw[p];
        k_st          = k_st + 1;
      end
    end
  end
  hsl_secded_dec u_dec (.c(dec_in), .d(dec_d), .ce(dec_ce), .ue(dec_ue), .syn(dec_syn));

  assign rx_fix = (en && !st_busy) ? dec_d : rx_raw;

  always_comb begin
    if (st_i2 == 7'd0)       st_ok = !st_ce2 && !st_ue2 && (st_d2 == ST_WORD);
    else if (st_i2 <= 7'd39) st_ok = st_ce2 && !st_ue2 && (st_d2 == ST_WORD);
    else                     st_ok = st_ue2 && !st_ce2;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      inj_pend <= 1'b0;
      cflip_q  <= '0;
      st_busy  <= 1'b0;
      st_done  <= 1'b0;
      st_pass  <= 1'b0;
      st_fails <= '0;
      st_i     <= '0;
      st_run   <= 1'b0;
      st_i1    <= '0;
      st_v1    <= 1'b0;
      st_d2    <= '0;
      st_ce2   <= 1'b0;
      st_ue2   <= 1'b0;
      st_i2    <= '0;
      st_v2    <= 1'b0;
      cnt_go   <= 1'b0;
      cnt_ce   <= 1'b0;
      cnt_ue   <= 1'b0;
      cnt_syn  <= '0;
      cnt_addr <= '0;
      ce_cnt   <= '0;
      ue_cnt   <= '0;
      log_v    <= 1'b0;
      log_ue   <= 1'b0;
      log_syn  <= '0;
      log_addr <= '0;
    end else begin
      if (inj_arm)      inj_pend <= 1'b1;
      else if (inj_go)  inj_pend <= 1'b0;
      if (wr_go) cflip_q <= inj_go ? inj_cmask : 7'h0;

      // Self-test pipeline: issue, decode, check.
      st_i1   <= st_i;
      st_v1   <= st_run;
      st_d2   <= dec_d;
      st_ce2  <= dec_ce;
      st_ue2  <= dec_ue;
      st_i2   <= st_i1;
      st_v2   <= st_v1;
      if (st_run) begin
        if (st_i == 7'd77) st_run <= 1'b0;
        else               st_i   <= st_i + 7'd1;
      end
      if (st_busy && st_v2) begin
        if (!st_ok && (st_fails != 7'h7F)) st_fails <= st_fails + 7'd1;
        if (st_i2 == 7'd77) begin
          st_busy <= 1'b0;
          st_done <= 1'b1;
          st_pass <= st_ok && (st_fails == 7'd0);
        end
      end else if (!st_busy && st_start) begin
        st_busy  <= 1'b1;
        st_run   <= 1'b1;
        st_done  <= 1'b0;
        st_pass  <= 1'b0;
        st_fails <= '0;
        st_i     <= '0;
      end

      // Counters and log, one clock after the read return.
      cnt_go   <= rx_go && en && !st_busy;
      cnt_ce   <= dec_ce;
      cnt_ue   <= dec_ue;
      cnt_syn  <= {^dec_in, dec_syn};
      cnt_addr <= rx_addr;
      if (clear) begin
        ce_cnt <= '0;
        ue_cnt <= '0;
        log_v  <= 1'b0;
        log_ue <= 1'b0;
      end else if (cnt_go && (cnt_ce || cnt_ue)) begin
        if (cnt_ce && (ce_cnt != 16'hFFFF)) ce_cnt <= ce_cnt + 16'd1;
        if (cnt_ue && (ue_cnt != 16'hFFFF)) ue_cnt <= ue_cnt + 16'd1;
        if (!log_v) begin
          log_v    <= 1'b1;
          log_ue   <= cnt_ue;
          log_syn  <= cnt_syn;
          log_addr <= cnt_addr;
        end
      end
    end
  end
  wire unused_ecc = ^{rx_chk[7], tx_c[38:33], tx_c[31:17], tx_c[15:9], tx_c[7:5], tx_c[3]};
endmodule

`default_nettype wire
