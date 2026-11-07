`timescale 1ns/100fs
// -----------------------------------------------------------------------------
// hsl_csr
// Host-facing control and status. Byte-addressed, 32-bit. Read data leaves a
// register: cfg_rdata holds the register at cfg_addr as of the last clock
// edge, so a read takes one clock and no input reaches cfg_rdata through
// logic alone (the chip STA flagged that feedthrough against the I/O budget).
//
// soft_rst is produced here and must not reset this block. Otherwise the bit
// clears itself and the datapath cannot be held in reset.
// A write to ERRCNT is a clear pulse. ID, VERSION, STATUS and TIMING0/1 ignore
// writes: the timings are the controller's dram_pkg constants. CTRL bit 5
// (the old phy_bypass) is reserved and reads 0.
// A write to LANE_BIST with bit 0 set starts a lane test; reads return its
// status. RDTRAIN works the same way for read leveling and reads back one
// lane's result, chosen by [6:4] of the last write (layouts in hsl_pkg).
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
  output logic        phy_en,
  output logic        train_start,
  output logic        zq_done,
  output logic        wrlvl_done,
  output logic        rdlvl_done,
  output logic        deskew_done,
  output logic [7:0]  train_wait,
  output logic        repair_en,
  output logic [3:0]  repair_lane,
  output logic        err_clear,
  output logic        lb_start,
  output logic [1:0]  lb_bank,
  output logic [7:0]  lb_row,
  output logic        rt_start,

  input  wire  [3:0]  train_state,
  input  wire         train_done,
  input  wire         mission_mode,
  input  wire  [15:0] err_cnt,
  input  wire         lb_busy,
  input  wire         lb_done,
  input  wire  [7:0]  lb_lane_err,
  input  wire  [4:0]  lb_err_bursts,
  input  wire         rt_busy,
  input  wire         rt_done,
  input  wire         rt_ok,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rt_code,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rt_lo,
  input  wire  [hsl_pkg::DQ_W*6-1:0]                 rt_len
);
  import hsl_pkg::*;

  logic [7:0] ctrl;
  logic [31:0] status;
  logic [31:0] lb_status;
  logic [31:0] rt_status;
  logic [2:0]  rt_sel;
  logic        lb_single;
  logic [3:0]  lb_fail_lane;
  logic [31:0] rdata_d;
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
      lb_start    <= 1'b0;
      lb_bank     <= '0;
      lb_row      <= '0;
      rt_start    <= 1'b0;
      rt_sel      <= '0;
    end else begin
      train_start <= 1'b0;
      zq_done     <= 1'b0;
      wrlvl_done  <= 1'b0;
      rdlvl_done  <= 1'b0;
      deskew_done <= 1'b0;
      err_clear   <= 1'b0;
      lb_start    <= 1'b0;
      rt_start    <= 1'b0;
      if (cfg_we) begin
        case (cfg_addr)
          CSR_CTRL: ctrl <= cfg_wdata[7:0] & 8'hDF;
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
          CSR_LANE_BIST: begin
            lb_start <= cfg_wdata[0];
            lb_bank  <= cfg_wdata[5:4];
            lb_row   <= cfg_wdata[15:8];
          end
          CSR_RDTRAIN: begin
            rt_start <= cfg_wdata[0];
            rt_sel   <= cfg_wdata[6:4];
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
  assign phy_en       = ctrl[CTRL_PHY_EN];

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
    rt_status        = '0;
    rt_status[0]     = rt_busy;
    rt_status[1]     = rt_done;
    rt_status[2]     = rt_ok;
    rt_status[6:4]   = rt_sel;
    rt_status[12:8]  = rt_code[rt_sel*RX_DLY_W +: RX_DLY_W];
    rt_status[20:16] = rt_lo[rt_sel*RX_DLY_W +: RX_DLY_W];
    rt_status[29:24] = rt_len[rt_sel*6 +: 6];
  end

  always_comb begin
    case (cfg_addr)
      CSR_ID:        rdata_d = HSL_ID;
      CSR_VERSION:   rdata_d = HSL_VERSION;
      CSR_CTRL:      rdata_d = {24'h0, ctrl};
      CSR_STATUS:    rdata_d = status;
      CSR_TRAIN:     rdata_d = {16'h0, train_wait, 8'h0};
      CSR_ERRCNT:    rdata_d = {16'h0, err_cnt};
      CSR_REMAP:     rdata_d = {24'h0, repair_lane, 3'h0, repair_en};
      CSR_TIMING0:   rdata_d = TIMING0_DEFAULT;
      CSR_TIMING1:   rdata_d = TIMING1_DEFAULT;
      CSR_LANE_BIST: rdata_d = lb_status;
      CSR_RDTRAIN:   rdata_d = rt_status;
      default:       rdata_d = 32'h0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_rdata <= '0;
    end else begin
      cfg_rdata <= rdata_d;
    end
  end
endmodule

`default_nettype wire
