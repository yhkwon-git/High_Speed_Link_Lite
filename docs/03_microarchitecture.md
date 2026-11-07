# 마이크로아키텍처

## 계층

```text
hsl_base_die_lite
  hsl_rst_sync
  hsl_csr
  hsl_training_fsm
  hsl_rd_train
  mem_ctrl                 Mini DRAM Controller v4 (rtl/mc, 그 저장소 44a0bb3과 같은 파일)
    mc_queue x2            읽기 8, 쓰기 8
    mc_xage
    mc_wdrain
    mc_bank x4
    mc_chan
    mc_refresh
    mc_sched
    mc_resp
  hsl_phy_top
    hsl_phy_clk
    hsl_dbi
    hsl_phy_mis
      hsl_lane_shift
      hsl_tx_gear
      hsl_cdc_fifo
  hsl_dft_top
    hsl_prbs
    hsl_loopback
    hsl_err_cnt
    hsl_lane_bist
    hsl_mbist
hsl_deskew                 블록 테스트만
```

## 호스트 포트

`cfg_*`는 바이트 주소의 32비트 버스다. 읽기 데이터는 레지스터에서 나온다: `cfg_rdata`는 직전 클럭 엣지의 `cfg_addr`에 있던 레지스터 값이라, 주소를 준 다음 엣지 뒤에 유효하다. 칩 STA(`8af801b`)에서 입력 → 출력 조합 feedthrough가 입출력 지연에 걸려 바꿨다. 테스트벤치는 negedge에 주소를 내고 다음 posedge 뒤에 읽는다. 쓰기는 `cfg_we`가 1인 클럭 엣지에서 일어난다.

요청 포트는 컨트롤러의 호스트 포트를 그대로 낸다.

| 신호 | 폭 | 뜻 |
| --- | --- | --- |
| `req_valid`, `req_ready` | 1, 1 | `valid && ready`인 엣지에서 요청 하나가 들어간다 |
| `req_write` | 1 | 1 쓰기, 0 읽기 |
| `req_addr` | 14 | 워드 주소. 컨트롤러의 XOR 맵: col = a[3:0], bank = a[5:4] ^ a[7:6], row = a[13:6]. `hsl_pkg::host_addr(bank, row, col)`이 그 반대 |
| `req_wdata` | 32 | 쓰기 데이터(버스트 하나) |
| `rsp_valid`, `rsp_ready` | 1, 1 | 요청마다 응답 하나, 요청 순서대로 |
| `rsp_rdata`, `rsp_err` | 32, 1 | 읽기 데이터. `rsp_err`는 0 |

- 쓰기는 받은 다음 클럭에 응답한다(posted). 데이터는 쓰기 큐에 있다가 쓰기 배치로 나간다.
- 쓰기 큐에 있는 주소를 읽으면 가장 최근 쓰기로 바로 답한다(forwarding). 이 읽기는 핀에 RD를 내지 않는다.
- 읽기 큐에 있는 주소로 쓰려 하면 그 읽기가 나갈 때까지 쓰기를 받지 않는다.
- 진행 중인 요청은 15개(tag 4 bit)까지다. 호스트가 `rsp_ready`를 내리면 응답이 쌓이고, tag가 차면 `req_ready`가 0이 된다.
- `req_ready`는 MISSION이면서 `CTRL.phy_en`일 때만 1이 될 수 있다. 레인 BIST나 MBIST가 도는 동안은 0이고 `rsp_valid`도 0이다.

## CSR

주소는 바이트 기준이고, 정렬되지 않은 주소는 0을 반환한다.

| 주소 | 이름 | 접근 | 리셋 | 내용 |
| --- | --- | --- | --- | --- |
| `0x00` | ID | RO | | `0x48534C31` |
| `0x04` | VERSION | RO | | `0x00000300` |
| `0x08` | CTRL | RW | 0 | 아래 비트 |
| `0x0C` | STATUS | RO | | 아래 비트 |
| `0x10` | TRAIN | RW | wait=2 | `[0]` start, `[4:1]` done 펄스, `[15:8]` wait 저장 |
| `0x14` | ERRCNT | RW | 0 | 읽기는 카운트, 쓰기는 clear |
| `0x18` | REMAP | RW | 0 | `[0]` enable, `[7:4]` 건너뛸 핀: 0–7 DQ, 8 DBI, 9 이상은 shift 없음 |
| `0x1C` | TIMING0 | RO | | `{tCCD_L, tRAS, tRP, tRCD}`, 컨트롤러 `dram_pkg` 상수 |
| `0x20` | TIMING1 | RO | | `{tRFC, tRTP, tWR, tWTR_L}`, 컨트롤러 `dram_pkg` 상수 |
| `0x24` | LANE_BIST | RW | 0 | 쓰기 `[0]` start, `[5:4]` bank, `[15:8]` row. 읽기 `[0]` busy, `[1]` done, `[2]` pass, `[3]` 한 레인만 실패, `[7:4]` 가장 낮은 실패 레인, `[15:8]` DQ 레인별 에러, `[20:16]` 불일치 버스트 수 |
| `0x28` | RDTRAIN | RW | 0 | 쓰기 `[0]` start, `[6:4]` 읽어 볼 레인. 읽기 `[0]` busy, `[1]` done, `[2]` 모든 레인에서 eye 찾음, `[6:4]` 레인, `[12:8]` 그 레인의 코드, `[20:16]` eye 시작, `[29:24]` eye 폭 |
| `0x2C` | MBIST | RW | 0 | 쓰기 `[0]` start, `[2:1]` 알고리즘(0 MATS+, 1 March X, 2 March C-, 3은 2로), `[5:4]` bank, `[15:8]` 첫 row, `[19:16]` row 수 − 1, `[22:20]` log2 컬럼 수(4보다 크면 4). 읽기 `[0]` busy, `[1]` done, `[2]` pass(done이고 실패 0), `[3]` 로그 넘침, `[8:4]` 로그의 실패 워드 수, `[31:16]` 실패 읽기 수(포화) |
| `0x30` | MBIST_LOG | RW | 0 | 쓰기 `[3:0]` 읽을 로그 항목. 읽기 `[13:0]` 첫 실패 읽기의 호스트 주소, `[23:16]` 그 항목 `{row offset[3:0], col[3:0]}`, `[27:24]` 항목 번호 |
| `0x34` | MBIST_BITS | RO | 0 | 첫 실패 읽기에서 기대값과 다른 비트 |

TIMING 필드는 8비트이고, 오른쪽이 LSB다. tRCD와 tWTR_L이 `[7:0]`에 있다. 쓰기는 무시한다. 타이밍은 컨트롤러가 상수로 지키므로, 바꾸려면 컨트롤러 저장소의 `dram_pkg`를 고친다.

CTRL 비트:

| 비트 | 이름 | 동작 |
| --- | --- | --- |
| 0 | soft_rst | CSR 바깥 데이터패스 리셋 |
| 1 | train_bypass | FSM을 MISSION으로. 내려도 MISSION에 남음 |
| 2 | loopback | 병렬 루프백. RD를 핀으로 내지 않고 루프백 중 마지막 쓰기 버스트로 답함. 핀 루프백은 아님 |
| 3 | prbs_en | PRBS7을 쓰기 페이로드로 |
| 4 | dbi_en | DBI 켬. 규칙은 bit 6 |
| 5 | (예약) | v0.1의 `phy_bypass`. 0으로 읽힘 |
| 6 | dbi_ac | 0: DC(beat popcount가 4보다 크면 반전), 1: AC(직전 UI 대비 DQ 전이가 4보다 많으면 반전. beat 0의 기준은 직전 클럭 쓰기 버스트의 마지막 바이트, 없으면 0) |
| 7 | phy_en | PHY 켬: CK 출력, 명령과 데이터를 핀으로. 요청 포트도 이때만 열림 |

STATUS 비트:

| 비트 | 이름 |
| --- | --- |
| 4:1 | train_state |
| 5 | train_done |
| 6 | mission_mode |
| 7 | soft_rst 에코 |

TRAIN 쓰기는 `[0]` start, `[1]` zq_done, `[2]` wrlvl_done, `[3]` rdlvl_done, `[4]` deskew_done을 한 클럭 펄스로 만든다. `[15:8]`은 `train_wait`에 저장되고, FSM은 이 값을 쓰지 않는다. 읽으면 펄스 비트는 0이고 wait만 보인다. FSM은 논블로킹 대입 때문에 펄스를 한 클럭 뒤에 본다.

## 트레이닝 상태

| 값 | 이름 | 진행 |
| --- | --- | --- |
| 0 | RESET | CKE = 0. `train_start`를 기다림 |
| 1 | CKE | 한 클럭 뒤 MRS |
| 2 | MRS | 한 클럭 뒤 ZQCAL |
| 3 | ZQCAL | `zq_done`까지 머무름 |
| 4 | WRLVL | `wrlvl_done`까지 머무름 |
| 5 | RDLVL | `rdlvl_done`까지 머무름 |
| 6 | DESKEW | `deskew_done`까지 머무름 |
| 7 | WRTRAIN | 한 클럭 뒤 MISSION |
| 8 | MISSION | CKE = 1, `train_done` = 1 |

`train_bypass`가 1이면 리셋이 풀린 다음 클럭에 MISSION으로 간다. bypass를 내려도 MISSION에 남는다. `soft_rst`가 리셋을 잡고 있으면 bypass보다 리셋이 우선한다. CKE가 0인 동안 채널 모델은 모든 뱅크를 닫힌 것으로 본다(soft reset 뒤 컨트롤러와 같은 상태).

## DRAM 명령

컨트롤러의 `dram_cmd_e` 코드가 그대로 CA 핀에 나간다.

| 값 | 이름 | 버스 | 뜻 |
| --- | --- | --- | --- |
| 0 | NOP | 둘 다 | |
| 1 | ACT | 행 | row를 연다 |
| 2 | RD | 열 | 열린 row에서 읽기. `ap` = 1이면 auto-precharge |
| 3 | WR | 열 | 열린 row에 쓰기. 데이터는 WL 클럭 뒤 |
| 4 | PRE | 행 | 한 뱅크 닫기 |
| 5 | REF | 행 | 전체 refresh. 모든 뱅크가 닫혀 있어야 함(REF_ALL 모드) |
| 6 | PREA | 행 | 모든 뱅크 닫기(REF_ALL 모드) |
| 7 | REFPB | 행 | 한 뱅크 refresh(per-bank 모드, 기본). RFM도 이 명령 |

컨트롤러는 매 클럭 행 명령 하나와 열 명령 하나를 낼 수 있다. 열 명령은 row를 싣지 않는다. 같은 뱅크 타이밍은 `mc_bank`, bank group 사이 타이밍(tCCD · tRRD · tWTR의 S/L, tFAW, tRTW, tRFC)은 `mc_chan`, refresh는 `mc_refresh`와 `mc_sched`가 맡는다. 자세한 규칙은 컨트롤러 저장소의 `docs/spec.md`에 있다.

## 핀

베이스 다이에서 채널을 본 방향이다.

| 핀 | 폭 | 값 |
| --- | --- | --- |
| `pin_ck` | 1 | `phy_en`일 때 `clk_phy`(게이트, PHY 하강 엣지 enable). 그 밖에는 0. enable 플롭은 ICG 래치처럼 리셋이 없다 |
| `pin_cke` | 1 | FSM이 RESET이 아니면 1 |
| `pin_rca` | 13 | 행 CA `{cmd[2:0], bank[1:0], row[7:0]}`, 한 컨트롤러 클럭 |
| `pin_cca` | 10 | 열 CA `{cmd[2:0], bank[1:0], col[3:0], ap}`, 한 컨트롤러 클럭 |
| `pin_tx_beat` | 20 | 쓰기 beat, UI 두 개 × `{RED, DBI, DQ[7:0]}`, UI0이 하위 |
| `pin_tx_dqs` | 2 | WDQS 패턴, 데이터가 있는 beat에서 `01`(UI0 high, UI1 low) |
| `pin_tx_dv` | 1 | 쓰기 beat 유효. 유효하지 않은 beat는 0 |
| `pin_rdqs` | 1 | 입력. RDQS, 읽기 beat를 이 상승 엣지에서 받음 |
| `pin_rx_beat`, `pin_rx_dv` | 20, 1 | 입력. 읽기 beat와 유효 |
| `rx_dly_code` | 8 × 5 | 레인별 읽기 지연선 코드, 아날로그 PHY로 |

PHY는 컨트롤러의 행 · 열 명령을 한 클럭 레지스터로 받아 그대로 낸다(`phy_en`이 0이면 NOP). 쓰기 데이터는 컨트롤러가 WR 뒤 WL(1) 클럭에 `wrdata_en`과 함께 낸다. PHY는 그 워드를 DBI → 레인 shift(4 심볼) → 레지스터에 넣고, TX 기어(`hsl_tx_gear`)가 반 주기 뒤의 PHY 엣지(E1)에서 받아 하위 beat를, 다음 E0에서 상위 beat를 낸다. E1은 컨트롤러 클럭 토글을 PHY 클럭으로 이전 값과 비교해 찾는다. 그래서 첫 beat는 WR이 핀에 나온 뒤 1.5 컨트롤러 클럭(CK 3주기)에 나간다.

읽기는 RDQS 상승 엣지에서 beat 두 개를 모아 깊이 4 Gray FIFO(40 bit)에 쓰고, 컨트롤러 클럭에서 꺼내 shift와 DBI를 푼 뒤 `rddata_valid`로 컨트롤러에 넘긴다. 핀의 RD부터 `rddata_valid`까지 6 클럭이다(T12). 지연을 고정하지 않으므로 컨트롤러는 `rddata_valid`로 진행 중인 RD를 센다.

채널 모델은 CA를 컨트롤러 클럭의 negedge에서, 쓰기 beat를 beat 가운데(`pin_ck` negedge)에서 샘플한다. 쓰기 버스트는 WR이 들어온 순서대로, WR 때 열려 있던 row에 저장한다. 읽기 beat는 RD 뒤 `RL_RDQS` = 3 RDQS 주기에 RDQS 하강 엣지에서 낸다.

`loopback`이 1이면 PHY는 쓰기를 그대로 핀으로 내고, `hsl_phy_top`의 `lb_hold`가 그 페이로드(DBI와 리페어 전)를 잡아 둔다. RD는 핀에 CA를 내지 않고 다음 클럭에 그 값으로 `rddata_valid`를 낸다. 컨트롤러가 진행 중인 RD를 세므로 순서는 유지된다. auto-precharge가 붙은 RD라면 DRAM 쪽 뱅크 상태가 컨트롤러와 어긋나므로, 루프백은 기본값인 open page에서만 쓴다.

## 레인 BIST

```text
IDLE --start--> P_WR: 쓰기 16개 (컬럼 0..15, PRBS7) --> P_DRAIN: q_empty 대기
     --> P_RD: 읽기 16개 --> P_WAIT: 응답 32개 (쓰기 응답 16은 세기만) --> done
```

`LANE_BIST`의 bank와 row는 DRAM 쪽 주소다. BIST는 `host_addr`로 호스트 주소를 만들어 요청 포트에 낸다. 쓰기가 큐에 남은 채 읽으면 컨트롤러가 큐에서 답해 링크를 거치지 않으므로, 컨트롤러의 `q_empty`(두 큐가 모두 빔)를 기다린 뒤 읽는다. 큐가 비면 모든 쓰기의 WR이 핀으로 나간 것이고, 같은 뱅크의 RD는 컨트롤러가 tWTR_L을 지키므로 데이터보다 먼저 닿지 않는다(채널 모델이 검사). 읽은 워드는 같은 seed의 PRBS7과 beat마다 비교해 DQ 레인별로 sticky 기록한다.

## MBIST

```text
IDLE --start--> LOAD: 다음 연산의 주소 · 데이터 · 로그 키를 플롭에 --> ISSUE: 요청 하나
  쓰기: --> WACK 응답 --> DRAIN q_empty --> GUARD 4클럭 --> NEXT
  읽기: --> RWAIT 응답, 기대값과 비교, 실패면 기록 --> NEXT
NEXT: 같은 요소의 두 번째 연산, 다음 워드(요소 방향), 다음 요소, 또는 done --> LOAD
```

영역은 `MBIST` 쓰기의 bank, 첫 row, row 수, 컬럼 수다. 워드 순서는 row마다 컬럼이 빠르게 돈다(`idx = row offset × 2^ncl + col`). 주소는 `host_addr(bank, row0 + row offset, col)`로 만들어 요청 포트에 낸다. 요소 표는 `{last, down, two, op0, op1}` 7 bit이고 연산은 `{write, value}`다.

- **순서**: 연산을 하나씩 낸다. 컨트롤러는 다른 주소의 요청 순서를 바꾸므로, March 순서를 배열에 그대로 전하려면 앞 연산이 배열에 닿은 뒤 다음을 낸다. 쓰기는 posted 응답 뒤 `q_empty`(WR이 핀으로 나감)와 4클럭(WL과 TX 기어를 지나 배열에 닿음)을, 읽기는 응답을 기다린다.
- **기록**: 실패 읽기마다 `fail_cnt`(16 bit 포화). 첫 실패는 주소와 다른 비트를 남긴다. 로그는 실패 워드를 `{row offset, col}`로 최대 16개, 같은 워드는 한 번만(16개 비교) 넣고, 17번째 새 워드부터는 `log_ovf`를 세운다.
- **포트 공유**: `hsl_dft_top`이 레인 BIST와 MBIST를 한 테스트 포트(`tp_*`)로 묶는다. 한 번에 하나만 돌고, 다른 엔진이 도는 동안 또는 같은 클럭에 온 start는 잡아 두었다가 포트가 비면 낸다(레인 BIST 우선). 읽기 레벨링이 자기가 낸 레인 BIST의 busy를 기다리므로 start를 버리지 않는다.
- **타이밍**: 요청 출력(`req_addr`, `req_write`, `req_wdata`)은 플롭이다. 조합 주소(가변 shift, 덧셈, XOR 맵)가 컨트롤러의 주소 비교 앞에 붙으면 칩 STA에서 −0.749 ns였다.
