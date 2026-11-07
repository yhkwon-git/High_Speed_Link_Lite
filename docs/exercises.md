# 실습

E0부터 E12까지 구현되어 있다. 각 실습은 자기 테스트가 `[SMOKE] PASS`와 함께 통과해야 끝이다. 스모크가 깨지면 그 실습의 완료로 보지 않는다. 회귀는 `sim/run_smoke.ps1` 한 번이고, T1–T8과 블록 검사가 같은 프로세스에서 돈다. E0/E1 설명은 `docs/e0_e1_notes.md`, E12 대조표는 `docs/e12_clocks.md`다.

포트 목록은 유지한다. 폭을 바꿔야 하면 `docs/01_requirements.md`와 `hsl_pkg`를 먼저 고친다.

## E0. 스모크와 계층

`sim/run_smoke.ps1`을 실행한다. `rtl/top/hsl_base_die_lite.sv`를 따라가며 인스턴스 트리를 종이로 그린다. `cmd_ready`가 MISSION에서도 0인 이유를 `hsl_cmd_queue`의 `push_ready`까지 따라간다.

완료: `[SMOKE] PASS`. 그리고 큐가 ready를 0으로 두는 문장을 가리킬 수 있다.

## E1. 리셋

`hsl_rst_sync`의 해제 타이밍을 파형으로 설명한다. CSR이 `soft_rst`의 리셋 도메인 밖에 있는 이유를 말로 적는다. 구현 변경은 필요 없다. 설명은 `docs/05_pd_guide.md`의 리셋 절과 모순이 없어야 한다.

## E2. 트레이닝 done

`train_wait` 카운터 대신 ZQ, write level, read level, deskew의 done 입력을 둔다. done이 오기 전에는 상태에 머문다. T1을 추가한다. bypass 동작과 스모크는 유지한다.

## E3. 커맨드 큐

깊이 4 링 버퍼. `push_ready`는 빈 슬롯이 있을 때 1이다. head는 `pop_valid` 동안 유지된다. 스모크의 "`cmd_ready`는 항상 0"은 "리셋 직후와 큐가 가득 찼을 때는 0"으로 바꾼다. 바꾸는 이유를 테스트 주석에 한 줄 남긴다.

## E4. 뱅크 FSM과 in-order 스케줄러

`docs/03_microarchitecture.md`의 상태와 소유 타이밍을 구현한다. 스케줄러는 head만 발행하고, head 뱅크의 `timing_ok`가 0이면 `req_ready`를 0으로 둔다. T2와 T3를 추가한다.

## E5. DRAM 모델과 첫 트래픽

`tb/models/dram_channel_behav.sv`가 ACT, WR, RD, PRE를 저장한다. `CTRL.phy_bypass`가 1일 때만 PHY 핀 타이밍을 건너뛰고 이 모델과 버스트를 주고받는다. 정상 경로의 기어박스는 아직 건드리지 않는다. T4를 추가한다.

## E6. DBI-DC

`hsl_dbi`에 스펙의 popcount 규칙을 넣는다. `dbi_en`이 0이면 입력을 그대로 통과시키고 플래그는 0이다. T5는 beat 하나에 1이 5개 이상일 때 플래그와 반전을 본다.

## E7. 기어박스

`beats_per_burst = 2`, PHY beat 16비트. `clk_phy`를 컨트롤러 클럭의 2배로 올리고, 한 버스트를 두 beat로 내보낸다. 처음에는 토글 핸드셰이크 기어박스였고, mission 경로를 붙이며 매 클럭 한 워드를 내는 동기 기어(`hsl_tx_gear`)로 바꿨다. 시뮬 클럭과 SDC 주기를 `docs/02_architecture.md`의 식에 맞게 다시 적는다. 숫자를 문서 없이 RTL에만 넣지 않는다.

## E8. 비동기 FIFO

그레이 포인터와 2플롭 싱크러나이저. 그레이 값은 자기 도메인의 플롭에서 나가게 한다. `SAME_CLOCK`을 0으로 둔 시뮬레이션이 버스트를 유지해야 한다. SDC에는 출발 그레이 플롭에서 첫 싱크 플롭까지 `set_max_delay`를 넣고, 포인터 false path는 넣지 않는다.

## E9. Deskew

레인마다 0에서 N단 시프트. N을 고르면 `docs/05_pd_guide.md`에 허용 스큐를 UI로 적는다.

## E10. 레인 리페어

처음에는 `repair_en`일 때 `DQ[repair_lane]`만 `red_in`으로 바꾸는 치환 방식이었다. 지금은 `hsl_lane_shift`가 고장 핀부터 레인을 한 칸씩 RED 쪽으로 민다(핀마다 2:1 mux). T7이 핀 값을, T10이 레인 BIST로 검출 → 재매핑 → 재검사를 본다.

## E11. PRBS 루프백

x^7 + x^6 + 1 을 구현한다. 시드 0은 무시한다. 병렬 루프백에서 비교가 틀리면 `hsl_err_cnt`가 증가한다. 루프백 중 보낸 WR 버스트를 다음 RD가 돌려주는지도 본다. 핀 루프백은 이 실습에 포함하지 않는다. T8을 추가한다.

## E12. 제약 정리

E7과 E8의 클럭이 문서, RTL, SDC에서 같은 주기와 같은 관계를 가리키는지 표를 만든다. 하나라도 다르면 E12는 끝나지 않은 것이다.
