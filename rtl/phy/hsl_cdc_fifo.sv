`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_cdc_fifo
// Depth-4 FIFO. Each side keeps its pointer as binary and as Gray, both flops
// in its own clock. Only the Gray flop crosses, through two flops:
//   wgray (clk_w) -> wptr_g_s1 -> wptr_g_s2 (clk_r)
//   rgray (clk_r) -> rptr_g_s1 -> rptr_g_s2 (clk_w)
// Gray is registered before it crosses. An XOR of binary flops can glitch
// while several binary bits change, and the first sync flop could catch a
// value that is neither the old nor the new pointer.
// Constrain the crossing (source Gray flop -> *_s1) with set_max_delay.
// Do not false-path it. SAME_CLOCK is retained; Gray code is correct for
// both the split-clock case and the tied-clock case.
// Each side has its own reset, released in its own clock (rst_w_n in clk_w,
// rst_r_n in clk_r). Both assert together; the side released later starts
// from the same empty pointers.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_cdc_fifo #(
  parameter int WIDTH      = 32,
  parameter int SAME_CLOCK = 1
) (
  input  wire              clk_w,
  input  wire              clk_r,
  input  wire              rst_w_n,   // released in clk_w
  input  wire              rst_r_n,   // released in clk_r
  input  wire              wr_en,
  input  wire  [WIDTH-1:0] wr_data,
  output logic             wr_full,
  input  wire              rd_en,
  output logic [WIDTH-1:0] rd_data,
  output logic             rd_empty
);
  localparam int DEPTH = 4;
  localparam int AW    = 2;

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW:0] wbin;
  logic [AW:0] rbin;
  logic [AW:0] wbin_next;
  logic [AW:0] rbin_next;
  logic [AW:0] wgray;     // flop in clk_w, the only write-side value that crosses
  logic [AW:0] rgray;     // flop in clk_r, the only read-side value that crosses
  logic [AW:0] wptr_g_s1;
  logic [AW:0] wptr_g_s2;
  logic [AW:0] rptr_g_s1;
  logic [AW:0] rptr_g_s2;

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    bin2gray = (b >> 1) ^ b;
  endfunction

  assign wbin_next = wbin + {{AW{1'b0}}, (wr_en && !wr_full)};
  assign rbin_next = rbin + {{AW{1'b0}}, (rd_en && !rd_empty)};
  assign wr_full   = (wgray == {~rptr_g_s2[AW], ~rptr_g_s2[AW-1], rptr_g_s2[AW-2:0]});
  assign rd_empty  = (rgray == wptr_g_s2);
  assign rd_data   = mem[rbin[AW-1:0]];

  // wgray is loaded with bin2gray(wbin_next) on the edge that loads wbin, so
  // it always equals bin2gray(wbin). Full and empty timing is unchanged.
  always_ff @(posedge clk_w or negedge rst_w_n) begin
    if (!rst_w_n) begin
      wbin      <= '0;
      wgray     <= '0;
      rptr_g_s1 <= '0;
      rptr_g_s2 <= '0;
    end else begin
      rptr_g_s1 <= rgray;
      rptr_g_s2 <= rptr_g_s1;
      wbin      <= wbin_next;
      wgray     <= bin2gray(wbin_next);
    end
  end

  // Data storage has no reset. Validity comes from the reset pointers.
  always_ff @(posedge clk_w) begin
    if (wr_en && !wr_full) begin
      mem[wbin[AW-1:0]] <= wr_data;
    end
  end

  always_ff @(posedge clk_r or negedge rst_r_n) begin
    if (!rst_r_n) begin
      rbin      <= '0;
      rgray     <= '0;
      wptr_g_s1 <= '0;
      wptr_g_s2 <= '0;
    end else begin
      wptr_g_s1 <= wgray;
      wptr_g_s2 <= wptr_g_s1;
      rbin      <= rbin_next;
      rgray     <= bin2gray(rbin_next);
    end
  end

  wire unused_same = (SAME_CLOCK != 0);
endmodule

`default_nettype wire
