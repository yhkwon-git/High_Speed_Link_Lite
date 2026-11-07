`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_secded_dec (encoder: hsl_secded_enc)
// SECDED (39,32): extended Hamming code. Code bit 0 is the overall parity;
// bits 1..38 are Hamming positions. Check bit k sits at position 2^k (1, 2, 4,
// 8, 16, 32) and covers every position with bit k set; the 32 data bits fill
// the other positions in order (data bit 0 at position 3).
// Decode: syndrome s (6 bits) and overall parity p over all 39 bits.
//   s = 0, p = 0   no error
//   p = 1          one bit flipped, at position s (s = 0: the parity bit); it
//                  is corrected (ce). s > 38 cannot be one bit: ue.
//   s != 0, p = 0  two bits flipped: ue, data passed through uncorrected
// The all-zero word is a valid codeword (an unprogrammed fuse reads as 0).
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_secded_dec (
  input  wire  [38:0] c,
  output logic [31:0] d,
  output logic        ce,
  output logic        ue,
  output logic [5:0]  syn
);
  logic [38:0] w;
  logic        par;
  int          j;

  always_comb begin
    syn = '0;
    for (int k = 0; k < 6; k++) begin
      for (int p = 1; p < 39; p++) begin
        if (((p >> k) & 1) == 1) syn[k] = syn[k] ^ c[p];
      end
    end
    par = ^c;
    w   = c;
    ce  = 1'b0;
    ue  = 1'b0;
    if (par) begin
      if (syn < 6'd39) begin
        w[syn] = ~w[syn];
        ce     = 1'b1;
      end else begin
        ue = 1'b1;
      end
    end else if (syn != 6'd0) begin
      ue = 1'b1;
    end
    d = '0;
    j = 0;
    for (int p = 1; p < 39; p++) begin
      if ((p & (p - 1)) != 0) begin
        d[j] = w[p];
        j    = j + 1;
      end
    end
  end
endmodule

`default_nettype wire
