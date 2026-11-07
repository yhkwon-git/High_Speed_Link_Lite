`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_mbist
// March test of a region of the DRAM array, through the controller's request
// port: one DRAM bank, rows row0 .. row0+nrows-1, columns 0 .. 2^ncols_log2-1,
// visited row by row (column fastest). Solid background: "0" is all zeros,
// "1" all ones.
//
//   algo 0  MATS+     {any(w0); up(r0,w1); down(r1,w0)}
//   algo 1  March X   {any(w0); up(r0,w1); down(r1,w0); any(r0)}
//   algo 2  March C-  {any(w0); up(r0,w1); up(r1,w0); down(r0,w1); down(r1,w0); any(r0)}
//   ("any" runs up)
//
// One operation at a time, so the array sees them in program order: the
// controller reorders requests to different addresses, and a coupling fault
// is only caught when the aggressor's write lands before the victim's read.
// A write is followed by a wait for q_empty (its WR is on the DRAM bus) and
// GUARD more clocks (its data has reached the array); a read waits for its
// response. Responses are in request order; posted-write answers are skipped.
// Each operation's address, data and log key are computed one clock ahead
// (S_LOAD) and the request port is driven from flops: the controller's input
// logic (queue address match, req_ready) then sees no MBIST logic in front.
//
// Each mismatching read counts in fail_cnt (saturating). The first one keeps
// its host address and the bits that differed. The fail log keeps each
// failing word once, as {row offset, column}, up to LOG_N words; one more
// sets log_ovf. The repair engine (hsl_bira) reads the whole log (log_keys).
// Start with the host quiet; the top hands this engine the request port while
// it runs.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_mbist #(
  parameter int GUARD = 4,
  parameter int LOG_N = 16
) (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        start,
  input  wire  [1:0]                 algo,
  input  wire  [hsl_pkg::BANK_W-1:0] bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  row0,
  input  wire  [3:0]                 nrows_m1,
  input  wire  [2:0]                 ncols_log2,
  input  wire                        q_empty,

  output logic                       busy,
  output logic                       req_valid,
  input  wire                        req_ready,
  output logic                       req_write,
  output logic [hsl_pkg::ADDR_W-1:0] req_addr,
  output logic [hsl_pkg::DATA_W-1:0] req_wdata,
  input  wire                        rsp_valid,
  input  wire  [hsl_pkg::DATA_W-1:0] rsp_rdata,

  output logic                       done,
  output logic [15:0]                fail_cnt,
  output logic [hsl_pkg::ADDR_W-1:0] first_addr,
  output logic [hsl_pkg::DATA_W-1:0] first_bits,
  output logic [4:0]                 log_n,
  output logic                       log_ovf,
  input  wire  [3:0]                 log_sel,
  output logic [7:0]                 log_entry,
  output logic [LOG_N*8-1:0]         log_keys,   // the whole log, entry i in [8i+7:8i]
  output logic [hsl_pkg::BANK_W-1:0] rg_bank,    // region of the last run
  output logic [hsl_pkg::ROW_W-1:0]  rg_row0
);
  import hsl_pkg::*;

  localparam logic [2:0] S_IDLE  = 3'd0;
  localparam logic [2:0] S_ISSUE = 3'd1;
  localparam logic [2:0] S_WACK  = 3'd2;
  localparam logic [2:0] S_DRAIN = 3'd3;
  localparam logic [2:0] S_GUARD = 3'd4;
  localparam logic [2:0] S_RWAIT = 3'd5;
  localparam logic [2:0] S_NEXT  = 3'd6;
  localparam logic [2:0] S_LOAD  = 3'd7;

  // One March element, {last, down, two, op0, op1}: the last element, runs
  // down, has a second op. An op is {write, value}.
  localparam logic [1:0] W0 = 2'b10;
  localparam logic [1:0] W1 = 2'b11;
  localparam logic [1:0] R0 = 2'b00;
  localparam logic [1:0] R1 = 2'b01;
  localparam int EL_LAST = 6;
  localparam int EL_DOWN = 5;
  localparam int EL_TWO  = 4;

  function automatic logic [6:0] elem_of(input logic [1:0] a, input logic [2:0] e);
    logic [6:0] x;
    begin
      x = {3'b100, R0, R0};
      case (a)
        2'd0: case (e)          // MATS+
          3'd0:    x = {3'b000, W0, R0};
          3'd1:    x = {3'b001, R0, W1};
          default: x = {3'b111, R1, W0};
        endcase
        2'd1: case (e)          // March X
          3'd0:    x = {3'b000, W0, R0};
          3'd1:    x = {3'b001, R0, W1};
          3'd2:    x = {3'b011, R1, W0};
          default: x = {3'b100, R0, R0};
        endcase
        default: case (e)       // March C-
          3'd0:    x = {3'b000, W0, R0};
          3'd1:    x = {3'b001, R0, W1};
          3'd2:    x = {3'b001, R1, W0};
          3'd3:    x = {3'b011, R0, W1};
          3'd4:    x = {3'b011, R1, W0};
          default: x = {3'b100, R0, R0};
        endcase
      endcase
      elem_of = x;
    end
  endfunction

  logic [2:0]        state;
  logic [1:0]        algo_r;
  logic [BANK_W-1:0] bank_r;
  logic [ROW_W-1:0]  row0_r;
  logic [2:0]        ncl_r;
  logic [2:0]        e;          // element
  logic              opi;        // op within the element
  logic [7:0]        idx;        // word within the region, in visiting order
  logic [7:0]        idx_last;
  logic [2:0]        gcnt;
  logic [7:0]        log_key [0:LOG_N-1];
  logic [6:0]        el;
  logic [6:0]        el_next;
  logic [1:0]        op;
  logic [3:0]        roff;
  logic [3:0]        col;
  logic              exp_q;      // the loaded op's value
  logic [7:0]        key_q;      // the loaded op's {row offset, column}
  logic [DATA_W-1:0] exp_word;
  logic [DATA_W-1:0] diff;
  logic              seen;

  assign el       = elem_of(algo_r, e);
  assign el_next  = elem_of(algo_r, e + 3'd1);
  assign op       = opi ? el[1:0] : el[3:2];
  assign roff     = 4'(idx >> ncl_r);
  assign col      = 4'(idx & ((8'd1 << ncl_r) - 8'd1));
  assign exp_word = exp_q ? '1 : '0;
  assign diff     = rsp_rdata ^ exp_word;

  assign req_valid = (state == S_ISSUE);
  assign req_wdata = exp_word;
  assign log_entry = log_key[log_sel];
  assign rg_bank   = bank_r;
  assign rg_row0   = row0_r;
  always_comb begin
    for (int i = 0; i < LOG_N; i++) log_keys[8*i +: 8] = log_key[i];
  end

  always_comb begin
    seen = 1'b0;
    for (int i = 0; i < LOG_N; i++) begin
      if ((i < int'(log_n)) && (log_key[i] == key_q)) seen = 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      busy       <= 1'b0;
      done       <= 1'b0;
      algo_r     <= '0;
      bank_r     <= '0;
      row0_r     <= '0;
      ncl_r      <= '0;
      e          <= '0;
      opi        <= 1'b0;
      idx        <= '0;
      idx_last   <= '0;
      gcnt       <= '0;
      req_addr   <= '0;
      req_write  <= 1'b0;
      exp_q      <= 1'b0;
      key_q      <= '0;
      fail_cnt   <= '0;
      first_addr <= '0;
      first_bits <= '0;
      log_n      <= '0;
      log_ovf    <= 1'b0;
      for (int i = 0; i < LOG_N; i++) log_key[i] <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            busy     <= 1'b1;
            done     <= 1'b0;
            algo_r   <= (algo == 2'd3) ? 2'd2 : algo;
            bank_r   <= bank;
            row0_r   <= row0;
            ncl_r    <= (ncols_log2 > 3'd4) ? 3'd4 : ncols_log2;
            idx_last <= 8'(({4'd0, nrows_m1} + 8'd1) << ((ncols_log2 > 3'd4) ? 3'd4 : ncols_log2)) - 8'd1;
            e        <= '0;
            opi      <= 1'b0;
            idx      <= '0;
            fail_cnt <= '0;
            log_n    <= '0;
            log_ovf  <= 1'b0;
            state    <= S_LOAD;
          end
        end
        S_LOAD: begin
          req_addr  <= host_addr(bank_r, row0_r + {4'd0, roff}, col);
          req_write <= op[1];
          exp_q     <= op[0];
          key_q     <= {roff, col};
          state     <= S_ISSUE;
        end
        S_ISSUE: begin
          if (req_ready) begin
            state <= req_write ? S_WACK : S_RWAIT;
          end
        end
        S_WACK: begin
          if (rsp_valid) begin
            state <= S_DRAIN;
          end
        end
        S_DRAIN: begin
          if (q_empty) begin
            gcnt  <= 3'(GUARD);
            state <= S_GUARD;
          end
        end
        S_GUARD: begin
          if (gcnt == 3'd0) begin
            state <= S_NEXT;
          end else begin
            gcnt <= gcnt - 3'd1;
          end
        end
        S_RWAIT: begin
          if (rsp_valid) begin
            if (diff != '0) begin
              if (fail_cnt == 16'd0) begin
                first_addr <= req_addr;
                first_bits <= diff;
              end
              if (fail_cnt != 16'hFFFF) begin
                fail_cnt <= fail_cnt + 16'd1;
              end
              if (!seen) begin
                if (log_n < 5'(LOG_N)) begin
                  log_key[log_n[3:0]] <= key_q;
                  log_n               <= log_n + 5'd1;
                end else begin
                  log_ovf <= 1'b1;
                end
              end
            end
            state <= S_NEXT;
          end
        end
        S_NEXT: begin
          state <= S_LOAD;
          if (el[EL_TWO] && !opi) begin
            opi <= 1'b1;
          end else begin
            opi <= 1'b0;
            // Next word in this element's direction, or the next element.
            if (el[EL_DOWN] ? (idx == 8'd0) : (idx == idx_last)) begin
              if (el[EL_LAST]) begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= S_IDLE;
              end else begin
                e   <= e + 3'd1;
                idx <= el_next[EL_DOWN] ? idx_last : 8'd0;
              end
            end else begin
              idx <= el[EL_DOWN] ? idx - 8'd1 : idx + 8'd1;
            end
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
