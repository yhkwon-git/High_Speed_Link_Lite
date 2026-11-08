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
// status. A start while the request port is closed is refused (LANE_BIST[21],
// MBIST[9], RDTRAIN[3]); pass and ok then read 0. MBIST does the same for a March test of the DRAM array; MBIST_LOG
// and MBIST_BITS read back its first failure and its fail log. RDTRAIN works
// the same way for read leveling and reads back one lane's result, chosen by
// [6:4] of the last write (layouts in hsl_pkg). BIRA, REPAIR and FUSE run the
// repair analysis, read back the repair table and program / load the fuses.
// ECC, ECC_INJ, ECC_CNT and ECC_ADDR control and observe the data ECC.
// TRACE, TRACE_DATA, EVCNT0/1 and MISR drive the DFD block (hsl_dfd).
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
  output logic        mb_start,
  output logic [1:0]  mb_algo,
  output logic [1:0]  mb_bank,
  output logic [7:0]  mb_row0,
  output logic [3:0]  mb_nrows_m1,
  output logic [2:0]  mb_ncl,
  output logic [3:0]  mb_log_sel,
  output logic        br_start,
  output logic        br_apply,
  output logic        rp_clear,
  output logic        fz_program,
  output logic        fz_load,
  output logic        ecc_en,
  output logic        ecc_inj_arm,
  output logic [31:0] ecc_inj_dmask,
  output logic [6:0]  ecc_inj_cmask,
  output logic        ecc_st_start,
  output logic        ecc_clear,
  output logic        tr_arm,
  output logic [2:0]  tr_trig_sel,
  output logic [3:0]  tr_post,
  output logic [1:0]  tr_flt_bank,
  output logic        tr_flt_en,
  output logic        tr_man,
  output logic [3:0]  tr_sel,
  output logic        ev_clear,
  output logic        misr_en,

  input  wire  [3:0]  train_state,
  input  wire         train_done,
  input  wire         mission_mode,
  input  wire  [15:0] err_cnt,
  input  wire         lb_busy,
  input  wire         lb_refused,
  input  wire         lb_done,
  input  wire  [7:0]  lb_lane_err,
  input  wire  [4:0]  lb_err_bursts,
  input  wire         rt_busy,
  input  wire         rt_refused,
  input  wire         rt_done,
  input  wire         rt_ok,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rt_code,
  input  wire  [hsl_pkg::DQ_W*hsl_pkg::RX_DLY_W-1:0] rt_lo,
  input  wire  [hsl_pkg::DQ_W*6-1:0]                 rt_len,
  input  wire         mb_busy,
  input  wire         mb_refused,
  input  wire         mb_done,
  input  wire  [15:0] mb_fail_cnt,
  input  wire  [hsl_pkg::ADDR_W-1:0] mb_first_addr,
  input  wire  [hsl_pkg::DATA_W-1:0] mb_first_bits,
  input  wire  [4:0]  mb_log_n,
  input  wire         mb_log_ovf,
  input  wire  [7:0]  mb_log_entry,
  input  wire         br_busy,
  input  wire         br_done,
  input  wire         br_ok,
  input  wire  [1:0]  br_rows,
  input  wire  [1:0]  br_cols,
  input  wire  [hsl_pkg::RT_N*hsl_pkg::RT_W-1:0] rep_tab,
  input  wire         fz_busy,
  input  wire         fz_loaded,
  input  wire  [3:0]  fz_ce,
  input  wire  [3:0]  fz_ue,
  input  wire  [hsl_pkg::RT_N-1:0] fz_drop,
  input  wire         ecc_inj_pend,
  input  wire         ecc_st_busy,
  input  wire         ecc_st_done,
  input  wire         ecc_st_pass,
  input  wire  [6:0]  ecc_st_fails,
  input  wire  [15:0] ecc_ce_cnt,
  input  wire  [15:0] ecc_ue_cnt,
  input  wire         ecc_log_v,
  input  wire         ecc_log_ue,
  input  wire  [6:0]  ecc_log_syn,
  input  wire  [hsl_pkg::ADDR_W-1:0] ecc_log_addr,
  input  wire         tr_recording,
  input  wire         tr_triggered,
  input  wire         tr_frozen,
  input  wire         tr_wrapped,
  input  wire  [3:0]  tr_wp,
  input  wire  [3:0]  tr_trig_pos,
  input  wire  [31:0] tr_entry,
  input  wire  [15:0] ev_act,
  input  wire  [15:0] ev_rd,
  input  wire  [15:0] ev_wr,
  input  wire  [15:0] ev_refpb,
  input  wire  [31:0] misr
);
  import hsl_pkg::*;

  logic [7:0] ctrl;
  logic [31:0] status;
  logic [31:0] lb_status;
  logic [31:0] rt_status;
  logic [2:0]  rt_sel;
  logic [1:0]  rp_sel;
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
      mb_start    <= 1'b0;
      mb_algo     <= '0;
      mb_bank     <= '0;
      mb_row0     <= '0;
      mb_nrows_m1 <= '0;
      mb_ncl      <= '0;
      mb_log_sel  <= '0;
      br_start    <= 1'b0;
      br_apply    <= 1'b0;
      rp_clear    <= 1'b0;
      fz_program  <= 1'b0;
      fz_load     <= 1'b0;
      rp_sel      <= '0;
      ecc_en        <= 1'b0;
      ecc_inj_arm   <= 1'b0;
      ecc_inj_dmask <= '0;
      ecc_inj_cmask <= '0;
      ecc_st_start  <= 1'b0;
      ecc_clear     <= 1'b0;
      tr_arm        <= 1'b0;
      tr_trig_sel   <= '0;
      tr_post       <= '0;
      tr_flt_bank   <= '0;
      tr_flt_en     <= 1'b0;
      tr_man        <= 1'b0;
      tr_sel        <= '0;
      ev_clear      <= 1'b0;
      misr_en       <= 1'b0;
    end else begin
      train_start <= 1'b0;
      zq_done     <= 1'b0;
      wrlvl_done  <= 1'b0;
      rdlvl_done  <= 1'b0;
      deskew_done <= 1'b0;
      err_clear   <= 1'b0;
      lb_start    <= 1'b0;
      rt_start    <= 1'b0;
      mb_start    <= 1'b0;
      br_start    <= 1'b0;
      br_apply    <= 1'b0;
      rp_clear    <= 1'b0;
      fz_program  <= 1'b0;
      fz_load     <= 1'b0;
      ecc_inj_arm  <= 1'b0;
      ecc_st_start <= 1'b0;
      ecc_clear    <= 1'b0;
      tr_arm       <= 1'b0;
      tr_man       <= 1'b0;
      ev_clear     <= 1'b0;
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
          CSR_MBIST: begin
            mb_start    <= cfg_wdata[0];
            mb_algo     <= cfg_wdata[2:1];
            mb_bank     <= cfg_wdata[5:4];
            mb_row0     <= cfg_wdata[15:8];
            mb_nrows_m1 <= cfg_wdata[19:16];
            mb_ncl      <= cfg_wdata[22:20];
          end
          CSR_MBIST_LOG: mb_log_sel <= cfg_wdata[3:0];
          CSR_BIRA: begin
            br_start <= cfg_wdata[0];
            br_apply <= cfg_wdata[1];
            rp_clear <= cfg_wdata[2];
          end
          CSR_REPAIR: rp_sel <= cfg_wdata[1:0];
          CSR_FUSE: begin
            fz_program <= cfg_wdata[0];
            fz_load    <= cfg_wdata[1];
          end
          CSR_ECC: begin
            ecc_en        <= cfg_wdata[0];
            ecc_inj_arm   <= cfg_wdata[1];
            ecc_st_start  <= cfg_wdata[2];
            ecc_clear     <= cfg_wdata[3];
            ecc_inj_cmask <= cfg_wdata[14:8];
          end
          CSR_ECC_INJ: ecc_inj_dmask <= cfg_wdata;
          CSR_TRACE: begin
            tr_arm      <= cfg_wdata[0];
            tr_trig_sel <= cfg_wdata[3:1];
            tr_post     <= cfg_wdata[7:4];
            tr_flt_bank <= cfg_wdata[9:8];
            tr_flt_en   <= cfg_wdata[10];
            tr_man      <= cfg_wdata[11];
          end
          CSR_TRACE_DATA: tr_sel <= cfg_wdata[3:0];
          CSR_EVCNT0:     ev_clear <= 1'b1;
          CSR_MISR:       misr_en <= cfg_wdata[0];
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
    lb_status[2]     = lb_done && (lb_lane_err == 8'h00) && !lb_refused;
    lb_status[3]     = lb_done && lb_single && !lb_refused;
    lb_status[7:4]   = lb_fail_lane;
    lb_status[15:8]  = lb_lane_err;
    lb_status[20:16] = lb_err_bursts;
    lb_status[21]    = lb_refused;
  end

  always_comb begin
    rt_status        = '0;
    rt_status[0]     = rt_busy;
    rt_status[1]     = rt_done;
    rt_status[2]     = rt_ok;
    rt_status[3]     = rt_refused;
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
      CSR_MBIST:     rdata_d = {mb_fail_cnt, 6'h0, mb_refused, mb_log_n, mb_log_ovf,
                                mb_done && (mb_fail_cnt == 16'h0) && !mb_refused, mb_done, mb_busy};
      CSR_MBIST_LOG: rdata_d = {4'h0, mb_log_sel, mb_log_entry, 2'h0, mb_first_addr};
      CSR_MBIST_BITS: rdata_d = mb_first_bits;
      CSR_BIRA:      rdata_d = {24'h0, br_cols, br_rows, 1'b0, br_ok, br_done, br_busy};
      CSR_REPAIR:    rdata_d = {14'h0, rp_sel, rep_tab[RT_W*rp_sel +: RT_W]};
      CSR_FUSE:      rdata_d = {16'h0, 4'(fz_drop), fz_ue, fz_ce, 2'b00, fz_loaded, fz_busy};
      CSR_ECC:       rdata_d = {9'h0, ecc_st_fails, 1'b0, ecc_log_syn, 1'b0, ecc_log_ue, ecc_log_v,
                                ecc_st_pass, ecc_st_done, ecc_st_busy, ecc_inj_pend, ecc_en};
      CSR_ECC_INJ:   rdata_d = ecc_inj_dmask;
      CSR_ECC_CNT:   rdata_d = {ecc_ue_cnt, ecc_ce_cnt};
      CSR_ECC_ADDR:  rdata_d = {18'h0, ecc_log_addr};
      CSR_TRACE:     rdata_d = {20'h0, tr_trig_pos, tr_wp, tr_wrapped, tr_frozen, tr_triggered,
                                tr_recording};
      CSR_TRACE_DATA: rdata_d = tr_entry;
      CSR_EVCNT0:    rdata_d = {ev_rd, ev_act};
      CSR_EVCNT1:    rdata_d = {ev_refpb, ev_wr};
      CSR_MISR:      rdata_d = misr;
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
