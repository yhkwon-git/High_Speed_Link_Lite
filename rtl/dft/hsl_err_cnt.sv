`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_err_cnt
// Saturating 16-bit error counter. DFD readback lives in CSR_ERRCNT.
//
// clear wins over an error on the same clock. The count stops at 16'hFFFF
// so a stuck failure does not wrap and look healthy.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_err_cnt (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         clear,
  input  wire         event_valid,
  input  wire         event_err,
  output logic [15:0] count
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      count <= '0;
    end else if (clear) begin
      count <= '0;
    end else if (event_valid && event_err && (count != 16'hFFFF)) begin
      count <= count + 16'd1;
    end
  end
endmodule

`default_nettype wire
