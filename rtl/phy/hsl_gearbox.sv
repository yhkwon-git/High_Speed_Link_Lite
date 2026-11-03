`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_gearbox
// One controller burst (32 bits) becomes two PHY beats of 16 bits.
// Beat 0 is din[15:0] and is first. Beat 1 is din[31:16].
//
// clk_phy is 2x clk_ctrl, synchronous in the study clock generator, but the
// data bus uses a toggle handshake so the beats do not depend on a same-edge
// race. din_ready stays 0 while a burst is in flight.
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_gearbox (
  input  wire                          clk_ctrl,
  input  wire                          clk_phy,
  input  wire                          rst_n,
  input  wire  [hsl_pkg::DATA_W-1:0]   din_ctrl,
  input  wire                          din_valid,
  output logic                         din_ready,
  output logic [hsl_pkg::DQ_W*hsl_pkg::DDR_BITS-1:0] dout_phy,
  output logic                         dout_valid
);
  import hsl_pkg::*;

  logic req_tog;
  logic ack_tog;
  logic ack_s1;
  logic ack_s2;
  logic req_s1;
  logic req_s2;
  logic [DATA_W-1:0] hold;
  logic beat;
  logic [DATA_W-1:0] shift;

  assign din_ready = (req_tog == ack_s2);

  always_ff @(posedge clk_ctrl or negedge rst_n) begin
    if (!rst_n) begin
      req_tog <= 1'b0;
      ack_s1  <= 1'b0;
      ack_s2  <= 1'b0;
      hold    <= '0;
    end else begin
      ack_s1 <= ack_tog;
      ack_s2 <= ack_s1;
      if (din_valid && din_ready) begin
        hold    <= din_ctrl;
        req_tog <= ~req_tog;
      end
    end
  end

  always_ff @(posedge clk_phy or negedge rst_n) begin
    if (!rst_n) begin
      req_s1    <= 1'b0;
      req_s2    <= 1'b0;
      ack_tog   <= 1'b0;
      beat      <= 1'b0;
      shift     <= '0;
      dout_phy  <= '0;
      dout_valid <= 1'b0;
    end else begin
      req_s1 <= req_tog;
      req_s2 <= req_s1;
      if (!beat) begin
        if (req_s2 != ack_tog) begin
          shift      <= hold;
          dout_phy   <= hold[DQ_W*DDR_BITS-1:0];
          dout_valid <= 1'b1;
          beat       <= 1'b1;
        end else begin
          dout_valid <= 1'b0;
        end
      end else begin
        dout_phy   <= shift[DATA_W-1:DQ_W*DDR_BITS];
        dout_valid <= 1'b1;
        beat       <= 1'b0;
        ack_tog    <= ~ack_tog;
      end
    end
  end
endmodule

`default_nettype wire
