`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_csr
// Host-facing control and status. Byte-addressed, 32-bit, combinational read.
//
// soft_rst is produced here and must not reset this block. Otherwise the bit
// clears itself and the datapath cannot be held in reset.
// A write to ERRCNT is a clear pulse. ID, VERSION, and STATUS ignore writes.
// A write to LANE_BIST with bit 0 set starts a lane test; reads return its
// status (layout in hsl_pkg).
// Map: docs/03_microarchitecture.md
// -----------------------------------------------------------------------------
`default_nettype none

module hsl_csr (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         cfg_we,
  input  wire  [7:0]  cfg_addr,
  input  wire  [31:0] cfg_wdata,
  output logic [31:0] cfg_rdata,

  output logic        soft_rst,
  output logic        train_bypass,
  output logic        loopback,
  output logic        prbs_en,
  output logic        dbi_en,
  output logic        dbi_ac,
  output logic        phy_bypass,
  output logic        train_start,
  output logic        zq_done,
  output logic        wrlvl_done,
  output logic        rdlvl_done,
  output logic        deskew_done,
  output logic [7:0]  train_wait,
  output logic        repair_en,
  output logic [3:0]  repair_lane,
  output logic        err_clear,
  output logic [31:0] timing0,
  output logic [31:0] timing1,
  output logic        lb_start,
  output logic [1:0]  lb_bank,
  output logic [7:0]  lb_row,

  input  wire  [3:0]  train_state,
  input  wire         train_done,
  input  wire         mission_mode,
  input  wire  [15:0] err_cnt,
  input  wire         lb_busy,
  input  wire         lb_done,
  input  wire  [7:0]  lb_lane_err,
  input  wire  [4:0]  lb_err_bursts
);
  import hsl_pkg::*;

  logic [6:0] ctrl;
  logic [31:0] status;
  logic [31:0] lb_status;
  logic        lb_single;
  logic [3:0]  lb_fail_lane;
  integer      li;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ctrl        <= '0;
      train_wait  <= 8'd2;
      train_start <= 1'b0;
      zq_done     <= 1'b0;
      wrlvl_done  <= 1'b0;
      rdlvl_done  <= 1'b0;
      deskew_done <= 1'b0;
      repair_en   <= 1'b0;
      repair_lane <= 4'h0;
      err_clear   <= 1'b0;
      timing0     <= TIMING0_DEFAULT;
      timing1     <= TIMING1_DEFAULT;
      lb_start    <= 1'b0;
      lb_bank     <= '0;
      lb_row      <= '0;
    end else begin
      train_start <= 1'b0;
      zq_done     <= 1'b0;
      wrlvl_done  <= 1'b0;
      rdlvl_done  <= 1'b0;
      deskew_done <= 1'b0;
      err_clear   <= 1'b0;
      lb_start    <= 1'b0;
      if (cfg_we) begin
        case (cfg_addr)
          CSR_CTRL: ctrl <= cfg_wdata[6:0];
          CSR_TRAIN: begin
            train_wait  <= cfg_wdata[15:8];
            train_start <= cfg_wdata[TRAIN_START];
            zq_done     <= cfg_wdata[TRAIN_ZQ];
            wrlvl_done  <= cfg_wdata[TRAIN_WRLVL];
            rdlvl_done  <= cfg_wdata[TRAIN_RDLVL];
            deskew_done <= cfg_wdata[TRAIN_DESKEW];
          end
          CSR_ERRCNT: err_clear <= 1'b1;
          CSR_REMAP: begin
            repair_en   <= cfg_wdata[0];
            repair_lane <= cfg_wdata[7:4];
          end
          CSR_TIMING0: timing0 <= cfg_wdata;
          CSR_TIMING1: timing1 <= cfg_wdata;
          CSR_LANE_BIST: begin
            lb_start <= cfg_wdata[0];
            lb_bank  <= cfg_wdata[5:4];
            lb_row   <= cfg_wdata[15:8];
          end
          default: ;
        endcase
      end
    end
  end

  assign soft_rst     = ctrl[CTRL_SOFT_RST];
  assign train_bypass = ctrl[CTRL_TRAIN_BYPASS];
  assign loopback     = ctrl[CTRL_LOOPBACK];
  assign prbs_en      = ctrl[CTRL_PRBS_EN];
  assign dbi_en       = ctrl[CTRL_DBI_EN];
  assign dbi_ac       = ctrl[CTRL_DBI_AC];
  assign phy_bypass   = ctrl[CTRL_PHY_BYPASS];

  always_comb begin
    status = '0;
    status[STAT_STATE_MSB:STAT_STATE_LSB] = train_state;
    status[STAT_TRAIN_DONE]               = train_done;
    status[STAT_MISSION]                  = mission_mode;
    status[STAT_SOFT_RST]                 = soft_rst;
  end

  // One spare lane: the result is repairable when exactly one DQ lane failed.
  always_comb begin
    lb_single    = (lb_lane_err != 8'h00) && ((lb_lane_err & (lb_lane_err - 8'h01)) == 8'h00);
    lb_fail_lane = 4'h0;
    for (li = DQ_W - 1; li >= 0; li = li - 1) begin
      if (lb_lane_err[li]) begin
        lb_fail_lane = 4'(li);
      end
    end
    lb_status        = '0;
    lb_status[0]     = lb_busy;
    lb_status[1]     = lb_done;
    lb_status[2]     = lb_done && (lb_lane_err == 8'h00);
    lb_status[3]     = lb_done && lb_single;
    lb_status[7:4]   = lb_fail_lane;
    lb_status[15:8]  = lb_lane_err;
    lb_status[20:16] = lb_err_bursts;
  end

  always_comb begin
    case (cfg_addr)
      CSR_ID:      cfg_rdata = HSL_ID;
      CSR_VERSION: cfg_rdata = HSL_VERSION;
      CSR_CTRL:    cfg_rdata = {25'h0, ctrl};
      CSR_STATUS:  cfg_rdata = status;
      CSR_TRAIN:   cfg_rdata = {16'h0, train_wait, 8'h0};
      CSR_ERRCNT:  cfg_rdata = {16'h0, err_cnt};
      CSR_REMAP:   cfg_rdata = {24'h0, repair_lane, 3'h0, repair_en};
      CSR_TIMING0: cfg_rdata = timing0;
      CSR_TIMING1: cfg_rdata = timing1;
      CSR_LANE_BIST: cfg_rdata = lb_status;
      default:     cfg_rdata = 32'h0;
    endcase
  end
endmodule

`default_nettype wire
