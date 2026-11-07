# DFT / DFD

## 이미 있는 관측점

| 관측 | 위치 | 용도 |
| --- | --- | --- |
| 트레이닝 상태, mission, soft_rst | `CSR_STATUS` | 브링업이 어디서 멈췄는지 |
| 에러 카운트 | `CSR_ERRCNT` | 불일치 누적. 쓰기는 clear |
| 리페어 설정 | `CSR_REMAP` | 웨이퍼 테스트나 레인 BIST가 찾은 배드 핀을 기록하는 자리 |
| 레인 BIST | `CSR_LANE_BIST` | DQ 레인별 에러, 한 레인만 실패했는지, 실패 레인 번호 |
| MBIST | `CSR_MBIST`, `CSR_MBIST_LOG`, `CSR_MBIST_BITS` | 배열 March 시험의 pass, 실패 읽기 수, 첫 실패 주소와 비트, 실패 워드 로그 16개와 넘침 |
| ECC | `CSR_ECC`, `CSR_ECC_CNT`, `CSR_ECC_ADDR` | 정정 · 정정 불가 읽기 수, 첫 오류의 호스트 주소와 syndrome, 디코더 self-test 결과 |
| DFD | `CSR_TRACE`, `CSR_TRACE_DATA`, `CSR_EVCNT0/1`, `CSR_MISR` | CA 핀과 이벤트의 trigger trace, 명령 수, 읽기 데이터 signature |
| Repair | `CSR_BIRA`, `CSR_REPAIR`, `CSR_FUSE` | 수리 가능 여부와 쓴 spare, repair 표 항목, fuse 로드 결과(정정 · 정정 불가 · 버린 항목) |
| CKE | `pin_cke` | RESET과 그 외를 핀에서 구분 |

카운터는 16'hFFFF에서 멈춘다. 고장이 계속될 때 0으로 돌아와 정상처럼 보이지 않게 하기 위해서다.

## 루프백 두 종류

1. `hsl_loopback`은 TX 기어 앞의 병렬 루프백이다. 컨트롤러 클럭에서 BIST를 돌린다. `prbs_en`이면 관측 데이터가 PRBS이고, `loopback`이면 체커가 그 값을 기대한다. 핀에서 되돌린 값은 아직 0에 묶여 있다. 호스트 경로에서는 루프백이 켜진 동안 마지막으로 보낸 쓰기 버스트를 `hsl_phy_top`의 `lb_hold`가 잡고, 다음 RD는 핀에 CA를 내지 않고 그 값을 돌려준다. T8은 채널 모델에 다른 값이 있는 컬럼을 읽고, 핀에 RD가 없는 것까지 확인해 이 경로를 구분한다.
2. 핀 루프백은 직렬화 이후의 경로다. deskew와 스트로브까지 포함한다. E11 다음에 별도 먹스로 둔다. 병렬 루프백 통과를 핀 경로 통과로 말하지 않는다.

## PRBS

다항식은 x^7 + x^6 + 1 이다. 시드 0은 무시하고, 리셋 LFSR은 `7'h5A`다. `parallel_o[0]`이 첫 새 비트다. 시드 0은 LFSR을 0 상태에 묶으므로 받지 않는다. 0과 0을 비교하면 고장이 통과한다.

`parallel_o`는 현재 상태가 만드는 32 bit를 풀어 쓴 XOR 망이다. TX 페이로드로 쓰는 DFT 인스턴스는 `REG_OUT = 1`로 같은 값을 레지스터에서 낸다(상태가 바뀔 때 다음 워드를 미리 계산). 칩 STA에서 XOR 망 → DBI-AC → TX 워드 경로가 800 MHz를 넘었기 때문이다(−0.136 ns). 레인 BIST의 두 인스턴스는 그대로다.

`prbs_en`이면 TX 페이로드가 PRBS다. `loopback`이 0이면 비교 입력을 0으로 두어 `event_err`가 오르고 `ERRCNT`가 증가한다. 핀 루프백은 이 비교에 들어가지 않는다.

비교점은 DBI 앞의 payload다. 루프백이 켜지면 비교 입력이 PRBS 생성기 출력 그 자체라 항상 일치한다. 이 검사가 보는 것은 PRBS, payload 먹스, 비교기, `ERRCNT` 경로다. DBI, 레인 리페어, TX 기어는 이 비교에 들어가지 않는다. 비교 이벤트는 쓰기 데이터가 나가는 클럭(`wrdata_en`)마다 하나다.

## 레인 BIST

`hsl_lane_bist`는 컨트롤러 요청 포트로 한 bank · row의 컬럼 0–15에 쓰기 16개를 넣고, 컨트롤러의 두 큐가 비면(`q_empty`) 같은 16 워드를 읽는다. 쓰는 데이터는 PRBS7 워드(시드 `7'h2D`, 버스트마다 32 bit 전진)이고, 같은 시퀀스를 다시 만들어 읽은 값과 비교한다. 응답은 요청 순서로 오므로 앞의 16개(쓰기 응답)는 세기만 한다. 비트 i, 8+i, 16+i, 24+i 중 하나라도 다르면 DQ 레인 i가 sticky로 표시된다.

- 큐가 빌 때까지 기다리는 이유: 컨트롤러는 쓰기 큐에 남은 주소의 읽기를 큐에서 답한다(forwarding). 그러면 읽기가 링크를 거치지 않아 고장이 보이지 않는다.
- 주소는 CA 핀으로 가므로 DQ 레인 고장이 주소를 바꾸지 않는다. 그래서 컬럼 16개를 써도 에러가 고장 레인에만 남는다(이전 bypass framer는 주소를 DQ로 보내서 한 컬럼만 썼다).
- 뱅크 타이밍, refresh, 버스 전환은 컨트롤러가 지킨다. BIST 동안 칩은 호스트의 `req_ready`와 `rsp_valid`를 0으로 두고 응답을 모두 BIST가 받는다. 시작할 때 호스트는 조용하고 응답을 다 받았어야 하며, 루프백은 꺼져 있어야 한다.
- DBI 핀 고장은 보이지 않는다. DBI를 끄면 송신 쪽은 0을 보내고, stuck-at-1이면 모델이 쓰기 데이터를 반전해 저장하고 읽을 때 다시 반전되어 상쇄된다. DBI와 RED 핀은 경계 스캔 방식의 핀 테스트로 봐야 하는데, 1500 포트에 아직 WBR(경계 레지스터)이 없다.

## MBIST

`hsl_mbist`는 레인 BIST와 같은 테스트 포트로 컨트롤러를 거쳐 DRAM 배열의 한 영역(bank 하나, row 1–16 × 컬럼 1–16)에 March 알고리즘을 돌린다. 배경은 solid다.

| 알고리즘 | 요소 | 워드당 연산 |
| --- | --- | ---: |
| MATS+ | {⇕(w0); ⇑(r0,w1); ⇓(r1,w0)} | 5 |
| March X | {⇕(w0); ⇑(r0,w1); ⇓(r1,w0); ⇕(r0)} | 6 |
| March C- | {⇕(w0); ⇑(r0,w1); ⇑(r1,w0); ⇓(r0,w1); ⇓(r1,w0); ⇕(r0)} | 10 |

고장 모델(채널 모델, 비트 단위, 최대 4개 동시):

| 고장 | 규칙 |
| --- | --- |
| SA | victim 비트가 늘 그 값으로 읽히고 저장된다 |
| TF ↑ / ↓ | victim 비트를 0 → 1(또는 1 → 0)로 바꾸는 쓰기가 먹지 않는다 |
| CFin | aggressor 비트가 정해진 방향으로 바뀌는 쓰기가 victim 비트를 뒤집는다 |
| CFid | 같은 전이가 victim 비트를 정해진 값으로 만든다 |
| CFst | aggressor 비트가 정해진 상태인 동안 victim 비트가 정해진 값으로 읽힌다 |

aggressor와 victim은 다른 워드이고, aggressor가 주소 순서로 victim 앞에 있는 경우와 뒤에 있는 경우를 따로 센다. `tb/march_ref.py`가 같은 규칙의 참조 시뮬레이터로 기대 검출표를 내고, T13이 칩에서 같은 표를 확인한다: MATS+ 13/24, March X 17/24, March C- 24/24. MATS+는 마지막 w0 뒤에 읽기가 없어 TF ↓를 놓친다. CFid · CFst를 두 순서 모두 잡으려면 두 방향 각각에 r0,w1과 r1,w0이 있어야 한다(March C-).

- 연산은 하나씩 낸다. 컨트롤러가 다른 주소의 요청 순서를 바꾸므로, 여러 개를 띄우면 aggressor 쓰기와 victim 읽기의 순서가 알고리즘과 달라진다. 쓰기 뒤에는 `q_empty` + 4클럭을 기다린다. 연산당 약 13.2클럭이다.
- 결과는 실패 읽기 수, 첫 실패 주소 · 비트, 실패 워드 로그(`{row offset, col}` 16개, 넘침 비트)다. 리페어 단계(BIRA)가 이 로그로 spare row · col을 고른다.
- 링크 고장도 MBIST에 실패로 보인다(DQ 핀 stuck-at-1이면 모든 r0 실패). 배열 시험 전에 레인 BIST로 링크를 먼저 확인해야 배열 고장과 구분된다.
- 다루지 않는 것: 워드 안 비트 사이 coupling, 이웃 패턴 고장, 데이터 보존, 주소 디코더 고장의 분리 진단. checkerboard 배경, 보존 대기 요소, 더 긴 알고리즘(March SS 등)이 필요하다.

## Repair

배열에 spare row 2개와 spare column 2개(col은 16-row 블록 하나에 걸림)가 있다고 두고, base die가 분석 · 기록 · 로드를 맡는다.

- **BIRA** (`hsl_bira`): MBIST 실패 워드 로그로 spare를 고른다. 로그가 넘쳤으면 수리 불가. must-repair(덮이지 않은 실패가 남은 spare col보다 많은 row는 반드시 spare row, 반대도 같음)를 바뀌는 것이 없을 때까지 반복한 뒤, 남은 spare의 순서(최대 16가지)를 차례로 시도한다. 모든 해가 어떤 순서에 해당하므로 해가 있으면 찾는다. greedy 한 번으로는 2 + 2 spare, 5워드 맵에서 63.1%만 고쳤고 순서 탐색은 73.2%(= exhaustive)다(`tb/bira_ref.py`).
- **soft repair**: BIRA 결과를 repair 표(spare마다 16 bit)에 넣으면 배열이 그 row · col 접근을 spare로 보낸다. 재시험으로 확인한다.
- **hard repair**: 표를 fuse 워드(SECDED (39,32))로 굽고, 리셋이 풀릴 때마다 디코더로 읽어 표를 채운다. 1 bit 오류는 정정, 2 bit 오류는 그 항목을 버리고 표시한다. 굽지 않은 fuse는 빈 표다.
- **다루지 않는 것**: subarray별 spare, 비트 단위 fail bitmap, spare 자체의 고장(spare를 쓰기 전에 시험), JEDEC PPR 명령 순서, fuse 프로그램 조건과 읽기 마진.

## ECC 시험

- **디코더 self-test**: `CSR_ECC[2]`. 고정 워드의 깨끗한 codeword, 1 bit 오류 39개, 이웃 2 bit 오류 38개를 데이터 경로 디코더에 넣어 정정 데이터와 ce · ue를 확인한다. 정정 플래그를 0에 묶은 디코더는 39개 실패로 잡힌다(T15). 공개된 decoder BIST 방식(알려진 오류 패턴을 주입해 디코더 출력을 확인)을 따랐다.
- **오류 주입**: `CSR_ECC_INJ`(데이터)와 `CSR_ECC[14:8]`(검사 비트) 마스크를 다음 쓰기 버스트 하나에 건다. 저장된 값이 틀리므로 읽기 경로(핀, FIFO, 디코더, 로그)를 끝까지 시험한다.
- **배열 시험과의 관계**: MBIST와 repair는 ECC를 끈 상태에서 돌린다. 켜면 1 bit 배열 고장이 정정되어 보이지 않는다(T15의 stuck bit).

## DFD

- **trace buffer**: CA 핀 명령과 이벤트를 16항목 ring에 쓰고, 고른 trigger에서 표시한 뒤 정한 수만큼 더 쓰고 멈춘다. trigger 앞 칸이 다 찬 뒤에만 trigger를 받아 앞뒤 맥락이 항상 남는다. bank 필터로 한 bank의 명령만 남겨 깊이 16을 아낀다.
- **카운터 · MISR**: 핀의 ACT · RD · WR · REFpb 수와 읽기 데이터 signature. 긴 시험을 값 몇 개로 비교한다(MISR은 기대 signature를 같은 함수로 계산해 비교).
- **디버그 사례**(README DFD 절, T16): 채널 모델에 심은 refresh 간섭 버그를 ECC 정정 오류 → 첫 오류 주소 → 재현 좁히기 → bank 필터 trace로 찾았다. trace에 REFpb → ACT → RD → 정정 오류가 매번 같은 간격으로 찍혔다.

## IEEE 1500 방식 포트

- 시험 장비는 1500 직렬 포트 하나로 모든 시험 기능에 닿는다: WIR = CSR로 두고 41 bit WDR `{write, addr, data}`로 CSR을 읽고 쓴다(읽기는 scan 두 번). ID 레지스터는 칩 확인용이다.
- WRCK는 clk로 오버샘플한다(clk의 1/8 이하). WIR · WDR 구조와 Capture / Shift / Update 순서는 1500을 따르고, 명령 코드는 이 설계의 것이다.
- T17이 MBIST를 이 포트만으로 실행하고 결과를 읽는다. 시험 순서의 모든 단계가 같은 방식으로 1500 포트에서 돈다.

## 스캔

- 상태 소자는 플롭만 쓴다.
- 제어 상태(FSM, 포인터, 카운터)에는 리셋이 없는 플롭을 두지 않는다.
- 리셋이 없는 플롭은 큐와 FIFO의 데이터 배열뿐이다. 별도 `always_ff`에 두고, 유효성은 리셋되는 포인터가 정한다.
- 스캔 체인 삽입은 합성 툴 몫이다. v0.1 filelist에 스캔 랩퍼는 없다.

## 테스트가 이 설계에 쓰는 순서

1. 리셋 해제 후 ID를 읽어 접근을 확인한다.
2. 병렬 루프백과 PRBS로 디지털 데이터패스를 본다.
3. `CSR_LANE_BIST`로 레인 BIST를 돌린다. 한 레인만 실패했으면 그 번호를 `CSR_REMAP`에 쓰고 DRAM 쪽에도 같은 설정을 한 뒤 다시 돌려 PASS를 확인한다.
4. 그다음 채널 트레이닝을 진행한다.
5. 링크가 통과한 뒤 `CSR_MBIST`로 배열 영역마다 March C-를 돌리고, 실패하면 `CSR_MBIST_LOG`로 실패 워드를 읽는다.
6. `CSR_BIRA` start로 spare를 고르고, 수리 가능하면 apply로 표에 넣은 뒤 같은 March C-로 재시험한다.
7. 재시험이 통과하면 `CSR_FUSE` program으로 fuse에 굽고, 리셋 뒤 `CSR_FUSE`에서 로드 결과(정정 · 버린 항목 0)와 재시험 PASS를 확인한다.
8. ECC 디코더 self-test를 돌리고, 오류 주입(1 bit · 2 bit)으로 카운터와 로그를 확인한 뒤 ECC를 켠다.

2번은 T8, 3번은 T10, 5번은 T13, 6–7번은 T14, 8번은 T15가 본다. 4번의 아날로그 완료는 TRAIN done 펄스로 테스트가 대신한다.
