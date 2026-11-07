`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_w1500
// IEEE 1500-style serial test port: WIR, WBY and two wrapper data registers,
// with the 1500 serial control signals (WRCK, WRSTN, SelectWIR, ShiftWR,
// CaptureWR, UpdateWR, WSI, WSO). The structure follows the standard; the
// instruction codes and data register layouts are this design's own.
//   WIR (3 bits, reset BYPASS)   000 BYPASS  WBY, 1 bit
//                                001 ID      32 bits, captures HSL_ID
//                                010 CSR     41 bits {write, addr[7:0], data[31:0]}
//                                others      BYPASS
// CSR: Update with write = 1 writes data to addr; with write = 0 reads addr,
// and the next Capture loads {0, addr, the data read}. So a read is two scans:
// one to send the address, one to bring the data out. Through this register a
// tester reaches every CSR (MBIST, repair, fuses, ECC, trace, lane repair).
// Clocking: the port is sampled in the controller clock (2-flop synchronizers
// on every input, WRCK edges found in clk). WRCK must be at least 8x slower
// than clk; there is no WRCK clock domain. Shift and Capture act on a WRCK
// rising edge, Update on a falling edge (as in 1500); WSO changes after a
// falling edge.
// While a CSR access runs (a clock for a write, two for a read) the port
// drives the CSR bus; the host must be quiet on cfg_* then.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_w1500 (
  input  wire        clk,
  input  wire        rst_n,

  input  wire        wrck,
  input  wire        wrstn,
  input  wire        selectwir,
  input  wire        shiftwr,
  input  wire        capturewr,
  input  wire        updatewr,
  input  wire        wsi,
  output logic       wso,

  output logic       bus_act,     // the port owns the CSR bus this clock
  output logic       bus_we,
  output logic [7:0] bus_addr,
  output logic [31:0] bus_wdata,
  input  wire  [31:0] bus_rdata
);
  import hsl_pkg::*;

  localparam logic [2:0] I_BYPASS = 3'b000;
  localparam logic [2:0] I_ID     = 3'b001;
  localparam logic [2:0] I_CSR    = 3'b010;

  // Input synchronizers: {wrck, wrstn, selectwir, shiftwr, capturewr, updatewr, wsi}
  logic [6:0] s1;
  logic [6:0] s2;
  logic       ck_q;
  logic       rise;
  logic       fall;
  logic       wrstn_s;
  logic       sel_s;
  logic       shift_s;
  logic       cap_s;
  logic       upd_s;
  logic       wsi_s;

  logic [2:0]  wir_sh;
  logic [2:0]  wir;
  logic        wby;
  logic [31:0] id_sh;
  logic [40:0] csr_sh;
  logic [40:0] csr_upd;     // the register the last Update took
  logic [31:0] rd_hold;     // data from the last CSR read
  logic [1:0]  acc;         // CSR access: 0 idle, 1 write, 2/3 read

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1   <= '0;
      s2   <= '0;
      ck_q <= 1'b0;
    end else begin
      s1   <= {wrck, wrstn, selectwir, shiftwr, capturewr, updatewr, wsi};
      s2   <= s1;
      ck_q <= s2[6];
    end
  end
  assign rise    = s2[6] && !ck_q;
  assign fall    = !s2[6] && ck_q;
  assign wrstn_s = s2[5];
  assign sel_s   = s2[4];
  assign shift_s = s2[3];
  assign cap_s   = s2[2];
  assign upd_s   = s2[1];
  assign wsi_s   = s2[0];

  assign bus_act   = (acc != 2'd0);
  assign bus_we    = (acc == 2'd1);
  assign bus_addr  = csr_upd[39:32];
  assign bus_wdata = csr_upd[31:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wir_sh  <= I_BYPASS;
      wir     <= I_BYPASS;
      wby     <= 1'b0;
      id_sh   <= '0;
      csr_sh  <= '0;
      csr_upd <= '0;
      rd_hold <= '0;
      acc     <= 2'd0;
      wso     <= 1'b0;
    end else if (!wrstn_s) begin
      wir_sh <= I_BYPASS;
      wir    <= I_BYPASS;
      acc    <= 2'd0;
    end else begin
      // CSR access in the controller clock.
      case (acc)
        2'd1:    acc <= 2'd0;
        2'd2:    acc <= 2'd3;
        2'd3: begin
          rd_hold <= bus_rdata;
          acc     <= 2'd0;
        end
        default: ;
      endcase

      if (rise) begin
        if (sel_s) begin
          if (cap_s)        wir_sh <= wir;
          else if (shift_s) wir_sh <= {wsi_s, wir_sh[2:1]};
        end else begin
          case (wir)
            I_ID: begin
              if (cap_s)        id_sh <= HSL_ID;
              else if (shift_s) id_sh <= {wsi_s, id_sh[31:1]};
            end
            I_CSR: begin
              if (cap_s)        csr_sh <= {1'b0, csr_upd[39:32], rd_hold};
              else if (shift_s) csr_sh <= {wsi_s, csr_sh[40:1]};
            end
            default: begin
              if (cap_s)        wby <= 1'b0;
              else if (shift_s) wby <= wsi_s;
            end
          endcase
        end
      end

      if (fall) begin
        if (upd_s) begin
          if (sel_s) begin
            wir <= wir_sh;
          end else if (wir == I_CSR) begin
            csr_upd <= csr_sh;
            acc     <= csr_sh[40] ? 2'd1 : 2'd2;
          end
        end
        // WSO: the low bit of the selected register, after the falling edge.
        if (sel_s) begin
          wso <= wir_sh[0];
        end else begin
          case (wir)
            I_ID:    wso <= id_sh[0];
            I_CSR:   wso <= csr_sh[0];
            default: wso <= wby;
          endcase
        end
      end
    end
  end
  wire unused_upd = csr_upd[40];   // the write flag acts at Update
endmodule

`default_nettype wire
