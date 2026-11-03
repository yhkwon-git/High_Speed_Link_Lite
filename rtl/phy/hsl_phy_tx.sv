`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_phy_tx
// phy_bypass command framer. One controller cycle per symbol, no DDR timing.
//
//   ACT:  one cycle, row on DQ[7:0], dqs=1
//   PRE:  one cycle, dqs=1
//   WR:   one header (col on DQ[3:0]) plus BL data beats
//   RD:   one header, then rd_start so the RX captures BL beats
//   NOP:  accepted in IDLE, pins stay quiet
//
// wdata is post-DBI and post-repair. raw_data is post-DBI and pre-repair
// so the redundant pin can carry the displaced bit.
// ready is 0 outside phy_bypass, so the gearbox path cannot pop a command.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_tx (
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        cke,
  input  wire                        phy_bypass,
  input  wire                        valid,
  output logic                       ready,
  input  wire  [3:0]                 opc,
  input  wire  [hsl_pkg::BANK_W-1:0] bank,
  input  wire  [hsl_pkg::ROW_W-1:0]  row,
  input  wire  [hsl_pkg::COL_W-1:0]  col,
  input  wire  [hsl_pkg::DATA_W-1:0] wdata,
  input  wire  [hsl_pkg::DATA_W-1:0] raw_data,
  input  wire  [hsl_pkg::BL-1:0]     dbi_flags,
  input  wire                        repair_en,
  input  wire  [3:0]                 repair_lane,
  output logic [7:0]                 ca,
  output logic [hsl_pkg::PIN_W-1:0]  dq_o,
  output logic                       dq_oe,
  output logic                       dqs_o,
  output logic                       rd_start
);
  import hsl_pkg::*;

  localparam logic [2:0] S_IDLE = 3'd0;
  localparam logic [2:0] S_ACT  = 3'd1;
  localparam logic [2:0] S_PRE  = 3'd2;
  localparam logic [2:0] S_WH   = 3'd3;
  localparam logic [2:0] S_WD   = 3'd4;
  localparam logic [2:0] S_RH   = 3'd5;
  localparam logic [2:0] S_RW   = 3'd6;

  logic [2:0] st;
  logic [2:0] idx;
  logic [3:0] opc_r;
  logic [BANK_W-1:0] bank_r;
  logic [ROW_W-1:0] row_r;
  logic [COL_W-1:0] col_r;
  logic [DATA_W-1:0] data_r;
  logic [DATA_W-1:0] raw_r;
  logic [BL-1:0] dbi_r;

  assign ready    = phy_bypass && (st == S_IDLE);
  assign rd_start = (st == S_RH);

  function automatic logic red_of(input logic [2:0] beat);
    if (repair_en && (repair_lane < 4'd8)) begin
      red_of = raw_r[beat*DQ_W + 32'(repair_lane)];
    end else begin
      red_of = 1'b0;
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= S_IDLE;
      idx      <= '0;
      opc_r    <= '0;
      bank_r   <= '0;
      row_r    <= '0;
      col_r    <= '0;
      data_r   <= '0;
      raw_r    <= '0;
      dbi_r    <= '0;
      ca       <= '0;
      dq_o     <= '0;
      dq_oe    <= 1'b0;
      dqs_o    <= 1'b0;
    end else if (!phy_bypass) begin
      st       <= S_IDLE;
      ca       <= '0;
      dq_o     <= '0;
      dq_oe    <= 1'b0;
      dqs_o    <= 1'b0;
    end else begin
      ca       <= '0;
      dq_o     <= '0;
      dq_oe    <= 1'b0;
      dqs_o    <= 1'b0;
      case (st)
        S_IDLE: begin
          if (valid) begin
            opc_r  <= opc;
            bank_r <= bank;
            row_r  <= row;
            col_r  <= col;
            data_r <= wdata;
            raw_r  <= raw_data;
            dbi_r  <= dbi_flags;
            case (opc)
              OPC_ACT: st <= S_ACT;
              OPC_PRE: st <= S_PRE;
              OPC_WR:  st <= S_WH;
              OPC_RD:  st <= S_RH;
              default: st <= S_IDLE;
            endcase
          end
        end
        S_ACT: begin
          ca    <= {2'b00, bank_r, OPC_ACT};
          dq_o  <= {{(PIN_W-ROW_W){1'b0}}, row_r};
          dq_oe <= 1'b1;
          dqs_o <= 1'b1;
          st    <= S_IDLE;
        end
        S_PRE: begin
          ca    <= {2'b00, bank_r, OPC_PRE};
          dqs_o <= 1'b1;
          st    <= S_IDLE;
        end
        S_WH: begin
          ca    <= {2'b00, bank_r, OPC_WR};
          dq_o  <= {{(PIN_W-COL_W){1'b0}}, col_r};
          dq_oe <= 1'b1;
          dqs_o <= 1'b1;
          idx   <= '0;
          st    <= S_WD;
        end
        S_WD: begin
          ca    <= {2'b00, bank_r, OPC_WR};
          dq_o  <= {red_of(idx), dbi_r[idx[1:0]], data_r[idx*DQ_W +: DQ_W]};
          dq_oe <= 1'b1;
          dqs_o <= 1'b1;
          if (idx == 3'(BL-1)) begin
            st <= S_IDLE;
          end else begin
            idx <= idx + 1'b1;
          end
        end
        S_RH: begin
          ca       <= {2'b00, bank_r, OPC_RD};
          dq_o     <= {{(PIN_W-COL_W){1'b0}}, col_r};
          dq_oe    <= 1'b1;
          dqs_o    <= 1'b1;
          idx      <= '0;
          st       <= S_RW;
        end
        S_RW: begin
          if (idx == 3'(BL-1)) begin
            st <= S_IDLE;
          end else begin
            idx <= idx + 1'b1;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  wire unused_cke = cke;
  wire unused_opc_r = |opc_r;
endmodule

`default_nettype wire
