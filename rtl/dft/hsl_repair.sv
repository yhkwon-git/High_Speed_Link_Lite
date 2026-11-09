`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_repair
// The repair table (one entry per spare element, format in hsl_pkg) and the
// fuse controller.
//   - Soft repair: apply copies the BIRA result into the table (rows as
//     row0 + offset, columns in row0's 16-row block); clear empties it. The
//     table drives rep_tab toward the array, where the spare rows and columns
//     sit (here: the channel model).
//   - Hard repair: program writes every table entry into its fuse word,
//     SECDED-encoded. load reads the fuse words back through the decoder and
//     fills the table. load runs on its own after reset: a repaired part comes
//     up repaired.
//   - A corrected word counts in fz_ce; an uncorrectable one counts in fz_ue,
//     its entry is dropped (left empty) and marked in fz_drop.
// Fuse port: fz_rd with fz_addr returns fz_rdata on the next clock, which is
// registered before the decoder (the decoder after the port's input delay
// missed 800 MHz); fz_pgm
// with fz_addr burns fz_wdata (a fuse bit only goes 0 -> 1). Program once: a
// second program ORs a new codeword into a burned word and breaks it (there
// is no blank check), so a later repair needs fuse words of its own.
// Change the table only with the request port quiet.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_repair #(
  parameter int SPR = 2,
  parameter int SPC = 2
) (
  input  wire                          clk,
  input  wire                          rst_n,
  input  wire                          apply,
  input  wire                          clear,
  input  wire                          fz_program,
  input  wire                          fz_load,

  input  wire                          bira_done,
  input  wire                          bira_ok,
  input  wire  [SPR-1:0]               rr_en,
  input  wire  [SPR*4-1:0]             rr_roff,
  input  wire  [SPC-1:0]               cr_en,
  input  wire  [SPC*4-1:0]             cr_col,
  input  wire  [hsl_pkg::BANK_W-1:0]   rg_bank,
  input  wire  [hsl_pkg::ROW_W-1:0]    rg_row0,

  output logic [(SPR+SPC)*16-1:0]      rep_tab,

  output logic [1:0]                   fz_addr,
  output logic                         fz_rd,
  input  wire  [38:0]                  fz_rdata,
  output logic                         fz_pgm,
  output logic [38:0]                  fz_wdata,

  output logic                         fz_busy,
  output logic                         fz_loaded,
  output logic [3:0]                   fz_ce,
  output logic [3:0]                   fz_ue,
  output logic [SPR+SPC-1:0]           fz_drop
);
  localparam int N = SPR + SPC;

  localparam logic [2:0] F_IDLE = 3'd0;
  localparam logic [2:0] F_READ = 3'd1;   // fz_rd out
  localparam logic [2:0] F_TAKE = 3'd2;   // fz_rdata back, registered
  localparam logic [2:0] F_DEC  = 3'd3;   // decoded into the table
  localparam logic [2:0] F_PGM  = 3'd4;

  logic [2:0]  fst;
  logic [38:0] rd_q;       // fuse word as read (decoded the next clock)
  logic [1:0]  fa;
  logic        boot;       // the load after reset is still owed
  logic [15:0] tab [0:N-1];
  logic [31:0] dec_d;
  logic        dec_ce;
  logic        dec_ue;
  logic [5:0]  dec_syn;
  logic [38:0] enc_c;

  hsl_secded_dec u_dec (.c(rd_q), .d(dec_d), .ce(dec_ce), .ue(dec_ue), .syn(dec_syn));
  hsl_secded_enc u_enc (.d({16'h0, tab[fa]}), .c(enc_c));

  assign fz_addr  = fa;
  assign fz_rd    = (fst == F_READ);
  assign fz_pgm   = (fst == F_PGM);
  assign fz_wdata = enc_c;
  assign fz_busy  = (fst != F_IDLE) || boot;

  always_comb begin
    for (int k = 0; k < N; k++) rep_tab[16*k +: 16] = tab[k];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fst       <= F_IDLE;
      fa        <= '0;
      boot      <= 1'b1;
      fz_loaded <= 1'b0;
      fz_ce     <= '0;
      fz_ue     <= '0;
      fz_drop   <= '0;
      rd_q      <= '0;
      for (int k = 0; k < N; k++) tab[k] <= '0;
    end else begin
      case (fst)
        F_IDLE: begin
          if (boot || fz_load) begin
            boot      <= 1'b0;
            fa        <= '0;
            fz_loaded <= 1'b0;
            fz_ce     <= '0;
            fz_ue     <= '0;
            fz_drop   <= '0;
            fst       <= F_READ;
          end else if (fz_program) begin
            fa  <= '0;
            fst <= F_PGM;
          end else if (clear) begin
            for (int k = 0; k < N; k++) tab[k] <= '0;
          end else if (apply && bira_done && bira_ok) begin
            for (int s = 0; s < SPR; s++) begin
              tab[s] <= rr_en[s] ? {1'b1, 1'b0, rg_bank, 8'(rg_row0 + {4'd0, rr_roff[4*s +: 4]}), 4'h0}
                                 : 16'h0;
            end
            for (int s = 0; s < SPC; s++) begin
              tab[SPR+s] <= cr_en[s] ? {1'b1, 1'b0, rg_bank, rg_row0[7:4], 4'h0, cr_col[4*s +: 4]}
                                     : 16'h0;
            end
          end
        end
        F_READ: begin
          fst <= F_TAKE;
        end
        F_TAKE: begin
          rd_q <= fz_rdata;
          fst  <= F_DEC;
        end
        F_DEC: begin
          if (dec_ue) begin
            tab[fa]     <= 16'h0;
            fz_ue       <= fz_ue + 4'd1;
            fz_drop[fa] <= 1'b1;
          end else begin
            tab[fa] <= dec_d[15:0];
            if (dec_ce) fz_ce <= fz_ce + 4'd1;
          end
          if (int'(fa) == N - 1) begin
            fst       <= F_IDLE;
            fz_loaded <= 1'b1;
          end else begin
            fa  <= fa + 2'd1;
            fst <= F_READ;
          end
        end
        F_PGM: begin
          if (int'(fa) == N - 1) begin
            fst <= F_IDLE;
          end else begin
            fa <= fa + 2'd1;
          end
        end
        default: fst <= F_IDLE;
      endcase
    end
  end

  wire unused_dec = ^{dec_d[31:16], dec_syn};
endmodule

`default_nettype wire
