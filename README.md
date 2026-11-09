<div align="center">

# High-Speed Link Lite

**HBM Base Die 디지털 링크를 한 채널 슬라이스로 축소한 SystemVerilog RTL 설계**<br>
Spec → Architecture → RTL → Verification → PD Guide

[![RTL](https://img.shields.io/badge/RTL-SystemVerilog-1f6feb)](rtl/)
[![Sim](https://img.shields.io/badge/Sim-Verilator%205.052%20%C2%B7%20ModelSim%2010.1d-2ea44f)](sim/)
[![Synth](https://img.shields.io/badge/Synth-Yosys%200.52-8250df)](syn/)

**[📄 포트폴리오 PDF (29쪽)](portfolio-deck/HighSpeedLinkLite_Portfolio.pdf)** · [PPTX](portfolio-deck/HighSpeedLinkLite_Portfolio.pptx) · [스터디 맵](docs/00_study_map.md)

<a href="portfolio-deck/HighSpeedLinkLite_Portfolio.pdf"><img src="portfolio-deck/cover.png" width="760" alt="포트폴리오 표지. 클릭하면 PDF가 열립니다"></a>

SK hynix HBM Digital Design (RTL Design) 지원 · 권용현

</div>

## 한눈에 보기

| 설계 범위 | 회귀 | 커버리지 | 면적 | STA |
| :---: | :---: | :---: | :---: | :---: |
| **MC · PHY · DFT** | **23 / 23 PASS** | **Line 96.9%**<br>**Branch 91.5%** | **53,763 µm²**<br>**4,846 FF** | **HSL 로직 통과**<br>**MC 459 MHz** |
| RTL 35개 모듈<br>4,676줄 (주석 제외) | SMOKE · T1–T17<br>E7 · E9 · E11 | Toggle 80.2% | Nangate45<br>배선 없음 | 800 MHz · 1.6 GHz<br>RDQS · CDC |

> [!NOTE]
> 표와 아래 결과는 commit `e61e90d` 기준이다(Verilator 5.052, ModelSim-Altera 10.1d 모두 23/23 PASS). `5a24f07`은 TB에 회귀 끝 채널 모델 검사를 더하고 주석만 고쳐 결과가 같다. `0193c04`에서 메모리 컨트롤러를 [Mini DRAM Controller](https://github.com/yhkwon-git/mini-dram-controller) v4로 바꿔 PHY와 DFI 형태로 붙이고 저속 bypass framer를 없앴으며, `8af801b`에서 칩 STA(세 클럭과 CDC)를 더하고 STA가 짚은 HSL 경로를 고쳤으며, `f018966`에서 DRAM 배열의 March MBIST를, `6c29d60`에서 그 실패 로그로 spare를 고르는 BIRA와 fuse repair를, `ffc073d`에서 ECC 핀 두 개에 실은 데이터 SECDED를, `796d969`에서 trace buffer · 명령 카운터 · MISR(DFD)과 디버그 사례를, `14fec6e`에서 CSR 전체에 닿는 IEEE 1500 방식 시험 포트를 더했고, `3d596a4`에서 리뷰가 짚은 세 가지(DFD가 카운터 clear를 이벤트로 보던 것, RDQS 쪽 리셋 해제의 동기화, 요청 포트가 닫힌 채 시작한 시험 엔진)를, `e61e90d`에서 재검토가 짚은 네 가지(다른 엔진 뒤에서 기다리는 start의 CSR 표시, Gray 포인터 최상위 비트의 CDC 제약, MBIST 첫 실패 기록의 초기화, 거절된 읽기 레벨링의 결과 보존)를, `5a24f07`에서 3차 검토가 짚은 두 가지(T12에서만 보던 채널 모델 오류 검사를 회귀 끝으로, PHY를 껐다 켤 때의 soft reset 규칙)를 고쳤다. 절마다 적은 commit은 그 숫자를 잰 commit이다. PDF는 2–20쪽과 23–28쪽이 이 칩(`e61e90d`)을 담고 쪽마다 측정 commit을 적었으며, 21–22쪽은 DBI-AC와 리뷰 수정의 당시 기록이다.

## 개요

HBM base die는 스택 맨 아래의 로직 다이로, 호스트 SoC와 DRAM core die 사이에서 인터페이스, TSV 연결, 테스트를 맡는다. 표준 HBM(HBM3E까지)에서는 메모리 컨트롤러와 PHY 트레이닝 로직이 호스트 SoC에 있고, base die는 호스트가 보낸 명령을 받아 core die로 넘긴다. HBM4 세대부터 base die를 로직 공정으로 만들면서, 컨트롤러를 base die로 옮기는 custom HBM 구조가 나왔다.

이 저장소는 custom HBM 구조를 전제로, 메모리 컨트롤러 · 디지털 PHY · DFT를 가진 base die의 한 채널을 스터디 규모(DQ 8 · BL 4 · Bank 4)로 줄여 요구 스펙부터 PD 인계 문서까지 한 흐름으로 설계했다. 호스트의 읽기 · 쓰기 요청은 메모리 컨트롤러가 DRAM 명령으로 바꿔 DFI 형태로 PHY에 넘기고, PHY가 핀으로 내보낸다. 실제 custom HBM에서 이 자리는 core die로 가는 TSV 인터페이스지만, 여기서는 공개된 HBM 인터페이스 개념(행 · 열 CA, WDQS · RDQS, DBI, 레인 리페어)을 축소해 핀으로 모델링했다. 핀 너머의 DRAM 동작은 테스트벤치의 채널 모델이 맡는다.

- **경계를 먼저 정했다.** 디지털은 핀의 논리값과 enable, 핸드셰이크, CDC, 리셋, DFT 관측점을 책임진다. 드라이버, 샘플러, VREF, ZQ 회로, 클럭 스파인은 아날로그와 풀커스텀 쪽이다.
- **컨트롤러는 검증된 것을 그대로 쓴다.** 메모리 컨트롤러는 별도 저장소에서 600만 요청 랜덤 회귀와 독립 타이밍 체커로 검증한 RTL을 파일 그대로 가져온다. 이 저장소는 그 경계(DFI 형태의 명령 · 데이터 신호)와 칩 레벨 검증(핀에서 재는 프로토콜 · 타이밍 검사, 참조 메모리 스코어보드)에 집중한다.
- **숫자는 한 곳에서 내려간다.** 스펙 값은 `docs/01_requirements.md` → `hsl_pkg` → RTL → 테스트벤치 → SDC 순서로 옮긴다. DRAM 타이밍은 컨트롤러의 `dram_pkg` 하나에서 오고, TIMING CSR은 그 값을 읽기 전용으로 보여 준다. 클럭 주기는 E12 대조표로 네 곳이 같은지 확인하고, 스모크 테스트가 시작할 때 패키지 상수를 다시 검사한다.
- **근거 없는 숫자는 쓰지 않는다.** 면적과 타이밍은 공개 교육용 라이브러리(Nangate45 typical)로 잰 값이다. 배선과 클럭 트리는 넣지 않았고(이상 클럭), mW와 사인오프 slack은 적지 않는다.

공개된 HBM 개념을 교육용으로 축소한 모델이다. 특정 제품의 내부 구조나 IP를 재현하지 않으며, 파라미터와 타이밍 숫자는 JEDEC 값이 아니다. RTL 이름과 주석은 영어, 설계 문서는 한글이다.

## 설계 범위

| 영역 | 구현 | 위치 |
| --- | --- | --- |
| Memory Controller | [Mini DRAM Controller](https://github.com/yhkwon-git/mini-dram-controller) v4 RTL(그 저장소 `44a0bb3`과 같은 파일). 읽기 8 + 쓰기 8 큐, FR-FCFS, 행 · 열 명령 버스에 매 클럭 하나씩, bank group 2 × 2, per-bank refresh와 RFM, posted write, 쓰기 큐 forwarding, in-order 응답 | [`rtl/mc/`](rtl/mc/) |
| PHY digital | DFI 형태 입력(행 · 열 명령, WL 뒤 쓰기 데이터, `rddata_valid`). 행 · 열 CA 핀, 동기 2:1 TX 기어 → 1.6 GHz beat + WDQS, RDQS 캡처 → Gray FIFO, DBI(DC · AC), shift 방식 레인 리페어(spare 핀 1개, 핀마다 2:1 mux), 읽기 레벨링(레인별 지연선 코드 스윕 → eye 중앙), SECDED (39,32) ECC(ECC 핀 2개, 오류 주입, CE · UE 카운터와 첫 오류의 주소 · syndrome, 디코더 self-test), 0–4 tap deskew(블록만) | [`rtl/phy/`](rtl/phy/) |
| Control | IEEE 1500 방식 시험 포트(WIR · WBY · ID · CSR 접근 WDR), CSR 26개, 트레이닝 FSM(9개 상태, done 펄스 대기), 리셋 동기화기(비동기 assert, 2-FF 동기 deassert), 호스트 · 테스트 엔진 요청 포트 mux | [`rtl/ctrl/`](rtl/ctrl/), [`rtl/top/`](rtl/top/) |
| DFT / DFD | PRBS7, 병렬 루프백, 16 bit 포화 에러 카운터, 레인 BIST(컨트롤러 요청 포트로 PRBS7 16워드를 쓰고 큐가 빈 뒤 읽어 DQ 레인별 고장 검출), MBIST(같은 포트로 DRAM 배열에 MATS+ · March X · March C-, 실패 워드 로그 16개), BIRA(must-repair + spare 순서 탐색으로 spare row 2 · col 2 할당), repair 표와 fuse(SECDED (39,32), 리셋 뒤 자동 로드), DFD(CA 핀과 이벤트의 trigger trace 16항목, ACT · RD · WR · REFpb 카운터, 읽기 데이터 MISR), STATUS · ERRCNT · REMAP · LANE_BIST · MBIST · BIRA · FUSE 관측점 | [`rtl/dft/`](rtl/dft/) |
| PD 인계 | SDC(클럭, 생성 클럭, I/O delay, CDC `set_max_delay`), 클럭 · 리셋 · CDC · 핀 · floorplan 가이드 | [`syn/`](syn/), [`docs/05_pd_guide.md`](docs/05_pd_guide.md) |
| 검증 | 칩 레벨 테스트, 블록 테스트, DRAM 채널 모델(핀에서 프로토콜과 같은 뱅크 타이밍 검사), 모든 호스트 응답을 참조 메모리와 비교하는 스코어보드를 한 번에 도는 회귀 | [`tb/`](tb/), [`sim/`](sim/) |

## 아키텍처

```mermaid
flowchart TB
  HOST(["Host SoC · tb_hsl_smoke"])
  ATE(["Tester · 1500 직렬 포트"])
  subgraph TOP["hsl_base_die_lite"]
    CTRL["<b>Control</b><br/>rst_sync · csr · training_fsm · w1500"]
    MC["<b>Memory Controller</b><br/>mem_ctrl (Mini DRAM Controller v4)<br/>queue 8 + 8 · FR-FCFS · refresh · 800 MHz"]
    PHY["<b>PHY digital</b><br/>dbi · phy_mis · lane_shift · ecc<br/>rd_train"]
    DFT["<b>DFT / DFD</b><br/>prbs7 · loopback · err_cnt<br/>lane_bist · mbist · bira · repair<br/>dfd: trace · 카운터 · MISR"]
    CDC["<b>clk_phy</b> 1.6 GHz · <b>RDQS</b><br/>tx_gear · RDQS 캡처 · Gray FIFO"]
  end
  DRAM[("DRAM channel model · dram_channel_behav")]
  HOST -->|"cfg_*"| CTRL
  ATE -->|"WRCK · WSI / WSO"| CTRL
  HOST <-->|"req_* / rsp_*"| MC
  CTRL -.->|"mission · phy_en: 요청 포트 열림"| MC
  CTRL -.->|"dbi · repair · loopback"| PHY
  MC <-->|"DFI: rcmd · ccmd · wrdata_en / rddata_valid"| PHY
  DFT <-.->|"prbs · compare"| PHY
  DFT -.->|"lane BIST · MBIST: 요청 포트 사용"| MC
  PHY -.- CDC
  PHY <-->|"CK · RCA · CCA · beat + ECC 핀 + WDQS / RDQS"| DRAM
  PHY -.->|"rx_dly_code: 레인별 지연선 코드"| DRAM
  DFT -.->|"rep_tab: spare row · col"| DRAM
  FUSE[("fuse 모델")] <-.->|"fz_*: 프로그램 · 로드"| DFT
```

- **요청**: `req_*`(14 bit 워드 주소) → `mem_ctrl`. 주소를 XOR 맵으로 bank · row · col로 나눠 읽기 큐와 쓰기 큐에 넣는다. 쓰기는 받은 다음 클럭에 응답하고(posted), 쓰기 큐에 있는 주소를 읽으면 핀을 거치지 않고 그 데이터로 답한다. 응답은 요청 순서대로 나간다
- **명령**: 스케줄러가 매 클럭 행 명령(ACT · PRE · REFpb) 하나와 열 명령(RD · WR) 하나를 고른다. PHY는 한 클럭 뒤 `pin_rca = {cmd, bank, row}`, `pin_cca = {cmd, bank, col, ap}`로 내고, 코드는 컨트롤러의 `dram_cmd_e` 그대로다. 열 명령은 row를 싣지 않고 그 뱅크의 열린 row를 쓴다
- **쓰기 데이터**: WR 뒤 WL(1) 클럭에 `wrdata_en` → DBI(DC 또는 AC) → 레인 shift(4 심볼) → 동기 2:1 TX 기어 → `clk_phy` beat 두 개(beat당 2 UI × 10핀)와 WDQS
- **읽기 데이터**: RDQS(= CK + tDQSCK)로 beat 두 개를 받아 Gray FIFO로 컨트롤러 클럭에 넘기고, shift 복원과 DBI 복원 뒤 `rddata_valid`. 지연을 고정하지 않아도 컨트롤러가 `rddata_valid`로 진행 중인 RD를 센다. 루프백이 켜져 있으면 RD를 핀으로 내지 않고 마지막 쓰기 버스트(`lb_hold`)로 답한다
- **포트**: 요청 포트는 MISSION이면서 PHY가 켜져 있을 때(`CTRL.phy_en`)만 열린다. CK는 PHY가 켜져 있을 때만 `pin_ck`로 나간다. PHY를 끈 뒤에는 soft reset을 거쳐 다시 켠다(꺼진 동안 컨트롤러 refresh가 핀에 나가지 않는다, [한계](#한계와-다음-단계)). 레인 BIST나 MBIST가 도는 동안은 그 엔진이 포트를 쓰고 응답을 모두 가져간다(한 번에 하나). deskew는 아직 경로에 없고 블록 테스트만 한다

<details>
<summary>모듈 계층 (35개 모듈 + 패키지 2개)</summary>

```text
hsl_base_die_lite
├─ hsl_rst_sync           비동기 assert, 2-FF 동기 deassert
├─ hsl_w1500             IEEE 1500 방식 포트: WIR · WBY · ID · CSR 접근 (clk로 오버샘플)
├─ hsl_csr                CSR 26개, ID "HSL1"
├─ hsl_training_fsm       RESET → … → MISSION
├─ hsl_rd_train           읽기 레벨링: 레인별 지연선 코드 스윕, eye 중앙 (레인 BIST로 판정)
├─ mem_ctrl               Mini DRAM Controller v4 (그 저장소 44a0bb3과 같은 파일)
│  ├─ mc_queue ×2         읽기 8 · 쓰기 8, 큐 안의 나이 행렬, 주소 비교
│  ├─ mc_xage             두 큐 사이의 나이 (WDRAIN = 0일 때만 씀)
│  ├─ mc_wdrain           읽기 모드 / 쓰기 배치 (WR_HI 6, WR_LO 2)
│  ├─ mc_bank ×4          열린 row, tRCD · tRP · tRAS · tRC · tRTP · tWR, auto-precharge, RAA
│  ├─ mc_chan             bank group별 tCCD · tRRD · tWTR(S/L), tFAW · tRTW · tRFC
│  ├─ mc_refresh          per-bank refresh (tREFI/4마다 REFpb 하나)
│  ├─ mc_sched            행 · 열 명령을 매 클럭, FR-FCFS, refresh와 RFM
│  └─ mc_resp             tag, 읽기 반환 FIFO, 쓰기 데이터 파이프, in-order 응답
├─ hsl_phy_top            DBI, PRBS 먹스, 루프백 보관, CK 게이트
│  ├─ hsl_phy_clk         2배 클럭 (합성 시 빈 쉘, PLL 자리)
│  ├─ hsl_dbi             DBI-DC · DBI-AC
│  └─ hsl_phy_mis         CA 핀, TX 기어, RDQS 캡처, 읽기 FIFO
│     ├─ hsl_lane_shift   shift 방식 레인 리페어 (TX · RX, 핀마다 2:1 mux)
│     ├─ hsl_tx_gear      동기 2:1, 컨트롤러 클럭마다 워드 하나 → beat 두 개
│     ├─ hsl_cdc_fifo     Gray 포인터, RDQS → clk (쓰기 · 읽기 쪽 리셋 따로)
│     ├─ hsl_rst_sync     RDQS 쪽 리셋: 비동기 assert, RDQS 2-FF로 deassert
│     └─ hsl_ecc          SECDED (39,32): 인코더 · 디코더, 주입, CE · UE 로그, self-test
├─ hsl_dft_top
│  ├─ hsl_prbs            x⁷ + x⁶ + 1
│  ├─ hsl_loopback        병렬 루프백
│  ├─ hsl_err_cnt         16 bit 포화 카운터
│  ├─ hsl_lane_bist       레인 BIST (요청 포트로 PRBS7 쓰기 → 큐 비움 → 읽기)
│  ├─ hsl_mbist           March MBIST (MATS+ · March X · March C-, 실패 워드 로그)
│  ├─ hsl_bira            spare 할당: must-repair → spare 순서 탐색
│  └─ hsl_repair          repair 표, fuse 프로그램 · 로드
│     ├─ hsl_secded_enc   SECDED (39,32) 인코더
│     └─ hsl_secded_dec   디코더 (1 bit 정정, 2 bit 검출)
└─ hsl_dfd                trace buffer(CA 핀 · 이벤트, trigger · pre/post), 명령 카운터, MISR
hsl_deskew                레인별 0–4 tap (블록 테스트만)
```

</details>

## 설계 결정

| 결정 | 이유 | 대가와 후속 조치 |
| --- | --- | --- |
| 단일 클럭(A)으로 시작해 E7에서 컨트롤러 1 : PHY 2(B)로 전환. RTL UI 직렬화(C)는 채택하지 않음 | 명령이 드롭되지 않는 핸드셰이크와 뱅크 타이밍을 먼저 닫고 CDC를 올린다. UI 직렬화는 아날로그 PHY 경계 밖이다 | 클럭이 하나 늘고 포인터 동기화 리스크가 생긴다 → E8 Gray FIFO, E12 클럭 대조표 |
| 메모리 컨트롤러는 Mini DRAM Controller v4 RTL을 파일 그대로 쓰고, PHY와는 DFI 형태 신호로만 연결 | 컨트롤러는 자기 저장소에서 랜덤 회귀 600만 요청과 독립 타이밍 체커로 검증했다. 이 칩은 경계(행 · 열 명령 버스, WL 뒤 쓰기 데이터, `rddata_valid`)만 맞추면 되고, 두 저장소가 같은 RTL을 쓴다 | 컨트롤러를 고칠 일은 그 저장소에서 먼저 고쳐 가져온다(ModelSim 캐스트 수정, `q_empty` 출력). 그쪽 모델은 RD를 낸 뒤 3 클럭에 data_valid를 받지만 이 PHY는 8 클럭이라, RD를 4개까지만 띄우는 `RD_PIPE`가 읽기 대역을 묶는다([mission 데이터패스](#mission-데이터패스-ca-핀-16-ghz-beat-rdqs)) |
| PHY 읽기 경로는 지연을 고정하지 않고 `rddata_valid`로 알림 | RDQS 캡처와 Gray FIFO 동기화의 지연은 RDQS 위상에 따라 한 클럭쯤 달라진다. 컨트롤러가 `rddata_valid`로 진행 중인 RD를 세므로 순서만 지키면 된다 | 실제 DFI의 `tphy_rdlat` 같은 고정 지연 계약은 없다. 컨트롤러의 읽기 반환 FIFO는 PHY 왕복만큼 깊어야 한다 |
| Beat-major 데이터 배치 | DBI와 ECC가 한 UI의 바이트를 한 덩어리로 다룬다 | 레인 단위 접근은 비트를 흩어 읽는다 |
| CSR은 `rst_sync_n`만, 데이터패스는 `rst_sync_n & ~soft_rst` | CSR까지 soft reset에 넣으면 `soft_rst` 비트가 다음 사이클에 스스로 지워진다 | 리셋 도메인이 둘이 된다 |
| RDQS 도메인 플롭은 RDQS로 해제를 맞춘 자기 리셋 동기화기(`u_rst_rdqs`)를 쓰고, 읽기 FIFO의 쓰기 · 읽기 쪽 리셋을 나눔 | 리셋은 비동기로 걸어도 되지만 해제는 그 플롭의 클럭에 맞아야 recovery · removal을 지킨다. 컨트롤러 클럭에서 맞춘 해제는 RDQS와 위상 관계가 없다 | RDQS가 돌기 전(PHY off)에는 그쪽이 리셋에 머문다(T12가 확인). 이상 클럭 STA에서 그 리셋 핀의 removal이 −0.048 ns다(CTS 뒤 hold 수리 대상). 채널 모델의 RDQS가 계속 돈다는 가정에 기댄다: 실제 RDQS는 읽기 버스트 동안만 토글하므로, 실제 PHY라면 해제를 `clk` 쪽에서 맞추고 DQS gating이 캡처를 여는 구조가 필요하다 |
| CSR 읽기 데이터를 레지스터로 낸다 | 칩 STA에서 `cfg_addr` → `cfg_rdata` 조합 feedthrough가 입출력 지연(각 0.5 ns)에 걸려 −0.174 ns였다. 블록 경계에 입력 → 출력 조합 경로를 두지 않는다 | 읽기가 한 클럭 늦다. 테스트벤치는 주소를 낸 다음 엣지 뒤에 읽는다 |
| CDC: Gray 포인터는 소스 클럭의 플롭에서 넘기고, 크로싱은 false path 대신 `set_max_delay` | 조합 XOR 출력이 넘어가면 여러 비트가 바뀌는 순간의 glitch를 싱크 플롭이 잡을 수 있다. false path는 그 경로의 지연을 타이밍이 보지 않게 만든다 | 포인터 레지스터가 늘고, 제약 값을 클럭 주기와 함께 관리해야 한다 |
| mission TX 기어는 동기식, RX는 RDQS로 받아 Gray FIFO로만 넘김 | `clk_phy`는 PLL에서 컨트롤러 클럭과 위상이 맞으므로, 워드를 컨트롤러 엣지 반 주기 뒤의 PHY 엣지(E1)에서 받으면 핸드셰이크 없이 매 클럭 한 워드를 고정 지연으로 낸다. RDQS는 위상이 정해지지 않은 클럭이라 FIFO 말고는 넘어가지 않는다 | 이전의 토글 핸드셰이크 기어박스는 3 클럭에 한 워드라 교체했다. E1은 컨트롤러 토글을 PHY 클럭으로 비교해 찾는다(FF 1개) |
| 레인 리페어는 shift 방식: 고장 핀부터 위쪽 레인을 한 칸씩 spare(RED) 쪽으로 | 핀마다 자기 레인과 아래 레인 중 하나를 고르는 2:1 mux라 배선이 이웃 핀까지만 간다. 치환 방식은 모든 레인에서 spare까지 경로가 필요하다 | 고장 핀 위의 레인 번호와 핀 번호가 어긋난다 → 양 끝(PHY, DRAM)이 같은 설정을 가져야 한다. 모델은 mode register 대신 입력으로 받는다 |
| 읽기 레벨링: 지연선은 아날로그 모델로 두고 디지털은 코드만 낸다 | 디지털이 책임지는 것은 코드 스윕, 레인별 판정, 가장 긴 통과 구간 찾기, 중앙 선택이다. 지연선과 샘플러는 채널 모델이 코드에 따라 흉내 낸다(창 밖에서는 이웃 UI를 읽음) | 판정에 레인 BIST를 재사용해 코드마다 BIST 한 번(32 코드). 레인당 상태 27 FF. 쓰기 방향 레벨링은 없다 |
| 레인 BIST는 컨트롤러 요청 포트로 16워드를 쓰고, 큐가 빌 때까지 기다린 뒤 읽음 | 뱅크 타이밍, refresh, 버스 전환은 컨트롤러가 지킨다. 쓰기가 큐에 남은 채 읽으면 컨트롤러가 쓰기 큐에서 바로 답해 링크를 거치지 않으므로, 컨트롤러에 `q_empty`를 내어 그때까지 기다린다. 주소는 CA 핀으로 가므로 16 컬럼을 써도 DQ 고장이 주소에 섞이지 않는다 | BIST 중에는 호스트 포트를 막고 응답을 BIST가 가져가므로, 호스트가 조용하고 응답을 다 받은 상태에서 시작해야 한다. 요청 포트가 닫혀 있으면(MISSION이 아니거나 PHY off) start를 바로 거절한다(done · refused, MBIST와 읽기 레벨링도 같음). DBI 레인 고장은 DBI를 끈 상태에서 양방향 반전이 상쇄돼 데이터에 드러나지 않는다 |
| MBIST는 컨트롤러를 거쳐 연산을 하나씩 낸다(쓰기 뒤에는 `q_empty` + 4클럭) | 배열 앞에 컨트롤러가 있어야 refresh와 뱅크 타이밍이 지켜진다. 그런데 컨트롤러는 다른 주소의 요청 순서를 바꾸므로, 여러 개를 띄우면 배열이 받는 순서가 March 순서와 달라지고 coupling fault는 aggressor 쓰기가 victim 읽기보다 먼저 닿아야 잡힌다 | 연산당 약 13.2클럭(March C- 64워드 640연산 8,443클럭). 실제 HBM의 MBIST는 core die 쪽에서 배열을 직접 몬다. 이 모델의 MBIST는 base die에서 컨트롤러 경계를 검사하는 위치다 |
| ECC 검사 비트는 ECC 핀 두 개로 따로 보내고, 디코더 앞에 레지스터 단을 둠 | HBM의 ECC 핀처럼 검사 비트를 데이터 beat 옆에 실어 DRAM에 함께 저장한다. 인코더를 컨트롤러의 쓰기 데이터 경로에 두면 그 경로가 −1.029 ns, 디코더를 읽기 FIFO 바로 뒤에 두면 −0.403 ns였다 | 읽기 지연 한 클럭(열린 row 읽기 9 → 10). RD를 4개까지만 띄우는 컨트롤러에서 연속 읽기 32개가 76 → 97 클럭이 됐다 → `RD_PIPE`를 PHY 왕복에 맞추는 것이 다음 단계 |
| repair는 배열 쪽 spare가 하고, base die는 BIST · BIRA · fuse 로드를 맡음 | 실제 HBM에서 spare row · col과 그 치환은 core die 배열 안에 있다. base die가 주소를 바꿔 다른 row로 보내는 방식은 컬럼 spare를 만들 수 없고, 컨트롤러 앞에 조합 논리를 더한다 | repair 표(`rep_tab`)를 배열 모델에 사이드밴드로 넘긴다(읽기 지연 코드 `rx_dly_code`와 같은 꼴). JEDEC PPR 명령 인터페이스는 아니다 |
| DBI는 DC 방식(beat의 1이 4개를 넘으면 반전)으로 시작하고, AC 방식(직전 UI 대비 DQ 전이가 4개를 넘으면 반전)을 CSR로 고르게 추가 | DC는 high 개수를 줄여 high에서 종단 전류가 흐르는 I/O에 맞다. HBM처럼 종단이 없는 짧은 채널에서는 전이 수가 스위칭 전력과 SSO를 정하므로 AC가 맞다 | AC는 이전 beat의 반전 여부에 묶인 직렬 체인이다 → 원시 beat끼리 전이를 미리 세어 beat당 2:1 mux 하나로 줄임([DBI-AC](#dbi-ac-off--dc--ac-비교)) |

## 스펙 요약

| 항목 | 값 |
| --- | --- |
| DQ / DBI / RED | 8 / 1 / 1 (데이터 핀 10개) |
| 버스트 | BL 4, beat-major (beat 0이 첫 UI) |
| 뱅크 / row / col | 4 (bank group 2 × 2) / 8 bit / 4 bit. 호스트 주소는 14 bit 워드 주소, XOR 맵(bank = a[5:4] ^ a[7:6]) |
| 데이터 폭 | 32 bit (`DQ_W × BL`). 컨트롤러 클럭 한 번에 버스트 하나 |
| 목표 데이터율 | 3.2 Gb/s/DQ → raw 3.2 GB/s (리프레시, 명령 간격, 트레이닝을 빼기 전) |
| 클럭 | 컨트롤러 1.25 ns (800 MHz), PHY 0.625 ns (1.6 GHz) |
| 타이밍 (컨트롤러 클럭, `dram_pkg`) | tRCD 3 · tRP 3 · tRAS 6 · tRC 9 · tRTP 2 · tWR 2 · tCCD_S/L 1/2 · tRRD_S/L 2/3 · tWTR_S/L 2/4 · tFAW 8 · tRTW 4 · tRFC 12 · tRFCpb 8 · tREFI 64 · WL 1 |
| 트레이닝 순서 | RESET → CKE → MRS → ZQCAL → WRLVL → RDLVL → DESKEW → WRTRAIN → MISSION. 상태 순서만 있고 MRS · ZQ · leveling 명령은 핀에 내지 않는다(DRAM 쪽 DBI · 리페어 설정은 TB가 채널 모델 입력으로 넣는다). 읽기 레벨링은 MISSION에서 `RDTRAIN`으로 돌린다 |
| 전력 · 신뢰성 규칙 | CKE는 RESET에서만 0, 쓰기 beat가 없으면 TX beat는 0, DBI-DC는 beat의 1이 4개를 넘으면 반전, DBI-AC는 직전 UI 대비 DQ 전이가 4개를 넘으면 반전, 에러 카운터는 16'hFFFF에서 포화 |

```text
CK              = 3.2 Gb/s ÷ 2   = 1.6 GHz (625 ps)
Controller      = CK ÷ 2         = 800 MHz (1250 ps)
beats_per_burst = BL ÷ DDR_BITS  = 2   → PHY beat 20 bit (2 UI × 10핀)
```

<details>
<summary>CSR 맵</summary>

| 주소 | 이름 | 접근 | 내용 |
| --- | --- | --- | --- |
| `0x00` | ID | RO | `0x48534C31` ("HSL1") |
| `0x04` | VERSION | RO | `0x00000400` |
| `0x08` | CTRL | RW | `soft_rst`, `train_bypass`, `loopback`, `prbs_en`, `dbi_en`, (bit 5 예약, 0으로 읽힘), `dbi_ac`, `phy_en` |
| `0x0C` | STATUS | RO | `train_state`, `train_done`, `mission_mode`, `soft_rst` 에코 |
| `0x10` | TRAIN | RW | `[0]` start, `[4:1]` done 펄스, `[15:8]` wait |
| `0x14` | ERRCNT | RW | 읽기는 카운트, 쓰기는 clear |
| `0x18` | REMAP | RW | `[0]` enable, `[7:4]` 건너뛸 핀 (0–7 DQ, 8 DBI, 9 이상은 shift 없음) |
| `0x1C` | TIMING0 | RO | `{tCCD_L, tRAS, tRP, tRCD}`, 컨트롤러 상수 |
| `0x20` | TIMING1 | RO | `{tRFC, tRTP, tWR, tWTR_L}`, 컨트롤러 상수 |
| `0x24` | LANE_BIST | RW | 쓰기: `[0]` start, `[5:4]` bank, `[15:8]` row(그 bank · row의 컬럼 0–15를 씀). 읽기: `[0]` busy, `[1]` done, `[2]` pass, `[3]` 한 레인만 실패, `[7:4]` 실패 레인, `[15:8]` 레인별 에러, `[20:16]` 불일치 버스트 수, `[21]` 시작 거절, `[22]` 대기(MBIST가 도는 중, busy로 읽힘) |
| `0x28` | RDTRAIN | RW | 쓰기: `[0]` start, `[6:4]` 읽어 볼 레인. 읽기: `[0]` busy, `[1]` done, `[2]` 모든 레인에서 eye 찾음, `[3]` 시작 거절, `[6:4]` 레인, `[12:8]` 그 레인의 코드, `[20:16]` eye 시작, `[29:24]` eye 폭 |
| `0x2C` | MBIST | RW | 쓰기: `[0]` start, `[2:1]` 알고리즘(0 MATS+, 1 March X, 2 March C-), `[5:4]` bank, `[15:8]` 첫 row, `[19:16]` row 수 − 1, `[22:20]` log2 컬럼 수(0–4). 읽기: `[0]` busy, `[1]` done, `[2]` pass, `[3]` 로그 넘침, `[8:4]` 로그의 실패 워드 수, `[9]` 시작 거절, `[10]` 대기(레인 BIST가 도는 중, busy로 읽힘), `[31:16]` 실패 읽기 수 |
| `0x30` | MBIST_LOG | RW | 쓰기: `[3:0]` 읽을 로그 항목. 읽기: `[13:0]` 첫 실패 읽기의 호스트 주소(없으면 0, start가 지움), `[23:16]` 그 항목 `{row offset, col}`(`MBIST[8:4]` 미만만 이번 실행의 것, start는 항목을 지우지 않음), `[27:24]` 항목 번호 |
| `0x34` | MBIST_BITS | RO | 첫 실패 읽기에서 다른 비트(없으면 0) |
| `0x38` | BIRA | RW | 쓰기: `[0]` start(마지막 MBIST 로그 분석), `[1]` 결과를 repair 표에 적용, `[2]` 표 비우기. 읽기: `[0]` busy, `[1]` done, `[2]` 수리 가능, `[5:4]` 쓴 spare row, `[7:6]` 쓴 spare col |
| `0x3C` | REPAIR | RW | 쓰기: `[1:0]` 읽을 표 항목. 읽기: `[15:0]` 항목 `{valid, 0, bank, row, col}`, `[17:16]` 항목 번호 |
| `0x40` | FUSE | RW | 쓰기: `[0]` 표를 fuse에 프로그램, `[1]` fuse 로드. 읽기: `[0]` busy, `[1]` 로드됨, `[7:4]` 정정한 워드, `[11:8]` 정정 못 한 워드, `[15:12]` 버린 항목 |
| `0x44` | ECC | RW | 쓰기: `[0]` enable, `[1]` 다음 쓰기 버스트에 주입, `[2]` 디코더 self-test, `[3]` 카운터 · 로그 지우기, `[14:8]` 뒤집을 검사 비트. 읽기: `[0]` enable, `[1]` 주입 대기, `[2]` self-test busy, `[3]` done, `[4]` pass, `[5]` 오류 기록됨, `[6]` 정정 불가였음, `[14:8]` 그 syndrome `{전체 패리티, s[5:0]}`, `[22:16]` self-test 실패 수 |
| `0x48` | ECC_INJ | RW | 뒤집을 데이터 비트 |
| `0x4C` | ECC_CNT | RO | `[15:0]` 정정, `[31:16]` 정정 불가 (포화) |
| `0x50` | ECC_ADDR | RO | 첫 오류 읽기의 호스트 주소 |
| `0x54` | TRACE | RW | 쓰기: `[0]` arm, `[3:1]` trigger(0 ECC 정정 불가, 1 ECC 정정, 2 PRBS 오류, 3 MBIST 실패, 4 필터 bank 명령, 5 수동), `[7:4]` trigger 뒤 항목 수, `[9:8]` 필터 bank, `[10]` 그 bank 명령만 기록, `[11]` 수동 trigger. 읽기: `[0]` 기록 중, `[1]` trigger됨, `[2]` 멈춤, `[3]` 한 바퀴 돎, `[7:4]` 다음 항목, `[11:8]` trigger 항목 |
| `0x58` | TRACE_DATA | RW | 쓰기: `[3:0]` 읽을 항목. 읽기: 항목 `{ts[7:0], 행 CA 13, 열 {cmd, bank}, 읽기 데이터, ECC 정정, ECC 정정 불가, PRBS 오류, MBIST 실패, trigger}` |
| `0x5C` | EVCNT0 | RW | 읽기: `[15:0]` ACT, `[31:16]` RD(핀). 쓰기: 카운터 모두 지움 |
| `0x60` | EVCNT1 | RO | `[15:0]` WR, `[31:16]` REFpb |
| `0x64` | MISR | RW | 쓰기 `[0]` 동작(0이면 seed 모두 1에 묶음). 읽기: 컨트롤러로 가는 읽기 데이터의 signature |

읽기 데이터는 레지스터에서 나온다: 주소를 준 다음 클럭 엣지 뒤에 유효하다. LANE_BIST · MBIST · RDTRAIN은 요청 포트가 닫힌 채(MISSION이 아니거나 `phy_en` = 0) start하면 요청을 내지 않고 바로 done과 시작 거절 비트를 세운다(pass 0). 레인 BIST와 MBIST는 다른 엔진이 도는 동안 받은 start를 기다리게 하고, 그동안 그 엔진은 busy와 대기 비트(`LANE_BIST[22]`, `MBIST[10]`)로 읽힌다(done · pass는 0, 결과 필드는 아직 지난 실행의 값). 같은 CSR을 IEEE 1500 방식 포트의 CSR 레지스터로도 읽고 쓴다([1500 포트](#ieee-1500-방식-시험-포트)). 비트 단위 정의는 [`docs/03_microarchitecture.md`](docs/03_microarchitecture.md)에 있다.

</details>

## 검증

`tb_hsl_smoke`가 칩 전체(`hsl_base_die_lite`)와 DRAM 채널 모델을 묶고, 같은 프로세스 안에서 `tb_hsl_blocks`가 블록을 독립 인스턴스로 검사한다. 한 번의 실행이 칩, 블록, 채널 세 계층을 모두 돈다.

- **스코어보드**: 호스트 요청 포트의 응답을 모두 참조 메모리와 비교한다. 요청이 받아들여지는 순간 그 주소의 기대값을 기록하고, 응답은 요청 순서로 온다. 회귀 전체에서 요청 4,791개, 읽기 1,720개(ModelSim 1,716개)를 비교해 불일치 0이다
- **채널 모델의 핀 검사**: 프로토콜(열린 뱅크에 ACT, 닫힌 뱅크에 RD/WR, 열린 뱅크에 REFpb, 다른 버스의 명령), 같은 뱅크 타이밍(tRCD · tRP · tRAS · tRC · tRTP · 쓰기 회복 · tRFCpb · tRFC), 쓰기 데이터가 닿기 전에 같은 주소를 읽는 RD, WDQS 패턴을 세고, 회귀 끝의 `[CH]` 줄에서 모두 0이어야 한다(T13–T17 포함, `5a24f07`. 그 전에는 T12가 그때까지만 봤다). 규칙을 일부러 tRCD + 1로 바꾼 모델은 1,162건을 잡았다(`0193c04`). bank group 간 규칙(tCCD · tRRD · tFAW · tWTR · tRTW)은 컨트롤러 저장소의 체커가 맡는다
- 체크마다 PASS나 FAIL을 찍는다. 하나라도 실패하면 마지막 줄이 `[ALL] FAIL (n)`이고 0이 아닌 코드로 끝난다. 타임아웃도 실패다
- 비교는 `!==`, `===`로 한다. X나 Z가 나오면 통과가 아니라 실패다
- 리셋은 클럭 negedge에서 푼다. posedge와 같은 시각에 풀면 첫 싱크러나이저 플롭과 레이스가 생긴다

| ID | 대상 | 확인 내용 |
| --- | --- | --- |
| SMOKE | 칩 기본 동작 | ID · VERSION · TIMING(읽기 전용) 값, 미정의 주소 0, 리셋 직후 핀과 ready 0, bypass 후 MISSION이어도 PHY가 꺼져 있으면 요청 포트가 닫힘, 응답을 막으면 요청 15개(tag 16개 중 진행 중 한도)에서 ready 0, soft reset 후 복귀 |
| T1 | 트레이닝 FSM | 순서대로 진행하고, 각 대기 상태는 done 펄스가 오기 전까지 머무름 |
| T2 | 핀의 DRAM 명령 | bank 1의 두 row에 쓰고 다시 읽을 때 행 · 열 CA 핀의 코드와 간격: ACT → WR 3, WR → PRE 4, PRE → ACT 3, ACT → RD 3, RD → PRE 3(tRAS가 묶음) 클럭으로 모두 그 자리에 걸린 규칙의 최소값. idle 256 클럭 동안 bank마다 REFpb 4번 |
| T3 | 랜덤 트래픽 | 4 bank × 4 row × 16 col을 채운 뒤 요청 2,000개(읽기 · 쓰기 무작위, 임의 idle, 응답은 네 클럭 중 세 클럭만 받음). 읽기 984개 모두 일치, row hit 35%, 쓰기 큐에서 답한 읽기 15개 |
| T4 | posted write · forwarding | 쓰기는 다음 클럭에 응답. 바로 뒤 같은 주소 읽기는 쓰기 큐에서 답하고 핀에 RD가 없음. 쓰기가 나간 뒤의 읽기는 채널 모델에서 `A5A5_5A5A` |
| T5 | DBI | 핀 beat에서 `0x1F` → `E0` + DBI 1, `0x0F` → 그대로 |
| T6 | CDC FIFO | 두 클럭 사이에서 3 word 순서 유지 |
| T7 | 레인 리페어 | shift 핀 값: lane 3이면 `FF` → 핀 `1F7`(DQ3 쉼, DBI 핀이 DQ7, RED가 DBI), lane 8(DBI 핀)이면 DBI가 RED로(`200`), lane 15는 그대로. 블록: 모든 설정 × 랜덤에서 참조 모델 일치, 건너뛴 핀의 stuck 값이 RX로 들어오지 않음 |
| T8 | PRBS · 루프백 | PRBS 비교는 루프백이면 ERRCNT 0, 아니면 증가. 루프백 RD는 핀에 RD를 내지 않고 마지막 쓰기 버스트(`2222_2222`)를 돌려줌 |
| T9 | DBI-AC | 블록: 직렬 참조 모델과 랜덤 4,000 버스트 비교, 두 AC 구조 등가, 랜덤 스트림 전이 수가 이항분포 기대값과 일치. 칩: AC 핀 값 정확 비교, bank group 두 개를 번갈아 버스트가 쉬지 않고 이어지는 PRBS7 · 55/AA 쓰기 스트림의 off / DC / AC 전이 수와 규칙 위반 0, 채널 모델이 DBI를 붙인 읽기 데이터를 RX가 복원 |
| T10 | 레인 BIST · 리페어 | 칩과 채널 모델 사이 링크 핀에 stuck-at 주입 → BIST가 그 레인만 표시 → REMAP과 모델 설정 → 재검사 PASS. DQ 8레인 × stuck 0/1 = 16/16 검출, 16/16 복구. 리페어된 링크로 DBI-AC 트래픽 읽기 16개 일치. 두 레인 고장은 수리 불가로 표시 |
| T11 | 읽기 레벨링 | 레인마다 eye(통과하는 지연선 코드 구간)를 주고 학습: 고정 eye 한 번, 랜덤 eye 한 번 모두 8레인의 eye 시작 · 폭이 정확하고 코드가 중앙. 학습 전에는 eye가 기본 코드 16을 벗어난 레인만 BIST 실패, 학습 후 BIST PASS와 호스트 트래픽 읽기 16개 일치. 닫힌 eye는 실패로 표시 |
| T12 | mission 데이터패스 | 이전 in-order MC로 쟀던 WR 16 + RD 16(162 → 81 클럭), 열린 row 읽기 하나의 지연(요청 → 응답 10, 핀의 RD → `rddata_valid` 7 클럭), bank group 두 개에 걸친 읽기 32개, DBI-AC 양방향 + lane 5 stuck-at-1 리페어 트래픽, 채널 모델 오류 0. RDQS 쪽 리셋은 PHY가 꺼진 동안 걸려 있다가 mission에서 풀림 |
| T13 | MBIST | 고장 없음: 세 알고리즘 PASS. 배열 고장 24개 × 알고리즘 3개: 검출 집합이 참조 시뮬레이터(`tb/march_ref.py`)와 같고(13 · 17 · 24), 검출된 고장은 첫 실패가 victim 워드와 비트. 4 × 16 영역의 고장 워드 3개가 처음 실패한 순서로 로그에 남음(실패 읽기 7개). DQ 핀 stuck-at-1은 모든 r0에서 실패해 로그 16개가 차고 넘침 표시. 한 엔진이 도는 동안 다른 엔진의 start는 기다렸다가 돌고, 둘이 함께 busy인 클럭 0. 요청 포트가 닫힌 채(MISSION, PHY off) start하면 레인 BIST · MBIST · 읽기 레벨링이 요청 없이 바로 거절(done, refused, pass 0)하고 BIRA는 그 MBIST를 수리 불가로 봄. 다른 엔진 뒤에서 기다리는 start는 busy · 대기 비트로 읽힘(지난 실행의 done · pass가 보이지 않음), 실패한 실행 뒤 통과한 MBIST는 첫 실패 주소 · 비트가 0, 거절된 읽기 레벨링은 코드와 eye 값을 그대로 둠 |
| T14 | Repair | 고장 워드 8개: must-repair가 row +1 · +6과 col 5를 고르고, soft repair 뒤 재시험 PASS(spare로 간 접근 460). fuse 프로그램 → 표 비움 → 칩 리셋: fuse 로드가 4항목을 되살리고 재시험 PASS. fuse 워드 1 bit 반전은 정정, 2 bit는 그 항목을 버리고 col 5가 다시 실패. 대각선 5워드와 넘친 로그는 수리 불가. greedy로는 못 고치는 5워드 맵을 spare 순서 탐색이 고침. 랜덤 맵 12개에서 BIRA가 TB 참조와 모두 같고, 수리 가능한 9개 모두 재시험 PASS |
| T15 | ECC | 디코더 self-test 78 codeword PASS, 정정 플래그를 0으로 강제한 디코더는 39개 실패로 잡음. ECC on: 깨끗한 16워드는 오류 0, 주입한 데이터 1 bit 오류는 정정되고 첫 오류로 호스트 주소 · syndrome(`4E`) 기록, 검사 비트 1 bit도 정정(기록은 첫 오류 유지), 2 bit는 정정 불가로 세고 데이터는 그대로, 배열 stuck bit는 정정. ECC off에서는 같은 워드가 원래 값으로, 셈 없음. clear |
| T16 | DFD | 명령 카운터가 채널 모델과 같고(ACT 2 · RD 16 · WR 16, REFpb ±1), 읽기 16개의 MISR이 TB 참조와 같음. 수동 trigger trace가 trigger 항목을 표시하고 3항목 뒤 멈춤. bank 명령 · MBIST 실패 · PRBS 오류 · ECC 정정 불가 trigger가 각각 그 이벤트 항목에서 멈추고, MBIST 재시작과 ERRCNT · ECC clear는 trigger를 내지 않음. 디버그 사례: 채널 모델에 심은 버그(REFpb 뒤 16클럭 안의 RD가 bit 5를 뒤집음)가 ECC 정정 오류로만 보이고, bank 3만 돌린 trace(정정 오류 trigger, bank 필터) 3번 모두 REFpb → ACT(+8) → RD(+11) → 정정 오류(RD + 8)를 보임. 버그를 끄면 같은 트래픽에서 오류 0 |
| T17 | 1500 포트 | WRSTN 리셋, ID 레지스터가 `HSL1`, WIR capture가 현재 명령, WBY가 패턴을 한 비트 늦춤, CSR 레지스터로 ID CSR 읽기, MBIST March C-를 직렬 포트만으로 시작하고 끝까지 폴링(PASS, 호스트가 읽는 상태와 같음) |
| E7 | TX 기어 | 32 bit 두 워드가 연속 PHY 클럭 네 beat로(`C3D4`, `A1B2`, `7788`, `5566`) |
| E9 | Deskew | tap 0 통과, tap 2 지연 |
| E11 | PRBS seed | 리셋 seed `5A`의 첫 비트 1, seed 0 load 무시 |

```text
[T7] unit PASS
[E9] PASS
[E11] prbs PASS
[E7] PASS
[T6] PASS
[SMOKE] PASS
[T9] random stream 40000 UI, DQ+DBI per UI: toggles off 4.00 dc 4.16 ac 3.38, ones off 4.00 dc 3.27 ac 4.36
[T9] unit PASS
[T1] PASS
[T2] bank 1 at the pins: ACT +3 WR +4 PRE +3 ACT +3 WR | PRE +11 ACT +3 RD +3 PRE +3 ACT +3 RD
[T2] 256 idle cycles: REFpb per bank 4 4 4 4 (tREFI 64)
[T2] PASS
[T3] 2000 requests (984 reads) in 6033 cycles; DFI data bus busy 32.9% (1016 WR, 969 RD bursts)
[T3] at the pins: 1291 ACT, 1290 PRE, 969 RD, 1016 WR, 376 REFpb; row hits 35.0%; 15 reads answered from the write queue
[T3] PASS
[T4] PASS
[T5] PASS
[T7] PASS
[T8] PASS
[T9] PRBS7 x254, DQ+DBI per data UI: toggles off 4.03 dc 4.12 ac 3.43, ones off 4.03 dc 3.31 ac 4.36
[T9] 55/AA x254, DQ+DBI per data UI: toggles off 7.74 dc 7.71 ac 1.20, ones off 4.00 dc 4.00 ac 4.50
[T9] PASS
[T10] stuck-at on 8 DQ lanes x {0,1}: found 16/16, repaired 16/16; two lanes flagged not repairable
[T10] PASS
[T11] lane:[eye]->code 0:[3,9]->6 1:[9,17]->13 2:[18,25]->21 3:[6,17]->11 4:[20,25]->22 5:[1,10]->5 6:[12,16]->14 7:[15,25]->20
[T11] lane:[eye]->code 0:[0,6]->3 1:[9,15]->12 2:[21,26]->23 3:[3,7]->5 4:[0,10]->5 5:[18,22]->20 6:[14,24]->19 7:[7,11]->9
[T11] PASS
[T12] 16 WR + 16 RD to one row, back to back: 81 cycles from the first write request to the last read response (16 RD at the pins)
[T12] one read of an open row: 10 cycles from request to response; RD on the pins to rddata_valid 7 cycles
[T12] 32 reads over two bank groups: 97 cycles from the first request to the last response (4 RDs in flight at most)
[T12] channel model, run so far: 1616 ACT, 1611 PRE, 3245 RD, 5096 WR, 1457 REFpb; errors: protocol 0, timing 0, read before its write data 0, WDQS 0
[T12] PASS
[T13] no fault, 8 words: MATS+ 40 ops in 507 clocks, March X 48 in 616, March C- 80 in 1021
[T13] fail log: 3 words of 64 (7 failing reads), entries {row,col} 03 29 3F; March C- on 64 words: 640 ops in 8443 clocks
[T13] DQ pin 5 stuck at 1: 192 failing reads, log full (16) with overflow, first bits 20202020
[T13] a start during the other engine's run waits for it: both orders ran and passed, 0 clocks with both busy
[T13] request port closed: lane BIST, MBIST and read leveling refuse the start at once (done, refused, pass 0); BIRA calls the refused MBIST not repairable
[T13] detected: MATS+ 13/24, March X 17/24, March C- 24/24 (reference 13, 17, 24)
[T13] PASS
[T14] A: 8 failing words -> spare rows +1 +6, spare column 5 (BIRA 66); retest PASS, 460 array accesses went to spares
[T14] B: fuses programmed, table cleared, chip reset: the fuse load restored all 4 entries, retest PASS
[T14] C: fuse word 0 with 1 bit flipped: corrected (1); word 2 with 2 bits: dropped (1, map 0100); column 5 fails again: 3 words, 9 reads
[T14] D: 5 words on a diagonal, and an overflowed log: both not repairable
[T14] E: 5 words a greedy pass cannot repair: rows +10 +14, columns 9 10, retest PASS
[T14] F: 12 random maps of 3-8 words: BIRA matches the reference on all 12, 9 repairable, each passes the retest
[T14] PASS
[T15] decoder self-test: 78 codewords PASS; with its correction flag forced to 0: FAIL, 39 codewords wrong
[T15] 1-bit data error (bit 9): read back corrected 12345678; logged at 1062, syndrome 4e
[T15] 2-bit error (bits 0, 1): uncorrectable counted, data passed through as face0003
[T15] stuck array bit 17: corrected with ECC on (ffffffff), raw with ECC off (fffdffff); counts CE 3 UE 1
[T15] PASS
[T16] counters: ACT 2 RD 16 WR 16 REFpb 7, as the channel model counted; MISR of 16 reads f5dfe450 = reference
[T16] manual trigger: frozen with the trigger at entry 12 of 16 and 3 after it
[T16] debug: symptom: 32 corrected reads in 200 (host data all correct), first at 1830 = bank 3
[T16] debug capture 0: REFpb b3, then the first RD b3 11 clocks later; corrected error 8 clocks after that RD
[T16] debug capture 1: REFpb b3, then the first RD b3 11 clocks later; corrected error 8 clocks after that RD
[T16] debug capture 2: REFpb b3, then the first RD b3 11 clocks later; corrected error 8 clocks after that RD
[T16] debug: 3 of 3 captures put a REFpb to bank 3 within 16 clocks before the failing reads; without the planted bug 200 reads have 0 errors
[T16] trigger sources: bank command, MBIST fail, PRBS error and ECC uncorrectable each froze the trace on its flagged entry; an MBIST restart and the ERRCNT and ECC clears fired none
[T16] PASS
[T17] 1500 port: ID 48534c31, WBY one bit, CSR register read ID and ran MBIST March C- to PASS (2 polls of 82 bits)
[T17] PASS
[CH] channel model, whole run: 13297 ACT, 13289 PRE, 29914 RD, 31480 WR, 44418 REFpb; errors: protocol 0, timing 0, read before its write data 0, WDQS 0
[SB] 4791 host requests, 1720 reads compared against the reference memory
[ALL] PASS
```

<sub>commit `5a24f07`의 Verilator 출력이다(`e61e90d`와 비교해 T12 줄의 문구와 회귀 끝 `[CH]` 줄만 다르다). T16 디버그 사례의 trace 덤프는 [DFD](#dfd-trace-카운터-misr-디버그-사례) 절에 있다. T13의 고장별 24줄은 [MBIST](#mbist-march-알고리즘과-검출표) 절에 표로 옮겼다. ModelSim은 난수 생성기가 달라 랜덤 입력에서 나온 수만 다르고(T3의 읽기 수와 row hit, T9 랜덤 스트림의 소수 둘째 자리, T11 랜덤 eye, T12와 `[CH]`의 채널 모델 합계, `[SB]` 읽기 1,716개), 나머지 줄은 같다. T2의 `PRE +11 ACT`는 그 사이에 bank 1의 REFpb(tRFCpb 8)가 끼어서다.</sub>

![T4 파형. 쓰기 요청은 다음 클럭에 응답하고, 바로 뒤 읽기는 쓰기 큐에서 답한다. 쓰기가 나간 뒤의 읽기는 핀의 RD, RDQS beat, rddata_valid를 거쳐 응답한다](docs/images/wave_t4_channel.png)

<sub>T4, commit `0193c04`의 Verilator VCD(가운데 idle 7.1 ns는 생략). ① 쓰기 요청(호스트 주소 `1D1` = bank 2, row 07, col 1)을 받은 다음 클럭에 응답한다(posted). ② 바로 뒤 같은 주소 읽기는 쓰기 큐에서 `A5A5_5A5A`로 답하고 `pin_cca`에는 RD가 없다. 같은 클럭에 ACT b2 r07이 `pin_rca`로 나간다. ③ tRCD 3 클럭 뒤 WR b2 c1, 다음 클럭에 `wrdata_en`, 이어서 TX beat 두 개(UI 순서 `5A 5A A5 A5`)와 WDQS. 그사이 per-bank refresh(REFpb b0, b1)가 행 버스로 나간다. ④ 쓰기가 나간 뒤 같은 주소를 다시 읽으면 RD b2 c1이 핀으로 나가고, ⑤ RDQS beat 두 개가 Gray FIFO를 지나 핀의 RD 6 클럭 뒤 `rddata_valid`, 요청 9 클럭 뒤 응답이다.</sub>

<details>
<summary>모듈별 코드 커버리지 (commit <code>e61e90d</code>, Verilator)</summary>

| 모듈 | Line | Branch | Toggle |
| --- | ---: | ---: | ---: |
| mem_ctrl (top) | 100.0% | 100.0% | 86.3% |
| mc_queue | 100.0% | 100.0% | 81.1% |
| mc_xage | 100.0% | 100.0% | 100.0% |
| mc_wdrain | 100.0% | 100.0% | 96.2% |
| mc_bank | 100.0% | 88.5% | 86.2% |
| mc_chan | 100.0% | 96.2% | 46.8% |
| mc_refresh | 100.0% | 83.3% | 95.7% |
| mc_sched | 91.9% | 62.5% | 81.5% |
| mc_resp | 80.0% | 100.0% | 100.0% |
| phy_top | 100.0% | 100.0% | 82.5% |
| phy_mis | 100.0% | 100.0% | 77.5% |
| ecc | 100.0% | 100.0% | 79.0% |
| tx_gear | 100.0% | 100.0% | 84.0% |
| cdc_fifo | 100.0% | 100.0% | 66.2% |
| lane_shift | – | 100.0% | 100.0% |
| dbi | 100.0% | 75.0% | 100.0% |
| rd_train | 93.3% | 92.3% | 86.3% |
| deskew | 100.0% | 83.3% | 23.4% |
| csr | 100.0% | 100.0% | 71.7% |
| w1500 | 100.0% | 95.8% | 68.6% |
| training_fsm | 92.9% | 100.0% | 75.0% |
| rst_sync | 100.0% | 100.0% | 100.0% |
| lane_bist | 100.0% | 100.0% | 95.9% |
| mbist | 96.9% | 89.6% | 81.4% |
| bira | 91.2% | 90.6% | 87.2% |
| repair | 93.8% | 93.8% | 49.4% |
| secded_enc | 100.0% | 100.0% | 100.0% |
| secded_dec | 100.0% | 100.0% | 100.0% |
| dfd | 100.0% | 96.7% | 74.2% |
| prbs | 93.8% | 83.3% | 95.2% |
| err_cnt | 100.0% | 100.0% | 47.6% |
| loopback | – | 100.0% | 67.0% |
| **전체 (`rtl/` 35개 모듈)** | **96.9%** | **91.5%** | **80.2%** |

Verilator `--coverage-line --coverage-toggle`로 회귀 전체를 돌리고 `rtl/` 파일만 셌다. 같은 모듈의 인스턴스는 합쳤다(어느 인스턴스든 닿으면 커버). 표에 없는 top, dft_top, phy_clk도 전체에 들어 있다. 이전 in-order MC 시절(`4feb39f`)에는 87.5 / 96.6 / 56.6%였고, toggle은 T3의 랜덤 주소 · 데이터로 올랐다. `prbs`의 branch는 출력 레지스터 파라미터(`REG_OUT`)의 두 갈래가 인스턴스마다 하나씩만 쓰여 낮다. `8af801b`(MBIST 전)에는 95.8 / 89.1 / 83.7%였고, toggle이 내려간 것은 MBIST의 넓은 레지스터(첫 실패 비트 32개, 주소, 로그)가 solid background 시험에서 몇 가지 값만 지나기 때문이다(`f018966`에서 `mbist` toggle 59.1%, T14의 넓은 영역 실행으로 81.2%). `f018966`에는 96.0 / 89.4 / 81.8%였다. `6c29d60`에는 95.6 / 89.6 / 80.3%였다. SECDED 인코더 · 디코더는 데이터 ECC 트래픽과 self-test를 지나며 모두 100%가 됐다. `ffc073d`에는 95.9 / 90.8 / 78.7%, `14fec6e`에는 95.5 / 91.4 / 78.8%였다. `3d596a4`에서 T16이 trigger 원천을 모두 돌고 ERRCNT clear를 지나, `dfd` · `err_cnt`의 line이 75 · 66.7%에서 100%가 됐다(96.9 / 91.4 / 79.5%). `e61e90d`에서는 T13이 읽기 레벨링을 한 번 더 돌려 `rd_train` toggle이 70.5 → 86.3%가 됐다.

</details>

이 측정에서 닿지 않은 곳은 다음과 같다.

- 컨트롤러의 branch 구멍 대부분은 이 칩이 쓰지 않는 파라미터 경로다(all-bank refresh, close · timer page policy, 명령 버스 하나, FCFS, WL > 1). 컨트롤러 저장소는 빌드 16개로 이 경로를 돈다
- 실제로 비어 있는 곳: starvation 우선(160 클럭 대기), RFM(뱅크당 ACT 누적), refresh 부채 포화, 읽기 레벨링의 일부 else 분기
- deskew(23.4%)와 err_cnt(47.6%)는 toggle이 낮다. deskew는 블록 테스트만 있고, 에러 카운터는 상위 비트까지 차오르는 시험이 없다

## DBI-AC: off · DC · AC 비교

DBI-AC는 beat마다 직전 UI에 실제로 나간 바이트와 비교해, DQ 8개 중 4개를 넘게 바뀌면 그 beat를 반전한다. 그래서 한 UI에 바뀌는 DQ는 4개 이하다(DBI 핀은 세지 않으며 함께 바뀔 수 있다). 첫 beat의 기준은 그 앞 UI다. DQ는 데이터만 실으므로, 직전 클럭에 쓰기 버스트가 나갔으면 그 마지막 바이트, 아니면 idle 버스(0)와 비교한다. CSR `CTRL[6]`이 DC와 AC를 고른다.

| 데이터 (측정 위치) | 지표 (UI당, DQ + DBI) | off | DC | AC |
| --- | --- | ---: | ---: | ---: |
| PRBS7, 쓰기 254개 (칩 핀) | 전이 | 4.03 | 4.12 | **3.43 (−15%)** |
| | high | 4.03 | **3.31 (−18%)** | 4.36 |
| `55 AA 55 AA` 반복, 쓰기 254개 (칩 핀) | 전이 | 7.74 | 7.71 | **1.20 (−84%)** |
| 균등 랜덤 연속 스트림 40,000 UI (블록) | 전이 | 4.00 | 4.16 | **3.38** |
| | high | 4.00 | 3.27 | 4.36 |

<sub>칩 핀 값은 T9가 쓰기 beat의 UI마다 핀에서 앞 UI(앞 beat의 마지막 UI, 비어 있으면 0) 대비로 잰 값이다(commit `8af801b`). 쓰기는 bank group 두 개를 번갈아 tCCD_S = 1 간격으로 이어지므로 버스트 경계를 넘는 전이도 들어간다. 55/AA의 off가 8이 아닌 7.74인 것은 refresh 등으로 쉰 뒤의 첫 UI(idle 0 → `55`, 4개)가 섞이기 때문이다. 랜덤 스트림은 버스트가 쉬지 않고 이어지는 경우이며, 이항분포 기대값(off 4.00, DC 4.16, AC 3.37)과 ±0.05 안에서 맞는지 T9가 검사한다.</sub>

- **두 규칙은 서로 다른 것을 줄인다.** DC는 high 핀 수를, AC는 전이 수를 줄인다. 랜덤에 가까운 데이터에서 DC는 오히려 전이를 조금 늘리고, AC는 high를 조금 늘린다.
- **AC가 이기는 경우는 전이가 몰린 데이터다.** 모든 DQ가 매 UI 바뀌는 `55/AA`에서 DC는 아무것도 하지 못하고(beat마다 1이 4개), AC는 DQ를 고정하고 DBI 핀만 바꾼다.
- **읽기 방향**: 채널 모델이 모드 레지스터 대신 `mr_dbi_en` · `mr_dbi_ac` 입력으로 읽기 데이터를 같은 규칙으로 인코딩한다. 모델의 인코더는 RTL과 따로 짠 직렬 규칙이고, RX가 DBI = 1인 beat를 복원해 읽기 32개가 모두 스코어보드와 일치했다.

AC 규칙은 직렬 체인이다. beat b의 기준은 beat b−1이 반전되어 나갔는지에 달려 있다. 그대로 짜면 beat마다 XOR, popcount, 비교, 반전이 차례로 붙는다. 원시 beat끼리의 전이 수 `r_b = popcount(din_b ^ din_b−1)`를 네 beat 모두 병렬로 세면, beat b−1이 반전된 경우 전이는 `8 − r_b`이므로 `inv_b = inv_b−1 ? (r_b < 4) : (r_b > 4)`가 되어 체인에는 beat당 2:1 mux 하나만 남는다. 두 구조는 파라미터 `AC_SERIAL`로 둘 다 빌드되고, 블록 테스트가 같은 입력에서 결과가 같은지 비교한다.

| `hsl_dbi` (Nangate45 typical, 배선 없음) | 면적 | Cell | 입력 → 출력 최대 지연 |
| --- | ---: | ---: | ---: |
| DC만 (commit `4d38ae9`) | 130 µm² | 101 | 0.449 ns |
| DC + AC, mux 체인 (기본) | 289 µm² | 224 | **0.882 ns** |
| DC + AC, 직렬 (`AC_SERIAL = 1`) | 301 µm² | 229 | 1.822 ns |

<sub>`syn/ppa_block.sh`(sv2v → Yosys 0.52 → OpenSTA 3.1, 입력 BUF_X1 구동, 출력 2 fF). 직렬 구조는 이 블록 하나로 컨트롤러 주기 1.25 ns를 넘는다. 칩 STA(`8af801b`)에서 컨트롤러의 쓰기 데이터 플롭 → payload mux → DBI-AC → 레인 shift → TX 워드 레지스터는 +0.130 ns로 통과했고, PRBS 워드를 레지스터로 내기 전에는 PRBS 쪽이 −0.136 ns였다([STA](#sta-세-클럭과-cdc)).</sub>

## Mission 데이터패스: CA 핀, 1.6 GHz beat, RDQS

```text
cycle t   : 컨트롤러가 행 명령과 열 명령을 고름 → t+1에 pin_rca, pin_cca (한 클럭씩)
WR        : t+1에 wrdata_en (WL 1) → DBI → lane shift(4 심볼) → tx_word ─ E1 ─▶ beat0 (UI0, UI1) ─ E0 ─▶ beat1 (UI2, UI3) + WDQS
RD        : DRAM ─ RL ─▶ beat0, beat1 on RDQS ─▶ 캡처 플롭(RDQS) ─▶ Gray FIFO ─▶ clk ─▶ unshift ─▶ DBI 복원 ─▶ rddata_valid
```

컨트롤러 클럭(800 MHz)마다 버스트 하나(4 UI × DQ 8)를 내보내므로 핀 기준 DQ당 3.2 Gb/s에 해당한다. UI 직렬화와 지연선, 샘플러는 아날로그 쪽이고, 디지털은 `clk_phy` beat와 strobe 패턴까지 책임진다(구조 B).

| 항목 (commit `ffc073d`) | 결과 |
| --- | --- |
| 이전 in-order MC로 쟀던 트래픽: 한 row에 WR 16 → RD 16을 연달아 (첫 쓰기 요청 → 마지막 읽기 응답) | 162 → **81 클럭**(ECC의 읽기 단계 전 `8af801b`에서는 77). 읽기 16개는 모두 핀을 거쳤다. 이전 MC는 같은 뱅크의 컬럼 명령 사이에도 tWR · tRTP를 기다렸고, 지금은 같은 bank group의 tCCD_L 2 클럭과 WR → RD 전환(tWTR_L 4)이 남는다 |
| 핀의 명령 간격 (T2) | ACT → WR 3, WR → PRE 4, PRE → ACT 3, ACT → RD 3 클럭. 모두 규칙의 최소값이다 |
| 열린 row 읽기 하나 (T12) | 요청 → 응답 10 클럭, 그중 핀의 RD → `rddata_valid`가 7 클럭(ECC의 읽기 단계 전에는 9 · 6) |
| 병목: 진행 중인 RD 수 | 컨트롤러는 RD를 4개(`RD_PIPE`)까지 띄우고, RD 하나는 낸 클럭부터 data_valid를 받을 때까지 슬롯을 잡는다. 컨트롤러 저장소의 모델에서는 3 클럭이지만 이 PHY에서는 8 클럭이라, 읽기만으로는 데이터 버스의 절반까지만 쓴다. bank group 두 개에 걸친 읽기 32개가 97 클럭 걸린다(T12, ECC의 읽기 단계 전에는 76). 읽기 반환 FIFO를 PHY 왕복만큼 늘리는 것이 다음 단계다 |
| 함께 검증한 것 | DBI-AC(양방향), lane 5 stuck-at-1 리페어, 읽기 레벨링, 루프백. 채널 모델이 WDQS 패턴, 짝 없는 쓰기 데이터, 프로토콜, 같은 뱅크 타이밍을 검사해 오류 0 |

| 블록 (Nangate45 typical) | 면적 | Cell | FF |
| --- | ---: | ---: | ---: |
| `hsl_tx_gear` (40 bit → 20 bit × 2) | 325 µm² | 130 | 44 |
| `hsl_phy_mis` (CA, shift, 기어, RDQS 캡처, 깊이 4 × 40 bit FIFO, 복원) | 2,827 µm² | 1,088 | 352 |

<sub>`syn/ppa_block.sh`, `hsl_phy_mis`는 commit `0193c04`(DFI 입력), `hsl_tx_gear`는 `6a5a4ce`.</sub>

## 읽기 레벨링: 지연선 코드 스윕

디지털은 레인마다 지연선 코드(0–31, `rx_dly_code`)를 내고, 지연선과 샘플러는 아날로그 쪽이다. 여기서는 채널 모델이 그 역할을 한다: 코드가 그 레인의 eye `[lo, hi]` 안이면 자기 UI를 읽고, 앞이면 이전 UI, 뒤면 다음 UI를 읽는다(버스트 밖은 0).

`hsl_rd_train`은 모든 레인에 같은 코드 c = 0 … 31을 차례로 주고, 코드마다 레인 BIST를 한 번 돌려 레인별 통과 여부를 받는다. 레인마다 연속으로 통과한 가장 긴 구간(시작, 길이)을 기억했다가, 끝나면 코드를 `lo + (len − 1) / 2`로 둔다. 구간이 2 코드보다 짧은 레인이 있으면 `ok` = 0이다. 판정을 레인 BIST에 맡겨서 이 블록은 스윕과 구간 추적만 한다.

```text
[T11] lane:[eye]->code 0:[3,9]->6 1:[9,17]->13 2:[18,25]->21 3:[6,17]->11 4:[20,25]->22 5:[1,10]->5 6:[12,16]->14 7:[15,25]->20
```

<sub>T11 고정 eye 회차. 레인 0, 2, 4, 5는 eye가 기본 코드 16을 벗어나서, 학습 전 BIST가 정확히 그 네 레인(`0x35`)을 실패로 표시한다. 학습 뒤에는 BIST와 호스트 트래픽이 모두 통과한다. 랜덤 eye 회차도 8레인 모두 eye 시작 · 폭과 중앙 코드가 정확했다.</sub>

| 블록 (Nangate45 typical) | 면적 | Cell | FF | 최대 경로 |
| --- | ---: | ---: | ---: | ---: |
| `hsl_rd_train` | 2,551 µm² | 1,361 | 228 | 0.707 ns |

<sub>commit `381dd5b`. FF는 레인당 27개(현재 구간 시작 · 길이, 최고 구간 시작 · 길이, 학습 코드) × 8과 코드 · 상태다. 지금은 모든 레인이 같은 코드로 함께 스윕하므로, 학습 코드를 최고 구간에서 바로 계산하면 레인당 5 FF를 더 줄일 수 있다.</sub>

## 레인 리페어: 검출 → 재매핑 → 재검사

논리 레인 9개 `{DBI, DQ[7:0]}`가 핀 10개 `{RED, DBI, DQ[7:0]}`를 쓴다. 고장 핀 k가 정해지면 k보다 아래 레인은 제자리, k부터 위 레인은 한 칸씩 위 핀으로 가고, 핀 k는 0으로 쉰다. RED는 마지막 레인(DBI)을 받는다. 수신 쪽은 반대로 푼다. 핀마다 "내 레인 또는 아래 레인"을 고르는 2:1 mux 하나라 어떤 레인도 이웃 핀보다 멀리 가지 않는다.

```text
lane 3이 고장인 경우      DQ0 DQ1 DQ2 DQ3 DQ4 DQ5 DQ6 DQ7 DBI RED   (핀)
                         L0  L1  L2  --  L3  L4  L5  L6  L7  L8    (실리는 논리 레인)
```

shift는 `hsl_phy_mis`에서 버스트의 네 심볼 모두에 걸린다(쓰기는 TX 기어 앞, 읽기는 FIFO 뒤). 주소는 CA 핀으로 가므로 DQ shift와 상관없다. 채널 모델은 mode register 대신 `mr_repair_en` · `mr_repair_lane` 입력으로 같은 설정을 받는다(RTL과 따로 짠 루프 구현).

| 단계 | 하는 일 | T10 결과 |
| --- | --- | --- |
| 검출 | `LANE_BIST` start → 컨트롤러 요청 포트로 한 bank · row의 컬럼 0–15에 PRBS7 워드 16개를 쓰고, 큐가 비면(`q_empty`) 다시 읽어 DQ 레인별로 비교, sticky 기록 | stuck-at 0/1 × DQ 8레인: 16/16이 정확히 그 레인 하나로 표시 |
| 재매핑 | 펌웨어(TB)가 `REMAP`에 그 핀을 쓰고 DRAM 쪽에도 같은 설정 | |
| 재검사 | BIST 다시 실행 | 16/16 PASS. 리페어된 링크(lane 5 stuck-at-1)로 DBI-AC 켠 쓰기 · 읽기 16개 일치 |
| 한계 | spare가 하나라 두 레인 고장은 고칠 수 없음 | lane 2 · 6 동시 고장: 에러 `0x44`, "한 레인만 실패" 비트 0 |

| 블록 (Nangate45 typical) | 면적 | Cell | FF | 최대 경로 |
| --- | ---: | ---: | ---: | ---: |
| `hsl_lane_shift` (TX + RX) | 61 µm² | 54 | 0 | 0.227 ns |
| 이전 치환 방식 `hsl_lane_repair` × 4 beat (TX만, commit `4d38ae9`) | 143 µm² | 136 | 0 | 0.177 ns |
| `hsl_lane_bist` (PRBS7 2개, 쓰기 → 큐 비움 → 읽기, 레인 비교, commit `0193c04`) | 630 µm² | 342 | 54 | 0.740 ns |

<sub>`syn/ppa_block.sh`. 치환 방식은 버스트(4 beat × 8 bit) 단계에서 beat마다 인스턴스가 하나씩 필요했고 RED로 옮길 비트를 고르는 mux가 framer에 따로 있었다. shift는 UI 심볼 하나에 걸어 한 벌로 TX와 RX를 함께 처리한다.</sub>

## MBIST: March 알고리즘과 검출표

`hsl_mbist`는 레인 BIST와 같은 요청 포트로 DRAM 배열의 한 영역(bank 하나, row 최대 16개 × 컬럼 최대 16개)에 March 알고리즘을 돌린다. 배경은 solid(0은 모두 0, 1은 모두 1)이고, ⇕는 위로 돈다.

| 알고리즘 | 요소 | 워드당 연산 | 8워드 실행 (T13) |
| --- | --- | ---: | ---: |
| MATS+ | {⇕(w0); ⇑(r0,w1); ⇓(r1,w0)} | 5 | 40연산, 507클럭 |
| March X | {⇕(w0); ⇑(r0,w1); ⇓(r1,w0); ⇕(r0)} | 6 | 48연산, 616클럭 |
| March C- | {⇕(w0); ⇑(r0,w1); ⇑(r1,w0); ⇓(r0,w1); ⇓(r1,w0); ⇕(r0)} | 10 | 80연산, 1,021클럭 |

- **연산을 하나씩 낸다.** 컨트롤러는 다른 주소의 요청 순서를 바꾼다(FR-FCFS, 쓰기 배치). 여러 개를 띄우면 배열이 받는 순서가 March 순서와 달라지는데, coupling fault는 aggressor 쓰기가 victim 읽기보다 먼저 배열에 닿아야 잡힌다. 쓰기 뒤에는 응답 → `q_empty`(WR이 핀으로 나감) → 4클럭(데이터가 배열에 닿음)을, 읽기 뒤에는 응답을 기다린다. 연산당 약 13.2클럭이다(March C- 64워드: 640연산, 8,443클럭, commit `ffc073d`. ECC 경로의 읽기 단계 전 `f018966`에서는 8,239클럭).
- **결과**: 실패 읽기 수(포화), 첫 실패 읽기의 호스트 주소와 다른 비트(start가 지워 실패가 없으면 0), 실패 워드 로그 16개(`{row offset, col}`, 워드마다 한 번, 17번째부터는 넘침 비트. start는 개수만 0으로 하고 항목은 남기므로 `MBIST[8:4]` 미만만 이번 실행의 것). [repair](#repair-bira-spare-fuse)의 BIRA가 이 로그를 읽는다.
- **고장 주입**: 채널 모델의 배열에 비트 단위 고장을 최대 4개 둔다. stuck-at(SA), 전이(TF ↑ · ↓), 서로 다른 두 워드 사이의 inversion · idempotent · state coupling(CFin, CFid, CFst)이다. [`tb/march_ref.py`](tb/march_ref.py)가 같은 규칙으로 도는 참조 March 시뮬레이터이고, 기대 검출표를 낸다.

| 고장 (victim 워드 2 또는 5의 bit 3, aggressor bit 7) | 개수 | MATS+ | March X | March C- |
| --- | ---: | ---: | ---: | ---: |
| SA0 · SA1 | 2 | 2 | 2 | 2 |
| TF ↑ · ↓ | 2 | 1 | 2 | 2 |
| CFin (전이 ↑ · ↓ × aggressor 앞 · 뒤) | 4 | 3 | 4 | 4 |
| CFid (전이 × 강제 값 × 순서) | 8 | 3 | 4 | 8 |
| CFst (aggressor 상태 × victim 값 × 순서) | 8 | 4 | 5 | 8 |
| **합계 (T13 = 참조)** | **24** | **13** | **17** | **24** |

<sub>T13이 고장 하나씩 넣고 세 알고리즘을 돌려, 고장마다 검출 여부가 참조와 같은지와 첫 실패가 victim 워드 · 비트인지 본다(commit `f018966`, 두 시뮬레이터 같은 결과). MATS+는 마지막 w0 뒤에 읽기가 없어 TF ↓를 놓치고, March X는 끝의 ⇕(r0)으로 그것을 잡는다. CFid와 CFst의 두 순서(aggressor가 victim보다 앞 · 뒤)를 모두 잡으려면 March C-처럼 두 방향 각각에서 r0,w1과 r1,w0이 모두 있어야 한다.</sub>

| 그 밖의 확인 (T13) | 결과 |
| --- | --- |
| 실패 워드 로그 | 4 × 16 영역에 SA1 (+0, 3) · SA0 (+2, 9) · TF ↑ (+3, 15): 처음 실패한 순서로 `03 29 3F`, 실패 읽기 7개 |
| 로그 넘침 | DQ 핀 5 stuck-at-1: 모든 r0이 실패(64워드 × 3 = 192), 로그 16개가 차고 넘침 비트, 다른 비트 `20202020`(DQ5의 네 UI) |
| 엔진 둘, 포트 하나 | 레인 BIST와 MBIST가 한 테스트 포트를 쓴다. 한 엔진이 도는 동안(또는 같은 클럭에) 온 다른 엔진의 start는 잡아 두었다가 포트가 비면 낸다. 기다리는 동안 그 엔진은 busy와 대기 비트로 읽혀, 폴링이 지난 실행의 done · pass를 가져가지 않는다(`e61e90d`). 두 순서 모두 둘 다 돌고 PASS, 함께 busy인 클럭 0 |
| 포트가 닫힌 start (`3d596a4`) | MISSION에서 PHY를 끈 채(요청 포트 닫힘) 레인 BIST · MBIST · 읽기 레벨링을 시작: 셋 다 요청 없이 바로 done과 refused, pass 0. BIRA는 거절된 MBIST를 수리 불가로 본다 |

- **start를 버리지 않고 기다리게 한 이유**: 읽기 레벨링은 자기가 낸 레인 BIST start 뒤에 busy가 오르기를 기다린다. MBIST 중이라고 start를 버리면 읽기 레벨링이 멈춘다. 같은 클럭에 둘 다 오면 레인 BIST가 먼저다.
- **요청 포트를 플롭에서 낸다**: 처음 구현은 주소를 조합으로 만들었다(가변 shift, row 덧셈, XOR 맵, 0.78 ns). 칩 STA에서 그 경로가 컨트롤러의 주소 비교와 `req_ready` 앞에 붙어 −0.749 ns였다. 연산마다 주소 · 데이터 · 로그 키를 한 클럭 먼저 계산해(`S_LOAD`) 플롭에서 내자, DFT에서 시작하는 실패 경로가 없어졌다.
- **포트가 닫힌 start는 거절한다**: 엔진은 요청 포트의 `req_ready`를 기다리므로, 처음 구현은 포트가 닫힌 채 시작하면 busy로 영원히 남았다(리뷰). 지금은 start 때 포트 상태(MISSION이고 `phy_en`)를 보고, 닫혀 있으면 그 클럭에 done과 refused를 세우고 결과를 비운다. 도는 중에 포트가 닫히는 경우는 잡지 않으며 soft reset이 푼다.
- **응답 비교를 레지스터로**: 읽기 응답과 기대값의 차이를 응답 클럭에 레지스터로 받고(`S_RWAIT`), 실패 수 · 첫 실패 · 로그는 다음 클럭(`S_NEXT`)에 기록한다. 컨트롤러 응답 FIFO → 비교 → 로그 중복 검사가 한 클럭에 붙어 칩 STA에서 −0.099 ns였다(끝점 88개). 다음 연산은 어차피 `S_NEXT`를 지나므로 실행 클럭 수는 같다(`3d596a4`).
- **면적** (칩 넷리스트): `hsl_mbist` 2,849 µm² · FF 264(`f018966`) → 3,086 µm² · FF 298(`3d596a4`, 읽기 차이 레지스터 32 bit와 거절 비트) → 3,117 µm²(`e61e90d`, start 때 첫 실패 기록 지우기). 로그 16 × 8 bit와 중복 검사 비교기 16개가 큰 몫이다.

## Repair: BIRA, spare, fuse

배열에는 spare row 2개와 spare column 2개가 있다(spare column은 16-row 블록 하나의 한 컬럼을 대신한다). base die는 MBIST 실패 로그로 어느 spare를 어디에 쓸지 고르고(BIRA), 그 결과를 repair 표로 배열에 넘기고, fuse에 굽고, 리셋 때마다 fuse에서 다시 읽는다.

```text
MBIST (March C-) ─▶ 실패 워드 로그 16개 ─▶ BIRA ─▶ apply ─▶ repair 표 ─▶ rep_tab ─▶ 배열의 spare
                                                          │          ▲
                                                 FUSE program      리셋 뒤 자동 로드
                                                          ▼          │
                                                 fuse 워드 4개 (SECDED 39,32)
```

| 단계 | 하는 일 |
| --- | --- |
| 1. 넘친 로그 | 기록하지 못한 실패 워드가 있으므로 수리 불가 |
| 2. must-repair | 한 pass가 아무것도 바꾸지 않을 때까지 반복. 덮이지 않은 실패 워드가 남은 spare column 수보다 많은 row는 spare row를, 남은 spare row 수보다 많은 column은 spare column을 반드시 써야 한다 |
| 3. spare 순서 탐색 | 남은 spare의 순서(1번째, 2번째 … spare가 row인지 col인지, 최대 16가지)를 차례로 시도한다. 로그 순서로 덮이지 않은 워드마다 그 순서의 다음 spare를 준다. 모두 덮는 첫 순서를 쓰고, 없으면 수리 불가 |

모든 repair 해는 이런 순서 하나에 해당하므로, 3단계는 해가 있으면 반드시 찾는다(exhaustive search와 같다). 처음 구현은 3단계 대신 greedy pass(그 row의 실패가 column보다 많거나 같으면 row)였다. 같은 규칙의 Python 참조([`tb/bira_ref.py`](tb/bira_ref.py))로 랜덤 맵을 돌린 결과 greedy가 해가 있는 맵을 놓쳐 바꿨다.

| 실패 워드 수 (16 × 16 블록, 맵 3,000개씩) | spare 1 + 1 | spare 2 + 2: greedy | spare 2 + 2: 순서 탐색 (`hsl_bira`) = exhaustive | spare 3 + 3: greedy / exhaustive |
| ---: | ---: | ---: | ---: | ---: |
| 3 | 31.4% | 100% | 100% | 100% / 100% |
| 4 | 4.8% | 100% | 100% | 100% / 100% |
| 5 | 0.6% | 63.1% | **73.2%** | 100% / 100% |
| 6 | 0.2% | 31.7% | **41.3%** | 100% / 100% |
| 8 | 0.0% | 4.9% | **5.2%** | 67.9% / 81.4% |
| 10 | 0.0% | 0.2% | 0.2% | 27.7% / 41.0% |

<sub>`python tb/bira_ref.py 3000`. 1 + 1에서는 greedy, 순서 탐색, exhaustive가 같다. 순서 탐색이 exhaustive와 같은지는 1 + 1과 2 + 2의 모든 맵에서 assert로 확인한다. spare가 4개를 넘으면 순서가 많아져(3 + 3은 20가지) 하드웨어는 2 + 2에 맞췄다.</sub>

- **repair 표**: spare마다 16 bit 항목 `{valid, 0, bank, row, col}`(row spare는 row 전체, col spare는 블록의 row[7:4]와 col). apply가 BIRA 결과를 넣고(row = 영역 첫 row + offset), clear가 비운다. 배열(채널 모델)은 표에 있는 row나 col 접근을 spare 저장소로 보낸다. row spare가 col spare보다 먼저다.
- **fuse**: program이 항목마다 SECDED (39,32)로 인코딩한 워드를 굽는다(fuse bit는 0 → 1만). 리셋이 풀리면 fuse 워드 4개를 디코더로 읽어 표를 채운다. 1 bit 오류는 정정해 세고, 2 bit 오류는 세고 그 항목을 버린다(빈 항목, `FUSE[15:12]`에 표시). 굽지 않은 fuse(모두 0)는 올바른 부호어이고 빈 표가 된다. program은 한 번만 한다: blank check가 없어, 이미 구운 워드에 다시 구우면 새 부호어가 OR로 겹쳐 워드가 깨진다. 나중의 수리에는 새 fuse 워드가 필요하다(다루지 않음).
- **STA가 정한 구조**: BIRA의 row · col 개수를 결정과 같은 클럭에 직렬 증가 체인으로 세면 −0.318 ns였다. 일치 벡터 → 균형 popcount로 바꾸고 결정 앞에 레지스터를 두었다(항목당 3클럭). fuse 읽기 데이터도 입력 지연 0.5 ns 뒤 바로 디코더를 지나면 −0.256 ns여서 먼저 레지스터로 받는다.

| T14 (commit `6c29d60`) | 결과 |
| --- | --- |
| A: 실패 워드 8개 | row +1에 3개(spare col 2개보다 많음 → row), col 5에 3개(→ col), row +6에 2개(col이 하나 남아 → row). 표 `AC10 AC60 AC05 0000`, 재시험 PASS, spare로 간 배열 접근 460 |
| B: hard repair | fuse 프로그램 → 표 비움 → 칩 리셋: fuse 로드가 4항목을 되살리고 재시험 PASS |
| C: fuse ECC | 워드 0의 1 bit 반전은 정정(1), 워드 2의 2 bit 반전은 정정 불가(1)로 그 항목(col 5)을 버림 → col 5의 3워드가 다시 실패(r0 실패 9) |
| D: 수리 불가 | 대각선 5워드(spare 5개 필요), 넘친 로그(DQ 핀 stuck) |
| E: greedy가 못 고치는 맵 | (+10, 0) (+11, 9) (+13, 10) (+14, 8) (+14, 14): greedy는 row +10, +11을 쓰고 spare가 모자란다. 순서 탐색은 row +10 · +14, col 9 · 10으로 고치고 재시험 PASS |
| F: 랜덤 맵 12개(3–8워드, 8 × 16) | BIRA의 판정과 할당이 TB 참조(같은 규칙을 SV로 다시 짠 것)와 12개 모두 같음. 수리 가능 9개(greedy였다면 8개) 모두 재시험 PASS |

- **면적** (`6c29d60`, 칩 넷리스트): `hsl_bira` 1,975 µm² · FF 127, `hsl_repair` 1,152 µm² · FF 122, SECDED 인코더 122 · 디코더 348 µm². BIRA의 대부분은 항목 16개에 대한 row · col 비교와 popcount, 탐색 전 상태 저장이다.

## ECC: SECDED, 주입, 로그, self-test

32 bit 버스트마다 SECDED (39,32)를 건다(fuse와 같은 `hsl_secded_enc` · `hsl_secded_dec`). 검사 비트 7개(+ 0 하나)는 HBM의 ECC 핀처럼 데이터 beat 옆의 ECC 핀 두 개로 나가고(2 핀 × 4 UI = 8 bit), DRAM이 워드 옆에 저장했다가 읽을 때 함께 돌려준다. ECC 핀은 DBI와 레인 리페어 밖이다. 기본값은 꺼짐이라 MBIST와 repair는 배열 고장을 그대로 본다.

```text
쓰기: 원시 워드(DBI 전) ─▶ tx_raw ─(반 클럭)─▶ 인코더 ─▶ ECC 핀 beat ┐
      DBI ─▶ lane shift ─▶ tx_word ─────────────────────────────▶ TX 기어 (48 bit) ─▶ 데이터 + ECC beat
읽기: RDQS 캡처 ─▶ Gray FIFO (48 bit) ─▶ unshift · DBI 복원 ─▶ 레지스터 단 ─▶ 디코더 ─▶ rddata
                                                         RD 추적 FIFO ─▶ 첫 오류의 호스트 주소
```

| 기능 | 동작 |
| --- | --- |
| 정정 · 검출 | ECC on이면 정정된 워드가 컨트롤러로 간다. 1 bit 오류는 정정해 `ECC_CNT[15:0]`, 2 bit 오류는 데이터를 그대로 넘기고 `ECC_CNT[31:16]`에 센다(포화). 정정 불가는 CSR로만 알린다: 컨트롤러의 DFI 쪽에 오류 입력이 없다 |
| 첫 오류 로그 | 처음 난 오류의 호스트 주소, syndrome `{전체 패리티, s[5:0]}`, 정정 가능 여부를 clear까지 잡아 둔다. 주소는 RD 추적 FIFO에서 온다: 핀으로 나간 RD마다(CA 레지스터에서) 그 bank의 열린 row와 column으로 호스트 주소를 넣고, 읽기 반환마다 하나 꺼낸다 |
| 오류 주입 | `ECC_INJ`(데이터 비트)와 `ECC[14:8]`(검사 비트) 마스크를 다음 쓰기 버스트 하나에만 XOR한다. 뒤집힌 값이 DRAM에 저장되므로 읽기 경로 전체를 시험한다 |
| 디코더 self-test | 고정 워드의 깨끗한 codeword 1, 1 bit 오류 39, 이웃 2 bit 오류 38, 모두 78개를 데이터 경로의 디코더에 넣어(읽기 반환 레지스터로 로드) 정정 데이터와 ce · ue를 확인하고 틀린 개수를 센다. PHY가 idle일 때 돌린다 |

| T15 (commit `ffc073d`) | 결과 |
| --- | --- |
| self-test | 78개 PASS. 정정 플래그(`dec_ce`)를 0으로 강제하면 FAIL, 39개 틀림 |
| 깨끗한 트래픽 | bank 3 row 40의 16워드 쓰기 · 읽기, 오류 0 |
| 데이터 1 bit (bit 9) | 읽기 값은 정정되어 그대로(`12345678`), 정정 1, 첫 오류로 호스트 주소 `1062` · syndrome `4E`(데이터 bit 9 = code 위치 14, 전체 패리티 1) |
| 검사 비트 1 bit (code bit 4) | 정정, 정정 2, 첫 오류 기록은 그대로 |
| 2 bit (bit 0, 1) | 정정 불가 1, 데이터는 뒤집힌 그대로(`FACE0003`) |
| 배열 stuck bit (bit 17 SA0) | ECC on: `FFFFFFFF`로 정정. ECC off: `FFFDFFFF`, 셈 없음 |

- **STA가 정한 구조**: 인코더는 원시 워드를 TX 워드와 함께 레지스터로 받은 뒤 TX 기어가 받는 E1 엣지까지 반 클럭 안에 돈다(`clk_phy` +0.044 ns, 지금 그 클럭의 최악). 주입할 데이터 비트도 자기 lane shift를 거쳐 TX 워드 레지스터 뒤에서 XOR한다. 디코더 앞에는 레지스터 단이 있고, self-test는 그 레지스터에 codeword를 넣어 디코더 앞에 mux가 없다. 카운터와 로그는 디코더 플래그를 한 클럭 뒤에 받는다. RD 추적은 컨트롤러의 명령 출력이 아니라 CA 레지스터에서, 루프백 RD는 레지스터한 명령으로 답한다. RDQS 쪽 FIFO 쓰기도 레지스터에서 한다.
- **대가**: 읽기 지연이 한 클럭 늘었다(열린 row 읽기 9 → 10, 핀의 RD → `rddata_valid` 6 → 7). 컨트롤러는 RD를 4개까지만 띄우므로, bank group 두 개에 걸친 읽기 32개가 76 → 97 클럭이 됐다. `RD_PIPE`를 PHY 왕복에 맞추는 것이 해결책이다(컨트롤러 저장소).
- **면적** (`ffc073d`): `hsl_ecc` 1,960 µm² · FF 153(카운터 32, self-test 파이프, 로그), SECDED 인코더 122 · 디코더 359 µm². 계층을 유지한 합성이라 self-test용 상수 입력 인코더도 한 벌로 세어져 122 µm²가 더 잡힌다.

## DFD: trace, 카운터, MISR, 디버그 사례

`hsl_dfd`는 칩 top에서 CA 핀 레지스터, 컨트롤러로 가는 읽기 데이터, ECC · PRBS · MBIST 카운터를 본다.

| 기능 | 동작 |
| --- | --- |
| trace buffer | 16항목 × 32 bit. 어느 CA 버스에든 명령이 있거나 이벤트(ECC 정정 · 정정 불가, PRBS 오류, MBIST 실패)가 있는 클럭만 쓴다. 항목은 `{timestamp 8, 행 CA {cmd, bank, row}, 열 {cmd, bank}, 읽기 데이터 · 이벤트 플래그, trigger 표시}`. bank 필터를 켜면 그 bank 명령만 세고 다른 bank의 CA 칸은 NOP로 둔다 |
| trigger · pre/post | arm 뒤 ring에 기록한다. trigger(ECC 정정 불가 · 정정, PRBS, MBIST, 필터 bank 명령, 수동)는 trigger 앞 칸이 다 찬 뒤에만 받고, 그 항목을 표시한 뒤 `post`개를 더 쓰고 멈춘다. 이벤트는 그 카운터가 0이 아닌 새 값으로 바뀌는 것으로 본다(ECC는 핀의 RD 몇 클럭 뒤). clear나 MBIST 재시작으로 0이 되는 것은 이벤트가 아니고, 포화한 카운터는 이벤트를 더 내지 않는다 |
| 명령 카운터 | 핀의 ACT · RD · WR · REFpb, 16 bit 포화, CSR로 지움 |
| MISR | 컨트롤러로 가는 읽기 데이터의 32 bit signature(x^32 + x^22 + x^2 + x + 1 되먹임, 시작값 모두 1). 긴 읽기 스트림을 값 하나로 비교한다 |

### 디버그 사례: 증상에서 원인까지

채널 모델에 버그를 심었다(`bug_refdis`): 어떤 bank의 REFpb 뒤 16클럭 안에 그 bank를 읽으면 bit 5가 뒤집혀 돌아온다. DRAM의 refresh 간섭 같은 종류다. 디버그하는 쪽은 이 사실을 모른다고 두고, 칩의 관측 수단으로만 찾는다(T16).

1. **증상**: ECC를 켠 랜덤 읽기 200개에서 호스트 데이터는 모두 맞지만(정정됨) 정정 오류가 32개다. 첫 오류 주소(`ECC_ADDR` `1830`)는 bank 3이다.
2. **재현 좁히기**: bank 3만 읽는 트래픽으로 바꾸면 정정 오류가 모두 bank 3 읽기다.
3. **trace**: trigger = ECC 정정, 필터 = bank 3, trigger 뒤 1항목. 3번 잡았다.

```text
t= 33  RD b3  data
t= 35  RD b3  data
t= 37  RD b3
t= 40  RD b3  data
t= 42  RD b3  data
t= 44  RD b3  data
t= 46  RD b3
t= 49  PRE b3  data
t= 52  REFpb b3
t= 60  ACT b3 r60
t= 63  RD b3
t= 65  RD b3
t= 67  RD b3
t= 69  RD b3
t= 71  ECC-CE  <- trigger
t= 72  RD b3  data
```

4. **읽기**: 세 번 모두 같은 모양이다. `REFpb b3`(t = 52) → tRFCpb 8클럭 뒤 `ACT` → REFpb 11클럭 뒤 첫 `RD b3` → 그 RD 8클럭 뒤 정정 오류(핀의 RD에서 디코더 플래그까지의 지연). refresh 뒤 처음 읽는 몇 워드만 깨진다는 가설이 나온다. REFpb 전의 RD 7개(t = 33–46)는 오류를 내지 않았다.
5. **확인**: 심은 버그를 끄면 같은 트래픽 200개에서 오류 0이다.

- **trigger 원천** (T16, `3d596a4`): 수동과 ECC 정정(위 사례) 말고도 bank 명령(bank 2의 REFpb), MBIST 실패(DQ 핀 5 stuck-at-1), PRBS 오류(PRBS를 켠 레인 BIST), ECC 정정 불가(2 bit 주입)를 각각 걸었고, 매번 그 이벤트 항목에 trigger가 표시된 뒤 멈췄다. 처음 구현은 카운터가 바뀌기만 하면 이벤트로 봐서 ECC clear · ERRCNT clear · MBIST 재시작에도 trigger가 났다(리뷰). 같은 시험이 그 셋에서 trigger가 나지 않는지 보고, 옛 RTL에서는 3건 FAIL이다.
- **면적** (`796d969`): `hsl_dfd` 6,019 µm² · FF 701. 거의 trace 512 bit(플롭)이다. 실제 칩이라면 trace는 SRAM 매크로로 둔다.

## IEEE 1500 방식 시험 포트

HBM은 IEEE 1500 시험 포트로 MBIST, repair, 레인 리페어 같은 시험 기능을 다룬다. `hsl_w1500`은 그 구조(WIR, WBY, wrapper data register, 직렬 제어 신호)를 따르고, 명령 코드와 레지스터 배치는 이 설계가 정했다(JEDEC 인코딩이 아니다).

| WIR (3 bit, 리셋 BYPASS) | 레지스터 | 동작 |
| --- | --- | --- |
| `000` BYPASS (그 외 코드도) | WBY 1 bit | 한 비트 늦춰 통과 |
| `001` ID | 32 bit | capture에서 `HSL_ID`(`48534C31`) |
| `010` CSR | 41 bit `{write, addr[7:0], data[31:0]}` | update에서 write면 그 CSR에 쓰고, 아니면 읽는다. 다음 capture가 `{0, addr, 읽은 값}`을 싣는다(읽기는 scan 두 번) |

```text
WRCK  ─┐  ┌──┐  ┌──      Shift · Capture: WRCK 상승 엣지
       └──┘  └──┘         Update: 하강 엣지, WSO는 하강 엣지 뒤 바뀜 (1500과 같음)
입력 7개 ─▶ 2-FF 동기화(clk) ─▶ WRCK 엣지 검출 ─▶ WIR / WDR ─▶ (CSR 접근 1–2 clk) ─▶ CSR 버스 mux
```

- **클럭**: WRCK 도메인을 따로 두지 않고 컨트롤러 클럭으로 오버샘플한다. 모든 입력이 2-FF 동기화를 지나고 WRCK 엣지를 clk에서 찾는다. WRCK는 clk보다 8배 이상 느려야 한다(T17은 20 ns = 16 clk). 그래서 STA에 새 클럭도 CDC도 없다. 대가는 WRCK 속도 상한이다.
- **CSR 접근**: 한 레지스터로 모든 CSR(MBIST, BIRA · repair · fuse, ECC, trace, REMAP)에 닿는다. 접근하는 1–2클럭 동안 포트가 CSR 버스를 잡으므로 호스트 쪽 `cfg_*`는 조용해야 한다.
- **리셋**: 항상 켜진 리셋(`rst_sync_n`)에 둬서 soft reset에도 WIR가 유지된다. WRSTN을 내리면 WIR가 BYPASS로 돌아간다.
- **T17** (`14fec6e`): ID가 `HSL1`, WIR capture가 현재 명령, WBY가 `B2` → `64`(한 비트 지연), CSR 레지스터로 ID CSR을 읽고, MBIST March C-를 직렬 포트만으로 시작해 폴링 두 번(82 bit씩)에 PASS. 호스트 CSR로 읽은 상태와 같다.
- **면적**: `hsl_w1500` 1,369 µm² · FF 170(41 bit shift · update 레지스터, 읽기 보관, 동기화기).
- **없는 것**: WBR(경계 레지스터)과 EXTEST가 없어 핀 하나하나를 몰고 볼 수는 없다. DBI · RED 핀 고장 시험(레인 BIST로 보이지 않는 것)은 아직 남아 있다.

## PPA · PD 인계

칩 STA가 보는 넷리스트의 면적이다(commit `e61e90d`, `bash syn/sta_chip.sh`): Yosys 0.52가 모듈 경계를 유지한 채 합성하고, ABC가 1.25 ns를 목표로 Nangate45 typical에 매핑(버퍼링 · 사이징 포함)한 뒤 팬아웃 버퍼 트리를 넣었다. 배선은 없다.

| 블록 | 면적 (µm²) | Cell | FF | 비중 | 구성 (µm²) |
| --- | ---: | ---: | ---: | ---: | --- |
| Memory Controller (`mem_ctrl`) | 23,582 | 13,241 | 2,004 | 44% | 쓰기 큐 5,431 · 읽기 큐 4,633 · resp 6,061 · sched 3,721 · bank ×4 1,411 · chan 689 · xage 609 · 그 외 1,026 |
| PHY digital | 8,873 | 4,132 | 910 | 17% | phy_mis 3,860 · ecc 1,952 · cdc_fifo 1,685 · tx_gear 395 · lane_shift ×2 354 · dbi 320 · phy_top 306 |
| 읽기 레벨링 (`hsl_rd_train`) | 2,680 | 1,470 | 229 | 5% | 레인당 구간 추적 상태 |
| DFT | 9,217 | 4,774 | 829 | 17% | w1500 1,373 · mbist 3,117 · bira 1,980 · repair 1,155 · prbs(출력 레지스터) 496 · lane_bist 428 + prbs ×2 261 · dft_top 193 · err_cnt 151 · loopback 63 |
| SECDED 코덱 | 1,097 | 827 | 0 | 2% | 인코더 ×3(fuse 1, ECC 2) · 디코더 ×2(fuse 1, ECC 1) |
| DFD (`hsl_dfd`) | 6,047 | 2,379 | 701 | 11% | trace 16 × 32 bit 플롭, 카운터 4개, MISR |
| CSR | 2,007 | 1,026 | 165 | 4% | 주소 26개, 읽기 mux와 읽기 데이터 레지스터 |
| 기타 | 260 | 148 | 8 | 0.5% | top 184(CSR 버스 mux 포함) · training_fsm 52 · rst_sync ×2 23 |
| **합계** | **53,763** | **27,997** | **4,846** | | |

<sub>`syn/area_by_block.py`가 Yosys `stat`을 블록별로 묶는다. `0193c04`의 같은 구성(지연 목표와 버퍼 없이 합성)은 30,241 µm² · 2,741 FF였고, 그 뒤 PRBS 워드와 CSR 읽기 데이터 레지스터(FF 60개)를 더해 `8af801b`에서 32,184 µm² · 2,801 FF였고, `f018966`에서 MBIST와 그 CSR이 더해져 35,610 µm² · 3,095 FF, `6c29d60`에서 BIRA · repair · fuse가 더해져 39,225 µm² · 3,351 FF, `ffc073d`에서 ECC가 더해져 45,482 µm² · 3,919 FF, `796d969`에서 DFD가 더해져 51,911 µm² · 4,638 FF, `14fec6e`에서 1500 포트가 더해져 53,316 µm² · 4,808 FF였다. `3d596a4`에서 MBIST 읽기 차이 레지스터, 시작 거절 비트, RDQS 리셋 동기화기로 FF가 38개 늘어 53,651 µm²였다. `e61e90d`는 FF가 그대로이고, 첫 실패 기록 지우기와 CSR 표시 논리, ABC 차이로 면적이 조금 움직였다. 다른 블록의 면적이 조금씩 움직인 것은 ABC 실행 간 차이다. 컨트롤러 RTL은 그대로인데 면적이 0.6% 움직인 것은 ABC 매핑의 실행 간 차이다. 컨트롤러 저장소는 `mem_ctrl`만 flatten 합성해 18,912 µm²를 낸다. 여기서는 블록별로 나누려고 경계를 유지해서, 경계를 넘는 최적화가 빠진 만큼 크다.</sub>

| 제약 | 내용 |
| --- | --- |
| `clk` | 1.25 ns (800 MHz), 포트 `clk` |
| `clk_phy` | `u_phy/u_phy_clk/clk_phy`에 `create_generated_clock -multiply_by 2` (0.625 ns). PLL 매크로 자리다. TX 기어의 clk → clk_phy는 반 주기 경로 |
| `rdqs` | `pin_rdqs`에 0.625 ns 클럭. 위상이 정해지지 않아, 그 도메인을 떠나는 경로는 읽기 FIFO뿐이고 모두 아래 `set_max_delay`로 묶는다(비동기 clock group은 그 제약을 false path로 덮으므로 쓰지 않음) |
| I/O delay | 컨트롤러 주기의 40%인 0.5 ns. 호스트 포트(`req_*`, `rsp_*`), CA 핀, `rx_dly_code` |
| CDC 포인터 · 데이터 | 읽기 FIFO(`u_phy/u_mis/u_rx_fifo`): 소스 클럭 → 첫 싱크 플롭(`*_s1`)에 `set_max_delay 0.625`(false path 아님). 소스 셀 이름으로 묶지 않는 이유는 Gray 최상위 비트가 binary 최상위 비트와 같아 합성이 두 플롭을 하나로 합치기 때문이다. FIFO 데이터 → `clk`에 `set_max_delay 1.25` |
| `rst_n` | `set_false_path`. v0.1 단순화이며, 실제 덱은 싱크러나이저의 recovery/removal을 따로 확인한다. RDQS 도메인은 자기 동기화기(`u_phy/u_mis/u_rst_rdqs`)에서 풀리고, 그 두 플롭으로 가는 assert 경로만 false path다. 풀린 리셋은 RDQS 기준 recovery · removal을 본다 |
| 리셋 트리 | 동기화된 리셋이 플롭 약 4,650개의 리셋 핀으로 간다(`e61e90d`: FF 4,846개 중 리셋 없는 것은 읽기 FIFO 데이터 192개와 클럭 게이트 enable 1개). 배치 전에는 `set_ideal_network`로 두고 P&R에서 트리를 만든다. OpenSTA 3.1은 이 명령을 적용하지 않아, STA 흐름이 버퍼 트리를 넣는다 |
| 준정적 설정 | CTRL · REMAP 설정 → TX 워드 레지스터 데이터 핀은 `set_multicycle_path 2`(설정은 컨트롤러가 idle일 때만 바뀜) |
| `pin_ck` | mission에서 `clk_phy`를 클럭 게이트(PHY 하강 엣지에서 enable)를 거쳐 내보냄. 출력 포트에 생성 클럭 `ck_out` |

- **성능** (`ffc073d`): 핀의 명령 간격은 규칙의 최소값이고(T2), 열린 row 읽기는 요청 → 응답 10 클럭이다. 이전 in-order MC의 WR 16 + RD 16(162 클럭)이 81 클럭으로 줄었다. 남은 병목은 진행 중인 RD 4개 대 PHY 왕복 8 클럭이다.
- **타이밍** (`e61e90d`): HSL 로직은 800 MHz · 1.6 GHz · RDQS를 모두 통과하고, 컨트롤러는 459 MHz에서 닫힌다([STA](#sta-세-클럭과-cdc)).
- **전력** (mW 미측정): DBI-DC는 DQ 8핀 중 high를 4개 이하로, DBI-AC는 UI당 DQ 전이를 4개 이하로 둔다([비교](#dbi-ac-off--dc--ac-비교)). CKE는 RESET에서만 0이고, 쓰기 beat가 없으면 TX beat는 0이다.
- **PD 가이드**: deskew 4 tap = 8 UI까지 레인 스큐 허용, SRAM 매크로 없음(읽기 FIFO는 깊이 4 플롭이고, 컨트롤러의 큐와 응답 버퍼도 플롭으로 FF 2,004개), PHY 핀 로직은 범프 쪽, CSR과 FSM은 안쪽. 자세한 내용은 [`docs/05_pd_guide.md`](docs/05_pd_guide.md)에 있다.

## STA: 세 클럭과 CDC

`bash syn/sta_chip.sh`가 RTL을 Nangate45 넷리스트로 합성하고 저장소의 SDC로 OpenSTA 3.1을 돌린다. 클럭은 이상 클럭(클럭 트리 없음)이고 배선은 없다. 경로를 찾기 위한 것이지 사인오프가 아니다.

| 클럭 · 검사 (commit `e61e90d`) | 결과 |
| --- | --- |
| `clk_phy` 1.6 GHz (0.625 ns) | slack +0.044 ns. 최악은 ECC 인코더(원시 워드 레지스터 → TX 기어, 반 주기). ECC 전에는 CSR `phy_en` → 클럭 게이트 enable 플롭이 +0.160 ns로 최악이었다 |
| `rdqs` (0.625 ns) | slack +0.106 ns. 입력 지연 0.25 ns를 뺀 `pin_rx_dv` → 버스트 레지스터 |
| 읽기 FIFO 크로싱 (`set_max_delay`) | Gray 포인터 세 비트 모두 최대 0.112 ns / 0.625 ns(최상위 비트), FIFO 데이터 → `clk` 0.402 ns / 1.25 ns |
| `clk` 800 MHz (1.25 ns), HSL 로직 | 모두 통과. 컨트롤러의 쓰기 데이터 → DBI-AC → 레인 shift → TX 워드는 +0.130 ns(`8af801b`) |
| `clk` 800 MHz, 컨트롤러 | −0.930 ns, 최소 주기 2.18 ns(459 MHz). 실패 끝점 1,971개, 모두 컨트롤러 안이거나 호스트 입력 → 컨트롤러다. `8af801b`에서는 −0.892 ns · 2.14 ns(467 MHz), `f018966`에서는 −0.909 ns · 2.16 ns, `6c29d60`에서는 −0.938 ns · 2.19 ns, `14fec6e`에서는 −0.930 ns(459 MHz), `3d596a4`에서는 −0.933 ns(458 MHz)였다. 컨트롤러 RTL은 같아 ABC 실행 간 차이다 |
| hold · removal | 최악 −0.048 ns: RDQS 도메인 리셋 핀 85개의 removal(`u_rst_rdqs`의 해제가 RDQS 엣지 0.18 ns 뒤에 닿고 removal 시간은 0.23 ns). `rst_sync_n` 쪽 리셋 핀 334개(CSR 164 · 1500 포트 170)는 최악 −0.017 ns(`8af801b`에서는 −0.038 ns). 둘 다 이상 클럭에서 리셋 해제가 조금 일찍 닿는 것이라 CTS 뒤 hold 수리 대상이다. 그 RDQS 리셋의 recovery는 +0.499 ns |

숫자가 의미를 갖기 전에 흐름에서 먼저 고친 것:

| 증상 | 원인 | 조치 |
| --- | --- | --- |
| 플롭 44개가 클럭 없음, 1.6 GHz 도메인 전체가 분석에서 빠짐 | PLL 자리(`hsl_phy_clk`)가 합성에서 빈 쉘이라, 생성 클럭 `clk_phy`가 마스터 클럭에서 이어지는 경로가 없다 | PLL 타이밍 스텁(`syn/lib/hsl_phy_clk_stub.lib`, `clk_ctrl` → `clk_phy` 아크 하나)으로 PLL `.lib`처럼 경로를 준다 |
| 읽기 FIFO `set_max_delay`가 아무 셀도 잡지 못함(경고만 나옴) | 합성 플롭 이름이 `_1234_` 꼴이라 SDC의 `wgray*` 패턴이 맞지 않는다 | 플롭에 레지스터 이름을 붙인다(`wgray[0]_reg`, 상용 넷리스트와 같은 꼴) |
| 리셋 recovery −27.7 ns | 게이트 하나가 리셋 핀 약 2,700개를 구동해 지연을 셀 표 바깥에서 외삽(22.7 ns) | `syn/fanout_buffer.py`: P&R repair처럼 부하 16개마다 버퍼, 리셋 입력은 블록마다 버퍼 하나 |
| Gray 포인터 최상위 비트의 크로싱이 `set_max_delay` 밖 | Gray 최상위 비트는 binary 최상위 비트와 같아 합성이 두 플롭을 하나(`wbin[2]` · `rbin[2]`)로 합쳤고, `wgray*` · `rgray*` 패턴은 두 비트만 잡았다(재검토에서 찾음, 14fec6e부터) | 소스 셀 대신 소스 클럭 → 싱크 플롭으로 제약 (`e61e90d`) |

STA가 짚어 RTL을 고친 HSL 경로(모두 800 MHz에서 통과로 바뀜):

| 경로 | slack (ns) | 조치 |
| --- | ---: | --- |
| PRBS LFSR → 32단 전개 XOR → payload mux → DBI-AC → TX 워드 | −0.136 | DFT의 PRBS가 워드를 레지스터로 낸다(`REG_OUT`, 같은 값을 한 상태 앞서 계산) |
| `cfg_addr` → CSR 읽기 mux → `cfg_rdata` (입출력 지연 각 0.5 ns) | −0.174 | 읽기 데이터 레지스터, 읽기 1클럭 |
| 리셋 해제(`clk`) → 클럭 게이트 enable 플롭(`clk_phy` 하강 엣지) | −0.049 | enable 플롭의 리셋을 뺌. ICG 래치처럼 리셋이 없고 입력 `phy_en`이 리셋된다 |
| CTRL · REMAP 설정 → DBI-AC → TX 워드 | −0.011 | 설정은 idle일 때만 바뀌므로 2클럭 multicycle(데이터 핀만) |
| MBIST 상태 → 조합 주소(shift · 덧셈 · XOR 맵) → 컨트롤러 주소 비교 → `req_ready` | −0.749 | 연산마다 요청을 한 클럭 먼저 계산해 플롭에서 냄(`f018966`) |
| BIRA 항목 → row · col 개수(직렬 증가 16단) → must-repair 결정 → 상태 저장 | −0.318 | 일치 벡터 + 균형 popcount, 개수를 레지스터로 받은 뒤 결정(`6c29d60`) |
| `fz_rdata`(입력 지연 0.5 ns) → SECDED 디코더 → repair 표 | −0.256 | fuse 읽기 데이터를 먼저 레지스터로(`6c29d60`) |
| 컨트롤러 쓰기 데이터 → ECC 인코더 → TX 워드 | −1.029 (전 −0.723) | 원시 워드를 레지스터로 받고 반 클럭 안에 인코딩, 주입 비트는 TX 워드 뒤에서(`ffc073d`) |
| 읽기 FIFO → unshift · DBI → ECC 디코더 → `rddata` | −0.403 | 디코더 앞 레지스터 단(`ffc073d`) |
| self-test 인덱스 → 비트 뒤집기 → 디코더 → 판정 → 실패 카운터 | −1.125 | 세 단계 파이프라인, codeword는 읽기 반환 레지스터로(`ffc073d`) |
| 컨트롤러 `ccmd` → 루프백 판정 → 읽기 FIFO pop · RD 추적 push | −0.810 | RD 추적은 CA 레지스터에서, 루프백은 레지스터한 명령으로(`ffc073d`). 이 경로의 실패 끝점 58 → 21 |
| 컨트롤러 응답 FIFO → MBIST 비교(32 bit XOR · OR) → 로그 중복 검사 → 로그 항목 | −0.099 | 차이를 레지스터로 받고 다음 클럭에 기록(`3d596a4`, 실행 클럭 수 그대로). 끝점 88개 |

컨트롤러가 800 MHz를 닫지 못하는 이유: 임계 경로는 큐 엔트리의 bank → 스케줄러의 row hit · 후보 계산 → refresh 차단 mux → FR-FCFS 선택 → ACT 결정 → 뱅크 타이머 갱신으로, 한 클럭에 명령을 고르고 모든 타이머를 갱신하는 루프다(약 35단, 2.1 ns). 호스트 입력도 컨트롤러의 `req_ready`가 요청 주소에 조합으로 걸려 있어(쓰기 큐 forwarding, 읽기 큐 충돌 검사) 입력 → `req_ready`가 feedthrough다(−0.521 ns, `8af801b`에서 −0.483). 같은 조합 경로가 `req_ready`를 받는 테스트 엔진의 상태 플롭까지 이어진다(끝점 19개, −0.271 ns, `14fec6e`에서는 −0.319).

같은 컨트롤러 RTL이 컨트롤러 저장소의 `make ppa`에서는 최소 주기 2.874 ns(reg2reg 2.831 + setup 0.043, 348 MHz)다. 두 흐름이 다르다: 그쪽은 `mem_ctrl`만 flatten해 ABC에 타이밍 목표 없이 매핑하고 팬아웃 버퍼를 넣지 않는다. 여기서는 칩 전체를 모듈 경계를 유지한 채 `abc -D 1250 -constr`(목표 1.25 ns, 입력 BUF_X1 · 부하 2 fF)로 매핑하고, 팬아웃 버퍼 트리(부하 16개마다)를 넣는다. 둘 다 배선 없는 Nangate45 typical 값이고, 어느 차이가 몇 %인지는 나눠 재지 않았다.

| 선택지 | 내용 | 판단 |
| --- | --- | --- |
| DFI 1 : 2 주파수 비율 | 컨트롤러를 400 MHz(2.5 ns)로 돌리고 클럭마다 명령 슬롯 두 개(phase 0 · 1)를 낸다. PHY가 phase를 800 MHz로 푼다 | 실제 DDR · HBM 컨트롤러가 쓰는 방식이고, 지금 논리 깊이(2.18 ns)로 닫힌다. 스케줄러가 한 클럭에 명령 두 개를 골라야 해서 컨트롤러 저장소에서 할 일이다 |
| 스케줄러 파이프라인 | 고르기와 타이머 갱신을 두 클럭으로 나눈다 | 이번 결정이 다음 클럭의 후보를 바꾸는 루프라, 나누면 추측 발행이나 한 클럭 쉬기가 필요하다 |
| 호스트 경계 레지스터 슬라이스 | 요청을 HSL 경계에서 한 번 레지스터로 받는다 | 입력 feedthrough만 없앤다(요청 1클럭 지연). 컨트롤러 내부 루프는 그대로다 |

## 이슈 기록

실습 중에 고친 문제와 재검증(실행, 합성, 코드 리뷰)에서 나온 문제다. PDF 17쪽에는 이 표의 주요 행이 있다.

| ID | 증상 | 원인 | 조치 |
| --- | --- | --- | --- |
| E1 | soft reset을 유지할 수 없음 | CSR까지 soft reset에 넣어 CTRL bit 0이 다음 사이클에 지워짐 | CSR은 `rst_sync_n`만, 나머지는 `rst_logic_n` |
| E3 | MISSION에서도 `cmd_ready` 0 | 스텁 큐가 `push_ready`를 0에 묶음 | 큐 구현 후 기대값을 "리셋 직후와 full일 때 0"으로 수정 |
| E8 | CDC 포인터 경로가 타이밍에서 빠짐 | false path는 그 경로의 지연을 보지 않음 | `set_max_delay`로 제약, false path 금지 |
| E11 | 고장이 통과하거나 정상처럼 보임 | seed 0끼리 비교, 16 bit wrap-around | seed 0 무시, 카운터 포화 |
| E12 | PHY 주기 1248 ps | 반주기를 정수 312 ps로 둠 | `#312.5ps`, 문서 · 패키지 · TB · SDC 대조표 |
| E12 | I/O delay 4.0 ns | 예전 10 ns 클럭의 40%가 남음 | 800 MHz 주기의 40%인 0.5 ns |
| A | `#312.5ps`가 313 ps로 반올림 | `timescale 1ns/1ps` | 정밀도 100 fs (`edb139a`) |
| B | 리셋 해제가 한 사이클 빨라짐 | TB가 posedge 직후 리셋을 풀어 첫 싱크 플롭과 레이스 | negedge에서 해제 (`edb139a`) |
| C | 합성 후 SDC 대상 셀이 사라짐 | 칩 안 `clk_phy` 경로의 입력이 tie-off | mission 경로가 TX 기어와 읽기 FIFO를 칩에서 써서 해소. SDC를 `u_phy/u_mis/u_rx_fifo`와 RDQS 기준으로 갱신. deskew만 블록 테스트로 남음 |
| D | 큐가 멈춘 채 풀리지 않음 | REF나 예약 opcode가 head에 오면 `head_ok` = 0 | 컨트롤러 교체로 해소(`0193c04`). 요청 포트에는 opcode가 없고, refresh는 컨트롤러가 스스로 낸다 |
| E | 리셋 없는 플롭 200개 | 큐 데이터 배열이 리셋 분기 밖 | 데이터 배열을 별도 `always_ff`로 분리하고 DFT 규칙에 명시 (`edb139a`) |
| 리뷰 | CDC 포인터 glitch 위험, 제약이 크로싱을 비켜 감 | binary 플롭의 XOR(조합 Gray)이 바로 싱크러나이저로 들어감. SDC는 한 클럭 안의 `*_s1` → `*_s2`를 묶고 있었음 | Gray 포인터를 소스 클럭 플롭으로 잡고, `set_max_delay`를 소스 Gray 플롭 → `*_s1`로 옮김 (`d1f8e2b`) |
| 리뷰 | 루프백 RD가 TX 버스트를 돌려주지 않음 (요구 5 미충족) | RD 응답이 그 시점의 TX 페이로드(큐 head의 wdata나 0)를 그대로 돌려줌 | 마지막 루프백 WR 버스트를 `lb_hold`에 보관해 RD로 반환, T8에 WR → RD 추가 (`d1f8e2b`) |
| 리뷰 | ModelSim-Altera 10.1d 컴파일 실패 | 폭이 파라미터인 캐스트 `BANK_W'(gi)`를 파싱하지 못함 | 타입이 있는 localparam으로 교체 (`d1f8e2b`) |
| 통합 | 가져온 컨트롤러가 ModelSim 10.1d에서 컴파일되지 않음 | 같은 파라미터 폭 캐스트 21곳 | 컨트롤러 저장소에서 고쳐 회귀를 다시 돌린 뒤(`44a0bb3`) 파일을 가져옴 |
| 통합 | 레인 BIST가 링크를 검사하지 못할 수 있음 | 새 컨트롤러는 쓰기 큐에 남은 주소의 읽기를 큐에서 답해 핀을 거치지 않음 | 컨트롤러에 `q_empty` 출력을 넣고, BIST가 쓰기 16개를 보낸 뒤 큐가 빌 때까지 기다렸다가 읽음 (`0193c04`) |
| STA | 1.6 GHz 도메인이 통째로 분석에서 빠짐(플롭 44개 클럭 없음) | PLL 빈 쉘 때문에 생성 클럭이 마스터에서 이어지지 않음 | PLL 타이밍 스텁 (`8af801b`) |
| STA | CDC `set_max_delay`가 아무 경로도 묶지 못함(경고만) | 합성 플롭 이름이 SDC 패턴과 다름 | 플롭에 레지스터 이름을 붙임 (`8af801b`). 같은 일이 실제 흐름에서 생기면 CDC가 조용히 제약 밖으로 빠진다 |
| STA | MBIST를 넣자 DFT에서 컨트롤러로 가는 실패 경로 1,752개(최악 −0.749 ns) | MBIST 주소를 조합으로 만들어 컨트롤러 입력 논리 앞에 0.78 ns가 붙음 | 요청을 플롭에서 냄 (`f018966`). 면적 표에서는 블록 분류 목록에 `hsl_mbist`가 없어 DFT FF가 그대로 보였고, 넷리스트를 열어 확인한 뒤 `area_by_block.py`를 고침 |
| 측정 | greedy BIRA가 수리 가능한 맵을 놓침(2 + 2 spare, 5워드에서 63.1% 대 73.2%) | must-repair 뒤의 greedy 선택은 앞 워드의 선택이 뒤를 막을 수 있음 | spare 순서 탐색으로 교체, 해가 있으면 찾음. Python 참조에서 exhaustive와 같음을 assert, T14 E가 greedy가 못 고치는 맵을 확인 (`6c29d60`) |
| 리뷰 | DFD trace가 카운터를 지울 때 trigger됨 | 이벤트를 "카운터가 바뀜"으로 봐서 ECC · ERRCNT clear와 MBIST 재시작(0으로 감)도 이벤트 | 0이 아닌 새 값으로 바뀔 때만 이벤트. T16이 trigger 원천 4개와 clear 3개를 확인(옛 RTL은 3건 FAIL) (`3d596a4`) |
| 리뷰 | RDQS 쪽 플롭의 리셋 해제가 RDQS에 맞지 않음 | 캡처 플롭과 FIFO 쓰기 쪽이 컨트롤러 클럭에서 맞춘 리셋으로 풀림 | RDQS 2-FF 동기화기(`u_rst_rdqs`), FIFO 쓰기 · 읽기 리셋 분리, 동기화기 입력만 false path. T12가 PHY off 동안 리셋 유지를 확인 (`3d596a4`) |
| 리뷰 | 요청 포트가 닫힌 채 시작한 레인 BIST · MBIST · 읽기 레벨링이 busy로 남음 | 엔진이 `req_ready`를 끝없이 기다림 | start 때 포트를 보고 닫혀 있으면 바로 done · refused(CSR 비트), BIRA는 수리 불가로. T13이 확인(옛 레인 BIST는 FAIL) (`3d596a4`) |
| 리뷰 | 다른 엔진 뒤에서 기다리는 start 동안 지난 실행의 done · pass가 보임 | 대기(`lb_hold` · `mb_hold`)가 CSR에 보이지 않고 done은 start가 실제로 들어갈 때만 지워짐 | 기다리는 동안 busy · 대기 비트로 읽고 done · pass는 0. T13이 두 순서에서 확인 (`e61e90d`) |
| 리뷰 | Gray 포인터 최상위 비트 크로싱이 CDC 제약 밖 | 합성이 Gray와 binary 최상위 비트 플롭을 합쳐 소스 셀 패턴이 놓침 | 소스 클럭 → 싱크 플롭 제약 (`e61e90d`) |
| 리뷰 | 통과한 MBIST 뒤에도 지난 실패의 첫 주소 · 비트가 남음. 거절된 읽기 레벨링이 eye 값만 지움 | start가 첫 실패 기록을 지우지 않음. 거절에도 구간 기록을 지움 | start가 첫 실패 기록을 지움, 거절이면 학습 결과를 그대로 둠. T13 (`e61e90d`) |
| 리뷰 | MBIST 중 읽기 레벨링을 시작하면 멈출 수 있음 | 첫 구현은 다른 엔진이 busy일 때 start를 버렸고, 읽기 레벨링은 자기가 낸 레인 BIST의 busy를 기다림. 같은 클럭에 두 start가 오면 둘 다 돌 수도 있었음 | start를 잡아 두었다가 포트가 비면 냄, 레인 BIST 우선. T13이 두 순서를 모두 확인 (`f018966`) |
| 리뷰 | 회귀의 채널 모델 오류 검사가 T12에서 멈춤 | T13–T17을 더할 때 검사 위치를 회귀 끝으로 옮기지 않음 | 회귀 끝 `[CH]` 검사. PHY off 재현을 넣은 TB가 `[ALL] FAIL`로 끝남을 확인 (`5a24f07`) |
| 리뷰 | PHY를 껐다 바로 켜면 열린 뱅크에 ACT(채널 모델 프로토콜 오류) | 컨트롤러가 idle이어도 refresh는 PRE · REFpb를 내고, PHY가 꺼진 동안 그 명령이 핀에 나가지 않음 | 규칙을 "다시 켜기 전 soft reset"으로 바로잡음(RTL 주석 · 문서). 실제 칩이면 self-refresh가 필요 (`5a24f07`) |

## 실행 방법

성공하면 `[ALL] PASS`가 찍히고 종료 코드 0으로 끝난다. 소스 순서는 [`sim/filelist.f`](sim/filelist.f)이고, 컨트롤러의 `dram_pkg`가 첫 파일, `hsl_pkg`가 그다음이다.

```powershell
# Windows: Icarus Verilog가 PATH에 있으면 그것을, 없으면 WSL의 Verilator를 쓴다
powershell -ExecutionPolicy Bypass -File .\sim\run_smoke.ps1
```

```bash
# Linux / WSL (Verilator 5.x, --binary --timing)
bash sim/run_smoke.sh        # 또는 make -C sim smoke
```

```bash
# RTL lint: Verilator -Wall, 경고 0. 남긴 waiver는 이유와 함께 syn/lint.vlt에 있다
make -C sim lint
```

```text
# ModelSim / Questa (저장소 루트에서. work/와 transcript는 git에서 제외됨)
vlib work
vlog -sv -f sim/filelist.f
vsim -c tb_hsl_smoke -do "run -all; quit -f"
```

```bash
# 칩 STA (WSL 등에서. sv2v, Yosys 0.52, OpenSTA 3.1, Nangate45 .lib 필요. 경로는 SV2V, LIB 환경 변수)
bash syn/sta_chip.sh         # 결과: build/sta_chip/sta.log, area.txt
```

확인한 조합은 Verilator 5.052와 ModelSim-Altera 10.1d다. HSL 파일은 `` `timescale 1ns/100fs ``라 `#312.5ps` 반주기가 반올림되지 않는다([`docs/e12_clocks.md`](docs/e12_clocks.md)). 컨트롤러 파일은 원래 저장소대로 `1ns/1ps`이고 지연 문장이 없다.

## 저장소 구조

```text
rtl/
  include/       hsl_pkg: 파라미터, 핀 · CA 배치, CSR 맵, host_addr (컨트롤러의 XOR 주소 맵)
  top/           hsl_base_die_lite, hsl_rst_sync
  ctrl/          hsl_csr, hsl_training_fsm
  mc/            dram_pkg, mem_ctrl, mc_* (Mini DRAM Controller v4, 그 저장소 44a0bb3과 같은 파일)
  phy/           hsl_phy_top, phy_mis, tx_gear, dbi, lane_shift, ecc, rd_train, deskew, cdc_fifo, phy_clk
  dft/           hsl_dft_top, prbs, loopback, err_cnt, lane_bist, mbist, bira, repair,
                 secded_enc · secded_dec, dfd, w1500
tb/              tb_hsl_smoke (top, 스코어보드), tb_hsl_blocks, models/dram_channel_behav (핀 검사, 배열 고장),
                 march_ref.py · bira_ref.py (MBIST 검출표와 BIRA 참조)
sim/             filelist.f, run_smoke.ps1, run_smoke.sh, Makefile
syn/             filelist.f, constraints/hsl_base_die_lite.sdc, ppa_block.sh (블록 PPA),
                 sta_chip.sh · sta_chip.tcl (칩 STA), fanout_buffer.py, area_by_block.py,
                 lib/hsl_phy_clk_stub.lib (PLL 타이밍 스텁)
docs/            스펙부터 PD 가이드까지 설계 문서, 실습 기록, images/
portfolio-deck/  포트폴리오 PDF, PPTX (29쪽, e61e90d 측정)
```

## 문서

[`docs/00_study_map.md`](docs/00_study_map.md)부터 읽고 [`docs/exercises.md`](docs/exercises.md)의 E0부터 따라가면 구현 순서(스펙 → 아키텍처 → 컨트롤러 타이밍 → PHY → DFT → PD 제약)와 같다.

| 문서 | 내용 |
| --- | --- |
| [00 스터디 맵](docs/00_study_map.md) | 항목별로 볼 파일, 3분 설명, 공개 HBM과 이 모델의 차이 |
| [01 요구 스펙](docs/01_requirements.md) | 기능 요구 7개, 파라미터, 타이밍, 전력 · 신뢰성 규칙, 수락 조건 |
| [02 아키텍처](docs/02_architecture.md) | 디지털 경계, 클럭 구조 A/B/C 비교, 클럭 식, 컨트롤러와 DFI 형태 경계, 데이터 배치, 리셋 |
| [03 마이크로아키텍처](docs/03_microarchitecture.md) | 계층, CSR 맵, 트레이닝 상태, 호스트 포트, CA 핀과 PHY beat, 레인 BIST, MBIST, repair, ECC, DFD |
| [04 검증 계획](docs/04_verification_plan.md) | 검증 계층, 스코어보드와 채널 모델 검사, SMOKE · T1–T17, 통과 규칙 |
| [05 PD 가이드](docs/05_pd_guide.md) | 클럭, 리셋, CDC, 핀 책임, floorplan, PD가 되묻는 항목 |
| [06 DFT 계획](docs/06_dft_plan.md) | 관측점, 루프백 두 종류, PRBS, 레인 BIST, MBIST와 고장 모델 · 검출표, BIRA · repair · fuse, ECC, DFD와 디버그 사례, 1500 포트, 스캔 규칙, 웨이퍼 테스트 순서 |
| [07 용어](docs/07_glossary.md) | 이 프로젝트에서 쓰는 용어의 뜻 |
| [08 시험 흐름](docs/08_test_flow.md) | 웨이퍼 · 패키지 시험 순서(전원 · fuse 로드 → 접근 → 데이터패스 → 링크 · 리페어 → 읽기 레벨링 → ECC → 배열 MBIST → BIRA · fuse → mission), 합격 조건, bin, 실패 분석, 시험 시간 |
| [실습 E0–E12](docs/exercises.md) · [E0/E1 노트](docs/e0_e1_notes.md) · [E12 클럭 대조](docs/e12_clocks.md) | 실습 단계와 완료 조건, 리셋 파형 설명, 클럭 주기 대조표 |

## 한계와 다음 단계

알려진 한계:

- 컨트롤러는 RD를 4개까지만 띄우는데, 이 PHY에서는 RD 하나가 슬롯을 오래 잡아(낸 클럭부터 data_valid까지 8 클럭, ECC 단계 전에는 7) 연속 읽기 대역이 절반 아래로 묶인다(읽기 32개 97 클럭, `ffc073d`)
- 컨트롤러가 Nangate45에서 459 MHz(2.18 ns, `e61e90d`)에서 닫혀 800 MHz 컨트롤러 클럭을 닫지 못한다. 한 클럭에 명령을 고르고 타이머를 갱신하는 루프 때문이며, DFI 1 : 2 주파수 비율이 맞는 방향이다([STA](#sta-세-클럭과-cdc)). 호스트 입력 → `req_ready`도 컨트롤러 안에서 조합으로 이어진다
- STA는 이상 클럭, 배선 없음, typical 한 코너다. hold는 CTS 뒤에 다시 봐야 하고(`e61e90d`의 removal 최악 −0.048 ns, RDQS 쪽 리셋 핀), 리셋 트리는 스크립트가 넣은 버퍼 트리로 대신했다
- PHY 읽기 경로에 고정 지연 계약(DFI `tphy_rdlat`)이 없다. 컨트롤러가 `rddata_valid`로 순서만 맞춘다
- PHY(`phy_en`)는 진행 중인 RD가 없을 때 끄고(끄면 답을 받지 못한다), 다시 켜기 전에 soft reset을 한다. 컨트롤러가 idle이어도 refresh는 계속 PRE · REFpb를 내는데, PHY가 꺼진 동안 그 명령은 핀에 나가지 않아 컨트롤러와 DRAM의 뱅크 상태가 어긋나고 DRAM은 refresh를 받지 못한다(row를 연 채 300클럭 끈 뒤 켜면 열린 뱅크에 ACT). soft reset은 둘을 모든 뱅크가 닫힌 상태로 다시 시작시킨다(채널 모델은 CKE low에서 뱅크를 닫는다). 실제 칩이면 PHY를 멈추기 전에 DRAM을 self-refresh에 넣어야 하고, 이 모델에는 self-refresh가 없다
- 루프백은 컨트롤러가 idle일 때만 바꿔야 한다. 루프백 RD는 핀에 CA를 내지 않으므로 auto-precharge(close page)와 함께 쓰면 DRAM 쪽 뱅크 상태가 어긋난다. 기본값인 open page에서만 쓴다
- deskew(0–4 tap)는 아직 칩 경로에 없고 블록 테스트만 한다
- mission 경로의 strobe와 UI 직렬화는 beat 단위로 추상화했다. 채널 모델이 RDQS를 CK + tDQSCK로 만들고, preamble · DQS gating은 없다. RDQS 쪽 리셋 동기화기도 RDQS가 계속 돈다는 이 가정에 기댄다(실제 RDQS는 읽기 동안만 토글)
- 루프백은 병렬 루프백만 있다. 직렬화 이후를 도는 핀 루프백은 없다
- 레인 BIST는 DQ 8레인만 진단한다. DBI 핀 고장은 DBI를 끈 상태에서 양방향 반전이 상쇄돼 데이터에 드러나지 않는다(경계 스캔 방식의 핀 테스트가 필요하다. 1500 포트에는 아직 WBR이 없다)
- 레인 BIST와 MBIST는 컨트롤러를 거치므로 호스트가 조용하고 응답을 다 받은 상태에서 시작해야 한다. 칩은 엔진이 도는 동안 호스트 포트를 막을 뿐 그 조건을 검사하지 않는다. 요청 포트가 닫힌 채 시작하면 엔진이 바로 거절하지만, 도는 중에 포트가 닫히면(PHY off) 엔진이 응답을 기다린 채 남아 soft reset으로 풀어야 한다
- MBIST는 solid background와 비트 단위 고장만 본다. 한 워드 안 비트 사이의 coupling(intra-word), 이웃 셀 패턴 고장, 데이터 보존(retention)은 checkerboard · 보존 대기 같은 배경과 요소가 더 필요하다. 영역은 bank 하나, 최대 16 × 16 워드다
- MBIST는 연산을 하나씩 내므로 느리다(연산당 약 13.2클럭, `ffc073d`). 실제 배열 MBIST는 core die에서 컨트롤러 없이 배열을 직접 몬다
- spare는 칩 전체에 row 2 · col 2뿐이고, col spare는 16-row 블록 하나에만 걸린다(MBIST 영역이 블록 경계에서 시작해야 col을 쓴다). BIRA는 실패 워드 로그(워드 단위, 16개)만 보므로 넘치면 수리 불가로 본다. 실제 배열은 subarray마다 spare가 있고 비트 단위 bitmap을 쓴다
- ECC 핀은 DBI와 레인 리페어 밖이다. 정정 불가 오류는 CSR로만 알리고 호스트 응답(`rsp_err`)에는 실리지 않는다(컨트롤러의 DFI 쪽에 오류 입력이 없음). SECDED라 3 bit 이상 오류는 잘못 정정될 수 있다. ECC enable은 컨트롤러가 idle일 때 바꾸고, 켜기 전에 쓴 데이터는 검사 비트가 없다
- 1500 포트는 WRCK를 clk로 오버샘플하므로 WRCK가 clk의 1/8 이하여야 하고, WBR · EXTEST가 없다
- trace는 16항목 플롭이고 column 주소를 담지 않는다(항목 32 bit에 행 CA와 열 명령 · bank만). 이벤트는 카운터가 0이 아닌 새 값으로 바뀌는 것으로 보므로 ECC 이벤트가 핀의 RD보다 몇 클럭 늦게 찍히고, 포화한(16'hFFFF) 카운터는 이벤트를 더 내지 않는다
- repair 표는 사이드밴드로 배열 모델에 간다. JEDEC의 PPR(post-package repair) 명령 순서는 없고, fuse 모델은 TB의 OTP 배열이다(프로그램 전압 · 시간, 읽기 마진 검사 없음)
- 읽기 레벨링은 MISSION에서 펌웨어(CSR)가 돌린다. 요청 포트가 MISSION에서만 열리기 때문이다. 트레이닝 FSM의 RDLVL 단계는 아직 done 펄스를 기다린다. 쓰기 방향 레벨링은 없다

다음 단계:

- [x] mission 데이터패스: 행 · 열 CA 핀, 동기 TX 기어 + WDQS, RDQS 캡처 + Gray FIFO (T12, 이슈 C)
- [x] Mini DRAM Controller v4를 DFI 형태로 붙여 in-order MC를 교체: FR-FCFS, refresh 발행과 tRFC, 핀 검사와 스코어보드 (T2–T4, `0193c04`)
- [x] Random traffic과 스코어보드로 toggle 커버리지 올리기 (T3, `0193c04`에서 56.6 → 83.4%. DFT · DFD를 더한 지금은 80.2%, `e61e90d`)
- [x] DBI-AC 모드와 off / DC / AC 전이 비교, DBI 읽기 경로 검증(T9)
- [x] shift 방식 레인 리페어와 레인 BIST: 검출 → 재매핑 → 재검사(T10)
- [x] 읽기 레벨링: 레인별 지연선 코드 스윕과 eye 중앙(T11)
- [x] 칩 STA: Nangate45 + OpenSTA로 `clk`, `clk_phy`, `rdqs` 세 클럭과 CDC 제약을 함께 확인하고, STA가 짚은 HSL 경로 4개를 고침 (`8af801b`)
- [x] March MBIST(MATS+ · March X · March C-)와 배열 고장 주입, 참조 시뮬레이터와 같은 검출표, 실패 워드 로그 (T13, `f018966`)
- [x] 실패 로그로 spare row · col 할당(BIRA, must-repair + spare 순서 탐색), repair 표로 soft repair, SECDED fuse와 리셋 뒤 로드로 hard repair (T14, `6c29d60`)
- [x] IEEE 1500 방식 시험 포트: WIR · WBY · ID · CSR 접근 WDR, MBIST를 직렬 포트만으로 실행 (T17, `14fec6e`)
- [x] DFD: trigger trace(pre/post, bank 필터), 명령 카운터, MISR, 심은 버그를 trace로 찾는 디버그 사례 (T16, `796d969`)
- [x] SECDED ECC: ECC 핀, 오류 주입, CE · UE 카운터와 첫 오류 주소 · syndrome, 디코더 self-test (T15, `ffc073d`)
- [x] 리뷰 수정: DFD가 clear를 이벤트로 보지 않음, RDQS 쪽 리셋 동기화, 포트가 닫힌 start 거절 (T12 · T13 · T16, `3d596a4`)
- [x] 재검토 수정: 기다리는 start의 CSR 표시, Gray 최상위 비트의 CDC 제약, MBIST 첫 실패 기록 초기화, 거절된 읽기 레벨링의 결과 보존 (T13, `e61e90d`)
- [x] 3차 검토 수정: 회귀 끝 채널 모델 검사, PHY를 껐다 켤 때의 soft reset 규칙, 트레이닝 FSM · fuse program · MBIST 로그 범위 명시 (`5a24f07`)
- [ ] 컨트롤러를 DFI 1 : 2로: 400 MHz에서 클럭마다 명령 두 개 (컨트롤러 저장소에서)
- [ ] 호스트 경계 레지스터 슬라이스로 입력 → `req_ready` feedthrough 없애기
- [ ] 컨트롤러의 읽기 반환 깊이(`RD_PIPE`)를 PHY 왕복에 맞추기 (컨트롤러 저장소에서)
- [ ] deskew를 읽기 경로에 연결
- [ ] starvation · RFM 경로를 지나는 테스트로 커버리지 구멍 메우기

## 관련 프로젝트

[Mini DRAM Controller](https://github.com/yhkwon-git/mini-dram-controller): 이 칩의 메모리 컨트롤러(`rtl/mc/`)가 그 저장소의 v4 RTL이다. 컨트롤러 단독 검증(랜덤 회귀 600만 요청, 독립 타이밍 체커, 기능 커버리지)과 v1–v4의 latency, throughput, PPA 비교는 그쪽에 있다.
