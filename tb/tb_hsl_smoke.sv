// Chip-level tests. The memory controller is Mini DRAM Controller v4: a host
// request port with posted writes and in-order responses.
//   SMOKE  CSRs, reset values, the request port (closed without the PHY,
//          15 response tags, soft reset)
//   T1     training FSM
//   T2     DRAM commands at the CA pins and their spacing, per-bank refresh
//   T3     random traffic against the reference memory, host backpressure
//   T4     posted write, read answered from the write queue, read from DRAM
//   T5     DBI-DC at the pins
//   T7     lane shift at the pins
//   T8     PRBS compare, parallel loopback
//   T9     DBI-AC at the pins, DBI on read data
//   T10    lane BIST, repair, retest
//   T11    read leveling against per-lane eyes
//   T12    mission datapath: the old 16 WR + 16 RD pattern, one read, a read
//          stream, DBI-AC with a repaired lane, channel-model checks
// Every host response is checked against a reference memory (scoreboard).
// Controller half-period is CTRL_PERIOD_PS/2 = 625 ps (800 MHz).
`timescale 1ns/100fs
`default_nettype none

module tb_hsl_smoke;
  import hsl_pkg::*;
  import dram_pkg::*;

  localparam logic [31:0] BYP = 32'h1 << CTRL_TRAIN_BYPASS;

  logic clk;
  logic rst_n;
  logic cfg_we;
  logic [7:0] cfg_addr;
  logic [31:0] cfg_wdata;
  logic [31:0] cfg_rdata;
  logic req_valid;
  logic req_ready;
  logic req_write;
  logic [ADDR_W-1:0] req_addr;
  logic [DATA_W-1:0] req_wdata;
  logic rsp_valid;
  logic rsp_ready = 1'b1;
  logic [DATA_W-1:0] rsp_rdata;
  logic rsp_err;
  logic pin_ck;
  logic pin_cke;
  logic [RCA_W-1:0]    pin_rca;
  logic [CCA_W-1:0]    pin_cca;
  logic [BEAT_W-1:0]   pin_tx_beat;
  logic [DDR_BITS-1:0] pin_tx_dqs;
  logic                pin_tx_dv;
  logic                pin_rdqs;
  logic [BEAT_W-1:0]   dram_rx_beat;
  logic                dram_rx_dv;
  wire  [BEAT_W-1:0]   beat_to_dram;
  wire  [BEAT_W-1:0]   beat_to_phy;
  wire  [DQ_W*RX_DLY_W-1:0] rx_dly_code; // chip -> analog delay lines (model)

  integer errors;
  integer block_errors;
  logic block_done;
  logic [31:0] rdata;
  logic [3:0] st;

  logic        mr_dbi_en;
  logic        mr_dbi_ac;
  logic        mr_repair_en;
  logic [3:0]  mr_repair_lane;
  logic [PIN_W-1:0] fault_mask; // stuck pins on the link, both directions, every UI
  logic [PIN_W-1:0] fault_val;
  logic [DQ_W*RX_DLY_W-1:0] eye_lo;      // per-lane eye in delay codes
  logic [DQ_W*RX_DLY_W-1:0] eye_hi;

  logic rsp_stall = 1'b0; // hold every response
  logic rsp_rand  = 1'b0; // take a response three clocks in four

  hsl_base_die_lite dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
    .req_valid(req_valid), .req_ready(req_ready), .req_write(req_write),
    .req_addr(req_addr), .req_wdata(req_wdata),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp_rdata(rsp_rdata), .rsp_err(rsp_err),
    .pin_ck(pin_ck), .pin_cke(pin_cke),
    .pin_rca(pin_rca), .pin_cca(pin_cca),
    .pin_tx_beat(pin_tx_beat), .pin_tx_dqs(pin_tx_dqs), .pin_tx_dv(pin_tx_dv),
    .pin_rdqs(pin_rdqs), .pin_rx_beat(beat_to_phy), .pin_rx_dv(dram_rx_dv),
    .rx_dly_code(rx_dly_code)
  );

  dram_channel_behav u_dram (
    .clk(clk), .rst_n(rst_n),
    .pin_ck(pin_ck), .pin_cke(pin_cke),
    .mr_dbi_en(mr_dbi_en), .mr_dbi_ac(mr_dbi_ac),
    .mr_repair_en(mr_repair_en), .mr_repair_lane(mr_repair_lane),
    .rx_dly(rx_dly_code), .eye_lo(eye_lo), .eye_hi(eye_hi),
    .pin_rca(pin_rca), .pin_cca(pin_cca),
    .pin_tx_beat(beat_to_dram), .pin_tx_dqs(pin_tx_dqs), .pin_tx_dv(pin_tx_dv),
    .pin_rdqs(pin_rdqs), .pin_rx_beat(dram_rx_beat), .pin_rx_dv(dram_rx_dv)
  );

  assign beat_to_dram = (pin_tx_beat & ~{DDR_BITS{fault_mask}}) | ({DDR_BITS{fault_val}} & {DDR_BITS{fault_mask}});
  assign beat_to_phy  = (dram_rx_beat & ~{DDR_BITS{fault_mask}}) | ({DDR_BITS{fault_val}} & {DDR_BITS{fault_mask}});

  tb_hsl_blocks u_blocks (
    .errors(block_errors),
    .done(block_done)
  );

  initial clk = 1'b0;
  always #625ps clk = ~clk;

  always @(negedge clk) begin
    rsp_ready <= !rsp_stall && (!rsp_rand || (($urandom % 4) != 0));
  end

  // ---------------------------------------------------------------------------
  // Scoreboard. A request taken on the host port records what its response
  // must carry: a read expects the reference word for its address, as left by
  // the host writes taken before it. Responses come back in request order.
  // With sb_on = 0 (PRBS payload, loopback, an unrepaired shift) a write makes
  // its address unknown and a read is logged but not compared.
  // ---------------------------------------------------------------------------
  localparam int SBN = 256;
  logic [DATA_W-1:0] ref_mem [0:(1<<ADDR_W)-1];
  bit                ref_ok  [0:(1<<ADDR_W)-1];
  logic              sb_rd   [0:SBN-1];
  logic              sb_chk  [0:SBN-1];
  logic [DATA_W-1:0] sb_exp  [0:SBN-1];
  logic [ADDR_W-1:0] sb_adr  [0:SBN-1];
  integer            sb_wp     = 0;
  integer            sb_rp     = 0;
  integer            sb_err    = 0;
  integer            sb_chkd   = 0; // reads compared
  integer            sb_nrd    = 0; // reads taken
  integer            sb_acc    = 0; // cycle the last request was taken
  logic              sb_on;
  logic [DATA_W-1:0] rsp_log [0:255]; // read data in order
  integer            rsp_n   = 0;
  integer            rsp_cyc = 0;
  integer            tb_cyc  = 0;

  always @(posedge clk) begin
    tb_cyc <= tb_cyc + 1;
    if (req_valid && req_ready) begin
      sb_rd[sb_wp % SBN]  <= !req_write;
      sb_chk[sb_wp % SBN] <= sb_on && !req_write && ref_ok[req_addr];
      sb_exp[sb_wp % SBN] <= ref_mem[req_addr];
      sb_adr[sb_wp % SBN] <= req_addr;
      if (req_write) begin
        ref_mem[req_addr] <= req_wdata;
        ref_ok[req_addr]  <= sb_on;
      end else begin
        sb_nrd <= sb_nrd + 1;
      end
      sb_wp  <= sb_wp + 1;
      sb_acc <= tb_cyc;
    end
    if (rsp_valid && rsp_ready) begin
      if (sb_rp == sb_wp) begin
        $display("[SB] response with no request open");
        sb_err <= sb_err + 1;
      end else begin
        if (sb_chk[sb_rp % SBN]) begin
          sb_chkd <= sb_chkd + 1;
          if (rsp_rdata !== sb_exp[sb_rp % SBN]) begin
            if (sb_err < 8) begin
              $display("[SB] read %h: %h, expected %h", sb_adr[sb_rp % SBN], rsp_rdata,
                       sb_exp[sb_rp % SBN]);
            end
            sb_err <= sb_err + 1;
          end
        end
        if (sb_rd[sb_rp % SBN]) begin
          rsp_log[rsp_n % 256] <= rsp_rdata;
          rsp_n   <= rsp_n + 1;
          rsp_cyc <= tb_cyc;
        end
        sb_rp <= sb_rp + 1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Pin monitors.
  // ---------------------------------------------------------------------------
  // CA log, sampled like the channel model (negedge clk), stamped with tb_cyc.
  logic        ca_on;
  integer      rl_n;
  logic [2:0]  rl_cmd  [0:255];
  logic [1:0]  rl_bank [0:255];
  logic [7:0]  rl_row  [0:255];
  integer      rl_cyc  [0:255];
  integer      cl_n;
  logic [2:0]  cl_cmd  [0:255];
  logic [1:0]  cl_bank [0:255];
  logic [3:0]  cl_col  [0:255];
  integer      cl_cyc  [0:255];

  always @(negedge clk) begin
    if (ca_on && pin_cke) begin
      if ((pin_rca[RCA_W-1 -: 3] != 3'b000) && (rl_n < 256)) begin
        rl_cmd[rl_n]  <= pin_rca[RCA_W-1 -: 3];
        rl_bank[rl_n] <= pin_rca[ROW_W +: BANK_W];
        rl_row[rl_n]  <= pin_rca[ROW_W-1:0];
        rl_cyc[rl_n]  <= tb_cyc;
        rl_n          <= rl_n + 1;
      end
      if ((pin_cca[CCA_W-1 -: 3] != 3'b000) && (cl_n < 256)) begin
        cl_cmd[cl_n]  <= pin_cca[CCA_W-1 -: 3];
        cl_bank[cl_n] <= pin_cca[COL_W+1 +: BANK_W];
        cl_col[cl_n]  <= pin_cca[1 +: COL_W];
        cl_cyc[cl_n]  <= tb_cyc;
        cl_n          <= cl_n + 1;
      end
    end
  end

  // TX beats in the middle of each beat (negedge pin_ck, as the model). With
  // tx_on the beats are kept for the exact-pin checks. With mon_on each UI
  // adds its DQ + DBI toggles against the UI before it on the pins (the last
  // UI of the beat before, or the idle bus, 0) and its DQ + DBI pins at 1.
  // With the AC rule on, a UI with more than DQ_W/2 DQ toggles is a
  // violation; with the DC rule on, a UI with more than DQ_W/2 ones.
  // DDR_BITS = 2: a beat is UI 0 (low bits) and UI 1.
  logic              tx_on;
  integer            tx_n;
  logic [BEAT_W-1:0] txb [0:63];
  logic              mon_on;
  logic              mon_dc;
  logic              mon_ac;
  logic              mon_pdv   = 1'b0;
  logic [PIN_W-1:0]  mon_last  = '0;
  integer            mon_beats = 0;
  integer            mon_ui    = 0;
  integer            mon_tog   = 0;
  integer            mon_high  = 0;
  integer            mon_bad   = 0;
  integer            rd_dbi1   = 0;

  always @(negedge pin_ck) begin : tx_mon
    logic [PIN_W-1:0] ui0;
    logic [PIN_W-1:0] ui1;
    logic [PIN_W-1:0] prev;
    integer           tg;
    integer           hi;
    integer           bd;
    if (pin_tx_dv) begin
      if (tx_on && (tx_n < 64)) begin
        txb[tx_n] <= pin_tx_beat;
        tx_n      <= tx_n + 1;
      end
      ui0  = pin_tx_beat[PIN_W-1:0];
      ui1  = pin_tx_beat[BEAT_W-1:PIN_W];
      prev = mon_pdv ? mon_last : '0;
      tg = $countones(ui0[DBI_LSB:0] ^ prev[DBI_LSB:0]) + $countones(ui1[DBI_LSB:0] ^ ui0[DBI_LSB:0]);
      hi = $countones(ui0[DBI_LSB:0]) + $countones(ui1[DBI_LSB:0]);
      bd = 0;
      if (mon_ac && ($countones(ui0[DQ_W-1:0] ^ prev[DQ_W-1:0]) > DQ_W / 2)) bd = bd + 1;
      if (mon_ac && ($countones(ui1[DQ_W-1:0] ^ ui0[DQ_W-1:0]) > DQ_W / 2)) bd = bd + 1;
      if (mon_dc && ($countones(ui0[DQ_W-1:0]) > DQ_W / 2)) bd = bd + 1;
      if (mon_dc && ($countones(ui1[DQ_W-1:0]) > DQ_W / 2)) bd = bd + 1;
      if (mon_on) begin
        mon_beats <= mon_beats + 1;
        mon_ui    <= mon_ui + DDR_BITS;
        mon_tog   <= mon_tog + tg;
        mon_high  <= mon_high + hi;
        mon_bad   <= mon_bad + bd;
      end
      mon_last <= ui1;
      mon_pdv  <= 1'b1;
    end else begin
      mon_pdv <= 1'b0;
    end
  end

  // Read UIs the channel model sent with DBI = 1 (the RX has to undo them),
  // where the chip captures them (rising RDQS).
  always @(posedge pin_rdqs) begin
    if (dram_rx_dv) begin
      rd_dbi1 <= rd_dbi1 + (beat_to_phy[DBI_LSB] ? 1 : 0) + (beat_to_phy[PIN_W + DBI_LSB] ? 1 : 0);
    end
  end

  // Data-bus use at the controller's DFI side.
  logic   bus_on  = 1'b0;
  integer bus_cyc = 0;
  integer bus_wr  = 0;
  integer bus_rd  = 0;
  integer rv_cyc  = -1; // first rddata_valid since rv_arm
  logic   rv_arm  = 1'b0;

  always @(posedge clk) begin
    if (bus_on) begin
      bus_cyc <= bus_cyc + 1;
      if (dut.dfi_wrdata_en)    bus_wr <= bus_wr + 1;
      if (dut.dfi_rddata_valid) bus_rd <= bus_rd + 1;
    end
    if (rv_arm && dut.dfi_rddata_valid && (rv_cyc < 0)) begin
      rv_cyc <= tb_cyc;
    end
  end

  // ---------------------------------------------------------------------------
  // CSR and host-port tasks.
  // ---------------------------------------------------------------------------
  task automatic wait_cycles(input integer n);
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) @(posedge clk);
    end
  endtask

  task automatic csr_write(input logic [7:0] addr, input logic [31:0] data);
    begin
      @(negedge clk);
      cfg_we = 1'b1;
      cfg_addr = addr;
      cfg_wdata = data;
      @(negedge clk);
      cfg_we = 1'b0;
    end
  endtask

  task automatic csr_read(input logic [7:0] addr, output logic [31:0] data);
    begin
      @(negedge clk);
      cfg_we = 1'b0;
      cfg_addr = addr;
      #1ps;
      data = cfg_rdata;
    end
  endtask

  task automatic expect_eq(input logic [31:0] got, input logic [31:0] exp, input integer tag);
    begin
      if (got !== exp) begin
        $display("[SMOKE] mismatch tag %0d got %h exp %h", tag, got, exp);
        errors = errors + 1;
      end
    end
  endtask

  // One request, held until the controller takes it. Calls back to back send
  // one request per clock. req_ready only changes on posedge, so the value
  // just after negedge is the one the next posedge uses.
  task automatic host_send(input logic wr, input logic [ADDR_W-1:0] a, input logic [DATA_W-1:0] d);
    integer guard;
    begin
      if (clk !== 1'b0) @(negedge clk);
      req_valid = 1'b1;
      req_write = wr;
      req_addr  = a;
      req_wdata = d;
      #1ps;
      guard = 0;
      while ((req_ready !== 1'b1) && (guard < 4000)) begin
        @(negedge clk);
        #1ps;
        guard = guard + 1;
      end
      if (guard >= 4000) begin
        $display("[TB] request to %h not taken", a);
        errors = errors + 1;
      end
      @(negedge clk);
      req_valid = 1'b0;
    end
  endtask

  task automatic host_write(input logic [ADDR_W-1:0] a, input logic [DATA_W-1:0] d);
    host_send(1'b1, a, d);
  endtask

  task automatic host_read(input logic [ADDR_W-1:0] a);
    host_send(1'b0, a, '0);
  endtask

  // Every request answered, both controller queues empty, and time for the
  // last write burst to reach the channel model.
  task automatic host_idle();
    integer guard;
    begin
      guard = 0;
      while (((sb_rp != sb_wp) || (dut.mc_q_empty !== 1'b1)) && (guard < 8000)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (guard >= 8000) begin
        $display("[TB] controller not idle: %0d requests unanswered", sb_wp - sb_rp);
        errors = errors + 1;
      end
      wait_cycles(10);
    end
  endtask

  // Soft reset, then mission mode by bypass with the PHY off. The controller
  // and PHY restart with every bank closed (CKE low closes them in the
  // model); the CSRs keep their values. Call it with the controller idle.
  task automatic soft_reset();
    begin
      csr_write(CSR_CTRL, BYP | (32'h1 << CTRL_SOFT_RST));
      wait_cycles(3);
      csr_write(CSR_CTRL, BYP);
      wait_cycles(4);
    end
  endtask

  task automatic arm_mission(input logic [31:0] extra);
    begin
      csr_write(CSR_CTRL, BYP | (32'h1 << CTRL_PHY_EN) | extra);
      wait_cycles(4);
    end
  endtask

  // ---------------------------------------------------------------------------
  // SMOKE
  // ---------------------------------------------------------------------------
  task automatic run_smoke();
    integer i;
    integer n;
    integer e0;
    begin
      e0 = sb_err;
      csr_read(CSR_ID, rdata);
      expect_eq(rdata, HSL_ID, 1);
      csr_read(CSR_VERSION, rdata);
      expect_eq(rdata, HSL_VERSION, 2);
      csr_read(CSR_TIMING0, rdata);
      expect_eq(rdata, TIMING0_DEFAULT, 3);
      csr_read(CSR_TIMING1, rdata);
      expect_eq(rdata, TIMING1_DEFAULT, 4);
      csr_read(8'h3C, rdata);
      expect_eq(rdata, 32'h0, 5);
      csr_read(CSR_ERRCNT, rdata);
      expect_eq(rdata, 32'h0, 6);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_RESET}, 7);
      expect_eq({31'h0, rdata[STAT_TRAIN_DONE]}, 32'h0, 8);
      expect_eq({31'h0, pin_cke}, 32'h0, 9);
      expect_eq({31'h0, req_ready}, 32'h0, 10);
      expect_eq({31'h0, pin_ck}, 32'h0, 11);
      expect_eq({31'h0, pin_tx_dv}, 32'h0, 12);
      expect_eq({31'h0, rsp_valid}, 32'h0, 13);

      // TIMING0/1 are read-only.
      csr_write(CSR_TIMING0, 32'hFFFF_FFFF);
      csr_read(CSR_TIMING0, rdata);
      expect_eq(rdata, TIMING0_DEFAULT, 131);

      csr_write(CSR_CTRL, BYP);
      wait_cycles(4);
      csr_read(CSR_CTRL, rdata);
      expect_eq(rdata, BYP, 14);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_MISSION}, 15);
      expect_eq({31'h0, rdata[STAT_TRAIN_DONE]}, 32'h1, 16);
      expect_eq({31'h0, rdata[STAT_MISSION]}, 32'h1, 17);
      expect_eq({31'h0, pin_cke}, 32'h1, 18);
      // Mission mode with the PHY off: the request port stays closed.
      expect_eq({31'h0, req_ready}, 32'h0, 19);
      expect_eq({31'h0, pin_ck}, 32'h0, 191);

      // CTRL bit 5 (the old phy_bypass) is reserved.
      csr_write(CSR_CTRL, BYP | (32'h1 << 5));
      csr_read(CSR_CTRL, rdata);
      expect_eq(rdata, BYP, 192);

      arm_mission(32'h0);
      expect_eq({31'h0, req_ready}, 32'h1, 193);

      // With responses held, fifteen requests fill the response tags and the
      // sixteenth waits.
      rsp_stall = 1'b1;
      wait_cycles(2);
      n = 0;
      @(negedge clk);
      for (i = 0; i < 40; i = i + 1) begin
        req_valid = 1'b1;
        req_write = 1'b1;
        req_addr  = host_addr(2'd0, 8'hF0, 4'(n));
        req_wdata = 32'h5100_0000 | n;
        #1ps;
        if (req_ready === 1'b1) n = n + 1;
        @(negedge clk);
      end
      req_valid = 1'b0;
      expect_eq(n, 15, 194);
      rsp_stall = 1'b0;
      host_idle();
      expect_eq(sb_rp, sb_wp, 195);

      csr_write(CSR_CTRL, BYP | (32'h1 << CTRL_SOFT_RST));
      wait_cycles(3);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_RESET}, 20);
      expect_eq({31'h0, rdata[STAT_SOFT_RST]}, 32'h1, 21);
      expect_eq({31'h0, pin_cke}, 32'h0, 22);
      expect_eq({31'h0, req_ready}, 32'h0, 221);

      csr_write(CSR_CTRL, BYP);
      wait_cycles(4);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_MISSION}, 23);
      expect_eq({31'h0, rdata[STAT_SOFT_RST]}, 32'h0, 24);
      expect_eq({31'h0, pin_cke}, 32'h1, 25);
      expect_eq({31'h0, req_ready}, 32'h0, 26);
      arm_mission(32'h0);
      expect_eq({31'h0, req_ready}, 32'h1, 27);
      expect_eq(sb_err, e0, 28);
    end
  endtask

  // ---------------------------------------------------------------------------
  // T1: training FSM.
  // ---------------------------------------------------------------------------
  task automatic pulse_done(input integer bitn);
    begin
      csr_write(CSR_TRAIN, 32'h1 << bitn);
      cfg_we = 1'b0;
      cfg_addr = CSR_STATUS;
    end
  endtask

  task automatic run_t1();
    integer i;
    integer hold;
    logic [8:0] seen;
    logic sent_zq, sent_wr, sent_rd, sent_ds;
    begin
      csr_write(CSR_CTRL, 32'h1 << CTRL_SOFT_RST);
      wait_cycles(3);
      csr_write(CSR_CTRL, 32'h0);
      wait_cycles(4);
      seen = '0;
      hold = 0;
      sent_zq = 0;
      sent_wr = 0;
      sent_rd = 0;
      sent_ds = 0;
      csr_write(CSR_TRAIN, 32'h1 << TRAIN_START);
      cfg_addr = CSR_STATUS;
      for (i = 0; i < 80; i = i + 1) begin
        @(negedge clk);
        #1ps;
        st = cfg_rdata[STAT_STATE_MSB:STAT_STATE_LSB];
        seen[st] = 1'b1;
        if (((st == TR_WRLVL) && !sent_zq) || ((st == TR_RDLVL) && !sent_wr) ||
            ((st == TR_DESKEW) && !sent_rd) ||
            (((st == TR_WRTRAIN) || (st == TR_MISSION)) && !sent_ds)) begin
          $display("[T1] state %0d reached before its done pulse", st);
          errors = errors + 1;
        end
        if ((st == TR_ZQCAL) && !sent_zq) begin
          hold = hold + 1;
          if (hold >= 3) begin
            pulse_done(TRAIN_ZQ);
            sent_zq = 1'b1;
            hold = 0;
          end
        end else if ((st == TR_WRLVL) && !sent_wr) begin
          hold = hold + 1;
          if (hold >= 3) begin
            pulse_done(TRAIN_WRLVL);
            sent_wr = 1'b1;
            hold = 0;
          end
        end else if ((st == TR_RDLVL) && !sent_rd) begin
          hold = hold + 1;
          if (hold >= 3) begin
            pulse_done(TRAIN_RDLVL);
            sent_rd = 1'b1;
            hold = 0;
          end
        end else if ((st == TR_DESKEW) && !sent_ds) begin
          hold = hold + 1;
          if (hold >= 3) begin
            pulse_done(TRAIN_DESKEW);
            sent_ds = 1'b1;
            hold = 0;
          end
        end
        if (sent_ds && (st == TR_MISSION)) i = 80;
      end
      if (!seen[TR_CKE] || !seen[TR_MRS] || !seen[TR_ZQCAL] || !seen[TR_WRLVL] ||
          !seen[TR_RDLVL] || !seen[TR_DESKEW] || !seen[TR_WRTRAIN] || !seen[TR_MISSION]) begin
        $display("[T1] states seen %b", seen);
        errors = errors + 1;
      end else begin
        $display("[T1] PASS");
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T2: DRAM commands at the CA pins. Two writes to two rows of bank 1, then
  // two reads of them, back to back: every command must use the controller's
  // code on the right bus and keep its same-bank spacing at the pins. Then an
  // idle window must carry one REFpb per tREFIpb, the banks in turn.
  // ---------------------------------------------------------------------------
  // First command on a bus after cycle c0 with this code and bank (and row or
  // column, unless rc < 0): its cycle, or -1.
  function automatic integer row_find(input integer c0, input integer cmd, input integer bank,
                                      input integer rc);
    integer i;
    begin
      row_find = -1;
      for (i = rl_n - 1; i >= 0; i = i - 1) begin
        if ((rl_cyc[i] > c0) && (int'(rl_cmd[i]) == cmd) && (int'(rl_bank[i]) == bank) &&
            ((rc < 0) || (int'(rl_row[i]) == rc))) begin
          row_find = rl_cyc[i];
        end
      end
    end
  endfunction

  function automatic integer col_find(input integer c0, input integer cmd, input integer bank,
                                      input integer rc);
    integer i;
    begin
      col_find = -1;
      for (i = cl_n - 1; i >= 0; i = i - 1) begin
        if ((cl_cyc[i] > c0) && (int'(cl_cmd[i]) == cmd) && (int'(cl_bank[i]) == bank) &&
            ((rc < 0) || (int'(cl_col[i]) == rc))) begin
          col_find = cl_cyc[i];
        end
      end
    end
  endfunction

  // Last row-bus command with this code and bank strictly between lo and hi.
  function automatic integer row_last(input integer lo, input integer hi, input integer cmd,
                                      input integer bank);
    integer i;
    begin
      row_last = -1;
      for (i = 0; i < rl_n; i = i + 1) begin
        if ((rl_cyc[i] > lo) && (rl_cyc[i] < hi) && (int'(rl_cmd[i]) == cmd) &&
            (int'(rl_bank[i]) == bank)) begin
          row_last = rl_cyc[i];
        end
      end
    end
  endfunction

  task automatic gap_check(input string what, input integer from, input integer to,
                           input integer need, inout integer bad);
    begin
      if ((from < 0) || (to < 0) || ((to - from) < need)) begin
        $display("[T2] %s: cycles %0d -> %0d, needs %0d", what, from, to, need);
        bad = bad + 1;
      end
    end
  endtask

  task automatic run_t2();
    integer bad;
    integer e0;
    integer n0;
    integer a1, w1, p1, a2, w2, p2, a3, r1, p3, a4, r2;
    integer b;
    integer i;
    integer nref [0:3];
    integer c0;
    begin
      bad = 0;
      e0 = sb_err;
      soft_reset();
      arm_mission(32'h0);
      rl_n = 0;
      cl_n = 0;
      ca_on = 1'b1;
      n0 = rsp_n;
      host_write(host_addr(2'd1, 8'h12, 4'd3), 32'hC0DE_0001);
      host_write(host_addr(2'd1, 8'h34, 4'd5), 32'hC0DE_0002);
      host_idle();
      host_read(host_addr(2'd1, 8'h12, 4'd3));
      host_read(host_addr(2'd1, 8'h34, 4'd5));
      host_idle();
      ca_on = 1'b0;

      a1 = row_find(-1, int'(CMD_ACT), 1, 'h12);
      w1 = col_find(a1, int'(CMD_WR), 1, 3);
      a2 = row_find(w1, int'(CMD_ACT), 1, 'h34);
      p1 = row_last(w1, a2, int'(CMD_PRE), 1);
      w2 = col_find(a2, int'(CMD_WR), 1, 5);
      a3 = row_find(w2, int'(CMD_ACT), 1, 'h12);
      p2 = row_last(w2, a3, int'(CMD_PRE), 1);
      r1 = col_find(a3, int'(CMD_RD), 1, 3);
      a4 = row_find(r1, int'(CMD_ACT), 1, 'h34);
      p3 = row_last(r1, a4, int'(CMD_PRE), 1);
      r2 = col_find(a4, int'(CMD_RD), 1, 5);
      gap_check("ACT -> WR (tRCD)", a1, w1, tRCD, bad);
      gap_check("WR -> PRE (WL + 1 + tWR)", w1, p1, WL + 1 + tWR, bad);
      gap_check("ACT -> PRE (tRAS)", a1, p1, tRAS, bad);
      gap_check("PRE -> ACT (tRP)", p1, a2, tRP, bad);
      gap_check("ACT -> ACT (tRC)", a1, a2, tRC, bad);
      gap_check("ACT -> WR (tRCD)", a2, w2, tRCD, bad);
      gap_check("PRE -> ACT (tRP)", p2, a3, tRP, bad);
      gap_check("ACT -> RD (tRCD)", a3, r1, tRCD, bad);
      gap_check("RD -> PRE (tRTP)", r1, p3, tRTP, bad);
      gap_check("ACT -> PRE (tRAS)", a3, p3, tRAS, bad);
      gap_check("PRE -> ACT (tRP)", p3, a4, tRP, bad);
      gap_check("ACT -> ACT (tRC)", a3, a4, tRC, bad);
      gap_check("ACT -> RD (tRCD)", a4, r2, tRCD, bad);
      $display("[T2] bank 1 at the pins: ACT +%0d WR +%0d PRE +%0d ACT +%0d WR | PRE +%0d ACT +%0d RD +%0d PRE +%0d ACT +%0d RD",
               w1 - a1, p1 - w1, a2 - p1, w2 - a2, a3 - p2, r1 - a3, p3 - r1, a4 - p3, r2 - a4);
      if ((rsp_n - n0 != 2) || (rsp_log[n0 % 256] !== 32'hC0DE_0001) ||
          (rsp_log[(n0 + 1) % 256] !== 32'hC0DE_0002)) begin
        $display("[T2] reads: %0d answers, %h %h", rsp_n - n0, rsp_log[n0 % 256],
                 rsp_log[(n0 + 1) % 256]);
        bad = bad + 1;
      end

      // Idle: one REFpb per tREFIpb, each bank once per tREFI.
      rl_n = 0;
      cl_n = 0;
      c0 = tb_cyc;
      ca_on = 1'b1;
      wait_cycles(4 * tREFI);
      ca_on = 1'b0;
      for (b = 0; b < 4; b = b + 1) nref[b] = 0;
      for (i = 0; i < rl_n; i = i + 1) begin
        if (int'(rl_cmd[i]) == int'(CMD_REFPB)) nref[rl_bank[i]] = nref[rl_bank[i]] + 1;
      end
      for (b = 0; b < 4; b = b + 1) begin
        if ((nref[b] < 3) || (nref[b] > 5)) begin
          $display("[T2] bank %0d: %0d REFpb in %0d idle cycles", b, nref[b], tb_cyc - c0);
          bad = bad + 1;
        end
      end
      $display("[T2] %0d idle cycles: REFpb per bank %0d %0d %0d %0d (tREFI %0d)", tb_cyc - c0,
               nref[0], nref[1], nref[2], nref[3], tREFI);
      if ((cl_n != 0) || (sb_err != e0)) begin
        $display("[T2] %0d column commands while idle, %0d read mismatches", cl_n, sb_err - e0);
        bad = bad + 1;
      end
      if (bad == 0) begin
        $display("[T2] PASS");
      end else begin
        errors = errors + bad;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T3: random traffic. 4 banks x 4 rows x 16 columns, written once, then
  // T3_N requests: reads and writes at random, random idle gaps, responses
  // taken three clocks in four. Row conflicts, row hits, reads answered from
  // the write queue, writes held behind reads of their address, refresh and
  // host backpressure all happen; the scoreboard checks every read.
  // ---------------------------------------------------------------------------
  localparam integer T3_N = 2000;

  function automatic logic [ADDR_W-1:0] t3_addr(input integer b, input integer r, input integer c);
    t3_addr = host_addr(2'(b), 8'(8'h80 + r), 4'(c));
  endfunction

  task automatic run_t3();
    integer bad;
    integer e0;
    integer k;
    integer b;
    integer r;
    integer c;
    integer c0;
    integer cyc;
    integer nrd0;
    integer chk0;
    integer act0, pre0, rd0, wr0, ref0;
    integer nact, nrd, nwr;
    begin
      bad = 0;
      soft_reset();
      arm_mission(32'h0);
      for (b = 0; b < 4; b = b + 1) begin
        for (r = 0; r < 4; r = r + 1) begin
          for (c = 0; c < 16; c = c + 1) begin
            host_write(t3_addr(b, r, c), $urandom);
          end
        end
      end
      host_idle();
      e0   = sb_err;
      nrd0 = sb_nrd;
      chk0 = sb_chkd;
      act0 = u_dram.n_act;
      pre0 = u_dram.n_pre;
      rd0  = u_dram.n_rd;
      wr0  = u_dram.n_wr;
      ref0 = u_dram.n_refpb;
      bus_cyc = 0;
      bus_wr  = 0;
      bus_rd  = 0;
      bus_on  = 1'b1;
      rsp_rand = 1'b1;
      c0 = tb_cyc;
      for (k = 0; k < T3_N; k = k + 1) begin
        b = $urandom % 4;
        r = $urandom % 4;
        c = $urandom % 16;
        if (($urandom % 2) == 0) begin
          host_write(t3_addr(b, r, c), $urandom);
        end else begin
          host_read(t3_addr(b, r, c));
        end
        if (($urandom % 8) == 0) begin
          wait_cycles($urandom % 6);
        end
      end
      host_idle();
      cyc = tb_cyc - c0;
      rsp_rand = 1'b0;
      bus_on   = 1'b0;
      nact = u_dram.n_act - act0;
      nrd  = u_dram.n_rd - rd0;
      nwr  = u_dram.n_wr - wr0;
      $display("[T3] %0d requests (%0d reads) in %0d cycles; DFI data bus busy %0.1f%% (%0d WR, %0d RD bursts)",
               T3_N, sb_nrd - nrd0, cyc, 100.0 * (bus_wr + bus_rd) / bus_cyc, bus_wr, bus_rd);
      $display("[T3] at the pins: %0d ACT, %0d PRE, %0d RD, %0d WR, %0d REFpb; row hits %0.1f%%; %0d reads answered from the write queue",
               nact, u_dram.n_pre - pre0, nrd, nwr, u_dram.n_refpb - ref0,
               100.0 * (nrd + nwr - nact) / (nrd + nwr), (sb_nrd - nrd0) - nrd);
      if ((sb_err != e0) || (sb_chkd - chk0 != sb_nrd - nrd0)) begin
        $display("[T3] %0d mismatches, %0d of %0d reads compared", sb_err - e0, sb_chkd - chk0,
                 sb_nrd - nrd0);
        bad = bad + 1;
      end
      if (bad == 0) begin
        $display("[T3] PASS");
      end else begin
        errors = errors + bad;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T4: a write is answered when taken (posted). A read right behind it is
  // answered from the write queue and sends no RD to the pins; once the write
  // has gone out, a read of the same word comes back from the channel model.
  // ---------------------------------------------------------------------------
  task automatic run_t4();
    integer n0;
    integer rd0;
    logic   fwd_ok;
    logic   dram_ok;
    begin
      soft_reset();
      arm_mission(32'h0);
      n0  = rsp_n;
      rd0 = u_dram.n_rd;
      host_write(host_addr(2'd2, 8'h07, 4'd1), 32'hA5A5_5A5A);
      host_read(host_addr(2'd2, 8'h07, 4'd1));
      host_idle();
      fwd_ok = (u_dram.n_rd == rd0) && (rsp_n - n0 == 1) && (rsp_log[n0 % 256] === 32'hA5A5_5A5A);
      host_read(host_addr(2'd2, 8'h07, 4'd1));
      host_idle();
      dram_ok = (u_dram.n_rd == rd0 + 1) && (rsp_n - n0 == 2) &&
                (rsp_log[(n0 + 1) % 256] === 32'hA5A5_5A5A);
      if (!fwd_ok || !dram_ok) begin
        $display("[T4] RD at the pins %0d, answers %0d: %h %h", u_dram.n_rd - rd0, rsp_n - n0,
                 rsp_log[n0 % 256], rsp_log[(n0 + 1) % 256]);
        errors = errors + 1;
      end else begin
        $display("[T4] PASS");
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T5: DBI-DC at the pins. Beat 0 (1F) has 5 ones and goes out inverted with
  // DBI = 1; beat 1 (0F) has 4 and stays. One burst = two PHY beats.
  // ---------------------------------------------------------------------------
  task automatic run_t5();
    begin
      soft_reset();
      arm_mission(32'h1 << CTRL_DBI_EN);
      tx_n = 0;
      tx_on = 1'b1;
      host_write(host_addr(2'd1, 8'h02, 4'd2), 32'h0000_0F1F);
      host_idle();
      tx_on = 1'b0;
      if ((tx_n != 2) || (txb[0] !== {10'h00F, 10'h1E0}) || (txb[1] !== '0)) begin
        $display("[T5] %0d beats: %h %h", tx_n, txb[0], txb[1]);
        errors = errors + 1;
      end else begin
        $display("[T5] PASS");
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T7: shift repair at the pins (chip side only, so the channel model stores
  // these words wrong and the scoreboard leaves them out). REMAP lane 3: DQ3
  // idles, lanes 3-7 use the next pin up, the DBI pin carries DQ7 and RED
  // carries DBI, so UI 0 = FF goes out as {RED 0, DBI 1, DQ F7} = 1F7. Lane 8
  // (the DBI pin) with DBI on: FF goes out as 00 + DBI 1 and DBI moves to RED
  // = 200. Lane 15: no shift.
  // ---------------------------------------------------------------------------
  task automatic t7_wr(input logic [3:0] col, input logic [PIN_W-1:0] exp, output logic ok);
    begin
      tx_n = 0;
      tx_on = 1'b1;
      host_write(host_addr(2'd2, 8'h04, col), 32'h0000_00FF);
      host_idle();
      tx_on = 1'b0;
      ok = (tx_n == 2) && (txb[0] === {10'h000, exp}) && (txb[1] === '0);
      if (!ok) begin
        $display("[T7] col %0d: %0d beats %h %h, UI 0 expected %h", col, tx_n, txb[0], txb[1], exp);
      end
    end
  endtask

  task automatic run_t7();
    logic ok3;
    logic ok8;
    logic ok15;
    begin
      soft_reset();
      arm_mission(32'h0);
      sb_on = 1'b0;
      csr_write(CSR_REMAP, {24'h0, 4'd3, 3'b0, 1'b1});
      t7_wr(4'h3, 10'h1F7, ok3);
      arm_mission(32'h1 << CTRL_DBI_EN);
      csr_write(CSR_REMAP, {24'h0, 4'd8, 3'b0, 1'b1});
      t7_wr(4'h4, 10'h200, ok8);
      arm_mission(32'h0);
      csr_write(CSR_REMAP, {24'h0, 4'd15, 3'b0, 1'b1});
      t7_wr(4'h5, 10'h0FF, ok15);
      csr_write(CSR_REMAP, 32'h0);
      sb_on = 1'b1;
      if (ok3 && ok8 && ok15) begin
        $display("[T7] PASS");
      end else begin
        errors = errors + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T8: PRBS compare on the write data, and parallel loopback.
  // ---------------------------------------------------------------------------
  task automatic run_t8();
    integer t8bad;
    integer n0;
    integer rd0;
    begin
      t8bad = 0;
      soft_reset();
      // PRBS replaces the write data; loopback returns it, so nothing counts.
      arm_mission((32'h1 << CTRL_PRBS_EN) | (32'h1 << CTRL_LOOPBACK));
      sb_on = 1'b0;
      host_write(host_addr(2'd3, 8'h09, 4'd7), 32'h0);
      host_idle();
      csr_read(CSR_ERRCNT, rdata);
      if (rdata !== 32'h0) begin
        $display("[T8] good loopback count %h", rdata);
        t8bad = t8bad + 1;
      end
      // Without loopback the pin hook returns 0: the burst counts.
      arm_mission(32'h1 << CTRL_PRBS_EN);
      host_write(host_addr(2'd3, 8'h09, 4'd8), 32'h0);
      host_idle();
      csr_read(CSR_ERRCNT, rdata);
      if ((rdata === 32'h0) || $isunknown(rdata)) begin
        $display("[T8] mismatch was not counted (%h)", rdata);
        t8bad = t8bad + 1;
      end

      // Loopback: a RD answers with the last write burst sent and sends no
      // CA. Column 1 holds another word in the channel model, so an answer
      // from the pins would not match.
      arm_mission(32'h0);
      sb_on = 1'b1;
      host_write(host_addr(2'd3, 8'h09, 4'd1), 32'h1111_1111);
      host_idle();
      arm_mission(32'h1 << CTRL_LOOPBACK);
      host_write(host_addr(2'd3, 8'h09, 4'd2), 32'h2222_2222);
      host_idle();
      sb_on = 1'b0;
      n0  = rsp_n;
      rd0 = u_dram.n_rd;
      host_read(host_addr(2'd3, 8'h09, 4'd1));
      host_idle();
      sb_on = 1'b1;
      if ((rsp_n - n0 != 1) || (rsp_log[n0 % 256] !== 32'h2222_2222) || (u_dram.n_rd != rd0)) begin
        $display("[T8] loopback RD: %0d answers, %h (exp 22222222), %0d RD at the pins",
                 rsp_n - n0, rsp_log[n0 % 256], u_dram.n_rd - rd0);
        t8bad = t8bad + 1;
      end
      arm_mission(32'h0);

      if (t8bad == 0) begin
        $display("[T8] PASS");
      end else begin
        errors = errors + t8bad;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T9: DBI-AC at the pins and DBI on read data.
  // ---------------------------------------------------------------------------
  // PRBS7 words in hsl_prbs order (x^7 + x^6 + 1, bit 0 first), one per burst.
  function automatic logic [DATA_W-1:0] prbs7_word(input logic [6:0] st0);
    logic [6:0] t;
    integer     i;
    begin
      t = st0;
      prbs7_word = '0;
      for (i = 0; i < DATA_W; i = i + 1) begin
        prbs7_word[i] = t[6] ^ t[5];
        t = {t[5:0], t[6] ^ t[5]};
      end
    end
  endfunction

  function automatic logic [6:0] prbs7_next(input logic [6:0] st0);
    logic [6:0] t;
    integer     i;
    begin
      t = st0;
      for (i = 0; i < DATA_W; i = i + 1) begin
        t = {t[5:0], t[6] ^ t[5]};
      end
      prbs7_next = t;
    end
  endfunction

  localparam logic [ROW_W-1:0] T9_ROW = 8'h3C;
  localparam logic [31:0]      T9_DC  = 32'h1 << CTRL_DBI_EN;
  localparam logic [31:0]      T9_AC  = (32'h1 << CTRL_DBI_EN) | (32'h1 << CTRL_DBI_AC);
  localparam integer           T9_N   = 254; // two PRBS7 periods of words

  // One write stream under one DBI setting. The words alternate between
  // banks 0 and 2 (two bank groups, tCCD_S = 1), so bursts follow each other
  // on DQ with no idle UI and the AC rule reaches across burst boundaries.
  // pattern 0: PRBS7 words from seed 5A. pattern 1: AA55_AA55, beats 55 AA
  // 55 AA, so every DQ toggles every UI without DBI.
  task automatic t9_stream(
    input  logic [31:0] dbi_bits,
    input  integer      pattern,
    output integer      ui,
    output integer      tog,
    output integer      high,
    output integer      bad
  );
    integer     k;
    integer     f0;
    integer     u0;
    integer     t0;
    integer     h0;
    integer     b0;
    logic [6:0] st;
    begin
      arm_mission(dbi_bits);
      mon_dc = dbi_bits[CTRL_DBI_EN] && !dbi_bits[CTRL_DBI_AC];
      mon_ac = dbi_bits[CTRL_DBI_EN] && dbi_bits[CTRL_DBI_AC];
      f0 = mon_beats;
      u0 = mon_ui;
      t0 = mon_tog;
      h0 = mon_high;
      b0 = mon_bad;
      mon_on = 1'b1;
      st = 7'h5A;
      for (k = 0; k < T9_N; k = k + 1) begin
        host_write(host_addr((k % 2 == 0) ? 2'd0 : 2'd2, T9_ROW, 4'((k / 2) % 16)),
                   (pattern == 0) ? prbs7_word(st) : 32'hAA55_AA55);
        st = prbs7_next(st);
      end
      host_idle();
      mon_on = 1'b0;
      ui   = mon_ui - u0;
      tog  = mon_tog - t0;
      high = mon_high - h0;
      bad  = mon_bad - b0;
      if ((mon_beats - f0) != 2 * T9_N) begin
        $display("[T9] stream saw %0d of %0d write bursts", (mon_beats - f0) / 2, T9_N);
        bad = bad + 1;
      end
    end
  endtask

  // Write 16 PRBS7 words, then read them back with the channel model encoding
  // read data under (mr_en, mr_ac). The RX must undo every DBI = 1 UI; the
  // scoreboard checks the words.
  task automatic t9_readback(
    input  logic   mr_en,
    input  logic   mr_ac,
    output integer bad,
    output integer dbi1
  );
    integer     k;
    integer     e0;
    integer     c0;
    integer     d0;
    logic [6:0] st;
    begin
      e0 = sb_err;
      c0 = sb_chkd;
      mr_dbi_en = mr_en;
      mr_dbi_ac = mr_ac;
      st = 7'h21;
      for (k = 0; k < 16; k = k + 1) begin
        host_write(host_addr(2'd0, T9_ROW + 8'h01, 4'(k)), prbs7_word(st));
        st = prbs7_next(st);
      end
      host_idle();
      d0 = rd_dbi1;
      for (k = 0; k < 16; k = k + 1) begin
        host_read(host_addr(2'd0, T9_ROW + 8'h01, 4'(k)));
      end
      host_idle();
      dbi1 = rd_dbi1 - d0;
      bad  = (sb_err - e0) + ((sb_chkd - c0 == 16) ? 0 : 1);
      mr_dbi_en = 1'b0;
      mr_dbi_ac = 1'b0;
    end
  endtask

  task automatic run_t9();
    integer      t9bad;
    integer      p;
    integer      m;
    integer      ui   [0:1][0:2];
    integer      tog  [0:1][0:2];
    integer      high [0:1][0:2];
    integer      bad;
    integer      dbi1;
    logic [31:0] bits;
    begin
      t9bad = 0;
      soft_reset();

      // Exact pins. Beat 0 (0F) is 4 toggles from the idle bus and stays;
      // F0 after 0F would toggle all 8 DQ, so beats 1 and 3 go out inverted
      // and the DQ pins hold 0F.
      arm_mission(T9_AC);
      csr_read(CSR_CTRL, rdata);
      if (rdata !== (BYP | (32'h1 << CTRL_PHY_EN) | T9_AC)) begin
        $display("[T9] CTRL readback %h", rdata);
        t9bad = t9bad + 1;
      end
      tx_n = 0;
      tx_on = 1'b1;
      host_write(host_addr(2'd0, T9_ROW, 4'h2), 32'hF00F_F00F);
      host_idle();
      tx_on = 1'b0;
      if ((tx_n != 2) || (txb[0] !== {10'h10F, 10'h00F}) || (txb[1] !== {10'h10F, 10'h00F})) begin
        $display("[T9] AC pins, %0d beats: %h %h", tx_n, txb[0], txb[1]);
        t9bad = t9bad + 1;
      end

      // The same streams under off, DC, and AC.
      for (p = 0; p < 2; p = p + 1) begin
        for (m = 0; m < 3; m = m + 1) begin
          bits = (m == 0) ? 32'h0 : ((m == 1) ? T9_DC : T9_AC);
          t9_stream(bits, p, ui[p][m], tog[p][m], high[p][m], bad);
          if (bad != 0) begin
            $display("[T9] pattern %0d mode %0d: %0d rule violations", p, m, bad);
            t9bad = t9bad + 1;
          end
        end
        $display("[T9] %s x%0d, DQ+DBI per data UI: toggles off %0.2f dc %0.2f ac %0.2f, ones off %0.2f dc %0.2f ac %0.2f",
                 (p == 0) ? "PRBS7" : "55/AA", T9_N,
                 1.0 * tog[p][0] / ui[p][0], 1.0 * tog[p][1] / ui[p][1],
                 1.0 * tog[p][2] / ui[p][2],
                 1.0 * high[p][0] / ui[p][0], 1.0 * high[p][1] / ui[p][1],
                 1.0 * high[p][2] / ui[p][2]);
        // Each rule must lower its own measure.
        if ((tog[p][2] >= tog[p][0]) || ((p == 0) && (high[p][1] >= high[p][0]))) begin
          $display("[T9] pattern %0d: AC toggles %0d vs off %0d, DC ones %0d vs off %0d",
                   p, tog[p][2], tog[p][0], high[p][1], high[p][0]);
          t9bad = t9bad + 1;
        end
      end

      // Read data with DBI from the channel model, DC then AC.
      arm_mission(T9_AC);
      for (m = 0; m < 2; m = m + 1) begin
        t9_readback(1'b1, m == 1, bad, dbi1);
        if ((bad != 0) || (dbi1 == 0)) begin
          $display("[T9] readback mr_ac %0d: %0d bad, %0d read UIs with DBI 1", m, bad, dbi1);
          t9bad = t9bad + 1;
        end
      end
      arm_mission(32'h0);

      if (t9bad == 0) begin
        $display("[T9] PASS");
      end else begin
        errors = errors + t9bad;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T10: lane repair flow. A stuck pin sits on the link between the chip and
  // the channel model (both directions, like a broken bump). The lane BIST
  // finds the lane, firmware (this TB) programs REMAP on the chip and the
  // repair setting on the model, and a second run must pass.
  // ---------------------------------------------------------------------------
  localparam logic [1:0] T10_BANK = 2'd1;
  localparam logic [7:0] T10_ROW  = 8'h55;

  task automatic lane_bist(output logic [31:0] st);
    integer guard;
    begin
      csr_write(CSR_LANE_BIST, {16'h0, T10_ROW, 2'b00, T10_BANK, 4'b0001});
      guard = 0;
      st = '0;
      while (((st[0] === 1'b1) || (st[1] !== 1'b1)) && (guard < 3000)) begin
        csr_read(CSR_LANE_BIST, st);
        guard = guard + 1;
      end
    end
  endtask

  task automatic set_repair(input logic en, input logic [3:0] lane);
    begin
      csr_write(CSR_REMAP, {24'h0, lane, 3'b0, en});
      mr_repair_en   = en;
      mr_repair_lane = lane;
    end
  endtask

  // 16 writes, then 16 reads of them; the scoreboard checks the reads.
  task automatic row_traffic(
    input  logic [1:0] bank,
    input  logic [7:0] row,
    input  integer     seed,
    output integer     bad
  );
    integer k;
    integer e0;
    integer c0;
    begin
      e0 = sb_err;
      c0 = sb_chkd;
      for (k = 0; k < 16; k = k + 1) begin
        host_write(host_addr(bank, row, 4'(k)), (32'h9E37_79B9 * (seed * 16 + k + 1)) ^ {16'(k), 16'(seed)});
      end
      host_idle();
      for (k = 0; k < 16; k = k + 1) begin
        host_read(host_addr(bank, row, 4'(k)));
      end
      host_idle();
      bad = (sb_err - e0) + ((sb_chkd - c0 == 16) ? 0 : 1);
    end
  endtask

  task automatic run_t10();
    integer      t10bad;
    integer      k;
    integer      v;
    integer      found;
    integer      fixed;
    integer      bad;
    logic [31:0] st;
    begin
      t10bad = 0;
      found  = 0;
      fixed  = 0;
      soft_reset();
      arm_mission(32'h0);

      // Clean link.
      lane_bist(st);
      if ((st[2:0] !== 3'b110) || (st[15:8] !== 8'h00)) begin
        $display("[T10] clean link status %h", st);
        t10bad = t10bad + 1;
      end

      // Each DQ lane stuck at 0 and at 1: detect, repair, retest.
      for (k = 0; k < DQ_W; k = k + 1) begin
        for (v = 0; v < 2; v = v + 1) begin
          fault_mask = 10'(1) << k;
          fault_val  = (v == 1) ? fault_mask : '0;
          lane_bist(st);
          if ((st[1] === 1'b1) && (st[2] === 1'b0) && (st[3] === 1'b1) &&
              (st[7:4] === 4'(k)) && (st[15:8] === (8'(1) << k)) && (st[20:16] !== 5'd0)) begin
            found = found + 1;
          end else begin
            $display("[T10] lane %0d stuck %0d: status %h", k, v, st);
            t10bad = t10bad + 1;
          end
          set_repair(1'b1, 4'(k));
          lane_bist(st);
          if ((st[2:0] === 3'b110) && (st[15:8] === 8'h00)) begin
            fixed = fixed + 1;
          end else begin
            $display("[T10] lane %0d stuck %0d after repair: status %h", k, v, st);
            t10bad = t10bad + 1;
          end
          set_repair(1'b0, 4'd0);
        end
      end

      // Host traffic through a repaired link, DBI-AC on both directions.
      fault_mask = 10'(1) << 5;
      fault_val  = fault_mask;
      set_repair(1'b1, 4'd5);
      arm_mission((32'h1 << CTRL_DBI_EN) | (32'h1 << CTRL_DBI_AC));
      mr_dbi_en = 1'b1;
      mr_dbi_ac = 1'b1;
      row_traffic(T10_BANK, 8'h66, 10, bad);
      if (bad != 0) begin
        $display("[T10] repaired link traffic: %0d bad", bad);
        t10bad = t10bad + 1;
      end
      mr_dbi_en = 1'b0;
      mr_dbi_ac = 1'b0;
      arm_mission(32'h0);
      set_repair(1'b0, 4'd0);

      // Two bad lanes: found, but one spare cannot fix them.
      fault_mask = (10'(1) << 2) | (10'(1) << 6);
      fault_val  = 10'(1) << 2;
      lane_bist(st);
      if ((st[1] !== 1'b1) || (st[2] !== 1'b0) || (st[3] !== 1'b0) || (st[15:8] !== 8'h44)) begin
        $display("[T10] two lanes: status %h", st);
        t10bad = t10bad + 1;
      end
      fault_mask = '0;
      fault_val  = '0;

      $display("[T10] stuck-at on 8 DQ lanes x {0,1}: found %0d/16, repaired %0d/16; two lanes flagged not repairable",
               found, fixed);
      if (t10bad == 0) begin
        $display("[T10] PASS");
      end else begin
        errors = errors + t10bad;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T11: read leveling. Each DQ lane gets its own eye (a window of delay-line
  // codes where the sampler reads its own UI). The trainer sweeps the codes
  // with the lane BIST and must land every lane on the middle of its eye.
  // ---------------------------------------------------------------------------
  task automatic set_eye(input integer p, input integer lo, input integer w);
    begin
      eye_lo[p*RX_DLY_W +: RX_DLY_W] = 5'(lo);
      eye_hi[p*RX_DLY_W +: RX_DLY_W] = 5'(lo + w - 1);
    end
  endtask

  task automatic rd_train(output logic [31:0] st);
    integer guard;
    begin
      csr_write(CSR_RDTRAIN, 32'h1);
      guard = 0;
      st = '0;
      while (((st[0] === 1'b1) || (st[1] !== 1'b1)) && (guard < 40000)) begin
        csr_read(CSR_RDTRAIN, st);
        guard = guard + 1;
      end
    end
  endtask

  integer t11_lo [0:DQ_W-1];
  integer t11_w  [0:DQ_W-1];

  // Train against the eyes in t11_lo / t11_w and check code, start and width.
  // A soft reset first puts every lane back at code 16.
  task automatic t11_round(output integer bad);
    integer      p;
    string       line;
    logic [7:0]  pre_bad;
    logic [31:0] st;
    begin
      bad = 0;
      pre_bad = '0;
      soft_reset();
      arm_mission(32'h0);
      for (p = 0; p < DQ_W; p = p + 1) begin
        set_eye(p, t11_lo[p], t11_w[p]);
        if ((16 < t11_lo[p]) || (16 > t11_lo[p] + t11_w[p] - 1)) begin
          pre_bad[p] = 1'b1;
        end
      end
      // Before training every lane sits at code 16: the BIST must fail on
      // exactly the lanes whose eye leaves 16 out.
      lane_bist(st);
      if (st[15:8] !== pre_bad) begin
        $display("[T11] before training: lane errors %h, expected %h", st[15:8], pre_bad);
        bad = bad + 1;
      end
      rd_train(st);
      if ((st[1] !== 1'b1) || (st[2] !== 1'b1)) begin
        $display("[T11] training status %h", st);
        bad = bad + 1;
      end
      line = "";
      for (p = 0; p < DQ_W; p = p + 1) begin
        csr_write(CSR_RDTRAIN, {25'h0, 3'(p), 4'h0});
        csr_read(CSR_RDTRAIN, st);
        line = {line, $sformatf(" %0d:[%0d,%0d]->%0d", p, st[20:16], st[20:16] + st[29:24] - 1, st[12:8])};
        if ((st[12:8] !== 5'(t11_lo[p] + (t11_w[p] - 1) / 2)) || (st[20:16] !== 5'(t11_lo[p])) ||
            (st[29:24] !== 6'(t11_w[p]))) begin
          $display("[T11] lane %0d: code %0d eye %0d+%0d, expected code %0d eye %0d+%0d",
                   p, st[12:8], st[20:16], st[29:24], t11_lo[p] + (t11_w[p] - 1) / 2,
                   t11_lo[p], t11_w[p]);
          bad = bad + 1;
        end
      end
      $display("[T11] lane:[eye]->code%s", line);
      lane_bist(st);
      if ((st[2:0] !== 3'b110) || (st[15:8] !== 8'h00)) begin
        $display("[T11] after training: status %h", st);
        bad = bad + 1;
      end
    end
  endtask

  task automatic run_t11();
    integer      t11bad;
    integer      bad;
    integer      p;
    logic [31:0] st;
    begin
      t11bad = 0;

      // Fixed eyes: lanes 0, 2, 4, 5 leave the default code 16 out.
      t11_lo[0] = 3;  t11_w[0] = 7;   t11_lo[1] = 9;  t11_w[1] = 9;
      t11_lo[2] = 18; t11_w[2] = 8;   t11_lo[3] = 6;  t11_w[3] = 12;
      t11_lo[4] = 20; t11_w[4] = 6;   t11_lo[5] = 1;  t11_w[5] = 10;
      t11_lo[6] = 12; t11_w[6] = 5;   t11_lo[7] = 15; t11_w[7] = 11;
      t11_round(bad);
      t11bad = t11bad + bad;

      // Host traffic at the trained codes.
      row_traffic(2'd2, 8'h21, 11, bad);
      if (bad != 0) begin
        $display("[T11] traffic at the trained codes: %0d bad", bad);
        t11bad = t11bad + 1;
      end

      // Random eyes, width 3-12.
      for (p = 0; p < DQ_W; p = p + 1) begin
        t11_w[p]  = 3 + ($urandom % 10);
        t11_lo[p] = $urandom % (33 - t11_w[p]);
      end
      t11_round(bad);
      t11bad = t11bad + bad;

      // A closed eye on lane 3: training must say so.
      set_eye(3, 20, 0);
      rd_train(st);
      csr_write(CSR_RDTRAIN, {25'h0, 3'd3, 4'h0});
      csr_read(CSR_RDTRAIN, st);
      if ((st[1] !== 1'b1) || (st[2] !== 1'b0) || (st[29:24] !== 6'd0)) begin
        $display("[T11] closed eye: status %h", st);
        t11bad = t11bad + 1;
      end

      // Open every eye again and put the codes back to their reset value.
      eye_lo = '0;
      eye_hi = '1;
      soft_reset();

      if (t11bad == 0) begin
        $display("[T11] PASS");
      end else begin
        errors = errors + t11bad;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // T12: mission datapath. Latency of one read and the PHY round trip inside
  // it, a read stream across two bank groups, host traffic with DBI-AC on both
  // ends and a repaired stuck lane, and the channel model's checks.
  // ---------------------------------------------------------------------------
  task automatic run_t12();
    integer t12bad;
    integer bad;
    integer n0;
    integer k;
    integer c0;
    integer rd_pin;
    integer lat_hit;
    logic   hit;
    integer rt;
    integer cyc;
    begin
      t12bad = 0;
      soft_reset();
      arm_mission(32'h0);

      // The pattern T12 timed on the in-order controller (162 cycles at
      // 6a5a4ce): 16 writes, then 16 reads of them, to one row, sent back to
      // back. Cycles from the first write request to the last read response.
      n0 = rsp_n;
      rd_pin = u_dram.n_rd;
      c0 = tb_cyc;
      for (k = 0; k < 16; k = k + 1) begin
        host_write(host_addr(2'd3, 8'h77, 4'(k)), 32'h7700_0000 | k);
      end
      for (k = 0; k < 16; k = k + 1) begin
        host_read(host_addr(2'd3, 8'h77, 4'(k)));
      end
      host_idle();
      cyc = rsp_cyc - c0;
      if (rsp_n - n0 != 16) begin
        $display("[T12] row traffic: %0d of 16 reads answered", rsp_n - n0);
        t12bad = t12bad + 1;
      end
      $display("[T12] 16 WR + 16 RD to one row, back to back: %0d cycles from the first write request to the last read response (%0d RD at the pins)",
               cyc, u_dram.n_rd - rd_pin);

      // One read of an open row on an idle controller: request to response,
      // and inside it rt, RD on the CA pins to rddata_valid at the controller.
      // No ACT on the pins for it means the row was still open (a REFpb can
      // close the bank in between).
      host_write(host_addr(2'd3, 8'h78, 4'd0), 32'h7800_0000);
      host_idle();
      n0 = rsp_n;
      cl_n = 0;
      rl_n = 0;
      rv_cyc = -1;
      rv_arm = 1'b1;
      ca_on = 1'b1;
      host_read(host_addr(2'd3, 8'h78, 4'd0));
      host_idle();
      ca_on = 1'b0;
      rv_arm = 1'b0;
      lat_hit = rsp_cyc - sb_acc;
      rd_pin = col_find(-1, int'(CMD_RD), 3, 0);
      rt = rv_cyc - rd_pin;
      hit = (row_find(-1, int'(CMD_ACT), 3, -1) < 0);
      if ((rsp_n - n0 != 1) || (rsp_log[n0 % 256] !== 32'h7800_0000) || (rd_pin < 0)) begin
        $display("[T12] single read: %0d answers, %h", rsp_n - n0, rsp_log[n0 % 256]);
        t12bad = t12bad + 1;
      end
      if (hit) begin
        $display("[T12] one read of an open row: %0d cycles from request to response; RD on the pins to rddata_valid %0d cycles",
                 lat_hit, rt);
      end else begin
        $display("[T12] one read, bank closed by refresh first: %0d cycles from request to response; RD on the pins to rddata_valid %0d cycles",
                 lat_hit, rt);
      end

      // Read stream: 32 reads alternating banks 0 and 2 (two bank groups).
      for (k = 0; k < 32; k = k + 1) begin
        host_write(host_addr((k % 2 == 0) ? 2'd0 : 2'd2, 8'h7A, 4'((k / 2) % 16)), 32'h7A00_0000 | k);
      end
      host_idle();
      n0 = rsp_n;
      c0 = tb_cyc;
      for (k = 0; k < 32; k = k + 1) begin
        host_read(host_addr((k % 2 == 0) ? 2'd0 : 2'd2, 8'h7A, 4'((k / 2) % 16)));
      end
      host_idle();
      cyc = rsp_cyc - c0;
      if (rsp_n - n0 != 32) begin
        $display("[T12] read stream: %0d of 32 answered", rsp_n - n0);
        t12bad = t12bad + 1;
      end
      $display("[T12] 32 reads over two bank groups: %0d cycles from the first request to the last response (%0d RDs in flight at most)",
               cyc, 4);

      // DBI-AC on both ends, lane 5 stuck at 1 and repaired.
      fault_mask = 10'(1) << 5;
      fault_val  = fault_mask;
      set_repair(1'b1, 4'd5);
      mr_dbi_en = 1'b1;
      mr_dbi_ac = 1'b1;
      arm_mission((32'h1 << CTRL_DBI_EN) | (32'h1 << CTRL_DBI_AC));
      row_traffic(2'd3, 8'h7B, 12, bad);
      if (bad != 0) begin
        $display("[T12] DBI-AC with a repaired lane: %0d bad", bad);
        t12bad = t12bad + 1;
      end
      mr_dbi_en = 1'b0;
      mr_dbi_ac = 1'b0;
      arm_mission(32'h0);
      set_repair(1'b0, 4'd0);
      fault_mask = '0;
      fault_val  = '0;

      $display("[T12] channel model, whole run: %0d ACT, %0d PRE, %0d RD, %0d WR, %0d REFpb; errors: protocol %0d, timing %0d, read before its write data %0d, WDQS %0d",
               u_dram.n_act, u_dram.n_pre, u_dram.n_rd, u_dram.n_wr, u_dram.n_refpb,
               u_dram.mis_err, u_dram.tim_err, u_dram.hz_err, u_dram.wdqs_err);
      if ((u_dram.wdqs_err != 0) || (u_dram.mis_err != 0) || (u_dram.tim_err != 0) ||
          (u_dram.hz_err != 0)) begin
        t12bad = t12bad + 1;
      end
      soft_reset();
      if (t12bad == 0) begin
        $display("[T12] PASS");
      end else begin
        errors = errors + t12bad;
      end
    end
  endtask

  initial begin
    errors = 0;
    // block_errors is driven by the u_blocks output port only.
    rst_n = 1'b0;
    cfg_we = 1'b0;
    cfg_addr = '0;
    cfg_wdata = '0;
    req_valid = 1'b0;
    req_write = 1'b0;
    req_addr = '0;
    req_wdata = '0;
    sb_on = 1'b1;
    ca_on = 1'b0;
    rl_n = 0;
    cl_n = 0;
    tx_on = 1'b0;
    tx_n = 0;
    mr_dbi_en = 1'b0;
    mr_dbi_ac = 1'b0;
    mr_repair_en = 1'b0;
    mr_repair_lane = '0;
    fault_mask = '0;
    fault_val = '0;
    eye_lo = '0;
    eye_hi = '1;
    mon_on = 1'b0;
    mon_dc = 1'b0;
    mon_ac = 1'b0;
    if ((CTRL_PERIOD_PS != 1250) || (PHY_PERIOD_PS != 625) || (DESKEW_TAPS != 4)) begin
      $fatal(1, "[E12] package clock constants drifted");
    end

    wait_cycles(5);
    // Release on negedge. Releasing right after posedge races the first
    // synchronizer flop and hides one of the two release clocks.
    @(negedge clk);
    rst_n = 1'b1;
    wait_cycles(4);

    run_smoke();
    if (errors == 0) $display("[SMOKE] PASS");
    run_t1();
    run_t2();
    run_t3();
    run_t4();
    run_t5();
    run_t7();
    run_t8();
    run_t9();
    run_t10();
    run_t11();
    run_t12();

    if (sb_err != 0) begin
      $display("[SB] %0d read mismatches over the run", sb_err);
      errors = errors + 1;
    end
    $display("[SB] %0d host requests, %0d reads compared against the reference memory", sb_wp,
             sb_chkd);

    wait (block_done);
    if (block_errors != 0) errors = errors + block_errors;

    if (errors == 0) begin
      $display("[ALL] PASS");
      $finish;
    end else begin
      $display("[ALL] FAIL (%0d)", errors);
      $fatal(1, "[ALL] FAIL (%0d)", errors);
    end
  end

  initial begin
    #400000;
    $fatal(1, "[SMOKE] timeout");
  end
endmodule

`default_nettype wire
