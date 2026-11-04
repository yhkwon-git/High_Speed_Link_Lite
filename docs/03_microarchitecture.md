# 마이크로아키텍처

## 계층

```text
hsl_base_die_lite
  hsl_rst_sync
  hsl_csr
  hsl_training_fsm
  hsl_mc_top
    hsl_cmd_queue
    hsl_bank_fsm x4
    hsl_scheduler
  hsl_phy_top
    hsl_phy_clk
    hsl_dbi
    hsl_lane_repair x4
    hsl_gearbox
    hsl_deskew
    hsl_cdc_fifo
    hsl_phy_tx
    hsl_phy_rx
  hsl_dft_top
    hsl_prbs
    hsl_loopback
    hsl_err_cnt
```

## 호스트 포트

`cfg_*`는 바이트 주소의 32비트 버스다. 읽기는 조합 논리라, 주소를 준 같은 사이클 안에 데이터가 유효하다. 테스트벤치는 주소를 준 뒤 1 ps 뒤에 읽는다. 쓰기는 `cfg_we`가 1인 클럭 엣지에서 일어난다.

`cmd_*`와 `rsp_*`는 valid/ready 버스트 버스다. 데이터 폭은 32비트다.

## CSR

주소는 바이트 기준이고, 정렬되지 않은 주소는 0을 반환한다.

| 주소 | 이름 | 접근 | 리셋 | 내용 |
| --- | --- | --- | --- | --- |
| `0x00` | ID | RO | | `0x48534C31` |
| `0x04` | VERSION | RO | | `0x00000100` |
| `0x08` | CTRL | RW | 0 | 아래 비트 |
| `0x0C` | STATUS | RO | | 아래 비트 |
| `0x10` | TRAIN | RW | wait=2 | `[0]` start, `[4:1]` done 펄스, `[15:8]` wait 저장 |
| `0x14` | ERRCNT | RW | 0 | 읽기는 카운트, 쓰기는 clear |
| `0x18` | REMAP | RW | 0 | `[0]` enable, `[7:4]` lane |
| `0x1C` | TIMING0 | RW | 패키지 기본값 | `{tCCD, tRAS, tRP, tRCD}` |
| `0x20` | TIMING1 | RW | 패키지 기본값 | `{tRFC, tRTP, tWR, tWTR}` |

각 필드는 8비트이고, 오른쪽이 LSB다. tRCD와 tWTR이 `[7:0]`에 있다.

CTRL 비트:

| 비트 | 이름 | 동작 |
| --- | --- | --- |
| 0 | soft_rst | CSR 바깥 데이터패스 리셋 |
| 1 | train_bypass | FSM을 MISSION으로. 내려도 MISSION에 남음 |
| 2 | loopback | 병렬 루프백. RD가 루프백 중 마지막 WR 버스트를 돌려줌. 핀 루프백은 아님 |
| 3 | prbs_en | PRBS7을 TX 페이로드로 |
| 4 | dbi_en | beat popcount가 4보다 크면 반전 |
| 5 | phy_bypass | 1일 때 TX가 채널 모델과 버스트를 주고받음 |

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

`train_bypass`가 1이면 리셋이 풀린 다음 클럭에 MISSION으로 간다. bypass를 내려도 MISSION에 남는다. `soft_rst`가 리셋을 잡고 있으면 bypass보다 리셋이 우선한다.

## 명령

| 값 | 이름 |
| --- | --- |
| 0 | NOP |
| 1 | ACT |
| 2 | PRE |
| 3 | PREA |
| 4 | RD |
| 5 | WR |
| 6 | REF |
| 7 | REFA |
| 8 | MRS |
| 9 | PDE |
| A | PDX |

## 핀

베이스 다이에서 채널을 본 방향이다.

| 핀 | 폭 | 값 |
| --- | --- | --- |
| `pin_ck` | 1 | 0에 고정. 로직 클럭을 범프에 연결하지 않는다 |
| `pin_cke` | 1 | FSM이 RESET이 아니면 1 |
| `pin_ca` | 8 | `{2'b00, bank, opc}` |
| `pin_dq_o` | 10 | `{RED, DBI, DQ[7:0]}` |
| `pin_dq_oe` | 1 | 구동 사이클만 1 |
| `pin_dqs_o` | 1 | 심볼 사이클만 1 |
| `pin_dq_i` | 10 | 입력 |
| `pin_dqs_i` | 1 | 입력 |

`phy_bypass`가 1일 때만 TX가 핀을 움직인다. 명령이 받아진 사이클은 IDLE이라 핀이 조용하고, 다음 사이클이 헤더다.

| 명령 | 핀 |
| --- | --- |
| ACT | 한 사이클. DQ[7:0]에 row, dqs=1 |
| PRE | 한 사이클. dqs=1 |
| WR | 헤더(DQ[3:0]에 col)와 데이터 beat 4개 |
| RD | 헤더 한 사이클. 모델이 그 negedge부터 논리 바이트 4개를 구동 |
| NOP | IDLE에서 받고 핀은 조용함 |

채널 모델은 컨트롤러 클럭의 negedge에서 샘플한다. DQS는 스터디용으로 송수신을 한 쌍의 단일 핀으로 줄였다. 실제 HBM3는 WDQS와 RDQS가 나뉜다.

`loopback`이 1이어도 TX는 핀을 똑같이 구동한다. 달라지는 것은 RX다. `hsl_phy_top`의 `lb_hold`가 루프백 중 받아진 WR의 페이로드(DBI와 리페어 전)를 잡아 두고, RD는 `rd_start` 다음 클럭에 핀을 보지 않고 그 값을 응답한다.

기어박스는 칩 안에서 `din_valid`가 0이다. 32비트를 16비트 두 beat로 나누는 동작은 별도 인스턴스가 검사한다. beat0이 하위 16비트다.

## 뱅크 FSM

```text
CLOSED --ACT--> ACTIVATING --tRCD--> OPEN --PRE--> PRECHARGING --tRP--> CLOSED
```

`timing_ok`는 CLOSED에서 1이다. OPEN에서는 `ras_left`와 컬럼 뒤 블록(tWR 또는 tRTP)이 둘 다 0일 때 1이다. 그래서 컬럼 명령은 tRCD에 더해 tRAS도 기다린다. JEDEC 최소보다 엄격하고, tRCD 전에 RD를 거절하는 조건은 그대로다. tCCD와 tWTR은 스케줄러가 채널 단위로 본다. 컬럼을 발행하면 `ccd_cnt`에 `tCCD-1`을 넣어, tCCD=2이면 한 사이클을 띄우고 다음 컬럼을 낸다.

스케줄러는 큐 head만 본다. head가 불법이면 그 비트를 버리지 않고 `req_ready`를 0으로 둔다. NOP은 항상 합법이다. REF와 그 밖의 예약 opcode는 불법이라 head를 막는다. 이런 명령이 큐에 들어가면 뒤 명령도 나가지 않고, `soft_rst`로만 풀린다.
