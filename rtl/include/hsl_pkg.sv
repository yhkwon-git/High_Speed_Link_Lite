`timescale 1ns/100fs
// High-Speed Link Lite
// Study-scale digital model of an HBM-style base-die link.
// Parameters below are project choices, not JEDEC values.
// The memory controller is Mini DRAM Controller v4 (rtl/mc/, dram_pkg); its
// geometry and timing come from dram_pkg, which is compiled first.
package hsl_pkg;
  import dram_pkg::*;

  localparam logic [31:0] HSL_ID      = 32'h4853_4C31; // ASCII "HSL1"
  localparam logic [31:0] HSL_VERSION = 32'h0000_0400; // v0.4.0: + MBIST, repair, ECC, DFD, 1500 port

  // Sim/SDC periods after E7. See docs/02_architecture.md and docs/e12_clocks.md.
  // Controller 800 MHz, PHY/CK 1.6 GHz, ratio 2.
  localparam int CTRL_PERIOD_PS = 1250;
  localparam int PHY_PERIOD_PS  = 625;
  localparam int DESKEW_TAPS    = 4; // one tap = one PHY beat = DDR_BITS UI

  localparam int DQ_W   = 8;
  localparam int DBI_W  = 1;
  localparam int RED_W  = 1;
  localparam int PIN_W  = DQ_W + DBI_W + RED_W; // 10
  localparam int LANE_N = DQ_W + DBI_W;         // 9 logical lanes: {DBI, DQ}
  localparam int BL     = 4;
  localparam int DDR_BITS = 2;                  // bits per DQ per CK
  localparam int BANK_N = NUM_BANKS;            // 4, from dram_pkg
  localparam int BANK_W = BANK_BITS;            // 2
  localparam int ROW_W  = ROW_BITS;             // 8
  localparam int COL_W  = COL_BITS;             // 4
  localparam int ADDR_W = ADDR_BITS;            // 14, host word address
  localparam int DATA_W = DQ_W * BL;            // 32, one burst = DATA_BITS

  // The controller's address map (mem_ctrl ADDR_MAP): host word address
  // {row, bank ^ row[1:0], col}. XOR is its own inverse, so host_addr gives
  // the host word that lands on a chosen bank, row and column.
  localparam int MC_ADDR_MAP = MAP_XOR;

  function automatic logic [ADDR_W-1:0] host_addr(
    input logic [BANK_W-1:0] bank,
    input logic [ROW_W-1:0]  row,
    input logic [COL_W-1:0]  col
  );
    return {row, bank ^ row[BANK_W-1:0], col};
  endfunction

  // One symbol (UI) on the pins, base die toward the channel:
  //   [DQ_W-1:0]                 DQ
  //   [DQ_W+DBI_W-1:DQ_W]        DBI
  //   [PIN_W-1:DQ_W+DBI_W]       redundant DQ
  localparam int DBI_LSB = DQ_W;
  localparam int RED_LSB = DQ_W + DBI_W;

  // Commands leave on two CA buses at the controller clock with the
  // controller's dram_cmd_e codes; data leaves as PHY beats of DDR_BITS UI.
  //   pin_rca = {rcmd[2:0], bank, row}       row bus: ACT, PRE, PREA, REF, REFPB
  //   pin_cca = {ccmd[2:0], bank, col, ap}   column bus: RD, WR, auto-precharge
  //   beat    = DDR_BITS symbols of PIN_W pins, UI 0 in the low bits
  localparam int RCA_W   = 3 + BANK_W + ROW_W;      // 13
  localparam int CCA_W   = 3 + BANK_W + COL_W + 1;  // 10
  localparam int BEAT_W  = DDR_BITS * PIN_W;        // 20
  localparam int WORD_PW = BL * PIN_W;              // 40, one burst on the pins

  // Burst layout is beat-major. Beat 0 is the first UI on the pin.
  //   beat b occupies [b*DQ_W +: DQ_W], and bit i inside a beat is DQi.
  // DBI flag [b] belongs to that beat. See docs/03_microarchitecture.md.

  localparam logic [3:0] TR_RESET   = 4'd0;
  localparam logic [3:0] TR_CKE     = 4'd1;
  localparam logic [3:0] TR_MRS     = 4'd2;
  localparam logic [3:0] TR_ZQCAL   = 4'd3;
  localparam logic [3:0] TR_WRLVL   = 4'd4;
  localparam logic [3:0] TR_RDLVL   = 4'd5;
  localparam logic [3:0] TR_DESKEW  = 4'd6;
  localparam logic [3:0] TR_WRTRAIN = 4'd7;
  localparam logic [3:0] TR_MISSION = 4'd8;

  localparam logic [7:0] CSR_ID        = 8'h00;
  localparam logic [7:0] CSR_VERSION   = 8'h04;
  localparam logic [7:0] CSR_CTRL      = 8'h08;
  localparam logic [7:0] CSR_STATUS    = 8'h0C;
  localparam logic [7:0] CSR_TRAIN     = 8'h10;
  localparam logic [7:0] CSR_ERRCNT    = 8'h14;
  localparam logic [7:0] CSR_REMAP     = 8'h18;
  localparam logic [7:0] CSR_TIMING0   = 8'h1C;
  localparam logic [7:0] CSR_TIMING1   = 8'h20;
  localparam logic [7:0] CSR_LANE_BIST = 8'h24;
  localparam logic [7:0] CSR_RDTRAIN   = 8'h28;
  localparam logic [7:0] CSR_MBIST     = 8'h2C;
  localparam logic [7:0] CSR_MBIST_LOG = 8'h30;
  localparam logic [7:0] CSR_MBIST_BITS = 8'h34;

  localparam int CTRL_SOFT_RST     = 0;
  localparam int CTRL_TRAIN_BYPASS = 1;
  localparam int CTRL_LOOPBACK     = 2;
  localparam int CTRL_PRBS_EN      = 3;
  localparam int CTRL_DBI_EN       = 4;
  // bit 5 was phy_bypass (the v0.1 framer); reserved, reads 0
  localparam int CTRL_DBI_AC       = 6; // 0: DC rule, 1: AC rule
  localparam int CTRL_PHY_EN       = 7; // PHY on: CK out, commands and data to the pins

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

  // LANE_BIST write: [0] start, [5:4] bank, [15:8] row: the BIST uses the 16
  //                  columns of that DRAM bank and row (host_addr).
  // LANE_BIST read:  [0] busy, [1] done, [2] pass, [3] one lane failed,
  //                  [7:4] lowest failing DQ lane, [15:8] DQ lane errors,
  //                  [20:16] bursts with a mismatch, [21] start refused
  //                  (request port closed; pass reads 0), [22] start held
  //                  while the MBIST runs (reads busy, not done).
  localparam int LB_BURSTS = 16; // words written, then read back, per run

  // MBIST: March test of DRAM bank [5:4], rows [15:8] .. +[19:16], columns
  //        0 .. 2^[22:20]-1, through the controller (hsl_mbist).
  // MBIST write:      [0] start, [2:1] algorithm (0 MATS+, 1 March X,
  //                   2 March C-), [5:4] bank, [15:8] first row,
  //                   [19:16] rows - 1, [22:20] log2 columns (0..4)
  // MBIST read:       [0] busy, [1] done, [2] pass, [3] fail log overflow,
  //                   [8:4] failing words in the log, [9] start refused
  //                   (request port closed), [10] start held while the
  //                   lane BIST runs (reads busy, not done),
  //                   [31:16] failing reads
  // MBIST_LOG write:  [3:0] fail log entry to read back
  // MBIST_LOG read:   [13:0] host address of the first failing read (0 when
  //                   none; a start clears it),
  //                   [23:16] the selected entry {row offset, column},
  //                   [27:24] its index
  // MBIST_BITS read:  bits that differed in the first failing read (0 when none)
  localparam int MB_LOG_N = 16;

  // Repair. The array has SPR_N spare rows and SPC_N spare columns (a spare
  // column replaces one column of a 16-row block). The repair table goes to the
  // array as rep_tab, one entry per spare (rows first), 16 bits each:
  //   [15] valid, [13:12] bank, [11:4] row (for a column: block << 4), [3:0] col
  // It is loaded from the fuses after reset, or from the BIRA result.
  // BIRA write:   [0] start (analyze the MBIST fail log), [1] apply the result
  //               to the repair table, [2] clear the table
  // BIRA read:    [0] busy, [1] done, [2] repairable, [5:4] spare rows used,
  //               [7:6] spare columns used
  // REPAIR write: [1:0] table entry to read back
  // REPAIR read:  [15:0] that entry, [17:16] its index
  // FUSE write:   [0] program the table into the fuses, [1] load the fuses
  // FUSE read:    [0] busy, [1] loaded, [7:4] corrected words,
  //               [11:8] uncorrectable words, [15:12] entries dropped
  // A fuse word is the entry in [15:0] of 32 data bits, SECDED (39,32).
  localparam int SPR_N   = 2;
  localparam int SPC_N   = 2;
  localparam int RT_N    = SPR_N + SPC_N;
  localparam int RT_W    = 16;
  localparam int FZ_W    = 39;
  localparam logic [7:0] CSR_BIRA   = 8'h38;
  localparam logic [7:0] CSR_REPAIR = 8'h3C;
  localparam logic [7:0] CSR_FUSE   = 8'h40;

  // ECC: SECDED (39,32) on the data, check bits on 2 ECC pins (hsl_ecc).
  // ECC write:      [0] enable, [1] arm an injection for the next write burst,
  //                 [2] start the decoder self-test, [3] clear counters and
  //                 log, [14:8] check bits to flip
  // ECC read:       [0] enable, [1] injection pending, [2] self-test busy,
  //                 [3] self-test done, [4] self-test pass, [5] an error is
  //                 logged, [6] it was uncorrectable, [14:8] its syndrome
  //                 {overall parity, s[5:0]}, [22:16] self-test failures
  // ECC_INJ:        data bits to flip (RW)
  // ECC_CNT read:   [15:0] corrected, [31:16] uncorrectable (saturating)
  // ECC_ADDR read:  [13:0] host address of the first error
  localparam logic [7:0] CSR_ECC      = 8'h44;
  localparam logic [7:0] CSR_ECC_INJ  = 8'h48;
  localparam logic [7:0] CSR_ECC_CNT  = 8'h4C;
  localparam logic [7:0] CSR_ECC_ADDR = 8'h50;

  // DFD (hsl_dfd): trace buffer, command counters, MISR.
  // TRACE write:      [0] arm, [3:1] trigger (0 ECC UE, 1 ECC CE, 2 PRBS
  //                   error, 3 MBIST fail, 4 command to the filter bank,
  //                   5 manual), [7:4] entries after the trigger, [9:8]
  //                   filter bank, [10] record only that bank's commands,
  //                   [11] manual trigger
  // TRACE read:       [0] recording, [1] triggered, [2] frozen, [3] wrapped,
  //                   [7:4] next entry, [11:8] trigger entry
  // TRACE_DATA:       write [3:0] entry to read; read the entry (hsl_dfd)
  // EVCNT0 read:      [15:0] ACT, [31:16] RD on the pins; a write clears all
  // EVCNT1 read:      [15:0] WR, [31:16] REFpb
  // MISR:             write [0] run (0 holds the seed, all ones); read the
  //                   signature of the read data to the controller
  localparam int TR_DEPTH = 16;

  // IEEE 1500-style port (hsl_w1500): WIR 000 BYPASS, 001 ID (32 bits),
  // 010 CSR (41 bits {write, addr, data}); see the module header.
  localparam logic [7:0] CSR_TRACE      = 8'h54;
  localparam logic [7:0] CSR_TRACE_DATA = 8'h58;
  localparam logic [7:0] CSR_EVCNT0     = 8'h5C;
  localparam logic [7:0] CSR_EVCNT1     = 8'h60;
  localparam logic [7:0] CSR_MISR       = 8'h64;

  // Read leveling: one delay-line code per DQ lane toward the analog PHY.
  // RDTRAIN write: [0] start, [6:4] lane to read back.
  // RDTRAIN read:  [0] busy, [1] done, [2] every lane found an eye,
  //                [3] start refused (request port closed),
  //                [6:4] lane, [12:8] its code, [20:16] eye start,
  //                [29:24] eye width in codes.
  localparam int                  RX_DLY_W   = 5;
  localparam logic [RX_DLY_W-1:0] RX_DLY_DEF = 5'd16; // before training
  localparam logic [RX_DLY_W-1:0] RX_DLY_MAX = 5'd31;
  localparam logic [5:0]          RX_EYE_MIN = 6'd2;  // narrowest run that counts

  // TIMING0/1 are read-only: the controller's timings are dram_pkg constants
  // (controller clocks, a scaled model, not a JEDEC AC table).
  // TIMING0: {tCCD_L, tRAS, tRP, tRCD}, tRCD in [7:0]
  // TIMING1: {tRFC, tRTP, tWR, tWTR_L}, tWTR_L in [7:0]
  localparam logic [31:0] TIMING0_DEFAULT = {8'(tCCD_L), 8'(tRAS), 8'(tRP), 8'(tRCD)};
  localparam logic [31:0] TIMING1_DEFAULT = {8'(tRFC), 8'(tRTP), 8'(tWR), 8'(tWTR_L)};

endpackage
