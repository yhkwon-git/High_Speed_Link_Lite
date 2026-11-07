`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_secded_enc (decoder: hsl_secded_dec)
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

module hsl_secded_enc (
  input  wire  [31:0] d,
  output logic [38:0] c
);
  logic [38:0] w;
  int          j;
  logic        x;

  always_comb begin
    w = '0;
    j = 0;
    for (int p = 1; p < 39; p++) begin
      if ((p & (p - 1)) != 0) begin
        w[p] = d[j];
        j    = j + 1;
      end
    end
    for (int k = 0; k < 6; k++) begin
      x = 1'b0;
      for (int p = 1; p < 39; p++) begin
        if ((((p >> k) & 1) == 1) && (p != (1 << k))) x = x ^ w[p];
      end
      w[1 << k] = x;
    end
    w[0] = ^w[38:1];
    c    = w;
  end
endmodule

`default_nettype wire
