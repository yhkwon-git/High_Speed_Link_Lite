`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_loopback
// Parallel (pre-serializer) loopback.
//
// Two different hooks, on purpose:
//   1. This mux. Digital BIST without leaving the controller clock.
//   2. A later pin-level loopback after the gearbox, which also covers
//      deskew and the strobe path. That one is not this module.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_loopback #(
  parameter int WIDTH = 32
) (
  input  wire              loopback,
  input  wire  [WIDTH-1:0] from_tx,
  input  wire  [WIDTH-1:0] from_pin,
  output logic [WIDTH-1:0] to_rx
);
  assign to_rx = loopback ? from_tx : from_pin;
endmodule

`default_nettype wire
