`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// dram_channel_behav
// Channel model behind the base-die pins. Stores one burst per
// {bank, row, col}.
//
// Commands: pin_rca (ACT, PRE, PREA, REF, REFPB) and pin_cca (RD, WR, with
// auto-precharge) carry the controller's dram_cmd_e codes, sampled on negedge
// clk while pin_cke is high. The column bus carries no row: RD and WR use the
// bank's open row. pin_cke low (the controller in reset or training) closes
// every bank; the stored data stays.
//
// Checks, counted for the testbench:
//   mis_err  protocol: ACT to an open bank, RD/WR to a closed one, REF or
//            REFPB to an open bank, a command on the wrong bus, a write burst
//            with no WR, a read queue overflow
//   tim_err  same-bank timing at the pins in controller clocks: tRCD, tRP,
//            tRAS, tRC, tRTP, write recovery (WL + 1 + tWR), tRFCpb, tRFC.
//            Auto-precharge closes the bank on the first edge a PRE would be
//            legal. Channel rules (tCCD, tRRD, tFAW, tWTR, tRTW) are the
//            controller repo's model's job.
//   hz_err   a RD that reaches a {bank, row, col} whose write data has not
//            arrived yet
//   wdqs_err WDQS not toggling with the write beats
//
// Write data arrives as two PHY beats after the WR, sampled in the middle of
// each beat (negedge pin_ck), and is stored at the oldest WR still waiting
// for data, with the row that was open when the WR came. It is decoded by its
// DBI pin whatever the mode.
//
// Read data leaves RL_RDQS RDQS cycles after the RD, as two beats launched on
// the falling RDQS edge (the chip captures on the rising one). RDQS is CK
// delayed by tDQSCK. It is encoded by mr_dbi_en / mr_dbi_ac, which stand in
// for the DRAM mode register. The encoder below is the plain serial rule,
// written apart from rtl/phy/hsl_dbi.sv so it can check that block's RX side.
//
// Lane repair on the DRAM side: mr_repair_en / mr_repair_lane give the same
// shift as rtl/phy/hsl_lane_shift.sv (pin k idles, lanes from k up use the
// next pin, RED carries the last one), written again as loops here.
//
// Array faults (for MBIST): up to NFLT bit-level faults set by the testbench in
// flt_* below, on one victim cell and, for coupling faults, one aggressor cell
// in another word:
//   SA    the victim bit reads and stores flt_val
//   TF    a write that would move the victim bit in direction flt_dir (1 up)
//         leaves it as it was
//   CFin  a write that moves the aggressor bit in direction flt_dir inverts
//         the victim bit
//   CFid  the same transition forces the victim bit to flt_val
//   CFst  while the aggressor bit is flt_s, the victim bit reads flt_val
// Spare rows and columns take the accesses rep_tab names (see spare_of).
// The two ECC pins' 8 bits per burst are stored beside each word and sent back
// with its read beats; array faults only touch data bits.
// The array starts at all zeros. tb/march_ref.py implements the same rules in a
// reference March simulator; it gives the expected MBIST detection table (T13).
//
// Read eye: rx_dly is the chip's delay-line code per DQ lane. Inside
// [eye_lo, eye_hi] a lane samples its own UI; before the window it samples
// the UI before, after the window the UI after (0 outside the burst, where the
// bus idles). This stands in for the analog delay line and sampler, in the
// logical lane domain (before the repair shift).
// -----------------------------------------------------------------------------
`default_nettype none

module dram_channel_behav (
  input  wire                          clk,
  input  wire                          rst_n,
  input  wire                          pin_ck,
  input  wire                          pin_cke,
  input  wire                          mr_dbi_en,
  input  wire                          mr_dbi_ac,
  input  wire                          mr_repair_en,
  input  wire  [3:0]                   mr_repair_lane,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rx_dly,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] eye_lo,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] eye_hi,
  input  wire  [hsl_pkg::RT_N*hsl_pkg::RT_W-1:0]      rep_tab,   // repair table (spares)

  input  wire  [hsl_pkg::RCA_W-1:0]    pin_rca,
  input  wire  [hsl_pkg::CCA_W-1:0]    pin_cca,
  input  wire  [hsl_pkg::BEAT_W-1:0]   pin_tx_beat,
  input  wire  [2*hsl_pkg::DDR_BITS-1:0] pin_tx_ecc,   // ECC pins (check bits)
  input  wire  [hsl_pkg::DDR_BITS-1:0] pin_tx_dqs,
  input  wire                          pin_tx_dv,
  output logic                         pin_rdqs,
  output logic [hsl_pkg::BEAT_W-1:0]   pin_rx_beat,
  output logic [2*hsl_pkg::DDR_BITS-1:0] pin_rx_ecc,
  output logic                         pin_rx_dv
);
  import hsl_pkg::*;
  import dram_pkg::*;

  localparam int RL_RDQS = 3; // RDQS cycles from the RD sample to the first beat
  localparam int QN      = 8;
  localparam int NMSG    = 8; // error lines printed per counter

  logic [ROW_W-1:0]  open_row [0:BANK_N-1];
  logic              open_v   [0:BANK_N-1];
  logic [DATA_W-1:0] mem [0:BANK_N-1][0:(1<<ROW_W)-1][0:(1<<COL_W)-1];
  logic [DATA_W-1:0] spr_mem [0:hsl_pkg::RT_N-1][0:15];   // spares (spare_of)
  // The ECC pins' 8 bits per burst are stored beside each word (no faults).
  logic [7:0]        mem_ecc [0:BANK_N-1][0:(1<<ROW_W)-1][0:(1<<COL_W)-1];
  logic [7:0]        spr_ecc [0:hsl_pkg::RT_N-1][0:15];
  integer            n_spare = 0;   // array accesses that went to a spare

  localparam int NFLT   = 16;
  localparam int F_NONE = 0;
  localparam int F_SA   = 1;
  localparam int F_TF   = 2;
  localparam int F_CFIN = 3;
  localparam int F_CFID = 4;
  localparam int F_CFST = 5;
  integer flt_kind [0:NFLT-1];
  integer flt_vb   [0:NFLT-1];   // victim bank, row, column, bit
  integer flt_vr   [0:NFLT-1];
  integer flt_vc   [0:NFLT-1];
  integer flt_vk   [0:NFLT-1];
  integer flt_ab   [0:NFLT-1];   // aggressor bank, row, column, bit
  integer flt_ar   [0:NFLT-1];
  integer flt_ac   [0:NFLT-1];
  integer flt_ak   [0:NFLT-1];
  integer flt_dir  [0:NFLT-1];
  integer flt_val  [0:NFLT-1];
  integer flt_s    [0:NFLT-1];

  integer ib, ir, ic;
  initial begin
    for (ib = 0; ib < BANK_N; ib = ib + 1) begin
      for (ir = 0; ir < (1 << ROW_W); ir = ir + 1) begin
        for (ic = 0; ic < (1 << COL_W); ic = ic + 1) begin
          mem[ib][ir][ic] = '0;
          mem_ecc[ib][ir][ic] = '0;
        end
      end
    end
    for (ib = 0; ib < NFLT; ib = ib + 1) begin
      flt_kind[ib] = F_NONE;
    end
    for (ib = 0; ib < hsl_pkg::RT_N; ib = ib + 1) begin
      for (ic = 0; ic < 16; ic = ic + 1) begin
        spr_mem[ib][ic] = '0;
        spr_ecc[ib][ic] = '0;
      end
    end
  end

  // Earliest legal cycle per bank, in ccyc (controller clocks at the pins).
  integer ccyc;
  integer act_at [0:BANK_N-1]; // ACT, REFPB: tRP, tRC, tRFCpb, auto-precharge
  integer col_at [0:BANK_N-1]; // RD, WR: tRCD
  integer pre_at [0:BANK_N-1]; // PRE: tRAS, tRTP, write recovery
  integer any_at;              // any command: tRFC after REF

  integer mis_err;
  integer tim_err;
  integer hz_err;
  integer wdqs_err;
  integer n_act, n_pre, n_prea, n_ref, n_refpb, n_rd, n_wr, n_ap;
  // A planted bug for the DFD debug case (T16): with bug_refdis, a RD to a
  // bank within bug_win clocks after that bank's REFpb returns bit 5 flipped.
  logic   bug_refdis = 1'b0;
  integer bug_win    = 16;
  integer n_bug      = 0;
  integer refpb_cyc [0:BANK_N-1];
  initial for (int b = 0; b < BANK_N; b++) refpb_cyc[b] = -1000;

  // Write path: WRs waiting for their data, two beats per burst.
  logic               wcap_half;
  logic [BEAT_W-1:0]  wcap_lo;
  logic               wdone_tog;
  logic               wdone_seen;
  logic [WORD_PW-1:0] wdone_pins;
  logic [BANK_W-1:0]  wq_bank [0:QN-1];
  logic [ROW_W-1:0]   wq_row  [0:QN-1];
  logic [COL_W-1:0]   wq_col  [0:QN-1];
  integer             wq_head;
  integer             wq_tail;
  // Read path: words queued on the RD, launched on RDQS.
  logic [DATA_W-1:0]  rq_word [0:QN-1];
  logic [7:0]         rq_ecc  [0:QN-1];
  logic [7:0]         wdone_ecc;
  logic [3:0]         wcap_lo_e;
  logic [3:0]         rx_hi_e;
  integer             rq_due  [0:QN-1];
  integer             rq_head;
  integer             rq_tail;
  integer             rcyc;
  logic               rx_phase;
  logic [BEAT_W-1:0]  rx_hi;
  logic               rx_last_dv;
  logic [DQ_W-1:0]    rx_last_byte;

  wire [2:0]         rcmd  = pin_rca[RCA_W-1 -: 3];  // dram_cmd_e codes
  wire [BANK_W-1:0]  rbank = pin_rca[ROW_W +: BANK_W];
  wire [ROW_W-1:0]   rrow  = pin_rca[ROW_W-1:0];
  wire [2:0]         ccmd  = pin_cca[CCA_W-1 -: 3];
  wire [BANK_W-1:0]  cbank = pin_cca[COL_W+1 +: BANK_W];
  wire [COL_W-1:0]   ccol  = pin_cca[1 +: COL_W];
  wire               cap   = pin_cca[0];

  function automatic integer imax(input integer a, input integer b);
    imax = (a > b) ? a : b;
  endfunction

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

  // Store w at (b, r, c) through the array faults.
  // Spare elements: rep_tab entry k (rows first, hsl_pkg format) replaces a
  // row (spr_mem[k][col]) or one column of a 16-row block (spr_mem[k][row % 16]).
  // A row spare wins over a column spare. Spares have no faults.

  function automatic integer spare_of(input integer b, input integer r, input integer c);
    logic [15:0] e;
    integer k;
    begin
      spare_of = -1;
      for (k = hsl_pkg::RT_N - 1; k >= 0; k = k - 1) begin
        e = rep_tab[16*k +: 16];
        if (e[15] && (int'(e[13:12]) == b)) begin
          if ((k < hsl_pkg::SPR_N) && (int'(e[11:4]) == r)) spare_of = k;
          if ((k >= hsl_pkg::SPR_N) && (spare_of < 0 || spare_of >= hsl_pkg::SPR_N) &&
              (int'(e[11:8]) == r / 16) && (int'(e[3:0]) == c)) spare_of = k;
        end
      end
    end
  endfunction

  task automatic ecc_write(input integer b, input integer r, input integer c, input logic [7:0] e);
    integer k;
    begin
      k = spare_of(b, r, c);
      if (k >= 0) spr_ecc[k][(k < hsl_pkg::SPR_N) ? c : (r % 16)] = e;
      else        mem_ecc[b][r][c] = e;
    end
  endtask

  function automatic logic [7:0] ecc_read(input integer b, input integer r, input integer c);
    integer k;
    begin
      k = spare_of(b, r, c);
      if (k >= 0) ecc_read = spr_ecc[k][(k < hsl_pkg::SPR_N) ? c : (r % 16)];
      else        ecc_read = mem_ecc[b][r][c];
    end
  endfunction

  task automatic array_write(input integer b, input integer r, input integer c,
                             input logic [DATA_W-1:0] w_in);
    logic [DATA_W-1:0] o;
    logic [DATA_W-1:0] w;
    integer f;
    integer k;
    begin
      k = spare_of(b, r, c);
      if (k >= 0) begin
        spr_mem[k][(k < hsl_pkg::SPR_N) ? c : (r % 16)] = w_in;
        n_spare = n_spare + 1;
        return;
      end
      o = mem[b][r][c];
      w = w_in;
      for (f = 0; f < NFLT; f = f + 1) begin
        if ((flt_vb[f] == b) && (flt_vr[f] == r) && (flt_vc[f] == c)) begin
          if (flt_kind[f] == F_TF) begin
            if ((flt_dir[f] == 1) && !o[flt_vk[f]] && w[flt_vk[f]]) w[flt_vk[f]] = 1'b0;
            if ((flt_dir[f] == 0) && o[flt_vk[f]] && !w[flt_vk[f]]) w[flt_vk[f]] = 1'b1;
          end
          if (flt_kind[f] == F_SA) w[flt_vk[f]] = (flt_val[f] != 0);
        end
      end
      mem[b][r][c] = w;
      for (f = 0; f < NFLT; f = f + 1) begin
        if (((flt_kind[f] == F_CFIN) || (flt_kind[f] == F_CFID)) &&
            (flt_ab[f] == b) && (flt_ar[f] == r) && (flt_ac[f] == c) &&
            (o[flt_ak[f]] != w[flt_ak[f]]) && (w[flt_ak[f]] == (flt_dir[f] != 0))) begin
          if (flt_kind[f] == F_CFIN) begin
            mem[flt_vb[f]][flt_vr[f]][flt_vc[f]][flt_vk[f]] = ~mem[flt_vb[f]][flt_vr[f]][flt_vc[f]][flt_vk[f]];
          end else begin
            mem[flt_vb[f]][flt_vr[f]][flt_vc[f]][flt_vk[f]] = (flt_val[f] != 0);
          end
        end
      end
    end
  endtask

  // Word at (b, r, c) as a read sees it through the array faults.
  function automatic logic [DATA_W-1:0] array_read(input integer b, input integer r, input integer c);
    logic [DATA_W-1:0] x;
    integer f;
    integer k;
    begin
      k = spare_of(b, r, c);
      if (k >= 0) begin
        n_spare = n_spare + 1;
        return spr_mem[k][(k < hsl_pkg::SPR_N) ? c : (r % 16)];
      end
      x = mem[b][r][c];
      for (f = 0; f < NFLT; f = f + 1) begin
        if ((flt_vb[f] == b) && (flt_vr[f] == r) && (flt_vc[f] == c)) begin
          if (flt_kind[f] == F_SA) x[flt_vk[f]] = (flt_val[f] != 0);
          if ((flt_kind[f] == F_CFST) &&
              (mem[flt_ab[f]][flt_ar[f]][flt_ac[f]][flt_ak[f]] == (flt_s[f] != 0))) begin
            x[flt_vk[f]] = (flt_val[f] != 0);
          end
        end
      end
      array_read = x;
    end
  endfunction

  task automatic proto(input string what);
    begin
      if (mis_err < NMSG) begin
        $display("[DRAM] cycle %0d: %s", ccyc, what);
      end
      mis_err = mis_err + 1;
    end
  endtask

  task automatic timing(input string what, input integer bank, input integer need);
    begin
      if (tim_err < NMSG) begin
        $display("[DRAM] cycle %0d: %s on bank %0d, legal from cycle %0d", ccyc, what, bank, need);
      end
      tim_err = tim_err + 1;
    end
  endtask

  // ------------------------------------------------------------ commands
  integer bi;
  integer qi;
  integer p_at;
  always @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ccyc       = 0;
      any_at     = 0;
      mis_err    = 0;
      tim_err    = 0;
      hz_err     = 0;
      n_act      = 0;
      n_pre      = 0;
      n_prea     = 0;
      n_ref      = 0;
      n_refpb    = 0;
      n_rd       = 0;
      n_wr       = 0;
      n_ap       = 0;
      wdone_seen = 1'b0;
      wq_head    = 0;
      wq_tail    = 0;
      rq_tail    = 0;
      for (bi = 0; bi < BANK_N; bi = bi + 1) begin
        open_v[bi]   = 1'b0;
        open_row[bi] = '0;
        act_at[bi]   = 0;
        col_at[bi]   = 0;
        pre_at[bi]   = 0;
      end
    end else begin
      ccyc = ccyc + 1;

      // A burst finished on the write beats: store it at the oldest WR.
      if (wdone_tog != wdone_seen) begin
        wdone_seen = wdone_tog;
        if (wq_head == wq_tail) begin
          proto("write burst with no WR waiting for it");
        end else begin
          array_write(int'(wq_bank[wq_head % QN]), int'(wq_row[wq_head % QN]),
                      int'(wq_col[wq_head % QN]), burst_in(wdone_pins, mr_repair_en, mr_repair_lane));
          ecc_write(int'(wq_bank[wq_head % QN]), int'(wq_row[wq_head % QN]),
                    int'(wq_col[wq_head % QN]), wdone_ecc);
          wq_head = wq_head + 1;
        end
      end

      if (!pin_cke) begin
        for (bi = 0; bi < BANK_N; bi = bi + 1) begin
          open_v[bi] = 1'b0;
        end
        wq_head = wq_tail;
      end else begin
        // Column bus first: it sees the bank state from before this edge.
        if ((ccmd == CMD_RD) || (ccmd == CMD_WR)) begin
          if (!open_v[cbank]) begin
            proto($sformatf("%s to closed bank %0d", (ccmd == CMD_RD) ? "RD" : "WR", cbank));
          end
          if (ccyc < col_at[cbank]) timing("tRCD", int'(cbank), col_at[cbank]);
          if (ccyc < any_at)        timing("tRFC", int'(cbank), any_at);
          if (ccmd == CMD_WR) begin
            n_wr = n_wr + 1;
            if (wq_tail - wq_head >= QN) begin
              proto("write queue overflow");
            end
            wq_bank[wq_tail % QN] = cbank;
            wq_row[wq_tail % QN]  = open_row[cbank];
            wq_col[wq_tail % QN]  = ccol;
            wq_tail = wq_tail + 1;
            p_at = imax(pre_at[cbank], ccyc + WL + 1 + tWR);
          end else begin
            n_rd = n_rd + 1;
            for (qi = wq_head; qi < wq_tail; qi = qi + 1) begin
              if ((wq_bank[qi % QN] == cbank) && (wq_row[qi % QN] == open_row[cbank]) &&
                  (wq_col[qi % QN] == ccol)) begin
                if (hz_err < NMSG) begin
                  $display("[DRAM] cycle %0d: RD bank %0d col %0d before its write data", ccyc,
                           cbank, ccol);
                end
                hz_err = hz_err + 1;
              end
            end
            if (rq_tail - rq_head >= QN) begin
              proto("read queue overflow");
            end
            rq_word[rq_tail % QN] = array_read(int'(cbank), int'(open_row[cbank]), int'(ccol));
            rq_ecc[rq_tail % QN]  = ecc_read(int'(cbank), int'(open_row[cbank]), int'(ccol));
            if (bug_refdis && (ccyc - refpb_cyc[cbank] <= bug_win)) begin
              rq_word[rq_tail % QN][5] = ~rq_word[rq_tail % QN][5];
              n_bug = n_bug + 1;
            end
            rq_due[rq_tail % QN]  = rcyc + RL_RDQS;
            rq_tail = rq_tail + 1;
            p_at = imax(pre_at[cbank], ccyc + tRTP);
          end
          pre_at[cbank] = p_at;
          if (cap) begin
            // Internal precharge on the first edge a PRE would be legal.
            n_ap = n_ap + 1;
            open_v[cbank] = 1'b0;
            act_at[cbank] = imax(act_at[cbank], p_at + tRP);
          end
        end else if (ccmd != CMD_NOP) begin
          proto($sformatf("command %0d on the column bus", ccmd));
        end

        case (rcmd)
          CMD_NOP: ;
          CMD_ACT: begin
            n_act = n_act + 1;
            if (open_v[rbank]) proto($sformatf("ACT to open bank %0d", rbank));
            if (ccyc < act_at[rbank]) timing("ACT (tRP / tRC / tRFCpb)", int'(rbank), act_at[rbank]);
            if (ccyc < any_at)        timing("tRFC", int'(rbank), any_at);
            open_v[rbank]   = 1'b1;
            open_row[rbank] = rrow;
            col_at[rbank]   = ccyc + tRCD;
            pre_at[rbank]   = ccyc + tRAS;
            act_at[rbank]   = ccyc + tRC;
          end
          CMD_PRE: begin
            n_pre = n_pre + 1;
            if (open_v[rbank]) begin
              if (ccyc < pre_at[rbank]) timing("PRE (tRAS / tRTP / tWR)", int'(rbank), pre_at[rbank]);
              open_v[rbank] = 1'b0;
              act_at[rbank] = imax(act_at[rbank], ccyc + tRP);
            end
          end
          CMD_PREA: begin
            n_prea = n_prea + 1;
            for (bi = 0; bi < BANK_N; bi = bi + 1) begin
              if (open_v[bi]) begin
                if (ccyc < pre_at[bi]) timing("PREA (tRAS / tRTP / tWR)", bi, pre_at[bi]);
                open_v[bi] = 1'b0;
                act_at[bi] = imax(act_at[bi], ccyc + tRP);
              end
            end
          end
          CMD_REF: begin
            n_ref = n_ref + 1;
            for (bi = 0; bi < BANK_N; bi = bi + 1) begin
              if (open_v[bi]) proto($sformatf("REF with bank %0d open", bi));
              if (ccyc < act_at[bi]) timing("REF (tRP)", bi, act_at[bi]);
            end
            if (ccyc < any_at) timing("tRFC", 0, any_at);
            any_at = ccyc + tRFC;
          end
          CMD_REFPB: begin
            n_refpb = n_refpb + 1;
            refpb_cyc[rbank] = ccyc;
            if (open_v[rbank]) proto($sformatf("REFPB to open bank %0d", rbank));
            if (ccyc < act_at[rbank]) timing("REFPB (tRP / tRFCpb)", int'(rbank), act_at[rbank]);
            if (ccyc < any_at)        timing("tRFC", int'(rbank), any_at);
            act_at[rbank] = imax(act_at[rbank], ccyc + tRFCpb);
          end
          default: proto($sformatf("command %0d on the row bus", rcmd));
        endcase
      end
    end
  end

  // ------------------------------------------------------------ write beats
  always @(negedge pin_ck or negedge rst_n) begin
    if (!rst_n) begin
      wcap_half  <= 1'b0;
      wcap_lo    <= '0;
      wdone_tog  <= 1'b0;
      wdone_pins <= '0;
      wdone_ecc  <= '0;
      wcap_lo_e  <= '0;
      wdqs_err   <= 0;
    end else if (pin_tx_dv) begin
      if (pin_tx_dqs !== {{(DDR_BITS-1){1'b0}}, 1'b1}) begin
        wdqs_err <= wdqs_err + 1;
      end
      if (!wcap_half) begin
        wcap_lo   <= pin_tx_beat;
        wcap_lo_e <= pin_tx_ecc;
        wcap_half <= 1'b1;
      end else begin
        wdone_pins <= {pin_tx_beat, wcap_lo};
        wdone_ecc  <= {pin_tx_ecc, wcap_lo_e};
        wdone_tog  <= ~wdone_tog;
        wcap_half  <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------ read beats
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
      pin_rx_ecc   <= '0;
      rx_hi_e      <= '0;
      pin_rx_dv    <= 1'b0;
    end else begin
      rcyc        <= rcyc + 1;
      pin_rx_beat <= '0;
      pin_rx_ecc  <= '0;
      pin_rx_dv   <= 1'b0;
      rx_last_dv  <= 1'b0;
      if (rx_phase) begin
        pin_rx_beat <= rx_hi;
        pin_rx_ecc  <= rx_hi_e;
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
        pin_rx_ecc   <= rq_ecc[rq_head % QN][3:0];
        pin_rx_dv    <= 1'b1;
        rx_hi        <= pins[WORD_PW-1:BEAT_W];
        rx_hi_e      <= rq_ecc[rq_head % QN][7:4];
        rx_phase     <= 1'b1;
        rx_last_byte <= enc[DATA_W-1 -: DQ_W];
        rq_head      <= rq_head + 1;
      end
    end
  end

  wire unused_pins = ^{TDQSCK_PS};
endmodule

`default_nettype wire
