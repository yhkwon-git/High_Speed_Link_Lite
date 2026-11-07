# Physical Design 가이드

v0.1에서 디지털이 PD에 넘기는 내용이다. 좌표와 라이브러리 숫자는 없다. 없는 숫자를 넣어 가이드처럼 보이게 하지 않는다.

## 클럭

- 컨트롤러 클럭 `clk`는 포트 `clk`, 주기 1.25 ns (800 MHz).
- PHY 클럭 `clk_phy`는 `u_phy/u_phy_clk/clk_phy`, 소스 `clk`, 관계 2:1, 주기 0.625 ns (1.6 GHz).
- `pin_ck`는 mission에서 `clk_phy`를 클럭 게이트로 내보낸다(enable은 PHY 하강 엣지에서 잡아 펄스가 잘리지 않음, 실리콘에서는 ICG). 출력 포트에 생성 클럭 `ck_out`.
- RDQS(`pin_rdqs`)는 0.625 ns 입력 클럭이다. CK + tDQSCK라 위상이 정해지지 않는다.
- 숫자 대조는 `docs/e12_clocks.md`다. 식은 `docs/02_architecture.md`다.

## 리셋

- `rst_n`은 비동기 assert다.
- 해제 동기는 `hsl_rst_sync`의 2플롭만 담당한다.
- 나머지 제어 플롭은 `rst_logic_n`을 비동기 리셋으로 쓴다. 큐와 FIFO의 데이터 배열은 리셋이 없고, 유효성은 리셋되는 포인터가 정한다. 래치는 없다.
- SDC의 `set_false_path -from rst_n`은 v0.1 단순화다. 실제 덱에서는 싱크러나이저 플롭의 recovery/removal을 이 false path가 가리지 않는지 확인한다.

## CDC

칩의 읽기 FIFO(`u_phy/u_mis/u_rx_fifo`)는 쓰기 클럭이 RDQS, 읽기 클럭이 `clk`다. TX 기어의 `clk` → `clk_phy`는 같은 PLL에서 나온 동기 경로라 FIFO가 없고, 반 주기(0.625 ns) 경로로 타이밍을 본다. deskew는 아직 경로에 없다. `hsl_phy_clk`는 `SYNTHESIS`가 정의되면 빈 쉘이다. PLL 매크로가 그 자리를 채운다.

- 포인터는 각 도메인의 그레이 코드 플롭(`wgray`, `rgray`)에서 나간다. 바이너리 플롭의 XOR를 그대로 넘기면 여러 비트가 바뀌는 순간 글리치가 생기고, 첫 싱크 플롭이 옛 값도 새 값도 아닌 포인터를 잡을 수 있다.
- 크로싱은 `wgray`(RDQS) → `wptr_g_s1`(`clk`)과 `rgray`(`clk`) → `rptr_g_s1`(RDQS) 두 개다. 둘 다 빠른 쪽 주기인 `set_max_delay 0.625`로 묶는다. 한 그레이 스텝의 비트들이 한 주기 안에 도착하게 하려는 것이다. FIFO 데이터 → `clk`는 포인터가 싱크 두 단을 지난 뒤에 읽히므로 `set_max_delay 1.25`다.
- RDQS와 다른 클럭 사이에 비동기 clock group을 걸지 않는다. clock group은 false path처럼 동작해 위 `set_max_delay`보다 우선한다.
- `*_s1` → `*_s2`는 한 클럭 안의 경로라 예외를 두지 않는다.
- 포인터 경로를 `set_false_path`로 묶지 않는다. false path는 그 경로의 지연을 타이밍이 보지 않게 만든다.

## 핀

디지털이 책임지는 값:

- `pin_cke`, 행 · 열 CA(`pin_rca`, `pin_cca`), 쓰기 beat(`pin_tx_beat`, `pin_tx_dqs`, `pin_tx_dv`)의 논리값과 `rx_dly_code`
- 쓰기 beat가 없으면 `pin_tx_beat = 0`, `pin_tx_dv = 0`(드라이버 enable의 근거)
- `pin_ck`의 게이트(`phy_en`, PHY 하강 엣지에서 잡은 enable)

아날로그와 풀커스텀이 책임지는 것:

- 드라이버 세기, 터미네이션, VREF, ZQ, 지연 셀
- 범프까지의 클럭 스파인. `pin_ck`는 그 스파인의 출력이다.

PD가 맞춰야 하는 의도:

- DQ 레인 사이의 배선 길이 차이는 deskew 범위 안에 둘 것. N은 4단이다. 0단은 조합 통과이고 1–4단은 플롭이다. 한 단은 PHY beat 하나고, PHY beat는 `DDR_BITS` = 2 UI다. 허용 스큐는 `4 * 2 = 8 UI`다. `delay_sel`이 4보다 크면 4로 자른다.
- DQS와 DQ 그룹은 같이 묶는다.

## Floorplan

컴파일된 SRAM 매크로는 없다. 읽기 FIFO는 깊이 4 플롭이고, 컨트롤러의 큐(읽기 8 · 쓰기 8)와 응답 버퍼도 플롭이다(컨트롤러 FF 2,004개, 칩 2,741개 중). 큐는 엔트리마다 주소를 비교하고 나이 행렬을 갖고 있어 매크로로 옮기기 어렵다.

배치 의도만 적으면:

- PHY 핀 로직은 채널 범프 쪽에 둔다.
- CSR, FSM, 컨트롤러는 그 안쪽에 둔다. 컨트롤러는 칩 면적의 74%다(Nangate45, `0193c04`).
- TSV keep-out 좌표는 스택 설계가 준다. 디지털은 keep-out 안에 매크로를 두지 않는다. 좌표가 생기기 전에는 "매크로 없음"이 이 가이드의 답이다.

나중에 응답 버퍼나 큐 데이터를 SRAM 매크로로 바꾸면, 그 매크로 이름과 halo를 이 절에 추가한다. Logic/Macro floorplan의 디지털 측 입력은 이 목록이다.

## PD가 디지털에 되묻는 항목

구현이 이 질문의 답을 바꾸면 가이드를 갱신한다.

1. 클럭이 여전히 `clk`와 2배 `clk_phy` 둘인가.
2. 리셋 싱크러나이저 플롭은 어느 셀인가.
3. 매크로가 생겼는가.
4. 레인당 deskew 범위는 몇 단인가.
