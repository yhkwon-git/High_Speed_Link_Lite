`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_phy_top
// Bypass path talks to the channel model in controller clocks.
// The gearbox, deskew, and async FIFO are on the 2x PHY clock. Command
// accept stays with the bypass framer so a beat is not popped into a path
// that does not store it. Gearbox behavior is checked on its own instance.
//
// Parallel loopback: lb_hold keeps the last WR burst sent while loopback is
// on, as returned by the DFT loopback mux. A RD in loopback answers with it,
// so WR then RD reads the TX burst back without the channel model.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_top (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        cke,
  input  wire                        dbi_en,
  input  wire                        phy_bypass,
  input  wire                        repair_en,
  input  wire  [3:0]                 repair_lane,
  input  wire                        loopback,
  input  wire                        prbs_en,
  input  wire  [hsl_pkg::DATA_W-1:0] prbs_data,

  input  wire                        valid,
  output logic                       ready,
  input  wire  [3:0]                 opc,
  input  wire  [hsl_pkg::BANK_W-1:0] bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  row,
  input  wire  [hsl_pkg::COL_W-1:0]  col,
  input  wire  [hsl_pkg::DATA_W-1:0] wdata,

  output logic                       rsp_valid,
  output logic [hsl_pkg::DATA_W-1:0] rsp_rdata,
  output logic [hsl_pkg::DATA_W-1:0] obs_tx_data,

  input  wire  [hsl_pkg::DATA_W-1:0] lb_rx_data,

  output logic                       pin_ck,
  output logic                       pin_cke,
  output logic [7:0]                 pin_ca,
  output logic [hsl_pkg::PIN_W-1:0]  pin_dq_o,
  output logic                       pin_dq_oe,
  output logic                       pin_dqs_o,
  input  wire  [hsl_pkg::PIN_W-1:0]  pin_dq_i,
  input  wire                        pin_dqs_i
);
  import hsl_pkg::*;

  logic [DATA_W-1:0] payload;
  logic [DATA_W-1:0] dbi_word;
  logic [BL-1:0]     dbi_flags;
  logic [DQ_W-1:0]   rep_beat [0:BL-1];
  logic              rep_dbi  [0:BL-1];
  logic [DATA_W-1:0] pin_data;
  logic              clk_phy;
  logic              rd_start;
  logic [DQ_W*DDR_BITS-1:0] gear_beat;
  logic              gear_valid;
  logic              gear_ready;
  logic [DQ_W-1:0]   deskew_q;
  logic              deskew_valid;
  logic [DATA_W-1:0] fifo_rdata;
  logic              fifo_full;
  logic              fifo_empty;
  logic [DATA_W-1:0] lb_hold;
  integer            pi;

  assign payload     = prbs_en ? prbs_data : wdata;
  assign obs_tx_data = payload; // compare point is before DBI and repair
  assign pin_ck      = 1'b0;
  assign pin_cke     = cke;

  hsl_phy_clk u_phy_clk (
    .clk_ctrl (clk),
    .clk_phy  (clk_phy)
  );

  hsl_dbi u_dbi (
    .en   (dbi_en),
    .din  (payload),
    .dout (dbi_word),
    .dbi  (dbi_flags)
  );

  generate
    for (genvar gb = 0; gb < BL; gb++) begin : g_rep
      hsl_lane_repair u_rep (
        .dq_in       (dbi_word[gb*DQ_W +: DQ_W]),
        .dbi_in      (dbi_flags[gb]),
        .red_in      (1'b0),
        .repair_en   (repair_en),
        .repair_lane (repair_lane),
        .dq_out      (rep_beat[gb]),
        .dbi_out     (rep_dbi[gb])
      );
    end
  endgenerate

  always_comb begin
    pin_data = '0;
    for (pi = 0; pi < BL; pi = pi + 1) begin
      pin_data[pi*DQ_W +: DQ_W] = rep_beat[pi];
    end
  end

  hsl_gearbox u_gear (
    .clk_ctrl   (clk),
    .clk_phy    (clk_phy),
    .rst_n      (rst_n),
    .din_ctrl   (payload),
    .din_valid  (1'b0),
    .din_ready  (gear_ready),
    .dout_phy   (gear_beat),
    .dout_valid (gear_valid)
  );

  hsl_deskew u_deskew (
    .clk        (clk_phy),
    .rst_n      (rst_n),
    .din        (pin_dq_i[DQ_W-1:0]),
    .din_valid  (pin_dqs_i),
    .delay_sel  (3'd0),
    .dout       (deskew_q),
    .dout_valid (deskew_valid)
  );

  hsl_cdc_fifo #(
    .WIDTH      (DATA_W),
    .SAME_CLOCK (0)
  ) u_fifo (
    .clk_w    (clk_phy),
    .clk_r    (clk),
    .rst_n    (rst_n),
    .wr_en    (1'b0),
    .wr_data  (payload),
    .wr_full  (fifo_full),
    .rd_en    (1'b0),
    .rd_data  (fifo_rdata),
    .rd_empty (fifo_empty)
  );

  hsl_phy_tx u_tx (
    .clk         (clk),
    .rst_n       (rst_n),
    .cke         (cke),
    .phy_bypass  (phy_bypass),
    .valid       (valid),
    .ready       (ready),
    .opc         (opc),
    .bank        (bank),
    .row         (row),
    .col         (col),
    .wdata       (pin_data),
    .raw_data    (dbi_word),
    .dbi_flags   (dbi_flags),
    .repair_en   (repair_en),
    .repair_lane (repair_lane),
    .ca          (pin_ca),
    .dq_o        (pin_dq_o),
    .dq_oe       (pin_dq_oe),
    .dqs_o       (pin_dqs_o),
    .rd_start    (rd_start)
  );

  // valid is already the scheduler's fire; ready is repeated for clarity.
  // lb_rx_data equals the WR payload (pre-DBI, pre-repair) while loopback is on.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lb_hold <= '0;
    end else if (valid && ready && loopback && (opc == OPC_WR)) begin
      lb_hold <= lb_rx_data;
    end
  end

  hsl_phy_rx u_rx (
    .clk       (clk),
    .rst_n     (rst_n),
    .rd_start  (rd_start),
    .dq_i      (pin_dq_i),
    .dqs_i     (pin_dqs_i),
    .lb_data   (lb_hold),
    .loopback  (loopback),
    .rsp_valid (rsp_valid),
    .rsp_rdata (rsp_rdata)
  );

  wire unused_path = ^{
    gear_ready, gear_beat, gear_valid, deskew_q, deskew_valid,
    fifo_rdata, fifo_full, fifo_empty, rep_dbi[0]
  };
endmodule

`default_nettype wire
