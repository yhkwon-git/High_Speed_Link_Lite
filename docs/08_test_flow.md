# 시험 흐름

이 칩의 시험 기능(PRBS · 루프백, 레인 BIST · 리페어, 읽기 레벨링, MBIST, BIRA · fuse, ECC, DFD)을 웨이퍼 · 패키지 시험 한 번의 순서로 묶는다. 시험 장비는 IEEE 1500 방식 포트 하나로 모든 단계를 돈다. WIR = CSR로 두고 41 bit WDR로 CSR을 읽고 쓴다. 각 단계는 회귀의 테스트 하나가 같은 CSR 순서로 확인한다.

## 순서

| # | 단계 | 하는 일 (CSR) | 합격 조건 | 실패하면 | 확인 |
| ---: | --- | --- | --- | --- | --- |
| 0 | 전원 · 리셋 | 리셋이 풀리면 fuse 워드 4개가 SECDED 디코더를 지나 repair 표로 자동 로드된다 | `FUSE`: 로드 끝, 정정 불가 0 | 정정 불가가 있으면 그 항목은 버려진다 → fuse bin | T14 B · C |
| 1 | 접근 | 1500 ID 레지스터, `ID` · `VERSION` CSR | `HSL1`, `0x400` | 접근 불가 bin | T17, SMOKE |
| 2 | PRBS 비교 회로 | `CTRL`의 `prbs_en` · `loopback`: 루프백이면 비교가 맞고, 끄면 `ERRCNT`가 오름 | 두 경우 모두 기대대로 | 로직 bin | T8 |
| 3 | 링크 핀 | `LANE_BIST`로 DQ 레인 검사. 한 레인만 실패하면 `REMAP`과 DRAM 쪽 설정 후 재검사 | 재검사 PASS | 두 레인 이상 → 링크 bin | T10 |
| 4 | 읽기 레벨링 | `RDTRAIN`: 레인별 지연선 코드 스윕, eye 중앙 | 모든 레인 eye 폭 2 코드 이상 | eye 없음 → 링크 bin | T11 |
| 5 | ECC 디코더 | `ECC[2]` self-test, 1 bit · 2 bit 주입으로 카운터와 로그 확인 | self-test 78개 PASS, 정정 · 정정 불가가 주입대로 | 로직 bin | T15 |
| 6 | 배열 | ECC 끈 상태에서 블록(bank 하나, 16 row × 16 col)마다 `MBIST` March C- | 실패 읽기 0 → 9로 | 실패 → 7 | T13 |
| 7 | 수리 | `BIRA` start → 수리 가능하면 apply → 같은 March C-로 재시험 → `FUSE` program | 재시험 PASS | 수리 불가(넘친 로그, spare 부족) → 배열 bin | T14 A · D · E · F |
| 8 | hard repair 확인 | 칩 리셋 → fuse 로드 결과 → 재시험 | 로드 끝, 정정 · 버린 항목 0, 재시험 PASS | fuse bin | T14 B |
| 9 | mission | ECC on, 호스트 트래픽, `EVCNT` · `MISR`로 결과를 값 몇 개로 비교 | 기대 signature, 정정 불가 0 | 9 실패는 FA로 | T12, T16 A |

- 2가 보는 범위: PRBS 생성기, payload 먹스, 비교기, `ERRCNT`다. 병렬 루프백은 DBI 앞에서 되돌리므로 DBI, 레인 shift, TX 기어, 핀은 이 비교에 들어가지 않는다. 그 경로와 핀은 3의 레인 BIST가 채널 모델까지 돌아 확인한다.
- 6에서 ECC를 끄는 이유: 켜면 1 bit 배열 고장이 정정되어 보이지 않는다(T15의 stuck bit). 배열 시험은 원시 데이터로 한다.
- 3이 6보다 먼저인 이유: 링크 고장도 MBIST에 실패로 보인다(DQ 핀 stuck-at-1이면 모든 r0 실패, T13). 링크를 먼저 고쳐야 배열 고장과 구분된다.
- 7의 BIRA는 MBIST 실패 워드 로그(16개)를 읽는다. 한 블록에 실패 워드가 16개를 넘으면 수리 불가로 본다.

## 분류 (bin)

| bin | 조건 |
| --- | --- |
| Pass | 0–9 모두 통과, repair 표 비어 있음 |
| Pass, repaired | 7에서 spare를 써서 통과, 8에서 fuse로 확인 |
| Fail: 접근 · 로직 | 1, 2, 5 실패 |
| Fail: 링크 | 3에서 두 레인 이상, 또는 4에서 eye 없음 |
| Fail: 배열 | 7에서 수리 불가 |
| Fail: fuse | 0 또는 8에서 정정 불가 워드, 또는 로드 뒤 재시험 실패 |

## 실패 분석

- 9에서 정정 오류가 늘면 `ECC_ADDR`가 첫 오류의 호스트 주소를, `ECC[14:8]`가 syndrome을 준다.
- trace(`TRACE`)를 정정 오류 trigger와 그 bank의 필터로 걸면 오류 직전의 명령 순서를 잡는다. T16은 채널 모델에 심은 refresh 간섭을 이렇게 찾았다(REFpb → ACT +8 → RD +11 → 정정 오류 +8, 세 번 모두 같음).
- 6의 MBIST는 첫 실패의 주소와 비트(`MBIST_LOG`, `MBIST_BITS`)를 남겨 비트 단위 위치를 준다.

## 시험 시간

측정치는 commit `ffc073d`(T13, March C- 64워드 640연산 8,443클럭 → 연산당 13.2클럭)에서 나왔다. 나머지는 그 비율로 계산한 추정이다.

| 항목 | 값 |
| --- | --- |
| March C- 한 블록(256워드 × 10연산) | 약 33,800클럭 = 42 µs(800 MHz) |
| 칩 전체 배열(4 bank × 256 row × 16 col) | 약 2.16M클럭 = 2.7 ms |
| 1500 포트 CSR 쓰기 · 읽기 | scan 43 · 86 WRCK. WRCK = clk / 8(100 MHz)이면 0.43 · 0.86 µs |

MBIST가 연산을 하나씩 내므로 배열 시험이 시간 대부분이다. 컨트롤러가 다른 주소의 순서를 바꾸지 않는 경로(배열 쪽 BIST 엔진, 실제 HBM에서는 core die)가 있으면 연산을 연속으로 낼 수 있다.

## 이 흐름 밖

- 로직 스캔(ATPG): 플롭만 쓰고 제어 상태는 모두 리셋되지만(`docs/06_dft_plan.md`), 스캔 체인과 패턴은 넣지 않았다.
- 핀 하나하나의 시험(WBR, EXTEST)과 DBI · RED 핀 고장: 1500 포트에 경계 레지스터가 없다.
- 아날로그(ZQ, VREF, 드라이버 · 샘플러), TSV, 보존(retention) · 스트레스 시험, at-speed I/O 특성: 디지털 경계 밖이다.
