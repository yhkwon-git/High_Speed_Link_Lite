`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_prbs
// PRBS7, x^7 + x^6 + 1.
//   lfsr_next = {lfsr[5:0], lfsr[6] ^ lfsr[5]}
// parallel_o[0] is the first bit. A seed of 0 is ignored.
// Reset state is 7'h5A, which is non-zero.
//
// parallel_o is the DATA_W bits the current state generates, an unrolled XOR
// network. REG_OUT = 1 keeps the same value in flops instead: the word of the
// next state is computed when the state advances, so parallel_o leaves a
// register. The chip STA asked for it where the word feeds the DBI-AC encoder
// on its way to the TX word register.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_prbs #(
  parameter bit REG_OUT = 1'b0
) (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        en,
  input  wire                        load,
  input  wire  [6:0]                 seed,
  output logic                       bit_o,
  output logic [hsl_pkg::DATA_W-1:0] parallel_o
);
  import hsl_pkg::*;

  logic [6:0]        lfsr;
  logic [DATA_W-1:0] word_now;
  logic [DATA_W-1:0] word_q;

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

  // The DATA_W bits a state generates, first bit in [0].
  function automatic logic [DATA_W-1:0] word_of(input logic [6:0] s0);
    integer k;
    logic [6:0] s;
    begin
      s = s0;
      word_of = '0;
      for (k = 0; k < DATA_W; k = k + 1) begin
        word_of[k] = s[6] ^ s[5];
        s = step1(s);
      end
    end
  endfunction

  assign word_now   = word_of(lfsr);
  assign parallel_o = REG_OUT ? word_q : word_now;
  assign bit_o      = (en && (lfsr != 7'h00)) ? (lfsr[6] ^ lfsr[5]) : 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsr   <= 7'h5A;
      word_q <= word_of(7'h5A);
    end else if (load && (seed != 7'h00)) begin
      lfsr   <= seed;
      word_q <= word_of(seed);
    end else if (en && (lfsr != 7'h00)) begin
      lfsr   <= step_n(lfsr, DATA_W);
      word_q <= word_of(step_n(lfsr, DATA_W));
    end
  end
endmodule

`default_nettype wire
