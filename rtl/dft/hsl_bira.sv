`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_bira
// Built-in redundancy analysis on the MBIST fail log: which failing words get
// a spare row and which a spare column. SPR spare rows, SPC spare columns
// (SPR + SPC <= 4); a spare column replaces one column of the 16-row block, so
// columns are only used when the MBIST region starts on a block (col_ok).
//
//   1. log_ovf: some failing words were not logged -> not repairable.
//   2. Must-repair, repeated until a pass changes nothing: a row with more
//      uncovered failing words than spare columns left must take a spare row;
//      a column with more than spare rows left must take a spare column.
//   3. Spare-order search: for each order of the L spares left (bit t of ord
//      is 1 if the t-th spare taken is a row; only orders with exactly the
//      rows left), each uncovered word in log order takes the next spare of
//      the order. The first order that covers every word wins; none -> not
//      repairable. Every repair solution is one such order, so this finds a
//      repair whenever one exists (a greedy pass missed 10 points at 5 failing
//      words with 2 + 2 spares; tb/bira_ref.py).
//
// Three clocks per log entry: the entry is registered, its row and column
// counts over the uncovered entries are registered, then it is decided (one
// clock for all three missed 800 MHz by 0.32 ns). At most 16 orders x 16
// entries.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_bira #(
  parameter int LOG_N = 16,
  parameter int SPR   = 2,
  parameter int SPC   = 2
) (
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire                  start,
  input  wire  [4:0]           log_n,
  input  wire                  log_ovf,
  input  wire  [LOG_N*8-1:0]   log_keys,   // entry i in [8i+7:8i], {row offset, col}
  input  wire                  col_ok,

  output logic                 busy,
  output logic                 done,
  output logic                 ok,
  output logic [SPR-1:0]       rr_en,
  output logic [SPR*4-1:0]     rr_roff,
  output logic [SPC-1:0]       cr_en,
  output logic [SPC*4-1:0]     cr_col
);
  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_SEL  = 3'd1;
  localparam logic [2:0] S_CNT  = 3'd2;   // row / column counts registered
  localparam logic [2:0] S_EVAL = 3'd3;
  localparam logic [2:0] S_ORD  = 3'd4;   // pick the next valid order, restore

  logic [2:0]       state;
  logic             srch;       // step 3
  logic             changed;    // a must-repair pass allocated something
  logic [4:0]       n;
  logic [3:0]       i;
  logic [LOG_N-1:0] cov;        // entry covered by an allocated spare
  logic [2:0]       rows_left;
  logic [2:0]       cols_left;
  logic [7:0]       key_r;
  logic             unc_r;      // the registered entry is still uncovered
  logic [4:0]       rcnt;
  logic [4:0]       ccnt;
  logic [4:0]       rcnt_r;
  logic [4:0]       ccnt_r;
  logic [3:0]       ki;
  logic [3:0]       kc;
  logic             do_row;
  logic             do_col;
  logic             fail;       // not repairable
  logic             miss;       // this order runs out of spares
  logic             last;

  // State after must-repair, restored before each order.
  logic [LOG_N-1:0] cov0;
  logic [2:0]       rl0;
  logic [2:0]       cl0;
  logic [SPR-1:0]   rr_en0;
  logic [SPR*4-1:0] rr_roff0;
  logic [SPC-1:0]   cr_en0;
  logic [SPC*4-1:0] cr_col0;
  logic [3:0]       ord;
  logic [2:0]       t;          // spares taken in this order
  logic [2:0]       len;        // spares left after must-repair
  logic [3:0]       lmask;
  logic [2:0]       ones;
  logic             ord_ok;

  // Uncovered entries in the registered entry's row and column: a match
  // vector, then a balanced adder tree (a serial count chain missed 800 MHz).
  logic [LOG_N-1:0] rmatch;
  logic [LOG_N-1:0] cmatch;

  function automatic logic [4:0] pop16(input logic [15:0] v);
    logic [1:0] a [0:7];
    logic [2:0] b [0:3];
    logic [3:0] c [0:1];
    begin
      for (int k = 0; k < 8; k++) a[k] = {1'b0, v[2*k]} + {1'b0, v[2*k+1]};
      for (int k = 0; k < 4; k++) b[k] = {1'b0, a[2*k]} + {1'b0, a[2*k+1]};
      for (int k = 0; k < 2; k++) c[k] = {1'b0, b[2*k]} + {1'b0, b[2*k+1]};
      pop16 = {1'b0, c[0]} + {1'b0, c[1]};
    end
  endfunction

  always_comb begin
    for (int e = 0; e < LOG_N; e++) begin
      ki = log_keys[8*e+4 +: 4];
      kc = log_keys[8*e +: 4];
      rmatch[e] = (e < int'(n)) && !cov[e] && (ki == key_r[7:4]);
      cmatch[e] = (e < int'(n)) && !cov[e] && (kc == key_r[3:0]);
    end
    rcnt = pop16(16'(rmatch));
    ccnt = pop16(16'(cmatch));
  end

  // What the registered entry takes.
  always_comb begin
    do_row = 1'b0;
    do_col = 1'b0;
    fail   = 1'b0;
    miss   = 1'b0;
    if (unc_r && !srch) begin
      if ({2'b00, cols_left} < rcnt_r) begin
        if (rows_left != 3'd0) do_row = 1'b1;
        else                   fail   = 1'b1;
      end else if ({2'b00, rows_left} < ccnt_r) begin
        if (cols_left != 3'd0) do_col = 1'b1;
        else                   fail   = 1'b1;
      end
    end else if (unc_r) begin
      if (t == len)          miss   = 1'b1;
      else if (ord[t[1:0]])  do_row = 1'b1;
      else                   do_col = 1'b1;
    end
  end
  assign last = ({1'b0, i} == (n - 5'd1));

  // An order is valid when it uses exactly the spares left after must-repair.
  assign len   = rl0 + cl0;
  assign lmask = 4'((5'd1 << len) - 5'd1);
  always_comb begin
    ones = '0;
    for (int b = 0; b < 4; b++) ones = ones + {2'b00, ord[b] & lmask[b]};
  end
  assign ord_ok = ((ord & ~lmask) == 4'h0) && (ones == rl0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      busy      <= 1'b0;
      done      <= 1'b0;
      ok        <= 1'b0;
      srch      <= 1'b0;
      changed   <= 1'b0;
      n         <= '0;
      i         <= '0;
      cov       <= '0;
      rows_left <= '0;
      cols_left <= '0;
      key_r     <= '0;
      unc_r     <= 1'b0;
      rcnt_r    <= '0;
      ccnt_r    <= '0;
      rr_en     <= '0;
      rr_roff   <= '0;
      cr_en     <= '0;
      cr_col    <= '0;
      cov0      <= '0;
      rl0       <= '0;
      cl0       <= '0;
      rr_en0    <= '0;
      rr_roff0  <= '0;
      cr_en0    <= '0;
      cr_col0   <= '0;
      ord       <= '0;
      t         <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start) begin
            done      <= 1'b0;
            ok        <= 1'b0;
            rr_en     <= '0;
            rr_roff   <= '0;
            cr_en     <= '0;
            cr_col    <= '0;
            cov       <= '0;
            n         <= log_n;
            i         <= '0;
            srch      <= 1'b0;
            changed   <= 1'b0;
            rows_left <= 3'(SPR);
            cols_left <= col_ok ? 3'(SPC) : 3'd0;
            if (log_ovf) begin
              done <= 1'b1;
            end else if (log_n == 5'd0) begin
              done <= 1'b1;
              ok   <= 1'b1;
            end else begin
              busy  <= 1'b1;
              state <= S_SEL;
            end
          end
        end
        S_SEL: begin
          key_r <= log_keys[8*i +: 8];
          unc_r <= !cov[i];
          state <= S_CNT;
        end
        S_CNT: begin
          rcnt_r <= rcnt;
          ccnt_r <= ccnt;
          state  <= S_EVAL;
        end
        S_EVAL: begin
          if (fail) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            done  <= 1'b1;
          end else if (miss) begin
            // This order cannot cover the log: the next one.
            if (ord == 4'hF) begin
              state <= S_IDLE;
              busy  <= 1'b0;
              done  <= 1'b1;
            end else begin
              ord   <= ord + 4'd1;
              state <= S_ORD;
            end
          end else begin
            // Spare slot SPR - rows_left (SPC - cols_left) is the next free one.
            if (do_row) begin
              for (int s = 0; s < SPR; s++) begin
                if (int'(rows_left) == SPR - s) begin
                  rr_en[s]          <= 1'b1;
                  rr_roff[4*s +: 4] <= key_r[7:4];
                end
              end
              rows_left <= rows_left - 3'd1;
            end
            if (do_col) begin
              for (int s = 0; s < SPC; s++) begin
                if (int'(cols_left) == SPC - s) begin
                  cr_en[s]         <= 1'b1;
                  cr_col[4*s +: 4] <= key_r[3:0];
                end
              end
              cols_left <= cols_left - 3'd1;
            end
            for (int e = 0; e < LOG_N; e++) begin
              if ((do_row && (log_keys[8*e+4 +: 4] == key_r[7:4])) ||
                  (do_col && (log_keys[8*e +: 4] == key_r[3:0]))) begin
                cov[e] <= 1'b1;
              end
            end
            if (srch && (do_row || do_col)) t <= t + 3'd1;
            state <= S_SEL;
            if (last) begin
              i <= '0;
              if (srch) begin
                state <= S_IDLE;
                busy  <= 1'b0;
                done  <= 1'b1;
                ok    <= 1'b1;
              end else if (!(changed || do_row || do_col)) begin
                // Must-repair is done: keep its state and start the search.
                srch     <= 1'b1;
                cov0     <= cov;
                rl0      <= rows_left;
                cl0      <= cols_left;
                rr_en0   <= rr_en;
                rr_roff0 <= rr_roff;
                cr_en0   <= cr_en;
                cr_col0  <= cr_col;
                ord      <= '0;
                state    <= S_ORD;
              end
              changed <= 1'b0;
            end else begin
              i       <= i + 4'd1;
              changed <= changed || do_row || do_col;
            end
          end
        end
        S_ORD: begin
          if (ord_ok) begin
            cov       <= cov0;
            rows_left <= rl0;
            cols_left <= cl0;
            rr_en     <= rr_en0;
            rr_roff   <= rr_roff0;
            cr_en     <= cr_en0;
            cr_col    <= cr_col0;
            t         <= '0;
            i         <= '0;
            state     <= S_SEL;
          end else if (ord == 4'hF) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            done  <= 1'b1;
          end else begin
            ord <= ord + 4'd1;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule

`default_nettype wire
