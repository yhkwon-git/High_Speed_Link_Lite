`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// hsl_phy_rx
// After rd_start, the next BL controller clocks are data beats from the model.
// DBI on the pin is undone here so the host sees logical bytes.
// loopback returns lb_data in one cycle and does not use the pins.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_phy_rx (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       rd_start,
  input  logic [hsl_pkg::PIN_W-1:0]  dq_i,
  input  logic                       dqs_i,
  input  logic [hsl_pkg::DATA_W-1:0] lb_data,
  input  logic                       loopback,
  output logic                       rsp_valid,
  output logic [hsl_pkg::DATA_W-1:0] rsp_rdata
);
  import hsl_pkg::*;

  logic              cap;
  logic [2:0]        nbeat;
  logic [DATA_W-1:0] acc;

  wire [DQ_W-1:0] pin_byte = dq_i[DQ_W-1:0];
  wire            pin_dbi  = dq_i[DBI_LSB];
  wire [DQ_W-1:0] logical  = pin_dbi ? ~pin_byte : pin_byte;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap       <= 1'b0;
      nbeat     <= '0;
      acc       <= '0;
      rsp_valid <= 1'b0;
      rsp_rdata <= '0;
    end else begin
      rsp_valid <= 1'b0;
      if (rd_start && loopback) begin
        cap       <= 1'b0;
        rsp_valid <= 1'b1;
        rsp_rdata <= lb_data;
      end else if (rd_start) begin
        cap   <= 1'b1;
        nbeat <= '0;
        acc   <= '0;
      end else if (cap) begin
        logic [DATA_W-1:0] next_acc;
        next_acc = acc;
        next_acc[nbeat*DQ_W +: DQ_W] = logical;
        acc <= next_acc;
        if (nbeat == BL[2:0]-3'd1) begin
          cap       <= 1'b0;
          rsp_valid <= 1'b1;
          rsp_rdata <= next_acc;
        end else begin
          nbeat <= nbeat + 1'b1;
        end
      end
    end
  end

  wire unused_dqs = dqs_i;
endmodule

`default_nettype wire
