`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_prbs
// PRBS7, x^7 + x^6 + 1.
//   lfsr_next = {lfsr[5:0], lfsr[6] ^ lfsr[5]}
// parallel_o[0] is the first bit. A seed of 0 is ignored.
// Reset state is 7'h5A, which is non-zero.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_prbs (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        en,
  input  wire                        load,
  input  wire  [6:0]                 seed,
  output logic                       bit_o,
  output logic [hsl_pkg::DATA_W-1:0] parallel_o
);
  import hsl_pkg::*;

  logic [6:0] lfsr;

  function automatic logic [6:0] step1(input logic [6:0] s);
    step1 = {s[5:0], s[6] ^ s[5]};
  endfunction

  function automatic logic [6:0] step_n(input logic [6:0] s, input int n);
    integer k;
    logic [6:0] acc;
    begin
      acc = s;
      for (k = 0; k < n; k = k + 1) begin
        acc = step1(acc);
      end
      step_n = acc;
    end
  endfunction

  integer bi;
  always_comb begin
    logic [6:0] s;
    s = lfsr;
    parallel_o = '0;
    for (bi = 0; bi < DATA_W; bi = bi + 1) begin
      parallel_o[bi] = s[6] ^ s[5];
      s = step1(s);
    end
  end

  assign bit_o = (en && (lfsr != 7'h00)) ? (lfsr[6] ^ lfsr[5]) : 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsr <= 7'h5A;
    end else if (load && (seed != 7'h00)) begin
      lfsr <= seed;
    end else if (en && (lfsr != 7'h00)) begin
      lfsr <= step_n(lfsr, DATA_W);
    end
  end
endmodule

`default_nettype wire
