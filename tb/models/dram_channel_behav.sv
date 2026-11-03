`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// dram_channel_behav
// Samples the base-die pins on negedge clk. Protocol is the phy_bypass framer
// in hsl_phy_tx: ACT/PRE are one strobe, WR is a header plus BL beats, RD
// drives BL logical bytes back with DBI held 0.
// Stores one burst per {bank, open row, col}.
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
  logic [ROW_W-1:0]  open_row [0:BANK_N-1];
  logic              open_v   [0:BANK_N-1];
  logic [DATA_W-1:0] mem [0:BANK_N-1][0:(1<<ROW_W)-1][0:(1<<COL_W)-1];

  wire [3:0]         opc_pin  = pin_ca[3:0];
  wire [BANK_W-1:0]  bank_pin = pin_ca[5:4];
  wire [DQ_W-1:0]    dq_b     = pin_dq_i[DQ_W-1:0];
  wire               dbi_b    = pin_dq_i[DBI_LSB];
  wire [DQ_W-1:0]    logical  = dbi_b ? ~dq_b : dq_b;

  integer bi;
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      phase     <= PH_IDLE;
      beat      <= '0;
      b_cap     <= '0;
      c_cap     <= '0;
      rd_word   <= '0;
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
                c_cap <= pin_dq_i[COL_W-1:0];
              end
              OPC_RD: begin
                phase   <= PH_DRV;
                beat    <= 3'd1;
                rd_word <= mem[bank_pin][open_row[bank_pin]][pin_dq_i[COL_W-1:0]];
                pin_dq_o  <= {{(PIN_W-DQ_W){1'b0}},
                              mem[bank_pin][open_row[bank_pin]][pin_dq_i[COL_W-1:0]][DQ_W-1:0]};
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
            pin_dq_o  <= {{(PIN_W-DQ_W){1'b0}}, rd_word[beat*DQ_W +: DQ_W]};
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
