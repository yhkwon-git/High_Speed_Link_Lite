`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_bank_fsm
// Per-bank timing.
//
//   CLOSED --ACT--> ACTIVATING --tRCD--> OPEN --PRE--> PRECHARGING --tRP--> CLOSED
//
// timing_ok is 1 in CLOSED (an ACT may be issued) and in OPEN once tRAS and
// the post-column block (tWR or tRTP) have both expired.
// Column commands therefore wait out tRAS as well as tRCD. That is stricter
// than a JEDEC minimum and still rejects an RD before tRCD.
// tCCD and tWTR belong to the scheduler.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_bank_fsm (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire  [hsl_pkg::BANK_W-1:0] bank_id,
  input  wire                        act_req,
  input  wire                        pre_req,
  input  wire                        rd_req,
  input  wire                        wr_req,
  input  wire  [31:0]                timing0,
  input  wire  [31:0]                timing1,
  output logic                       is_open,
  output logic                       timing_ok
);
  localparam logic [1:0] ST_CLOSED = 2'd0;
  localparam logic [1:0] ST_ACT    = 2'd1;
  localparam logic [1:0] ST_OPEN   = 2'd2;
  localparam logic [1:0] ST_PRE    = 2'd3;

  logic [1:0] st;
  logic [7:0] cnt;
  logic [7:0] ras_left;
  logic [7:0] block;

  wire [7:0] t_rcd = timing0[7:0];
  wire [7:0] t_rp  = timing0[15:8];
  wire [7:0] t_ras = timing0[23:16];
  wire [7:0] t_wr  = timing1[15:8];
  wire [7:0] t_rtp = timing1[23:16];

  wire [7:0] t_rcd_u = (t_rcd == 8'd0) ? 8'd1 : t_rcd;
  wire [7:0] t_rp_u  = (t_rp  == 8'd0) ? 8'd1 : t_rp;

  assign is_open   = (st == ST_OPEN);
  assign timing_ok = (st == ST_CLOSED) ||
                     ((st == ST_OPEN) && (ras_left == 8'd0) && (block == 8'd0));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= ST_CLOSED;
      cnt      <= 8'd0;
      ras_left <= 8'd0;
      block    <= 8'd0;
    end else begin
      case (st)
        ST_CLOSED: begin
          if (act_req) begin
            st  <= ST_ACT;
            cnt <= t_rcd_u;
          end
        end
        ST_ACT: begin
          if (cnt <= 8'd1) begin
            st       <= ST_OPEN;
            ras_left <= t_ras;
            block    <= 8'd0;
          end else begin
            cnt <= cnt - 8'd1;
          end
        end
        ST_OPEN: begin
          if (ras_left != 8'd0) begin
            ras_left <= ras_left - 8'd1;
          end else if (block != 8'd0) begin
            block <= block - 8'd1;
          end else if (pre_req) begin
            st  <= ST_PRE;
            cnt <= t_rp_u;
          end else if (wr_req) begin
            block <= t_wr;
          end else if (rd_req) begin
            block <= t_rtp;
          end
        end
        ST_PRE: begin
          if (cnt <= 8'd1) begin
            st <= ST_CLOSED;
          end else begin
            cnt <= cnt - 8'd1;
          end
        end
        default: st <= ST_CLOSED;
      endcase
    end
  end

  wire unused_id = |bank_id;
endmodule

`default_nettype wire
