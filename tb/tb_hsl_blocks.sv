`timescale 1ns/1ps
// Block-level checks for E4, E7, E8, E9, E10, and the PRBS seed rule.
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
    errors = local_errors;
    done = 1'b1;
  end

  task automatic bump(input logic cond, input integer tag);
    begin
      if (!cond) begin
        $display("[BLK] fail tag %0d", tag);
        local_errors = local_errors + 1;
      end
    end
  endtask

  task automatic check_repair();
    logic [7:0] q;
    logic       db;
    begin
      // Inline the module via a hierarchy-free expectation by instantiating below.
      // The instance u_rep is driven by rep_* wires from this task through hierarchical... 
      // Drive the ports declared in this module.
      rep_dq  = 8'h00;
      rep_red = 1'b1;
      rep_en  = 1'b1;
      rep_lane = 4'd3;
      #1ps;
      bump(rep_q == 8'h08, 701);
      rep_lane = 4'd8;
      #1ps;
      bump(rep_q == 8'h00, 702);
      rep_lane = 4'd3;
      rep_en = 1'b0;
      #1ps;
      bump(rep_q == 8'h00, 703);
      if (local_errors == 0) begin
        $display("[T7] unit PASS");
      end
    end
  endtask

  logic [7:0] rep_dq;
  logic       rep_red;
  logic       rep_en;
  logic [3:0] rep_lane;
  logic [7:0] rep_q;
  logic       rep_db;

  hsl_lane_repair u_rep (
    .dq_in(rep_dq),
    .dbi_in(1'b0),
    .red_in(rep_red),
    .repair_en(rep_en),
    .repair_lane(rep_lane),
    .dq_out(rep_q),
    .dbi_out(rep_db)
  );

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
    begin
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
      if (local_errors == 0) begin
        $display("[E9] PASS");
      end
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
    begin
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
      if (local_errors == 0) begin
        $display("[E11] prbs PASS");
      end
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
    begin
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
      if (local_errors == 0) begin
        $display("[T3] PASS");
      end
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
    begin
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
      if (local_errors == 0) begin
        $display("[T2] PASS");
      end
    end
  endtask

  logic gclk_c;
  logic gclk_p;
  logic grst;
  logic [31:0] gdin;
  logic gvalid;
  logic gready;
  logic [15:0] gbeat;
  logic gbeat_v;
  logic [15:0] ggot [0:1];
  integer gcount;

  hsl_gearbox u_gear (
    .clk_ctrl(gclk_c),
    .clk_phy(gclk_p),
    .rst_n(grst),
    .din_ctrl(gdin),
    .din_valid(gvalid),
    .din_ready(gready),
    .dout_phy(gbeat),
    .dout_valid(gbeat_v)
  );

  initial begin
    gclk_c = 1'b0;
    gclk_p = 1'b0;
  end
  always #625ps gclk_c = ~gclk_c;
  always #312.5ps gclk_p = ~gclk_p;

  always @(posedge gclk_p) begin
    if (grst && gbeat_v && (gcount < 2)) begin
      ggot[gcount] <= gbeat;
      gcount <= gcount + 1;
    end
  end

  task automatic check_gearbox();
    integer guard;
    begin
      grst = 1'b0;
      gvalid = 1'b0;
      gdin = 32'hA1B2_C3D4;
      gcount = 0;
      repeat (4) @(posedge gclk_c);
      grst = 1'b1;
      @(negedge gclk_c);
      gvalid = 1'b1;
      @(posedge gclk_c);
      @(negedge gclk_c);
      gvalid = 1'b0;
      guard = 0;
      while ((gcount < 2) && (guard < 40)) begin
        @(posedge gclk_p);
        guard = guard + 1;
      end
      #1ps;
      bump(gcount == 2, 7011);
      bump(ggot[0] == 16'hC3D4, 7012);
      bump(ggot[1] == 16'hA1B2, 7013);
      if (local_errors == 0) begin
        $display("[E7] PASS");
      end
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
    begin
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
      if (local_errors == 0) begin
        $display("[T6] PASS");
      end
    end
  endtask
endmodule

`default_nettype wire
