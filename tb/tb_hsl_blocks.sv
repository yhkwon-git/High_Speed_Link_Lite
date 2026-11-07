`timescale 1ns/100fs
// Block-level checks for E4, E7, E8, E9, E10, the PRBS seed rule, and DBI.
`default_nettype none

module tb_hsl_blocks (
  output integer errors,
  output logic   done
);
  import hsl_pkg::*;

  integer local_errors;

  initial begin
    errors = 0;
    local_errors = 0;
    done = 1'b0;
    check_repair();
    check_deskew();
    check_prbs();
    check_t3();
    check_t2();
    check_gearbox();
    check_fifo();
    check_dbi();
    errors = local_errors;
    done = 1'b1;
  end

  task automatic bump(input logic cond, input integer tag);
    begin
      // X or Z counts as a failure, not a pass.
      if (cond !== 1'b1) begin
        $display("[BLK] fail tag %0d", tag);
        local_errors = local_errors + 1;
      end
    end
  endtask

  // Each check judges only its own failures (e0 = count at its start), so a
  // failure in an earlier check does not hide a later PASS line.
  task automatic report(input string label, input integer e0);
    begin
      if (local_errors == e0) begin
        $display("%s PASS", label);
      end else begin
        $display("%s FAIL (%0d)", label, local_errors - e0);
      end
    end
  endtask

  // T7 unit: hsl_lane_shift against a loop reference, every lane setting.
  // Declared before the task: SystemVerilog requires declaration before use.
  logic              sh_en;
  logic [3:0]        sh_lane;
  logic [LANE_N-1:0] sh_l;
  logic [PIN_W-1:0]  sh_p;
  logic [PIN_W-1:0]  sh_rx;
  logic [LANE_N-1:0] sh_back;

  hsl_lane_shift u_shift (
    .en   (sh_en),
    .lane (sh_lane),
    .tx_l (sh_l),
    .tx_p (sh_p),
    .rx_p (sh_rx),
    .rx_l (sh_back)
  );

  function automatic logic [PIN_W-1:0] shift_ref(
    input logic [LANE_N-1:0] l,
    input logic              en,
    input logic [3:0]        lane
  );
    integer i;
    integer k;
    begin
      k = (en && (lane < 4'(LANE_N))) ? int'(lane) : PIN_W;
      shift_ref = '0;
      for (i = 0; i < PIN_W; i = i + 1) begin
        if ((i < k) && (i < LANE_N)) begin
          shift_ref[i] = l[i];
        end else if (i > k) begin
          shift_ref[i] = l[i-1];
        end
      end
    end
  endfunction

  task automatic check_repair();
    integer e0;
    integer k;
    integer n;
    begin
      e0 = local_errors;
      // Directed: lane 3 with all ones (T7 at the pins), lane 8 moves DBI to RED.
      sh_en = 1'b1; sh_lane = 4'd3; sh_l = 9'h0FF; sh_rx = '0;
      #1ps;
      bump(sh_p === 10'h1F7, 701);
      sh_lane = 4'd8; sh_l = 9'h100;
      #1ps;
      bump(sh_p === 10'h200, 702);
      sh_en = 1'b0;
      #1ps;
      bump(sh_p === 10'h100, 703);
      // Every setting, random lanes: reference, round trip, and a stuck value
      // on the skipped pin must not reach the logical side.
      for (k = 0; k < 16; k = k + 1) begin
        for (n = 0; n < 64; n = n + 1) begin
          sh_en   = (n % 8) != 0;
          sh_lane = 4'(k);
          sh_l    = 9'($urandom);
          #1ps;
          bump(sh_p === shift_ref(sh_l, sh_en, sh_lane), 704);
          sh_rx = sh_p;
          if (sh_en && (k < LANE_N)) begin
            sh_rx[k] = 1'($urandom);
          end
          #1ps;
          bump(sh_back === sh_l, 705);
        end
      end
      report("[T7] unit", e0);
    end
  endtask

  logic       dclk;
  logic       drst;
  logic [7:0] ddin;
  logic       dvalid;
  logic [2:0] dsel;
  logic [7:0] ddout;
  logic       ddvalid;

  initial dclk = 1'b0;
  always #5 dclk = ~dclk;

  hsl_deskew u_dsk (
    .clk(dclk),
    .rst_n(drst),
    .din(ddin),
    .din_valid(dvalid),
    .delay_sel(dsel),
    .dout(ddout),
    .dout_valid(ddvalid)
  );

  task automatic check_deskew();
    integer e0;
    begin
      e0 = local_errors;
      drst = 1'b0;
      ddin = '0;
      dvalid = 1'b0;
      dsel = 3'd0;
      repeat (4) @(posedge dclk);
      drst = 1'b1;
      @(negedge dclk);
      ddin = 8'hA5;
      #1ps;
      bump(ddout == 8'hA5, 901);
      dsel = 3'd2;
      ddin = 8'h01;
      @(posedge dclk);
      @(negedge dclk);
      ddin = 8'h00;
      @(posedge dclk);
      @(negedge dclk);
      #1ps;
      bump(ddout == 8'h01, 902);
      report("[E9]", e0);
    end
  endtask

  logic       pclk;
  logic       prst;
  logic       pen;
  logic       pload;
  logic [6:0] pseed;
  logic       pbit;
  logic [31:0] ppar;

  initial pclk = 1'b0;
  always #5 pclk = ~pclk;

  hsl_prbs u_prbs (
    .clk(pclk),
    .rst_n(prst),
    .en(pen),
    .load(pload),
    .seed(pseed),
    .bit_o(pbit),
    .parallel_o(ppar)
  );

  task automatic check_prbs();
    logic [31:0] first;
    integer e0;
    begin
      e0 = local_errors;
      prst = 1'b0;
      pen = 1'b0;
      pload = 1'b0;
      pseed = 7'h00;
      repeat (3) @(posedge pclk);
      prst = 1'b1;
      @(negedge pclk);
      #1ps;
      // 7'h5A: bit [6]^[5] = 1.
      bump(ppar[0] === 1'b1, 801);
      bump(ppar !== 32'h0, 802);
      first = ppar;
      @(negedge pclk);
      pload = 1'b1;
      pen = 1'b1;
      pseed = 7'h00;
      @(posedge pclk);
      @(negedge pclk);
      pload = 1'b0;
      #1ps;
      bump(ppar !== 32'h0, 803);
      bump(ppar !== first, 804);
      report("[E11] prbs", e0);
    end
  endtask

  logic       sclk;
  logic       srst;
  logic [3:0] bank_open;
  logic [3:0] bank_ready;
  logic       req_valid;
  logic       req_ready;
  logic [3:0] req_opc;
  logic [1:0] req_bank;
  logic       issue_valid;
  logic       issue_ready;
  logic [3:0] issue_opc;
  logic [1:0] issue_bank;

  initial sclk = 1'b0;
  always #5 sclk = ~sclk;

  hsl_scheduler u_sch (
    .clk(sclk),
    .rst_n(srst),
    .bank_open(bank_open),
    .bank_ready(bank_ready),
    .timing0(TIMING0_DEFAULT),
    .timing1(TIMING1_DEFAULT),
    .req_valid(req_valid),
    .req_ready(req_ready),
    .req_opc(req_opc),
    .req_bank(req_bank),
    .issue_valid(issue_valid),
    .issue_ready(issue_ready),
    .issue_opc(issue_opc),
    .issue_bank(issue_bank)
  );

  task automatic check_t3();
    integer e0;
    begin
      e0 = local_errors;
      srst = 1'b0;
      req_valid = 1'b0;
      req_opc = OPC_WR;
      req_bank = 2'd0;
      issue_ready = 1'b1;
      bank_open = 4'b0001;
      bank_ready = 4'b0001;
      repeat (3) @(posedge sclk);
      srst = 1'b1;
      @(negedge sclk);
      req_valid = 1'b1;
      // issue_valid is combo and drops on the edge that loads tCCD.
      #1ps;
      bump(issue_valid === 1'b1, 301);
      @(posedge sclk);
      #1ps;
      bump(issue_valid === 1'b0, 302);
      @(posedge sclk);
      #1ps;
      bump(issue_valid === 1'b1, 303);
      req_valid = 1'b0;
      report("[T3]", e0);
    end
  endtask

  logic mclk;
  logic mrst;
  logic m_valid;
  logic m_ready;
  logic [3:0] m_opc;
  logic [1:0] m_bank;
  logic [7:0] m_row;
  logic [3:0] m_col;
  logic [31:0] m_wdata;
  logic m_rsp_v;
  logic [31:0] m_rsp_d;
  logic m_rsp_e;
  logic p_valid;
  logic [3:0] p_opc;
  logic [1:0] p_bank;
  logic [7:0] p_row;
  logic [3:0] p_col;
  logic [31:0] p_wdata;

  initial mclk = 1'b0;
  always #5 mclk = ~mclk;

  hsl_mc_top u_mc (
    .clk(mclk),
    .rst_n(mrst),
    .mission_mode(1'b1),
    .timing0(TIMING0_DEFAULT),
    .timing1(TIMING1_DEFAULT),
    .cmd_valid(m_valid),
    .cmd_ready(m_ready),
    .cmd_opc(m_opc),
    .cmd_bank(m_bank),
    .cmd_row(m_row),
    .cmd_col(m_col),
    .cmd_wdata(m_wdata),
    .rsp_valid(m_rsp_v),
    .rsp_rdata(m_rsp_d),
    .rsp_err(m_rsp_e),
    .phy_valid(p_valid),
    .phy_ready(1'b1),
    .phy_opc(p_opc),
    .phy_bank(p_bank),
    .phy_row(p_row),
    .phy_col(p_col),
    .phy_wdata(p_wdata),
    .phy_rsp_valid(1'b0),
    .phy_rsp_rdata('0)
  );

  task automatic mc_push(input logic [3:0] opc);
    begin
      @(negedge mclk);
      m_valid = 1'b1;
      m_opc = opc;
      @(posedge mclk);
      #1ps;
      bump(m_ready === 1'b1, 210);
      @(negedge mclk);
      m_valid = 1'b0;
    end
  endtask

  task automatic wait_issue(input logic [3:0] opc, input integer tag, input integer limit);
    integer guard;
    begin
      guard = 0;
      // phy_valid is high for the cycle before the pop edge, so sample then.
      while (!((p_valid === 1'b1) && (p_opc === opc)) && (guard < limit)) begin
        @(negedge mclk);
        guard = guard + 1;
      end
      bump((p_valid === 1'b1) && (p_opc === opc), tag);
    end
  endtask

  task automatic check_t2();
    integer k;
    integer e0;
    begin
      e0 = local_errors;
      mrst = 1'b0;
      m_valid = 1'b0;
      m_opc = OPC_ACT;
      m_bank = 2'd0;
      m_row = 8'h3;
      m_col = 4'h1;
      m_wdata = 32'h0;
      repeat (3) @(posedge mclk);
      mrst = 1'b1;
      @(negedge mclk);
      mc_push(OPC_ACT);
      wait_issue(OPC_ACT, 211, 10);
      mc_push(OPC_RD);
      for (k = 0; k < T_RCD; k = k + 1) begin
        @(negedge mclk);
        bump(p_valid === 1'b0, 212);
      end
      wait_issue(OPC_RD, 213, 80);
      // Let tRTP expire, then PRE, then prove ACT is refused for tRP cycles.
      repeat (8) @(posedge mclk);
      mc_push(OPC_PRE);
      wait_issue(OPC_PRE, 214, 40);
      mc_push(OPC_ACT);
      // Two samples stay inside tRP. The closing edge is tRP clocks after PRE.
      for (k = 0; k < (int'(T_RP) - 2); k = k + 1) begin
        @(negedge mclk);
        bump(p_valid === 1'b0, 215);
      end
      report("[T2]", e0);
    end
  endtask

  // E7: hsl_tx_gear, one word per controller clock as two PHY beats, low
  // half first. Two words on consecutive controller clocks give four beats on
  // consecutive PHY clocks. The two clocks here are free-running, so E1 is
  // the first PHY edge after a controller edge.
  logic gclk_c;
  logic gclk_p;
  logic grst;
  logic [31:0] gdin;
  logic gvalid;
  logic [15:0] gbeat;
  logic gbeat_v;
  logic [15:0] ggot [0:3];
  integer gat [0:3];
  integer gcount;
  integer gcyc;

  hsl_tx_gear #(.W(32)) u_gear (
    .clk_ctrl   (gclk_c),
    .clk_phy    (gclk_p),
    .rst_n      (grst),
    .din        (gdin),
    .din_valid  (gvalid),
    .dout       (gbeat),
    .dout_valid (gbeat_v)
  );

  initial begin
    gclk_c = 1'b0;
    gclk_p = 1'b0;
    gcyc = 0;
  end
  always #625ps gclk_c = ~gclk_c;
  always #312.5ps gclk_p = ~gclk_p;

  always @(posedge gclk_p) begin
    gcyc <= gcyc + 1;
    if (grst && gbeat_v && (gcount < 4)) begin
      ggot[gcount] <= gbeat;
      gat[gcount]  <= gcyc;
      gcount       <= gcount + 1;
    end
  end

  task automatic check_gearbox();
    integer guard;
    integer e0;
    begin
      e0 = local_errors;
      grst = 1'b0;
      gvalid = 1'b0;
      gdin = 32'hA1B2_C3D4;
      gcount = 0;
      repeat (4) @(posedge gclk_c);
      grst = 1'b1;
      repeat (2) @(posedge gclk_c);
      @(negedge gclk_c);
      gvalid = 1'b1;
      @(posedge gclk_c);
      @(negedge gclk_c);
      gdin = 32'h5566_7788;
      @(posedge gclk_c);
      @(negedge gclk_c);
      gvalid = 1'b0;
      guard = 0;
      while ((gcount < 4) && (guard < 40)) begin
        @(posedge gclk_p);
        guard = guard + 1;
      end
      @(posedge gclk_p);
      #1ps;
      bump(gcount == 4, 7011);
      bump(ggot[0] == 16'hC3D4, 7012);
      bump(ggot[1] == 16'hA1B2, 7013);
      bump(ggot[2] == 16'h7788, 7014);
      bump(ggot[3] == 16'h5566, 7015);
      bump((gat[1] == gat[0] + 1) && (gat[2] == gat[0] + 2) && (gat[3] == gat[0] + 3), 7016);
      report("[E7]", e0);
    end
  endtask

  logic wclk;
  logic rclk;
  logic frst;
  logic fwen;
  logic [31:0] fwdata;
  logic ffull;
  logic fren;
  logic [31:0] frdata;
  logic fempty;
  logic [31:0] fgot [0:2];
  integer fcount;

  hsl_cdc_fifo #(.WIDTH(32), .SAME_CLOCK(0)) u_fifo (
    .clk_w(wclk),
    .clk_r(rclk),
    .rst_n(frst),
    .wr_en(fwen),
    .wr_data(fwdata),
    .wr_full(ffull),
    .rd_en(fren),
    .rd_data(frdata),
    .rd_empty(fempty)
  );

  initial wclk = 1'b0;
  always #312.5ps wclk = ~wclk;
  initial begin
    rclk = 1'b0;
    #200ps;
    forever #625ps rclk = ~rclk;
  end

  task automatic check_fifo();
    integer guard;
    integer e0;
    begin
      e0 = local_errors;
      frst = 1'b0;
      fwen = 1'b0;
      fren = 1'b0;
      fwdata = 32'h0;
      fcount = 0;
      repeat (4) @(posedge wclk);
      frst = 1'b1;
      @(negedge wclk);
      fwdata = 32'h1111_0001;
      fwen = 1'b1;
      @(posedge wclk);
      @(negedge wclk);
      fwdata = 32'h2222_0002;
      @(posedge wclk);
      @(negedge wclk);
      fwdata = 32'h3333_0003;
      @(posedge wclk);
      @(negedge wclk);
      fwen = 1'b0;
      guard = 0;
      while ((fcount < 3) && (guard < 40)) begin
        @(negedge rclk);
        #1ps;
        if (!fempty) begin
          fgot[fcount] = frdata;
          fcount = fcount + 1;
          fren = 1'b1;
          @(posedge rclk);
          @(negedge rclk);
          fren = 1'b0;
        end
        guard = guard + 1;
      end
      bump(fcount == 3, 601);
      bump(fgot[0] == 32'h1111_0001, 602);
      bump(fgot[1] == 32'h2222_0002, 603);
      bump(fgot[2] == 32'h3333_0003, 604);
      report("[T6]", e0);
    end
  endtask

  // ---------------------------------------------------------------------------
  // T9 unit: hsl_dbi against a serial reference, DC and AC rules. u_dbi_ser
  // is the AC_SERIAL build on the same inputs; the two must agree everywhere.
  // ---------------------------------------------------------------------------
  logic              dbi_en_t;
  logic              dbi_ac_t;
  logic [DQ_W-1:0]   dbi_prev_t;
  logic [DATA_W-1:0] dbi_din_t;
  logic [DATA_W-1:0] dbi_dout_t;
  logic [BL-1:0]     dbi_flag_t;
  logic [DATA_W-1:0] dbi_dout_s;
  logic [BL-1:0]     dbi_flag_s;

  hsl_dbi u_dbi (
    .en   (dbi_en_t),
    .ac   (dbi_ac_t),
    .prev (dbi_prev_t),
    .din  (dbi_din_t),
    .dout (dbi_dout_t),
    .dbi  (dbi_flag_t)
  );

  hsl_dbi #(.AC_SERIAL(1'b1)) u_dbi_ser (
    .en   (dbi_en_t),
    .ac   (dbi_ac_t),
    .prev (dbi_prev_t),
    .din  (dbi_din_t),
    .dout (dbi_dout_s),
    .dbi  (dbi_flag_s)
  );

  // {flags, bytes as sent}, one beat after another as the rule reads.
  function automatic logic [DATA_W+BL-1:0] dbi_ref(
    input logic [DATA_W-1:0] w,
    input logic [DQ_W-1:0]   last,
    input logic              ac
  );
    logic [DATA_W-1:0] enc;
    logic [BL-1:0]     flg;
    logic [DQ_W-1:0]   sent;
    logic [DQ_W-1:0]   cmp;
    integer            b;
    begin
      enc  = w;
      flg  = '0;
      sent = last;
      for (b = 0; b < BL; b = b + 1) begin
        cmp = ac ? (w[b*DQ_W +: DQ_W] ^ sent) : w[b*DQ_W +: DQ_W];
        if ($countones(cmp) > DQ_W / 2) begin
          enc[b*DQ_W +: DQ_W] = ~w[b*DQ_W +: DQ_W];
          flg[b] = 1'b1;
        end
        sent = enc[b*DQ_W +: DQ_W];
      end
      dbi_ref = {flg, enc};
    end
  endfunction

  task automatic dbi_drive(
    input logic              en,
    input logic              ac,
    input logic [DQ_W-1:0]   prev,
    input logic [DATA_W-1:0] din
  );
    begin
      dbi_en_t   = en;
      dbi_ac_t   = ac;
      dbi_prev_t = prev;
      dbi_din_t  = din;
      #1ps;
    end
  endtask

  // Decode, then the rule's own bound on every beat: DC at most DQ_W/2 ones,
  // AC at most DQ_W/2 DQ toggles against the byte sent before it.
  task automatic dbi_check_beats(input integer tag);
    integer          b;
    logic [DQ_W-1:0] sent;
    begin
      sent = dbi_prev_t;
      for (b = 0; b < BL; b = b + 1) begin
        bump((dbi_dout_t[b*DQ_W +: DQ_W] ^ {DQ_W{dbi_flag_t[b]}}) === dbi_din_t[b*DQ_W +: DQ_W], tag);
        if (dbi_ac_t) begin
          bump($countones(dbi_dout_t[b*DQ_W +: DQ_W] ^ sent) <= DQ_W / 2, tag + 1);
        end else begin
          bump($countones(dbi_dout_t[b*DQ_W +: DQ_W]) <= DQ_W / 2, tag + 2);
        end
        sent = dbi_dout_t[b*DQ_W +: DQ_W];
      end
    end
  endtask

  task automatic check_dbi();
    integer e0;
    integer i;
    integer b;
    integer m;
    integer ui;
    integer tog [0:2];
    integer one [0:2];
    integer btg [0:2];
    logic [DQ_W-1:0]   sent [0:2];
    logic              fsent [0:2];
    logic [DATA_W-1:0] w;
    real    exp_tog [0:2];
    real    exp_one [0:2];
    real    got;
    begin
      e0 = local_errors;

      // Off is a pass-through.
      dbi_drive(1'b0, 1'b1, 8'h00, 32'hFFFF_FFFF);
      bump((dbi_dout_t === 32'hFFFF_FFFF) && (dbi_flag_t === 4'b0000), 900);
      // DC: 5 ones inverts, 4 ones stays (T5 at the block).
      dbi_drive(1'b1, 1'b0, 8'h00, 32'h0000_0F1F);
      bump((dbi_dout_t === 32'h0000_0FE0) && (dbi_flag_t === 4'b0001), 901);
      // AC, prev = WR header 02: 0F keeps 3 toggles, F0 after 0F would toggle
      // all 8, so beats 1 and 3 go out inverted and the DQ pins stay at 0F.
      dbi_drive(1'b1, 1'b1, 8'h02, 32'hF00F_F00F);
      bump((dbi_dout_t === 32'h0F0F_0F0F) && (dbi_flag_t === 4'b1010), 902);
      // Same data under DC: every beat has 4 ones, nothing inverts.
      dbi_drive(1'b1, 1'b0, 8'h02, 32'hF00F_F00F);
      bump((dbi_dout_t === 32'hF00F_F00F) && (dbi_flag_t === 4'b0000), 903);
      // AC ties. Beat 0: 4 toggles stays. Beat 2 follows an inverted beat with
      // r = 4 raw toggles, which is 8 - 4 = 4 on the pins: stays.
      dbi_drive(1'b1, 1'b1, 8'h00, 32'hDCC3_F00F);
      bump((dbi_dout_t === 32'h23C3_0F0F) && (dbi_flag_t === 4'b1010), 904);
      // After an inverted beat, r = 3 raw toggles is 5 on the pins: inverts.
      dbi_drive(1'b1, 1'b1, 8'h00, 32'h00F7_F00F);
      bump((dbi_dout_t === 32'h0008_0F0F) && (dbi_flag_t === 4'b0110), 905);

      // Random bursts and prev against the reference, both rules.
      for (i = 0; i < 4000; i = i + 1) begin
        dbi_drive(1'b1, i[0], 8'($urandom), $urandom);
        bump({dbi_flag_t, dbi_dout_t} === dbi_ref(dbi_din_t, dbi_prev_t, dbi_ac_t), 910);
        bump({dbi_flag_s, dbi_dout_s} === {dbi_flag_t, dbi_dout_t}, 913);
        dbi_check_beats(911);
      end

      // A contiguous stream of random bursts (prev = last beat sent), as on a
      // DQ bus that carries data only. Measured toggles and ones per UI on
      // DQ + DBI against the binomial expectation for uniform bytes:
      //   off 4, DC 3.70 + 0.46 DBI, AC 744/256 = 2.91 + 0.46 DBI toggles.
      exp_tog[0] = 4.0;  exp_tog[1] = 4.164; exp_tog[2] = 3.369;
      exp_one[0] = 4.0;  exp_one[1] = 3.270; exp_one[2] = 4.363;
      for (m = 0; m < 3; m = m + 1) begin
        tog[m] = 0; one[m] = 0; btg[m] = 0; sent[m] = '0; fsent[m] = 1'b0;
      end
      ui = 0;
      for (i = 0; i < 10000; i = i + 1) begin
        w = $urandom;
        for (m = 0; m < 3; m = m + 1) begin
          dbi_drive(m != 0, m == 2, sent[m], w);
          if (m != 0) dbi_check_beats(912);
          for (b = 0; b < BL; b = b + 1) begin
            tog[m] = tog[m] + $countones({dbi_flag_t[b], dbi_dout_t[b*DQ_W +: DQ_W]} ^
                                         {fsent[m], sent[m]});
            one[m] = one[m] + $countones({dbi_flag_t[b], dbi_dout_t[b*DQ_W +: DQ_W]});
            sent[m]  = dbi_dout_t[b*DQ_W +: DQ_W];
            fsent[m] = dbi_flag_t[b];
          end
        end
        ui = ui + BL;
      end
      for (m = 0; m < 3; m = m + 1) begin
        got = 1.0 * tog[m] / ui;
        bump((got > exp_tog[m] - 0.05) && (got < exp_tog[m] + 0.05), 920 + m);
        got = 1.0 * one[m] / ui;
        bump((got > exp_one[m] - 0.05) && (got < exp_one[m] + 0.05), 925 + m);
      end
      $display("[T9] random stream %0d UI, DQ+DBI per UI: toggles off %0.2f dc %0.2f ac %0.2f, ones off %0.2f dc %0.2f ac %0.2f",
               ui, 1.0 * tog[0] / ui, 1.0 * tog[1] / ui, 1.0 * tog[2] / ui,
               1.0 * one[0] / ui, 1.0 * one[1] / ui, 1.0 * one[2] / ui);
      report("[T9] unit", e0);
    end
  endtask
endmodule

`default_nettype wire
