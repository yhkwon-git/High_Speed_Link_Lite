`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_dft_top
// Parallel loopback compare. When prbs_en is set, each tx_valid beat is
// checked against the PRBS word. loopback selects the TX beat; otherwise the
// expected pin return is 0 in this study hook, so a mismatch counts.
// Pin-level loopback is not this block.
// hsl_lane_bist drives the controller's host port while it runs and checks
// the read data per DQ lane.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_dft_top (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        loopback,
  input  wire                        prbs_en,
  input  wire                        err_clear,
  input  wire                        tx_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] tx_data,
  output logic [hsl_pkg::DATA_W-1:0] rx_data,
  output logic [hsl_pkg::DATA_W-1:0] prbs_data,
  output logic [15:0]                err_cnt,

  input  wire                        lb_start,
  input  wire  [hsl_pkg::BANK_W-1:0] lb_bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  lb_row,
  output logic                       lb_busy,
  output logic                       lb_cmd_valid,
  input  wire                        lb_cmd_ready,
  output logic [3:0]                 lb_cmd_opc,
  output logic [hsl_pkg::BANK_W-1:0] lb_cmd_bank,
  output logic [hsl_pkg::ROW_W-1:0]  lb_cmd_row,
  output logic [hsl_pkg::COL_W-1:0]  lb_cmd_col,
  output logic [hsl_pkg::DATA_W-1:0] lb_cmd_wdata,
  input  wire                        lb_rsp_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] lb_rsp_rdata,
  output logic                       lb_done,
  output logic [hsl_pkg::DQ_W-1:0]   lb_lane_err,
  output logic [4:0]                 lb_err_bursts
);
  import hsl_pkg::*;

  logic prbs_bit;
  logic [DATA_W-1:0] got;

  hsl_prbs u_prbs (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (prbs_en),
    .load       (1'b0),
    .seed       (7'h5A),
    .bit_o      (prbs_bit),
    .parallel_o (prbs_data)
  );

  hsl_loopback #(.WIDTH(DATA_W)) u_lb (
    .loopback (loopback),
    .from_tx  (tx_data),
    .from_pin ('0),
    .to_rx    (rx_data)
  );

  assign got = rx_data; // hsl_loopback output: tx_data, or 0 from the pin hook

  hsl_err_cnt u_err (
    .clk         (clk),
    .rst_n       (rst_n),
    .clear       (err_clear),
    .event_valid (prbs_en && tx_valid),
    .event_err   (prbs_en && tx_valid && (got != prbs_data)),
    .count       (err_cnt)
  );

  hsl_lane_bist u_lane_bist (
    .clk        (clk),
    .rst_n      (rst_n),
    .start      (lb_start),
    .bank       (lb_bank),
    .row        (lb_row),
    .busy       (lb_busy),
    .cmd_valid  (lb_cmd_valid),
    .cmd_ready  (lb_cmd_ready),
    .cmd_opc    (lb_cmd_opc),
    .cmd_bank   (lb_cmd_bank),
    .cmd_row    (lb_cmd_row),
    .cmd_col    (lb_cmd_col),
    .cmd_wdata  (lb_cmd_wdata),
    .rsp_valid  (lb_rsp_valid),
    .rsp_rdata  (lb_rsp_rdata),
    .done       (lb_done),
    .lane_err   (lb_lane_err),
    .err_bursts (lb_err_bursts)
  );

  wire unused_bit = prbs_bit;
endmodule

`default_nettype wire
