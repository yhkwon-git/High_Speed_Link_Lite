# 검증 계획

## 계층

| 계층 | 담당 | 상태 |
| --- | --- | --- |
| 칩 | 호스트 요청 포트와 CSR로 칩 전체를 몰고, 응답을 스코어보드로 확인 | `tb/tb_hsl_smoke.sv` |
| 채널 | 핀 너머의 DRAM: 데이터 저장, DBI · 리페어 · eye 모델, 배열 고장(SA · TF · CFin · CFid · CFst, 16개), spare row · col 저장소(repair 표가 가리키는 접근), ECC 핀 8 bit를 워드 옆에 저장(고장 없음), 핀에서 프로토콜과 같은 뱅크 타이밍 검사 | `tb/models/dram_channel_behav.sv` |
| 블록 | 레인 shift, deskew, PRBS, TX 기어, FIFO, DBI | `tb/tb_hsl_blocks.sv` |

컨트롤러(`rtl/mc/`)의 단독 검증(랜덤 회귀, bind 타이밍 체커, 기능 커버리지)은 Mini DRAM Controller 저장소에 있다. 여기서는 칩 안에서 그 경계와 동작을 본다.

## 스코어보드와 채널 모델 검사

- **스코어보드**: 요청이 받아들여지는 엣지에서 그 요청의 응답이 가져야 할 값을 기록한다. 읽기는 그보다 먼저 받아들여진 호스트 쓰기가 남긴 참조 메모리 값을 기대한다. 응답은 요청 순서로 오므로 FIFO로 맞춘다. PRBS 페이로드, 루프백, 한쪽만 리페어한 쓰기처럼 DRAM에 다른 값이 남는 경우에는 `sb_on` = 0으로 그 주소를 "모름"으로 표시하고 비교하지 않는다. 레인 BIST가 쓰는 bank 1 · row `55`와 T13의 MBIST가 쓰는 bank 2 · row `C0`–`C3`, `C8`은 호스트 테스트가 읽지 않는다. 테스트 엔진이 도는 동안 호스트 포트는 닫혀 있어 스코어보드에 요청이 없다.
- **채널 모델 검사**: 프로토콜(열린 뱅크에 ACT, 닫힌 뱅크에 RD/WR, 열린 뱅크에 REF/REFpb, 다른 버스의 명령, WR 없이 온 쓰기 버스트, 큐 넘침), 같은 뱅크 타이밍(tRCD, tRP, tRAS, tRC, tRTP, 쓰기 회복 WL + 1 + tWR, tRFCpb, tRFC), 쓰기 데이터가 닿기 전에 같은 주소를 읽는 RD, WDQS 패턴을 센다. 회귀 끝의 `[CH]` 줄이 모두 0이어야 한다(T13–T17 포함). T12는 그때까지를 따로 본다(`5a24f07` 전에는 T12만 봤다). auto-precharge는 PRE가 합법이 되는 첫 엣지에 닫힌 것으로 계산한다. bank group 사이 규칙(tCCD, tRRD, tFAW, tWTR, tRTW)은 컨트롤러 저장소의 체커가 맡는다.
- **검사가 살아 있는지**: 모델의 tRCD를 일부러 1 늘리면 1,162건이 잡히고 T12가 실패한다(`0193c04`).

## 스모크가 보는 것

1. ID, VERSION, TIMING0/1 값. TIMING은 쓰기를 무시함
2. 미정의 주소 `0x3C`는 0
3. 리셋 해제 직후 상태는 RESET, CKE는 0, `req_ready`는 0, CK와 TX beat 유효는 0, 응답은 없음
4. `train_bypass` 후 상태는 MISSION, CKE는 1. PHY가 꺼져 있으면 `req_ready`는 0이고 CK도 0. CTRL bit 5(예약)는 0으로 읽힘
5. `phy_en`을 켜면 `req_ready`는 1. 응답을 막으면(`rsp_ready` = 0) 요청 15개에서 `req_ready`가 0이 되고, 풀면 응답 15개가 모두 나옴
6. `soft_rst` 동안 상태는 RESET, CKE는 0, `req_ready`는 0, STATUS에 soft_rst가 보임
7. soft_rst만 지우면 bypass가 남아 있어 MISSION으로 돌아옴. PHY를 다시 켜면 포트가 열림

## 칩 테스트

| ID | 내용 |
| --- | --- |
| T1 | `train_start`로 상태가 순서대로 걷고, ZQ/WRLVL/RDLVL/DESKEW는 각자의 done 펄스 전에는 다음 상태로 가지 않음 |
| T2 | bank 1의 두 row에 쓰고(연달아) 다시 읽을 때(연달아), 핀의 ACT → WR, WR → PRE, PRE → ACT, ACT → ACT, ACT → RD, RD → PRE 간격이 규칙 이상이고 읽은 값이 맞음. idle 4 × tREFI 동안 bank마다 REFpb 3–5번이고 열 명령은 없음 |
| T3 | 4 bank × 4 row × 16 col을 채운 뒤 요청 2,000개(읽기 · 쓰기 반반, 임의 idle, 응답은 네 클럭 중 세 클럭만 받음). 읽기를 모두 비교해 불일치 0. row hit 비율, forwarding 수, DFI 데이터 버스 사용률을 출력 |
| T4 | 쓰기는 다음 클럭에 응답. 바로 뒤 같은 주소 읽기는 핀에 RD 없이 `32'hA5A5_5A5A`. 쓰기가 나간 뒤의 읽기는 RD 하나로 같은 값 |
| T5 | DBI-DC 핀 값: 1이 5개인 beat(`1F`)는 `E0` + DBI 1, 4개인 beat(`0F`)는 그대로 |
| T6 | 두 클럭으로 나눈 FIFO가 버스트를 유지 (블록) |
| T7 | shift 리페어 핀 값(lane 3 → `1F7`, lane 8 → DBI가 RED로 `200`, lane 15 → 그대로), 블록은 모든 설정에서 참조 모델 일치와 건너뛴 핀의 고장 무시 |
| T8 | PRBS 비교는 루프백이면 `ERRCNT` 0, 아니면 증가. 루프백 RD가 핀에 RD를 내지 않고, 채널 모델 값(`32'h1111_1111`)이 아니라 마지막 쓰기 버스트(`32'h2222_2222`)를 돌려줌 |
| T9 | DBI-AC: 블록은 직렬 참조 모델 · 두 AC 구조 등가 · 랜덤 스트림 전이 수 기대값, 칩은 AC 핀 값, bank group 두 개를 번갈아 이어지는 PRBS7 · 55/AA 쓰기 254개의 off / DC / AC 전이 수와 규칙 위반 0, DBI가 붙은 읽기 데이터 복원 |
| T10 | 링크 핀 stuck-at → 레인 BIST가 그 레인만 표시 → REMAP · 모델 설정 → 재검사 PASS(8레인 × 0/1), 리페어된 링크로 DBI-AC 트래픽 일치, 두 레인 고장은 수리 불가 표시 |
| T11 | 레인별 eye(고정 · 랜덤)에 대해 읽기 레벨링: eye 시작 · 폭과 중앙 코드 정확, 학습 전 BIST는 eye가 16을 벗어난 레인만 실패, 학습 후 BIST · 트래픽 통과, 닫힌 eye는 실패 표시 |
| T12 | 이전 in-order MC로 쟀던 WR 16 + RD 16(사이클 출력), 열린 row 읽기 하나의 지연과 그 안의 핀 RD → `rddata_valid`, bank group 두 개에 걸친 읽기 32개, DBI-AC 양방향 + lane 5 stuck-at-1 리페어 트래픽, 채널 모델 오류 0. RDQS 쪽 리셋(`u_rst_rdqs`)이 PHY off 동안 0, mission 뒤 1 |
| T13 | MBIST. 고장 없이 세 알고리즘 PASS(연산 수와 클럭 출력). 배열 고장 24개(SA 2, TF 2, CFin 4, CFid 8, CFst 8; victim 워드 2 · 5의 bit 3, aggressor bit 7) × MATS+ · March X · March C-: 고장마다 검출 여부가 `tb/march_ref.py`의 기대값(13 · 17 · 24)과 같고, 검출되면 첫 실패 주소가 victim 워드, 다른 비트가 bit 3. 4 × 16 영역의 고장 워드 3개가 처음 실패한 순서로 로그에 남고 실패 읽기 7개. DQ 핀 stuck-at-1에서 실패 읽기 192개, 로그 16개와 넘침. 한 엔진이 도는 동안 다른 엔진의 start가 기다렸다가 돌고(두 순서) 둘이 함께 busy인 클럭 0. 요청 포트가 닫힌 채(MISSION, PHY off) 레인 BIST · MBIST · 읽기 레벨링 start: 셋 다 요청 없이(MBIST 실행 클럭 0) done · refused · pass 0, BIRA는 수리 불가. 다른 엔진 뒤에서 기다리는 start는 busy · 대기 비트로 읽힘(두 순서), DQ 핀 실행 뒤 통과한 MBIST는 MBIST_BITS · 첫 실패 주소가 0, 거절된 읽기 레벨링은 lane 0의 코드 · eye 시작 · 폭이 거절 전과 같음 |
| T14 | Repair. A: 고장 워드 8개에서 BIRA 할당(row +1 · +6, col 5)과 표 값, soft repair 뒤 재시험 PASS와 spare 접근 수. B: fuse 프로그램 → 표 비움 → 칩 리셋 → fuse 로드가 표를 되살림, 재시험 PASS. C: fuse 워드 1 bit 반전 정정 · 2 bit 반전 항목 버림, 버린 col의 워드가 다시 실패. D: 대각선 5워드와 넘친 로그는 수리 불가. E: greedy로 못 고치는 맵을 고침. F: 랜덤 맵 12개(3–8워드)에서 BIRA 상태와 표가 TB 참조와 같고, 수리 가능하면 재시험 PASS |
| T15 | ECC. 디코더 self-test PASS와, 정정 플래그를 0으로 강제한 디코더에서 FAIL(39개). ECC on: 깨끗한 16워드 오류 0. 주입한 데이터 1 bit · 검사 비트 1 bit는 정정, 첫 오류의 호스트 주소와 syndrome이 기대값. 2 bit는 정정 불가로 세고 데이터는 그대로. 배열 SA0 1 bit는 정정. ECC off에서 같은 워드는 원래 값, 셈 없음. clear 뒤 카운터 · 로그 0 |
| T16 | DFD. 명령 카운터가 채널 모델의 수와 같음(REFpb는 읽는 순간 차이로 ±1), MISR이 TB 참조 함수와 같음. 수동 trigger: trigger 표시 하나, 그 뒤 3항목, 멈춤, timestamp 순서. 나머지 trigger 원천: bank 명령(bank 2), MBIST 실패(DQ5 stuck), PRBS 오류(PRBS를 켠 레인 BIST), ECC 정정 불가(2 bit 주입)가 각각 그 이벤트 항목에 trigger 표시와 멈춤. MBIST 재시작, ERRCNT clear, ECC clear는 trigger 없음. 디버그 사례: 채널 모델의 `bug_refdis`(REFpb 뒤 16클럭 안의 RD에서 bit 5 반전)를 켜고 ECC 정정 오류로 증상 확인 → 첫 오류 주소의 bank만 읽으며 trace(정정 오류 trigger, bank 필터) 3번 → 매번 REFpb 뒤 16클럭 안에 RD가 있는지 TB가 trace를 해석해 확인 → 버그를 끄면 오류 0 |
| T17 | 1500 포트. WRSTN 리셋 뒤 WIR=ID에서 32 bit가 `HSL_ID`, WIR capture가 현재 명령, WBY가 8 bit 패턴을 한 비트 늦춤, CSR WDR로 ID CSR 읽기(scan 두 번), MBIST March C-를 CSR WDR 쓰기로 시작하고 같은 WDR 읽기로 done까지 폴링, 결과가 호스트 CSR 읽기와 같음. WRCK 20 ns |

블록 테스트 E7(TX 기어), E9(deskew), E11(PRBS seed)은 `tb_hsl_blocks`가 같은 실행 안에서 돈다. 이전 in-order 컨트롤러의 블록 테스트(T2 뱅크 FSM, T3 스케줄러)는 컨트롤러 교체와 함께 지웠고, 번호는 칩 테스트가 이어받았다.

T16의 버그는 채널 모델에 심은 것이다(`bug_refdis`, 기본 꺼짐). 디버그 절차는 칩의 CSR(ECC 카운터 · 주소, trace)만 쓰고, TB는 마지막 확인에서만 버그 스위치를 끈다. T15의 디코더 고장은 `force`로 디코더의 정정 플래그를 0에 묶어 만든다(Verilator와 ModelSim 모두 지원). T14의 fuse는 테스트벤치의 OTP 배열(워드 4개, 비트는 0 → 1만, 칩 리셋에도 값 유지)이다. BIRA의 기대값은 같은 규칙을 SV로 다시 짠 `bira_ref` 태스크에서, 수리율 표는 `tb/bira_ref.py`(greedy, spare 순서 탐색, exhaustive 비교)에서 나온다.

T13의 고장은 테스트벤치가 채널 모델의 `flt_*` 표에 계층 참조로 넣고, 매 실행 전에 그 영역을 0으로 지운다(참조 시뮬레이터가 0에서 시작하므로). 기대 검출표는 같은 고장 규칙을 Python으로 다시 짠 참조에서 나온다. RTL이 아니라 모델 규칙에 대한 기대값이라, 모델 규칙이 틀리면 둘이 같이 틀릴 수 있다. 그래서 모델 규칙은 March 문헌의 고장 정의(전이에 걸리는 CFin · CFid, 상태에 걸리는 CFst)를 따라 모델 머리 주석과 참조 docstring 두 곳에 같은 규칙으로 적었다.

## 통과 규칙

- 기대와 다르면 해당 테스트 이름과 불일치 내용(`[SB] read ...`, `[DRAM] cycle ...: tRCD ...`, `[T2] ...` 등)이 보이고, 마지막 `[ALL] FAIL (n)`과 함께 프로세스가 0이 아닌 코드로 끝난다.
- 블록 검사의 PASS/FAIL은 그 검사 안에서 생긴 실패만 본다. 앞 검사가 실패해도 뒤 검사의 PASS가 가려지지 않는다.
- 타임아웃은 실패다.
- X를 데이터로 샘플하지 않는다. 구동하지 않는 beat는 0이다.
- 비교는 `!==`/`===`로 한다. X나 Z가 나오면 통과가 아니라 실패다.
- 리셋은 클럭 negedge에서 푼다. posedge와 같은 시각에 풀면 첫 싱크러나이저 플롭과 레이스가 생긴다.
- 요청은 negedge에서 내고 1 ps 뒤 `req_ready`를 본다. `req_ready`는 posedge에서만 바뀌므로 그 값이 다음 posedge의 수락 여부다.
- CSR 읽기는 negedge에 주소를 내고 다음 posedge 뒤에 `cfg_rdata`를 읽는다(읽기 데이터 레지스터).
