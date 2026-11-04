# 요구 스펙

v0.1 스터디 스펙이다. 고객 요구를 설계자가 받아 적는 형식으로 두었다. 숫자 변경은 이 문서를 먼저 고치고, 그다음 `hsl_pkg`를 고친다.

## 대상

Base die 디지털 한 슬라이스. 호스트에서 본 제어 버스와 명령 버스, 채널 쪽에서 본 핀을 가진다. DRAM 코어와 아날로그 PHY는 경계 밖의 모델이다.

## 기능

1. 리셋 해제 후 트레이닝 시퀀스를 끝내기 전에는 호스트 명령을 받지 않는다.
2. 트레이닝 순서는 RESET, CKE, MRS, ZQ 대기, write leveling, read leveling, deskew, write training, MISSION이다.
3. MISSION 이후 ACT, PRE, RD, WR, REF를 받는다. NOP, PREA, REFA, MRS, PDE, PDX 인코딩은 예약해 둔다.
4. RD 응답은 버스트 하나다. 응답이 준비되기 전에는 `rsp_valid`가 0이다.
5. 루프백 모드에서는 DRAM 대신 TX 쪽 버스트를 RX로 되돌릴 수 있어야 한다.
6. 레인 리페어 레지스터로 DQ 하나를 리던던트 핀에 바꿀 수 있어야 한다.
7. 호스트는 ID, 버전, 트레이닝 상태, 에러 카운트를 읽을 수 있어야 한다.

E2 이후 구현은 1–7을 스터디 범위 안에서 만족한다. 5번은 병렬 루프백이다. 루프백이 켜진 동안 마지막으로 보낸 WR 버스트를 다음 RD가 핀을 보지 않고 돌려준다. ZQ, write leveling, read leveling, deskew는 done 펄스가 오기 전에는 그 상태에 머문다. REF는 인코딩만 있고 스케줄러가 발행하지 않는다. 큐에 넣으면 head를 막으므로 v0.1 호스트는 REF를 보내지 않는다.

## 스터디 파라미터

| 항목 | 값 | 비고 |
| --- | --- | --- |
| DQ | 8 | HBM 채널 폭이 아니다 |
| DBI | 1 | 비트는 버스트의 beat마다 하나 |
| 리던던트 DQ | 1 | 디지털 먹스만 |
| 버스트 | 4 | beat 0이 첫 UI |
| 뱅크 | 4 | |
| Row / Col | 8 / 4 bit | 주소 공간은 모델용 |
| 컨트롤러가 보는 데이터 | 32 bit | `DQ_W * BL` |
| 목표 데이터율 | 3.2 Gb/s per DQ | CK 1.6 GHz, 컨트롤러 800 MHz |
| 시뮬 / SDC 클럭 | 컨트롤러 1.25 ns, PHY 0.625 ns | `CTRL_PERIOD_PS`, `PHY_PERIOD_PS`. 표는 `docs/e12_clocks.md` |

목표 데이터율의 raw 대역은 `8 * 3.2 Gb/s = 25.6 Gb/s = 3.2 GB/s`다. 리프레시, 커맨드 간격, 트레이닝을 빼기 전의 숫자다.

## 타이밍 기본값

컨트롤러 클럭 단위다.

| 파라미터 | 클럭 | 소유 블록 |
| --- | --- | --- |
| tRCD | 4 | bank FSM |
| tRP | 4 | bank FSM |
| tRAS | 10 | bank FSM |
| tRTP | 3 | bank FSM |
| tWR | 4 | bank FSM |
| tCCD | 2 | scheduler |
| tWTR | 4 | scheduler |
| tRFC | 20 | scheduler 또는 refresh 블록 |

tRC는 저장하지 않고 tRAS + tRP로 본다. 레지스터 리셋값은 `TIMING0_DEFAULT`, `TIMING1_DEFAULT`다.

## 전력과 신뢰성

- CKE가 0이면 채널 클럭 쪽 활동이 없는 것으로 본다. v0.1은 FSM이 RESET일 때만 CKE가 0이다.
- DBI는 beat의 1 개수가 `DQ_W/2`보다 크면 반전한다. 전제: high가 터미네이션 전류를 쓴다. 이 극성은 스터디 규칙이다.
- 드라이버 enable은 버스트 구간 밖에서 0이다.
- 배드 레인 1개를 리던던트 핀으로 치환한다.
- 에러 카운터는 16비트에서 포화하고, 랩어라운드하지 않는다.

## 수락 조건

- 스모크 테스트가 `[SMOKE] PASS`다.
- 이후 실습은 새 테스트를 추가해도 스모크가 깨지지 않아야 한다.
- `ready`가 0인 구간에서 명령을 드롭하는 구현은 실패다.

## 하지 않을 것

멀티 채널, 전력 숫자(mW)의 사인오프, 아날로그 마진, JEDEC 호환 선언, DFI 호환 선언.
