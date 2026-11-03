`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_dbi
// DBI-DC, one flag per beat. Study rule: invert a beat when its popcount
// of ones is greater than DQ_W/2. dbi_en == 0 is a pass-through.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_dbi (
  input  wire                          en,
  input  wire  [hsl_pkg::DATA_W-1:0]   din,
  output logic [hsl_pkg::DATA_W-1:0]   dout,
  output logic [hsl_pkg::BL-1:0]       dbi
);
  import hsl_pkg::*;

  function automatic logic [3:0] pop8(input logic [7:0] b);
    pop8 = {3'b0, b[0]} + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + b[7];
  endfunction

  integer bi;
  always_comb begin
    dout = din;
    dbi  = '0;
    if (en) begin
      for (bi = 0; bi < BL; bi = bi + 1) begin
        if (pop8(din[bi*DQ_W +: DQ_W]) > 4'd4) begin
          dout[bi*DQ_W +: DQ_W] = ~din[bi*DQ_W +: DQ_W];
          dbi[bi] = 1'b1;
        end
      end
    end
  end
endmodule

`default_nettype wire
