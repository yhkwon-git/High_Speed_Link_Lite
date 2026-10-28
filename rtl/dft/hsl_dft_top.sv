`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_dft_top
// Parallel loopback compare. When prbs_en is set, each tx_valid beat is
// checked against the PRBS word. loopback selects the TX beat; otherwise the
// expected pin return is 0 in this study hook, so a mismatch counts.
// Pin-level loopback is not this block.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_dft_top (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       loopback,
  input  logic                       prbs_en,
  input  logic                       err_clear,
  input  logic                       tx_valid,
  input  logic [hsl_pkg::DATA_W-1:0] tx_data,
  output logic [hsl_pkg::DATA_W-1:0] rx_data,
  output logic [hsl_pkg::DATA_W-1:0] prbs_data,
  output logic [15:0]                err_cnt
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

  assign got = loopback ? tx_data : '0;

  hsl_err_cnt u_err (
    .clk         (clk),
    .rst_n       (rst_n),
    .clear       (err_clear),
    .event_valid (prbs_en && tx_valid),
    .event_err   (prbs_en && tx_valid && (got != prbs_data)),
    .count       (err_cnt)
  );

  wire unused_bit = prbs_bit;
endmodule

`default_nettype wire
