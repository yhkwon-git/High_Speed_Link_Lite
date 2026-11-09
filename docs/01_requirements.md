# 요구 스펙

스터디 스펙이다(v0.1에서 시작해 지금은 v0.3). 고객 요구를 설계자가 받아 적는 형식으로 두었다. 숫자 변경은 이 문서를 먼저 고치고, 그다음 `hsl_pkg`를 고친다. DRAM 타이밍은 컨트롤러 저장소의 `dram_pkg`가 원본이다.

## 대상

Base die 디지털 한 슬라이스. 메모리 컨트롤러를 base die 안에 두는 custom HBM 구조를 전제로 한다. 표준 HBM에서는 컨트롤러가 호스트 SoC에 있어 호스트가 DRAM 명령을 직접 보내지만, 여기서는 호스트가 워드 주소의 읽기 · 쓰기 요청을 보내고 DRAM 명령은 base die가 만든다. 호스트에서 본 제어 버스와 요청 버스, 채널 쪽에서 본 핀을 가진다. DRAM 코어와 아날로그 PHY는 경계 밖의 모델이다.

## 기능

1. 리셋 해제 후 트레이닝 시퀀스를 끝내고 PHY를 켜기 전에는 호스트 요청을 받지 않는다.
2. 트레이닝 순서는 RESET, CKE, MRS, ZQ 대기, write leveling, read leveling, deskew, write training, MISSION이다. read leveling은 레인마다 지연선 코드를 스윕해 통과 구간의 중앙을 고를 수 있어야 한다. 이 칩의 FSM은 상태 순서만 두고 MRS · ZQ · leveling 명령은 내지 않는다(DRAM 쪽 설정은 채널 모델 입력, 읽기 레벨링은 MISSION에서 CSR로).
3. MISSION 이후 워드 주소의 읽기와 쓰기를 받는다. ACT, PRE, refresh 같은 DRAM 명령은 컨트롤러가 스스로 만들고, refresh는 빠뜨리지 않는다.
4. 요청마다 응답이 하나 있고 요청 순서대로 나온다. 쓰기는 받은 즉시 응답하고(posted), 읽기 응답은 버스트 하나다. 호스트가 `rsp_ready`를 내리면 응답은 기다린다.
5. 루프백 모드에서는 DRAM 대신 TX 쪽 버스트를 RX로 되돌릴 수 있어야 한다.
6. 레인 리페어 레지스터로 고장 핀 하나(DQ 또는 DBI)를 건너뛰고 리던던트 핀까지 레인을 한 칸씩 옮길 수 있어야 한다. 고장 레인은 칩 안의 BIST로 찾을 수 있어야 한다.
7. 호스트는 ID, 버전, 트레이닝 상태, 에러 카운트를 읽을 수 있어야 한다.
8. DRAM 배열을 March 알고리즘(MATS+, March X, March C-)으로 시험하고, 첫 실패의 주소 · 비트와 실패 워드 목록을 남길 수 있어야 한다.
9. 실패 목록으로 spare row · column을 고르고(수리할 수 있으면 반드시 찾음), 그 결과를 배열에 적용(soft repair)하고 fuse에 기록해 리셋 뒤에도 유지(hard repair)할 수 있어야 한다. fuse 데이터는 ECC로 보호한다.
10. 쓰기 · 읽기 데이터에 SECDED ECC를 걸 수 있어야 한다. 오류 주입, 정정 · 정정 불가 수와 첫 오류의 주소, 디코더 자체 시험이 있어야 한다.
11. 실리콘 디버그를 위해 핀의 명령과 오류 이벤트를 trigger 전후로 기록하고, 명령 수와 읽기 데이터 signature를 볼 수 있어야 한다.
12. 시험 장비가 IEEE 1500 방식 직렬 포트 하나로 모든 시험 기능(CSR)에 닿을 수 있어야 한다.

E2 이후 구현은 1–7을, 4단계 구현(`f018966` – `14fec6e`)은 8–12를 스터디 범위 안에서 만족한다(T13–T17, 시험 순서는 `docs/08_test_flow.md`). 5번은 병렬 루프백이다. 루프백이 켜진 동안 마지막으로 보낸 WR 버스트를 다음 RD가 핀을 보지 않고 돌려준다. ZQ, write leveling, read leveling, deskew는 done 펄스가 오기 전에는 그 상태에 머문다. read leveling의 알고리즘은 `hsl_rd_train`이고 MISSION에서 CSR로 돌린다. refresh는 컨트롤러가 per-bank(REFpb)로 tREFI/4마다 한 뱅크씩 낸다.

## 스터디 파라미터

| 항목 | 값 | 비고 |
| --- | --- | --- |
| DQ | 8 | HBM 채널 폭이 아니다 |
| DBI | 1 | 비트는 버스트의 beat마다 하나 |
| 리던던트 DQ | 1 | 디지털 먹스만 |
| 버스트 | 4 | beat 0이 첫 UI |
| 뱅크 | 4 | bank group 2 × 2 |
| Row / Col | 8 / 4 bit | 주소 공간은 모델용 |
| 호스트 주소 | 14 bit 워드 주소 | XOR 맵: bank = a[5:4] ^ a[7:6] |
| 컨트롤러가 보는 데이터 | 32 bit | `DQ_W * BL` |
| 목표 데이터율 | 3.2 Gb/s per DQ | CK 1.6 GHz, 컨트롤러 800 MHz |
| 시뮬 / SDC 클럭 | 컨트롤러 1.25 ns, PHY 0.625 ns | `CTRL_PERIOD_PS`, `PHY_PERIOD_PS`. 표는 `docs/e12_clocks.md` |

목표 데이터율의 raw 대역은 `8 * 3.2 Gb/s = 25.6 Gb/s = 3.2 GB/s`다. 리프레시, 커맨드 간격, 트레이닝을 빼기 전의 숫자다.

## 타이밍 기본값

컨트롤러 클럭 단위다. 값은 컨트롤러의 `dram_pkg`에 있는 축소 모델 값이고 JEDEC 값이 아니다. TIMING0/1 CSR이 그중 일부를 읽기 전용으로 보여 준다(`TIMING0_DEFAULT`, `TIMING1_DEFAULT`).

| 파라미터 | 클럭 | 소유 블록 |
| --- | --- | --- |
| tRCD | 3 | `mc_bank` |
| tRP | 3 | `mc_bank` |
| tRAS | 6 | `mc_bank` |
| tRC | 9 | `mc_bank` |
| tRTP | 2 | `mc_bank` |
| tWR | 2 | `mc_bank` (WR → PRE ≥ WL + 1 + tWR) |
| tCCD_S / tCCD_L | 1 / 2 | `mc_chan` (bank group 밖 / 안) |
| tRRD_S / tRRD_L | 2 / 3 | `mc_chan` |
| tWTR_S / tWTR_L | 2 / 4 | `mc_chan` |
| tFAW | 8 | `mc_chan` |
| tRTW | 4 | `mc_chan` |
| tRFC / tRFCpb | 12 / 8 | `mc_chan` / `mc_bank` |
| tREFI | 64 | `mc_refresh` (per-bank는 tREFI/4마다 REFpb 하나) |
| WL | 1 | `mc_resp` (쓰기 데이터 파이프) |

채널 모델은 같은 뱅크 규칙(tRCD, tRP, tRAS, tRC, tRTP, 쓰기 회복, tRFCpb, tRFC)을 핀에서 다시 잰다.

## 전력과 신뢰성

- CKE가 0이면 채널 클럭 쪽 활동이 없는 것으로 본다. v0.1은 FSM이 RESET일 때만 CKE가 0이다.
- DBI-DC는 beat의 1 개수가 `DQ_W/2`보다 크면 반전한다. 전제: high가 터미네이션 전류를 쓴다. 이 극성은 스터디 규칙이다.
- DBI-AC는 직전 UI에 나간 바이트 대비 바뀌는 DQ가 `DQ_W/2`보다 많으면 반전한다. 전이 수가 스위칭 전력과 SSO를 정하는 종단 없는 짧은 채널용이다. CSR `CTRL[6]`로 고른다.
- 쓰기 beat가 없으면 TX beat는 0이다. 드라이버 enable은 아날로그 쪽이 `pin_tx_dv`로 만든다.
- 배드 핀 1개를 shift 방식으로 우회한다(spare 핀 1개). 양 끝이 같은 설정을 쓴다.
- 에러 카운터는 16비트에서 포화하고, 랩어라운드하지 않는다(ECC 정정 · 정정 불가 카운터, MBIST 실패 수도 같다).
- 배열에 spare row 2개와 spare column 2개(column은 16-row 블록 하나)가 있다고 둔다. 수리 결과는 fuse 워드(SECDED (39,32))로 남고, 1 bit 오류는 정정, 2 bit 오류는 그 항목을 버리고 알린다.
- ECC 검사 비트는 ECC 핀 두 개로 데이터와 함께 나가고 DRAM이 저장한다. ECC는 기본으로 꺼져 있고, 배열 시험은 ECC를 끄고 한다.

## 수락 조건

- 스모크 테스트가 `[SMOKE] PASS`다.
- 이후 실습은 새 테스트를 추가해도 스모크가 깨지지 않아야 한다.
- `ready`가 0인 구간에서 명령을 드롭하는 구현은 실패다.

## 하지 않을 것

멀티 채널, 전력 숫자(mW)의 사인오프, 아날로그 마진, JEDEC 호환 선언(1500 명령 코드, PPR 명령 포함), DFI 호환 선언, 로직 스캔 체인과 ATPG, 경계 레지스터(WBR).
