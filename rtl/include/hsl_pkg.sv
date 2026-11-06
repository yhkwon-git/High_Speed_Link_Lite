`timescale 1ns/100fs
// High-Speed Link Lite
// Study-scale digital model of an HBM-style base-die link.
// Parameters below are project choices, not JEDEC values.
package hsl_pkg;

  localparam logic [31:0] HSL_ID      = 32'h4853_4C31; // ASCII "HSL1"
  localparam logic [31:0] HSL_VERSION = 32'h0000_0100; // v0.1.0

  // Sim/SDC periods after E7. See docs/02_architecture.md and docs/e12_clocks.md.
  // Controller 800 MHz, PHY/CK 1.6 GHz, ratio 2.
  localparam int CTRL_PERIOD_PS = 1250;
  localparam int PHY_PERIOD_PS  = 625;
  localparam int DESKEW_TAPS    = 4; // one tap = one PHY beat = DDR_BITS UI

  localparam int DQ_W   = 8;
  localparam int DBI_W  = 1;
  localparam int RED_W  = 1;
  localparam int PIN_W  = DQ_W + DBI_W + RED_W; // 10
  localparam int BL     = 4;
  localparam int DDR_BITS = 2;                  // bits per DQ per CK
  localparam int BANK_N = 4;
  localparam int BANK_W = 2;
  localparam int ROW_W  = 8;
  localparam int COL_W  = 4;
  localparam int DATA_W = DQ_W * BL;            // 32, one burst

  // pin_dq layout, base die toward the channel:
  //   [DQ_W-1:0]                 DQ
  //   [DQ_W+DBI_W-1:DQ_W]        DBI
  //   [PIN_W-1:DQ_W+DBI_W]       redundant DQ
  localparam int DBI_LSB = DQ_W;
  localparam int RED_LSB = DQ_W + DBI_W;

  // Burst layout is beat-major. Beat 0 is the first UI on the pin.
  //   beat b occupies [b*DQ_W +: DQ_W], and bit i inside a beat is DQi.
  // DBI flag [b] belongs to that beat. See docs/03_microarchitecture.md.

  localparam logic [3:0] OPC_NOP  = 4'h0;
  localparam logic [3:0] OPC_ACT  = 4'h1;
  localparam logic [3:0] OPC_PRE  = 4'h2;
  localparam logic [3:0] OPC_PREA = 4'h3;
  localparam logic [3:0] OPC_RD   = 4'h4;
  localparam logic [3:0] OPC_WR   = 4'h5;
  localparam logic [3:0] OPC_REF  = 4'h6;
  localparam logic [3:0] OPC_REFA = 4'h7;
  localparam logic [3:0] OPC_MRS  = 4'h8;
  localparam logic [3:0] OPC_PDE  = 4'h9;
  localparam logic [3:0] OPC_PDX  = 4'hA;

  localparam logic [3:0] TR_RESET   = 4'd0;
  localparam logic [3:0] TR_CKE     = 4'd1;
  localparam logic [3:0] TR_MRS     = 4'd2;
  localparam logic [3:0] TR_ZQCAL   = 4'd3;
  localparam logic [3:0] TR_WRLVL   = 4'd4;
  localparam logic [3:0] TR_RDLVL   = 4'd5;
  localparam logic [3:0] TR_DESKEW  = 4'd6;
  localparam logic [3:0] TR_WRTRAIN = 4'd7;
  localparam logic [3:0] TR_MISSION = 4'd8;

  localparam logic [7:0] CSR_ID      = 8'h00;
  localparam logic [7:0] CSR_VERSION = 8'h04;
  localparam logic [7:0] CSR_CTRL    = 8'h08;
  localparam logic [7:0] CSR_STATUS  = 8'h0C;
  localparam logic [7:0] CSR_TRAIN   = 8'h10;
  localparam logic [7:0] CSR_ERRCNT  = 8'h14;
  localparam logic [7:0] CSR_REMAP   = 8'h18;
  localparam logic [7:0] CSR_TIMING0 = 8'h1C;
  localparam logic [7:0] CSR_TIMING1 = 8'h20;

  localparam int CTRL_SOFT_RST     = 0;
  localparam int CTRL_TRAIN_BYPASS = 1;
  localparam int CTRL_LOOPBACK     = 2;
  localparam int CTRL_PRBS_EN      = 3;
  localparam int CTRL_DBI_EN       = 4;
  localparam int CTRL_PHY_BYPASS   = 5;
  localparam int CTRL_DBI_AC       = 6; // 0: DC rule, 1: AC rule

  localparam int TRAIN_START  = 0;
  localparam int TRAIN_ZQ     = 1;
  localparam int TRAIN_WRLVL  = 2;
  localparam int TRAIN_RDLVL  = 3;
  localparam int TRAIN_DESKEW = 4;

  localparam int STAT_STATE_LSB  = 1;
  localparam int STAT_STATE_MSB  = 4;
  localparam int STAT_TRAIN_DONE = 5;
  localparam int STAT_MISSION    = 6;
  localparam int STAT_SOFT_RST   = 7;

  // Study timings in controller clocks. Not a JEDEC AC table.
  localparam logic [7:0] T_RCD = 8'd4;
  localparam logic [7:0] T_RP  = 8'd4;
  localparam logic [7:0] T_RAS = 8'd10;
  localparam logic [7:0] T_CCD = 8'd2;
  localparam logic [7:0] T_WTR = 8'd4;
  localparam logic [7:0] T_WR  = 8'd4;
  localparam logic [7:0] T_RTP = 8'd3;
  localparam logic [7:0] T_RFC = 8'd20;

  // TIMING0: {tCCD, tRAS, tRP, tRCD}, tRCD in [7:0]
  // TIMING1: {tRFC, tRTP, tWR, tWTR}, tWTR in [7:0]
  localparam logic [31:0] TIMING0_DEFAULT = {T_CCD, T_RAS, T_RP, T_RCD};
  localparam logic [31:0] TIMING1_DEFAULT = {T_RFC, T_RTP, T_WR, T_WTR};

endpackage
