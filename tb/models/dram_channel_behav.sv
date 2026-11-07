`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// dram_channel_behav
// Samples the base-die pins on negedge clk. Protocol is the phy_bypass framer
// in hsl_phy_tx: ACT/PRE are one strobe, WR is a header plus BL beats, RD
// drives BL bytes back. Stores one burst per {bank, open row, col}.
//
// WR data is decoded by its DBI pin whatever the mode. RD data is encoded by
// mr_dbi_en / mr_dbi_ac, which stand in for the DRAM mode register (this
// framer has no MRS). The encoder below is the plain serial rule, written
// apart from rtl/phy/hsl_dbi.sv so it can check that block's RX side.
//
// Lane repair on the DRAM side: mr_repair_en / mr_repair_lane give the same
// shift as rtl/phy/hsl_lane_shift.sv (pin k idles, lanes from k up use the
// next pin, RED carries the last one). It is written again as loops here and
// applies to every symbol, headers included, in both directions.
// -----------------------------------------------------------------------------
`default_nettype none

module dram_channel_behav (
  input  wire                       clk,
  input  wire                       rst_n,
  input  wire                       pin_ck,
  input  wire                       pin_cke,
  input  wire  [7:0]                pin_ca,
  input  wire  [hsl_pkg::PIN_W-1:0] pin_dq_i,
  input  wire                       pin_dq_oe,
  input  wire                       pin_dqs_i,
  input  wire                       mr_dbi_en,
  input  wire                       mr_dbi_ac,
  input  wire                       mr_repair_en,
  input  wire  [3:0]                mr_repair_lane,
  output logic [hsl_pkg::PIN_W-1:0] pin_dq_o,
  output logic                      pin_dqs_o
);
  import hsl_pkg::*;

  localparam logic [1:0] PH_IDLE = 2'd0;
  localparam logic [1:0] PH_CAP  = 2'd1;
  localparam logic [1:0] PH_DRV  = 2'd2;

  logic [1:0] phase;
  logic [2:0] beat;
  logic [BANK_W-1:0] b_cap;
  logic [COL_W-1:0]  c_cap;
  logic [7:0]        cap_b [0:BL-1];
  logic [DATA_W-1:0] rd_word;
  logic [BL-1:0]     rd_dbi;
  logic [ROW_W-1:0]  open_row [0:BANK_N-1];
  logic              open_v   [0:BANK_N-1];
  logic [DATA_W-1:0] mem [0:BANK_N-1][0:(1<<ROW_W)-1][0:(1<<COL_W)-1];

  // Pins -> logical {DBI, DQ}: lane i is on pin i below the bad pin, on i+1 from it.
  function automatic logic [LANE_N-1:0] from_pins(
    input logic [PIN_W-1:0] p,
    input logic             en,
    input logic [3:0]       lane
  );
    integer i;
    integer k;
    begin
      k = (en && (lane < 4'(LANE_N))) ? int'(lane) : PIN_W;
      for (i = 0; i < LANE_N; i = i + 1) begin
        from_pins[i] = (i < k) ? p[i] : p[i+1];
      end
    end
  endfunction

  // Logical {DBI, DQ} -> pins; the bad pin and, without repair, RED stay 0.
  function automatic logic [PIN_W-1:0] to_pins(
    input logic [LANE_N-1:0] l,
    input logic              en,
    input logic [3:0]        lane
  );
    integer i;
    integer k;
    begin
      k = (en && (lane < 4'(LANE_N))) ? int'(lane) : PIN_W;
      to_pins = '0;
      for (i = 0; i < PIN_W; i = i + 1) begin
        if ((i < k) && (i < LANE_N)) begin
          to_pins[i] = l[i];
        end else if (i > k) begin
          to_pins[i] = l[i-1];
        end
      end
    end
  endfunction

  wire [LANE_N-1:0]  lin      = from_pins(pin_dq_i, mr_repair_en, mr_repair_lane);
  wire [LANE_N-1:0]  lout     = from_pins(pin_dq_o, mr_repair_en, mr_repair_lane);
  wire [3:0]         opc_pin  = pin_ca[3:0];
  wire [BANK_W-1:0]  bank_pin = pin_ca[5:4];
  wire [DQ_W-1:0]    dq_b     = lin[DQ_W-1:0];
  wire               dbi_b    = lin[DQ_W];
  wire [DQ_W-1:0]    logical  = dbi_b ? ~dq_b : dq_b;

  // {flags, bytes as sent}. last is the DQ byte in the UI before beat 0.
  function automatic logic [DATA_W+BL-1:0] dbi_encode(
    input logic [DATA_W-1:0] word,
    input logic [DQ_W-1:0]   last,
    input logic              en,
    input logic              ac
  );
    logic [DATA_W-1:0] enc;
    logic [BL-1:0]     flg;
    logic [DQ_W-1:0]   sent;
    logic [DQ_W-1:0]   cmp;
    integer            b;
    begin
      enc  = word;
      flg  = '0;
      sent = last;
      for (b = 0; b < BL; b = b + 1) begin
        cmp = ac ? (word[b*DQ_W +: DQ_W] ^ sent) : word[b*DQ_W +: DQ_W];
        if (en && ($countones(cmp) > DQ_W / 2)) begin
          enc[b*DQ_W +: DQ_W] = ~word[b*DQ_W +: DQ_W];
          flg[b] = 1'b1;
        end
        sent = enc[b*DQ_W +: DQ_W];
      end
      dbi_encode = {flg, enc};
    end
  endfunction

  integer bi;
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase     <= PH_IDLE;
      beat      <= '0;
      b_cap     <= '0;
      c_cap     <= '0;
      rd_word   <= '0;
      rd_dbi    <= '0;
      pin_dq_o  <= '0;
      pin_dqs_o <= 1'b0;
      for (bi = 0; bi < BANK_N; bi = bi + 1) begin
        open_v[bi]   <= 1'b0;
        open_row[bi] <= '0;
      end
    end else begin
      pin_dq_o  <= '0;
      pin_dqs_o <= 1'b0;
      case (phase)
        PH_IDLE: begin
          if (pin_cke && pin_dqs_i) begin
            case (opc_pin)
              OPC_ACT: begin
                open_v[bank_pin]   <= 1'b1;
                open_row[bank_pin] <= dq_b;
              end
              OPC_PRE: begin
                open_v[bank_pin] <= 1'b0;
              end
              OPC_WR: begin
                phase <= PH_CAP;
                beat  <= '0;
                b_cap <= bank_pin;
                c_cap <= lin[COL_W-1:0];
              end
              OPC_RD: begin
                logic [DATA_W+BL-1:0] rd_enc;
                // pin_dq_o still holds the UI before this one (0 when idle).
                rd_enc    = dbi_encode(mem[bank_pin][open_row[bank_pin]][lin[COL_W-1:0]],
                                       lout[DQ_W-1:0], mr_dbi_en, mr_dbi_ac);
                phase     <= PH_DRV;
                beat      <= 3'd1;
                rd_word   <= rd_enc[DATA_W-1:0];
                rd_dbi    <= rd_enc[DATA_W +: BL];
                pin_dq_o  <= to_pins({rd_enc[DATA_W], rd_enc[DQ_W-1:0]}, mr_repair_en, mr_repair_lane);
                pin_dqs_o <= 1'b1;
              end
              default: ;
            endcase
          end
        end
        PH_CAP: begin
          if (pin_cke && pin_dqs_i) begin
            cap_b[beat[1:0]] <= logical;
            if (beat == BL[2:0]-3'd1) begin
              phase <= PH_IDLE;
              if (open_v[b_cap]) begin
                mem[b_cap][open_row[b_cap]][c_cap] <= {
                  (beat == 3) ? logical : cap_b[3],
                  (beat == 2) ? logical : cap_b[2],
                  (beat == 1) ? logical : cap_b[1],
                  (beat == 0) ? logical : cap_b[0]
                };
              end
            end else begin
              beat <= beat + 1'b1;
            end
          end
        end
        PH_DRV: begin
          if (beat >= BL[2:0]) begin
            phase <= PH_IDLE;
          end else begin
            pin_dq_o  <= to_pins({rd_dbi[beat[1:0]], rd_word[beat*DQ_W +: DQ_W]}, mr_repair_en, mr_repair_lane);
            pin_dqs_o <= 1'b1;
            beat      <= beat + 1'b1;
          end
        end
        default: phase <= PH_IDLE;
      endcase
    end
  end

  wire unused_pins = ^{pin_ck, pin_dq_oe};
endmodule

`default_nettype wire
