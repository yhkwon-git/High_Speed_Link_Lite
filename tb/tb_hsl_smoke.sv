// Chip-level smoke plus T1, T4, T5, T7, T8 (PRBS compare, loopback WR->RD),
// and T9 (DBI-AC at the pins, DBI on RD data).
// Controller half-period is CTRL_PERIOD_PS/2 = 625 ps (800 MHz).
`timescale 1ns/100fs
`default_nettype none

module tb_hsl_smoke;
  import hsl_pkg::*;

  logic clk;
  logic rst_n;
  logic cfg_we;
  logic [7:0] cfg_addr;
  logic [31:0] cfg_wdata;
  logic [31:0] cfg_rdata;
  logic cmd_valid;
  logic cmd_ready;
  logic [3:0] cmd_opc;
  logic [BANK_W-1:0] cmd_bank;
  logic [ROW_W-1:0] cmd_row;
  logic [COL_W-1:0] cmd_col;
  logic [DATA_W-1:0] cmd_wdata;
  logic rsp_valid;
  logic [DATA_W-1:0] rsp_rdata;
  logic rsp_err;
  logic pin_ck;
  logic pin_cke;
  logic [7:0] pin_ca;
  logic [PIN_W-1:0] pin_dq_o;
  logic pin_dq_oe;
  logic pin_dqs_o;
  logic [PIN_W-1:0] pin_dq_i;
  logic pin_dqs_i;
  logic [PIN_W-1:0] dram_dq;
  logic dram_dqs;

  integer errors;
  integer block_errors;
  logic block_done;
  logic [31:0] rdata;
  logic [3:0] st;

  logic        cap_pins;
  logic [9:0]  caps [0:15];
  logic [7:0]  caps_ca [0:15];
  integer      ncap;
  logic        got_rsp;
  logic [31:0] got_data;
  logic        mr_dbi_en;
  logic        mr_dbi_ac;

  hsl_base_die_lite dut (
    .clk(clk), .rst_n(rst_n),
    .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .cfg_rdata(cfg_rdata),
    .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
    .cmd_opc(cmd_opc), .cmd_bank(cmd_bank), .cmd_row(cmd_row), .cmd_col(cmd_col),
    .cmd_wdata(cmd_wdata),
    .rsp_valid(rsp_valid), .rsp_rdata(rsp_rdata), .rsp_err(rsp_err),
    .pin_ck(pin_ck), .pin_cke(pin_cke), .pin_ca(pin_ca),
    .pin_dq_o(pin_dq_o), .pin_dq_oe(pin_dq_oe), .pin_dqs_o(pin_dqs_o),
    .pin_dq_i(pin_dq_i), .pin_dqs_i(pin_dqs_i)
  );

  dram_channel_behav u_dram (
    .clk(clk), .rst_n(rst_n),
    .pin_ck(pin_ck), .pin_cke(pin_cke), .pin_ca(pin_ca),
    .pin_dq_i(pin_dq_o), .pin_dq_oe(pin_dq_oe), .pin_dqs_i(pin_dqs_o),
    .mr_dbi_en(mr_dbi_en), .mr_dbi_ac(mr_dbi_ac),
    .pin_dq_o(dram_dq), .pin_dqs_o(dram_dqs)
  );

  assign pin_dq_i  = dram_dq;
  assign pin_dqs_i = dram_dqs;

  tb_hsl_blocks u_blocks (
    .errors(block_errors),
    .done(block_done)
  );

  initial clk = 1'b0;
  always #625ps clk = ~clk;

  always @(posedge clk) begin
    if (rsp_valid) begin
      got_rsp  <= 1'b1;
      got_data <= rsp_rdata;
    end
  end

  // Same edge the channel model uses, so a beat is the value launched on posedge.
  always @(negedge clk) begin
    if (cap_pins && pin_dqs_o && (ncap < 16)) begin
      caps[ncap]    <= pin_dq_o;
      caps_ca[ncap] <= pin_ca;
      ncap          <= ncap + 1;
    end
  end

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

  task automatic push_cmd(
    input logic [3:0] opc,
    input logic [BANK_W-1:0] bank,
    input logic [ROW_W-1:0] row,
    input logic [COL_W-1:0] col,
    input logic [DATA_W-1:0] data
  );
    begin
      @(negedge clk);
      cmd_valid = 1'b1;
      cmd_opc = opc;
      cmd_bank = bank;
      cmd_row = row;
      cmd_col = col;
      cmd_wdata = data;
      @(posedge clk);
      if (cmd_ready !== 1'b1) begin
        $display("[TB] push rejected opc %h", opc);
        errors = errors + 1;
      end
      @(negedge clk);
      cmd_valid = 1'b0;
    end
  endtask

  task automatic run_smoke();
    integer i;
    begin
      csr_read(CSR_ID, rdata);
      expect_eq(rdata, HSL_ID, 1);
      csr_read(CSR_VERSION, rdata);
      expect_eq(rdata, HSL_VERSION, 2);
      csr_read(CSR_TIMING0, rdata);
      expect_eq(rdata, TIMING0_DEFAULT, 3);
      csr_read(CSR_TIMING1, rdata);
      expect_eq(rdata, TIMING1_DEFAULT, 4);
      csr_read(8'h24, rdata);
      expect_eq(rdata, 32'h0, 5);
      csr_read(CSR_ERRCNT, rdata);
      expect_eq(rdata, 32'h0, 6);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_RESET}, 7);
      expect_eq({31'h0, rdata[STAT_TRAIN_DONE]}, 32'h0, 8);
      expect_eq({31'h0, pin_cke}, 32'h0, 9);
      expect_eq({31'h0, cmd_ready}, 32'h0, 10);
      expect_eq({31'h0, pin_ck}, 32'h0, 11);
      expect_eq({31'h0, pin_dq_oe}, 32'h0, 12);
      expect_eq({31'h0, rsp_valid}, 32'h0, 13);

      csr_write(CSR_CTRL, 32'h1 << CTRL_TRAIN_BYPASS);
      wait_cycles(4);
      csr_read(CSR_CTRL, rdata);
      expect_eq(rdata, 32'h1 << CTRL_TRAIN_BYPASS, 14);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_MISSION}, 15);
      expect_eq({31'h0, rdata[STAT_TRAIN_DONE]}, 32'h1, 16);
      expect_eq({31'h0, rdata[STAT_MISSION]}, 32'h1, 17);
      expect_eq({31'h0, pin_cke}, 32'h1, 18);
      // E3: push_ready is 1 while the ring has a free slot, so MISSION opens cmd_ready.
      // The old expect-0 was the stub that never accepted a beat.
      expect_eq({31'h0, cmd_ready}, 32'h1, 19);

      for (i = 0; i < 4; i = i + 1) begin
        push_cmd(OPC_ACT, 2'd0, 8'h1, 4'h0, 32'h0);
      end
      @(negedge clk);
      // Queue depth is 4 and PHY ready is 0, so the fifth beat must wait.
      expect_eq({31'h0, cmd_ready}, 32'h0, 191);

      csr_write(CSR_CTRL, (32'h1 << CTRL_TRAIN_BYPASS) | (32'h1 << CTRL_SOFT_RST));
      wait_cycles(3);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_RESET}, 20);
      expect_eq({31'h0, rdata[STAT_SOFT_RST]}, 32'h1, 21);
      expect_eq({31'h0, pin_cke}, 32'h0, 22);

      csr_write(CSR_CTRL, 32'h1 << CTRL_TRAIN_BYPASS);
      wait_cycles(4);
      csr_read(CSR_STATUS, rdata);
      expect_eq({28'h0, rdata[STAT_STATE_MSB:STAT_STATE_LSB]}, {28'h0, TR_MISSION}, 23);
      expect_eq({31'h0, rdata[STAT_SOFT_RST]}, 32'h0, 24);
      expect_eq({31'h0, pin_cke}, 32'h1, 25);
      expect_eq({31'h0, cmd_ready}, 32'h1, 26);
    end
  endtask

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

  task automatic arm_bypass(input logic [31:0] extra);
    begin
      csr_write(CSR_CTRL, (32'h1 << CTRL_TRAIN_BYPASS) | (32'h1 << CTRL_PHY_BYPASS) | extra);
      wait_cycles(4);
    end
  endtask

  task automatic run_t4();
    integer guard;
    begin
      got_rsp = 1'b0;
      got_data = '0;
      arm_bypass(32'h0);
      push_cmd(OPC_ACT, 2'd0, 8'h07, 4'h0, 32'h0);
      push_cmd(OPC_WR, 2'd0, 8'h07, 4'h1, 32'hA5A5_5A5A);
      push_cmd(OPC_RD, 2'd0, 8'h07, 4'h1, 32'h0);
      guard = 0;
      while (!got_rsp && (guard < 200)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      #1ps;
      if (!got_rsp || (got_data !== 32'hA5A5_5A5A)) begin
        $display("[T4] rsp %b data %h", got_rsp, got_data);
        errors = errors + 1;
      end else begin
        $display("[T4] PASS");
      end
    end
  endtask

  task automatic wait_dqs_done();
    integer g;
    begin
      g = 0;
      while ((pin_dqs_o !== 1'b1) && (g < 100)) begin
        @(negedge clk);
        g = g + 1;
      end
      g = 0;
      while ((pin_dqs_o !== 1'b0) && (g < 100)) begin
        @(negedge clk);
        g = g + 1;
      end
    end
  endtask

  task automatic wait_caps(input integer need);
    integer guard;
    begin
      guard = 0;
      while ((ncap < need) && (guard < 200)) begin
        @(negedge clk);
        #1ps;
        guard = guard + 1;
      end
    end
  endtask

  task automatic run_t5();
    begin
      got_rsp = 1'b0;
      arm_bypass(32'h1 << CTRL_DBI_EN);
      push_cmd(OPC_ACT, 2'd1, 8'h02, 4'h0, 32'h0);
      wait_dqs_done();
      ncap = 0;
      cap_pins = 1'b1;
      // beat0 has 5 ones, beat1 has 4 ones.
      push_cmd(OPC_WR, 2'd1, 8'h02, 4'h2, 32'h0000_0F1F);
      wait_caps(5);
      cap_pins = 1'b0;
      if ((ncap < 5) || (caps_ca[0][3:0] !== OPC_WR) ||
          (caps[1][7:0] !== 8'hE0) || (caps[1][DBI_LSB] !== 1'b1) ||
          (caps[2][7:0] !== 8'h0F) || (caps[2][DBI_LSB] !== 1'b0)) begin
        $display("[T5] ncap %0d ca %h b0 %h b1 %h b2 %h", ncap, caps_ca[0], caps[0], caps[1], caps[2]);
        errors = errors + 1;
      end else begin
        $display("[T5] PASS");
      end
    end
  endtask

  task automatic run_t7();
    integer t7bad;
    begin
      t7bad = 0;
      arm_bypass(32'h0);
      csr_write(CSR_REMAP, {24'h0, 4'd3, 3'b0, 1'b1});
      push_cmd(OPC_ACT, 2'd2, 8'h04, 4'h0, 32'h0);
      wait_dqs_done();
      ncap = 0;
      cap_pins = 1'b1;
      push_cmd(OPC_WR, 2'd2, 8'h04, 4'h3, 32'h0000_00FF);
      wait_caps(5);
      cap_pins = 1'b0;
      wait_dqs_done();
      if ((ncap < 2) || (caps[1][7:0] !== 8'hF7) || (caps[1][RED_LSB] !== 1'b1)) begin
        $display("[T7] lane3 ncap %0d b0 %h b1 %h", ncap, caps[0], caps[1]);
        errors = errors + 1;
        t7bad = 1;
      end
      csr_write(CSR_REMAP, {24'h0, 4'd8, 3'b0, 1'b1});
      ncap = 0;
      cap_pins = 1'b1;
      push_cmd(OPC_WR, 2'd2, 8'h04, 4'h4, 32'h0000_00FF);
      wait_caps(5);
      cap_pins = 1'b0;
      if ((ncap < 2) || (caps[1][7:0] !== 8'hFF)) begin
        $display("[T7] lane8 ncap %0d b0 %h b1 %h", ncap, caps[0], caps[1]);
        errors = errors + 1;
        t7bad = 1;
      end
      if (t7bad == 0) begin
        $display("[T7] PASS");
      end
      csr_write(CSR_REMAP, 32'h0);
    end
  endtask

  task automatic run_t8();
    integer t8bad;
    integer guard;
    begin
      t8bad = 0;
      arm_bypass((32'h1 << CTRL_PRBS_EN) | (32'h1 << CTRL_LOOPBACK));
      push_cmd(OPC_NOP, 2'd0, 8'h0, 4'h0, 32'h0);
      wait_cycles(4);
      csr_read(CSR_ERRCNT, rdata);
      if (rdata !== 32'h0) begin
        $display("[T8] good loopback count %h", rdata);
        errors = errors + 1;
        t8bad = 1;
      end
      arm_bypass(32'h1 << CTRL_PRBS_EN);
      push_cmd(OPC_NOP, 2'd0, 8'h0, 4'h0, 32'h0);
      wait_cycles(4);
      csr_read(CSR_ERRCNT, rdata);
      if ((rdata === 32'h0) || $isunknown(rdata)) begin
        $display("[T8] mismatch was not counted (%h)", rdata);
        errors = errors + 1;
        t8bad = 1;
      end

      // Loopback WR then RD returns the TX burst. Column 1 holds another word
      // in the channel model, so an answer from the pins would not match.
      arm_bypass(32'h0);
      push_cmd(OPC_ACT, 2'd3, 8'h09, 4'h0, 32'h0);
      push_cmd(OPC_WR, 2'd3, 8'h09, 4'h1, 32'h1111_1111);
      arm_bypass(32'h1 << CTRL_LOOPBACK);
      push_cmd(OPC_WR, 2'd3, 8'h09, 4'h2, 32'h2222_2222);
      got_rsp = 1'b0;
      push_cmd(OPC_RD, 2'd3, 8'h09, 4'h1, 32'h0);
      guard = 0;
      while (!got_rsp && (guard < 200)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      #1ps;
      if (!got_rsp || (got_data !== 32'h2222_2222)) begin
        $display("[T8] loopback RD rsp %b data %h (exp 22222222)", got_rsp, got_data);
        errors = errors + 1;
        t8bad = 1;
      end

      if (t8bad == 0) begin
        $display("[T8] PASS");
      end
    end
  endtask

  // T9 pin monitor. A WR frame is a header strobe and then BL data strobes,
  // all with WR on CA. For each data UI it adds the DQ + DBI toggles against
  // the UI before it (the header for beat 0) and the DQ + DBI pins at 1.
  // With the AC rule on, a data UI with more than DQ_W/2 DQ toggles is a
  // violation; with the DC rule on, a beat with more than DQ_W/2 ones.
  // Only these blocks write the counters; T9 reads them before and after.
  logic             mon_on;
  logic             mon_dc;
  logic             mon_ac;
  integer           mon_beat   = 0;
  logic [PIN_W-1:0] mon_last   = '0;
  integer           mon_frames = 0;
  integer           mon_ui     = 0;
  integer           mon_tog    = 0;
  integer           mon_high   = 0;
  integer           mon_bad    = 0;
  integer           rd_dbi1    = 0;

  always @(negedge clk) begin
    if (!pin_dqs_o || (pin_ca[3:0] !== OPC_WR)) begin
      mon_beat <= 0;
    end else if (mon_beat == 0) begin
      mon_last <= pin_dq_o;
      mon_beat <= 1;
    end else begin
      if (mon_on) begin
        mon_ui   <= mon_ui + 1;
        mon_tog  <= mon_tog + $countones(pin_dq_o[DBI_LSB:0] ^ mon_last[DBI_LSB:0]);
        mon_high <= mon_high + $countones(pin_dq_o[DBI_LSB:0]);
        if ((mon_ac && ($countones(pin_dq_o[DQ_W-1:0] ^ mon_last[DQ_W-1:0]) > DQ_W / 2)) ||
            (mon_dc && ($countones(pin_dq_o[DQ_W-1:0]) > DQ_W / 2))) begin
          mon_bad <= mon_bad + 1;
        end
        if (mon_beat == BL) begin
          mon_frames <= mon_frames + 1;
        end
      end
      mon_last <= pin_dq_o;
      mon_beat <= (mon_beat == BL) ? 0 : mon_beat + 1;
    end
  end

  // RD beats the channel model sent with DBI = 1 (the RX has to undo them).
  always @(posedge clk) begin
    if (pin_dqs_i && (pin_dq_i[DBI_LSB] === 1'b1)) begin
      rd_dbi1 <= rd_dbi1 + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // T9: DBI-AC at the pins and DBI on RD data.
  // ---------------------------------------------------------------------------
  // push_cmd for a stream: holds valid until the queue takes the beat.
  task automatic push_wait(
    input logic [3:0] opc,
    input logic [BANK_W-1:0] bank,
    input logic [ROW_W-1:0] row,
    input logic [COL_W-1:0] col,
    input logic [DATA_W-1:0] data
  );
    integer guard;
    begin
      @(negedge clk);
      cmd_valid = 1'b1;
      cmd_opc = opc;
      cmd_bank = bank;
      cmd_row = row;
      cmd_col = col;
      cmd_wdata = data;
      guard = 0;
      @(posedge clk);
      while ((cmd_ready !== 1'b1) && (guard < 500)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (guard >= 500) begin
        $display("[TB] push timeout opc %h", opc);
        errors = errors + 1;
      end
      @(negedge clk);
      cmd_valid = 1'b0;
    end
  endtask

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

  // One WR stream to bank 0, col = k mod 16, under one DBI setting.
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
    integer     guard;
    integer     f0;
    integer     u0;
    integer     t0;
    integer     h0;
    integer     b0;
    logic [6:0] st;
    begin
      arm_bypass(dbi_bits);
      mon_dc = dbi_bits[CTRL_DBI_EN] && !dbi_bits[CTRL_DBI_AC];
      mon_ac = dbi_bits[CTRL_DBI_EN] && dbi_bits[CTRL_DBI_AC];
      f0 = mon_frames;
      u0 = mon_ui;
      t0 = mon_tog;
      h0 = mon_high;
      b0 = mon_bad;
      mon_on = 1'b1;
      st = 7'h5A;
      for (k = 0; k < T9_N; k = k + 1) begin
        push_wait(OPC_WR, 2'd0, T9_ROW, 4'(k),
                  (pattern == 0) ? prbs7_word(st) : 32'hAA55_AA55);
        st = prbs7_next(st);
      end
      guard = 0;
      while (((mon_frames - f0) < T9_N) && (guard < 1000)) begin
        @(negedge clk);
        guard = guard + 1;
      end
      @(negedge clk);
      mon_on = 1'b0;
      ui   = mon_ui - u0;
      tog  = mon_tog - t0;
      high = mon_high - h0;
      bad  = mon_bad - b0;
      if ((mon_frames - f0) != T9_N) begin
        $display("[T9] stream saw %0d of %0d WR frames", mon_frames - f0, T9_N);
        bad = bad + 1;
      end
    end
  endtask

  // Write 16 PRBS7 words, then read them back with the channel model encoding
  // RD data under (mr_en, mr_ac). The RX must undo every DBI = 1 beat.
  task automatic t9_readback(
    input  logic   mr_en,
    input  logic   mr_ac,
    output integer bad,
    output integer dbi1
  );
    integer     k;
    integer     guard;
    integer     d0;
    logic [6:0] st;
    begin
      bad = 0;
      mr_dbi_en = mr_en;
      mr_dbi_ac = mr_ac;
      st = 7'h21;
      for (k = 0; k < 16; k = k + 1) begin
        push_wait(OPC_WR, 2'd0, T9_ROW, 4'(k), prbs7_word(st));
        st = prbs7_next(st);
      end
      d0 = rd_dbi1;
      st = 7'h21;
      for (k = 0; k < 16; k = k + 1) begin
        got_rsp = 1'b0;
        push_wait(OPC_RD, 2'd0, T9_ROW, 4'(k), 32'h0);
        guard = 0;
        while (!got_rsp && (guard < 200)) begin
          @(posedge clk);
          guard = guard + 1;
        end
        #1ps;
        if (!got_rsp || (got_data !== prbs7_word(st))) begin
          $display("[T9] RD col %0d rsp %b data %h exp %h", k, got_rsp, got_data,
                   prbs7_word(st));
          bad = bad + 1;
        end
        st = prbs7_next(st);
      end
      dbi1 = rd_dbi1 - d0;
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
      // Soft reset closes every bank, so the streams start from a known state.
      csr_write(CSR_CTRL, (32'h1 << CTRL_TRAIN_BYPASS) | (32'h1 << CTRL_SOFT_RST));
      wait_cycles(3);
      csr_write(CSR_CTRL, 32'h1 << CTRL_TRAIN_BYPASS);
      wait_cycles(4);

      // Exact pins. The WR header (col 2) is 02 on DQ; beat 0 (0F) is 3
      // toggles from it and stays; F0 after 0F would toggle all 8 DQ, so
      // beats 1 and 3 go out inverted and the DQ pins hold 0F.
      arm_bypass(T9_AC);
      csr_read(CSR_CTRL, rdata);
      if (rdata !== ((32'h1 << CTRL_TRAIN_BYPASS) | (32'h1 << CTRL_PHY_BYPASS) | T9_AC)) begin
        $display("[T9] CTRL readback %h", rdata);
        t9bad = t9bad + 1;
      end
      push_wait(OPC_ACT, 2'd0, T9_ROW, 4'h0, 32'h0);
      wait_dqs_done();
      ncap = 0;
      cap_pins = 1'b1;
      push_wait(OPC_WR, 2'd0, T9_ROW, 4'h2, 32'hF00F_F00F);
      wait_caps(5);
      cap_pins = 1'b0;
      if ((ncap < 5) || (caps[0][7:0] !== 8'h02) ||
          (caps[1][8:0] !== 9'h00F) || (caps[2][8:0] !== 9'h10F) ||
          (caps[3][8:0] !== 9'h00F) || (caps[4][8:0] !== 9'h10F)) begin
        $display("[T9] AC pins ncap %0d: %h %h %h %h %h", ncap, caps[0], caps[1], caps[2],
                 caps[3], caps[4]);
        t9bad = t9bad + 1;
      end
      wait_dqs_done();

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

      // RD data with DBI from the channel model, DC then AC.
      arm_bypass(T9_AC);
      for (m = 0; m < 2; m = m + 1) begin
        t9_readback(1'b1, m == 1, bad, dbi1);
        if ((bad != 0) || (dbi1 == 0)) begin
          $display("[T9] readback mr_ac %0d: %0d mismatches, %0d RD beats with DBI 1",
                   m, bad, dbi1);
          t9bad = t9bad + 1;
        end
      end
      arm_bypass(32'h0);

      if (t9bad == 0) begin
        $display("[T9] PASS");
      end else begin
        errors = errors + t9bad;
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
    cmd_valid = 1'b0;
    cmd_opc = '0;
    cmd_bank = '0;
    cmd_row = '0;
    cmd_col = '0;
    cmd_wdata = '0;
    cap_pins = 1'b0;
    ncap = 0;
    got_rsp = 1'b0;
    got_data = '0;
    mr_dbi_en = 1'b0;
    mr_dbi_ac = 1'b0;
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
    run_t4();
    run_t5();
    run_t7();
    run_t8();
    run_t9();

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
    #200000;
    $fatal(1, "[SMOKE] timeout");
  end
endmodule

`default_nettype wire
