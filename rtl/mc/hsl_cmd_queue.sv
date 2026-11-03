`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_cmd_queue
// In-order ring buffer. push_ready is 1 while a slot is free.
// The head is held on pop_* for the whole time pop_valid is high.
// A beat moves only on valid && ready. Depth is 4.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_cmd_queue #(
  parameter int DEPTH = 4
) (
  input  wire                            clk,
  input  wire                            rst_n,
  input  wire                            push_valid,
  output logic                           push_ready,
  input  wire  [3:0]                     push_opc,
  input  wire  [hsl_pkg::BANK_W-1:0]     push_bank,
  input  wire  [hsl_pkg::ROW_W-1:0]      push_row,
  input  wire  [hsl_pkg::COL_W-1:0]      push_col,
  input  wire  [hsl_pkg::DATA_W-1:0]     push_wdata,
  output logic                           pop_valid,
  input  wire                            pop_ready,
  output logic [3:0]                     pop_opc,
  output logic [hsl_pkg::BANK_W-1:0]     pop_bank,
  output logic [hsl_pkg::ROW_W-1:0]      pop_row,
  output logic [hsl_pkg::COL_W-1:0]      pop_col,
  output logic [hsl_pkg::DATA_W-1:0]     pop_wdata,
  output logic                           empty,
  output logic                           full
);
  localparam int AW = $clog2(DEPTH); // DEPTH must be a power of two

  logic [3:0]                 mem_opc   [0:DEPTH-1];
  logic [hsl_pkg::BANK_W-1:0] mem_bank  [0:DEPTH-1];
  logic [hsl_pkg::ROW_W-1:0]  mem_row   [0:DEPTH-1];
  logic [hsl_pkg::COL_W-1:0]  mem_col   [0:DEPTH-1];
  logic [hsl_pkg::DATA_W-1:0] mem_wdata [0:DEPTH-1];

  logic [AW:0] wptr;
  logic [AW:0] rptr;
  logic [AW-1:0] widx;
  logic [AW-1:0] ridx;

  assign widx  = wptr[AW-1:0];
  assign ridx  = rptr[AW-1:0];
  assign empty = (wptr == rptr);
  assign full  = (wptr[AW] != rptr[AW]) && (widx == ridx);

  assign push_ready = !full;
  assign pop_valid  = !empty;
  assign pop_opc    = empty ? '0 : mem_opc[ridx];
  assign pop_bank   = empty ? '0 : mem_bank[ridx];
  assign pop_row    = empty ? '0 : mem_row[ridx];
  assign pop_col    = empty ? '0 : mem_col[ridx];
  assign pop_wdata  = empty ? '0 : mem_wdata[ridx];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end else begin
      if (push_valid && push_ready) begin
        wptr <= wptr + 1'b1;
      end
      if (pop_valid && pop_ready) begin
        rptr <= rptr + 1'b1;
      end
    end
  end

  // Payload storage has no reset on purpose. A slot is read only after its
  // push, and pop_* is masked while empty. Pointers above are reset.
  always_ff @(posedge clk) begin
    if (push_valid && push_ready) begin
      mem_opc[widx]   <= push_opc;
      mem_bank[widx]  <= push_bank;
      mem_row[widx]   <= push_row;
      mem_col[widx]   <= push_col;
      mem_wdata[widx] <= push_wdata;
    end
  end
endmodule

`default_nettype wire
