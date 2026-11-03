`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_cdc_fifo
// Depth-4 FIFO. Pointers cross domains as Gray code through two flops:
//   wptr_g_s1 -> wptr_g_s2 in clk_r
//   rptr_g_s1 -> rptr_g_s2 in clk_w
// Constrain those flops with set_max_delay of one destination period.
// Do not false-path them. SAME_CLOCK is retained; Gray code is correct for
// both the split-clock case and the tied-clock case.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_cdc_fifo #(
  parameter int WIDTH      = 32,
  parameter int SAME_CLOCK = 1
) (
  input  wire              clk_w,
  input  wire              clk_r,
  input  wire              rst_n,
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
  logic [AW:0] wgray;
  logic [AW:0] rgray;
  logic [AW:0] wptr_g_s1;
  logic [AW:0] wptr_g_s2;
  logic [AW:0] rptr_g_s1;
  logic [AW:0] rptr_g_s2;

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    bin2gray = (b >> 1) ^ b;
  endfunction

  assign wgray    = bin2gray(wbin);
  assign rgray    = bin2gray(rbin);
  assign wr_full  = (wgray == {~rptr_g_s2[AW], ~rptr_g_s2[AW-1], rptr_g_s2[AW-2:0]});
  assign rd_empty = (rgray == wptr_g_s2);
  assign rd_data  = mem[rbin[AW-1:0]];

  always_ff @(posedge clk_w or negedge rst_n) begin
    if (!rst_n) begin
      wbin      <= '0;
      rptr_g_s1 <= '0;
      rptr_g_s2 <= '0;
    end else begin
      rptr_g_s1 <= rgray;
      rptr_g_s2 <= rptr_g_s1;
      if (wr_en && !wr_full) begin
        wbin <= wbin + 1'b1;
      end
    end
  end

  // Data storage has no reset. Validity comes from the reset pointers.
  always_ff @(posedge clk_w) begin
    if (wr_en && !wr_full) begin
      mem[wbin[AW-1:0]] <= wr_data;
    end
  end

  always_ff @(posedge clk_r or negedge rst_n) begin
    if (!rst_n) begin
      rbin      <= '0;
      wptr_g_s1 <= '0;
      wptr_g_s2 <= '0;
    end else begin
      wptr_g_s1 <= wgray;
      wptr_g_s2 <= wptr_g_s1;
      if (rd_en && !rd_empty) begin
        rbin <= rbin + 1'b1;
      end
    end
  end

  wire unused_same = (SAME_CLOCK != 0);
endmodule

`default_nettype wire
