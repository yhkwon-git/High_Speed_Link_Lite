`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_dbi
// Data bus inversion, one flag per beat. Two study rules:
//   DC (ac = 0): invert a beat whose count of ones is greater than DQ_W/2.
//                Level rule: at most DQ_W/2 ones per beat on the DQ pins.
//   AC (ac = 1): invert a beat when more than DQ_W/2 of its DQ bits would
//                change against the byte sent in the UI before it.
//                Transition rule: at most DQ_W/2 DQ toggles per UI. The DBI
//                pin is not counted and may toggle as well.
// en == 0 is a pass-through. prev is the byte on the DQ pins in the UI before
// beat 0, as sent.
//
// AC is a chain: beat b is compared with beat b-1 as sent, and that depends
// on whether beat b-1 was inverted. Comparing raw beats instead,
//   r_b   = popcount(din_b ^ din_b-1)        all beats in parallel
//   inv_b = inv_b-1 ? (r_b < DQ_W/2) : (r_b > DQ_W/2)
// because an inverted beat b-1 turns r_b toggles into DQ_W - r_b. The serial
// path is then one 2:1 mux per beat instead of XOR, popcount, compare, and
// invert per beat. AC_SERIAL = 1 builds that textbook serial form; the
// function is the same (tb_hsl_blocks compares the two) and it is kept only
// to measure the difference with syn/ppa.sh.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_dbi #(
  parameter bit AC_SERIAL = 1'b0
) (
  input  wire                          en,
  input  wire                          ac,
  input  wire  [hsl_pkg::DQ_W-1:0]     prev,
  input  wire  [hsl_pkg::DATA_W-1:0]   din,
  output logic [hsl_pkg::DATA_W-1:0]   dout,
  output logic [hsl_pkg::BL-1:0]       dbi
);
  import hsl_pkg::*;

  localparam logic [3:0] HALF = 4'(DQ_W / 2);

  function automatic logic [3:0] pop8(input logic [7:0] b);
    pop8 = {3'b0, b[0]} + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + b[7];
  endfunction

  logic [DQ_W-1:0] beat [0:BL-1];
  logic [BL-1:0]   dc_inv;
  logic [BL-1:0]   ac_inv;

  integer bi;
  always_comb begin
    for (bi = 0; bi < BL; bi = bi + 1) begin
      beat[bi]   = din[bi*DQ_W +: DQ_W];
      dc_inv[bi] = pop8(din[bi*DQ_W +: DQ_W]) > HALF;
    end
  end

  logic [DQ_W-1:0] last [0:BL-1]; // raw byte before beat b (prev for beat 0)
  logic [3:0]      r    [0:BL-1]; // raw toggles; unused (removed) if AC_SERIAL

  integer ci;
  always_comb begin
    logic            inv;  // inv_b-1 while beat b is decided
    logic [DQ_W-1:0] sent; // AC_SERIAL: byte sent before beat b
    last[0] = prev;
    for (ci = 1; ci < BL; ci = ci + 1) begin
      last[ci] = beat[ci-1];
    end
    for (ci = 0; ci < BL; ci = ci + 1) begin
      r[ci] = pop8(beat[ci] ^ last[ci]);
    end
    inv  = 1'b0; // prev is already as sent
    sent = prev;
    for (ci = 0; ci < BL; ci = ci + 1) begin
      if (AC_SERIAL) begin
        inv  = pop8(beat[ci] ^ sent) > HALF;
        sent = inv ? ~beat[ci] : beat[ci];
      end else begin
        inv  = inv ? (r[ci] < HALF) : (r[ci] > HALF);
      end
      ac_inv[ci] = inv;
    end
  end

  integer oi;
  always_comb begin
    dout = din;
    dbi  = '0;
    if (en) begin
      dbi = ac ? ac_inv : dc_inv;
      for (oi = 0; oi < BL; oi = oi + 1) begin
        if (dbi[oi]) begin
          dout[oi*DQ_W +: DQ_W] = ~din[oi*DQ_W +: DQ_W];
        end
      end
    end
  end
endmodule

`default_nettype wire
