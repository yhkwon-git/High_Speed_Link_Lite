# Physical Design 가이드

디지털이 PD에 넘기는 내용이다. 좌표는 없고, 라이브러리 숫자는 교육용 Nangate45로 잰 칩 STA 결과뿐이다(사인오프 아님). 없는 숫자를 넣어 가이드처럼 보이게 하지 않는다.

## 클럭

- 컨트롤러 클럭 `clk`는 포트 `clk`, 주기 1.25 ns (800 MHz).
- PHY 클럭 `clk_phy`는 `u_phy/u_phy_clk/clk_phy`, 소스 `clk`, 관계 2:1, 주기 0.625 ns (1.6 GHz). PLL 매크로의 `.lib`가 `clk_ctrl` → `clk_phy` 경로를 줘야 생성 클럭이 마스터에서 이어진다. 저장소의 STA는 `syn/lib/hsl_phy_clk_stub.lib`로 그 아크를 대신한다. 이것이 없으면 이 도메인의 플롭 44개가 클럭 없음으로 빠진다.
- `pin_ck`는 mission에서 `clk_phy`를 클럭 게이트로 내보낸다(enable은 PHY 하강 엣지에서 잡아 펄스가 잘리지 않음, 실리콘에서는 ICG). enable 플롭은 ICG 래치처럼 리셋이 없다: 컨트롤러 클럭에서 풀리는 리셋은 PHY 반 주기 안에 닿아야 해서 recovery가 맞지 않았다. 출력 포트에 생성 클럭 `ck_out`.
- RDQS(`pin_rdqs`)는 0.625 ns 입력 클럭이다. CK + tDQSCK라 위상이 정해지지 않는다.
- 숫자 대조는 `docs/e12_clocks.md`다. 식은 `docs/02_architecture.md`다.

## 리셋

- `rst_n`은 비동기 assert다.
- 해제 동기는 `hsl_rst_sync`의 2플롭이 맡는다. 칩 top의 `u_rst`는 `clk`로, PHY의 `u_phy/u_mis/u_rst_rdqs`는 RDQS로 맞춘다. RDQS 쪽(캡처 플롭, 읽기 FIFO의 쓰기 쪽)은 RDQS가 돌기 전에는 리셋에 머문다. 이 동기화기는 RDQS가 계속 돈다는 채널 모델의 가정에 기댄다. 실제 RDQS는 읽기 버스트 동안만 토글하므로, 실제 PHY에서는 해제를 `clk` 쪽에서 맞추고 DQS gating으로 캡처를 여는 구조가 필요하다.
- 나머지 제어 플롭은 `rst_logic_n`(RDQS 쪽은 `rst_rdqs_n`)을 비동기 리셋으로 쓴다. 큐와 FIFO의 데이터 배열은 리셋이 없고, 유효성은 리셋되는 포인터가 정한다. 래치는 없다.
- SDC의 `set_false_path -from rst_n`은 v0.1 단순화다. 실제 덱에서는 싱크러나이저 플롭의 recovery/removal을 이 false path가 가리지 않는지 확인한다. RDQS 동기화기는 두 플롭의 리셋 핀으로 가는 assert 경로만 false path로 두고, 풀린 리셋은 RDQS 기준 recovery(+0.499 ns) · removal을 본다.
- 동기화된 리셋은 플롭 약 4,650개의 리셋 핀으로 간다(`e61e90d`: FF 4,846개 중 리셋 없는 것은 읽기 FIFO 데이터 192개와 클럭 게이트 enable 1개). 클럭 트리처럼 P&R에서 트리를 만든다고 보고 SDC는 `set_ideal_network`를 둔다. OpenSTA 3.1은 이 명령을 적용하지 않아, 저장소의 STA는 `syn/fanout_buffer.py`로 버퍼 트리(부하 16개마다, 블록마다 리셋 버퍼 하나)를 넣어 본다. 버퍼가 없으면 게이트 하나가 모든 리셋 핀을 구동해 지연이 22.7 ns로 외삽된다(`8af801b`, 리셋 핀 약 2,700개일 때).
- 이상 클럭에서 리셋 핀의 removal이 음수다(`e61e90d`, `3d596a4`와 같음): RDQS 쪽 85개가 −0.048 ns, `rst_sync_n` 쪽 334개(CSR 164 · 1500 포트 170)가 −0.017 ns(`8af801b`에서는 −0.038 ns). 리셋 해제가 removal 시간 0.23 ns보다 조금 일찍 닿는 것이라 CTS 뒤 hold 수리 단계에서 다시 본다.

## CDC

칩의 읽기 FIFO(`u_phy/u_mis/u_rx_fifo`)는 쓰기 클럭이 RDQS, 읽기 클럭이 `clk`다. TX 기어의 `clk` → `clk_phy`는 같은 PLL에서 나온 동기 경로라 FIFO가 없고, 반 주기(0.625 ns) 경로로 타이밍을 본다. deskew는 아직 경로에 없다. `hsl_phy_clk`는 `SYNTHESIS`가 정의되면 빈 쉘이다. PLL 매크로가 그 자리를 채운다.

- 포인터는 각 도메인의 그레이 코드 플롭(`wgray`, `rgray`)에서 나간다. 바이너리 플롭의 XOR를 그대로 넘기면 여러 비트가 바뀌는 순간 글리치가 생기고, 첫 싱크 플롭이 옛 값도 새 값도 아닌 포인터를 잡을 수 있다.
- 크로싱은 `wgray`(RDQS) → `wptr_g_s1`(`clk`)과 `rgray`(`clk`) → `rptr_g_s1`(RDQS) 두 개다. 둘 다 빠른 쪽 주기인 `set_max_delay 0.625`로 묶는다. 제약은 소스 클럭 → 첫 싱크 플롭으로 건다: Gray 최상위 비트는 binary 최상위 비트와 같아 합성이 두 플롭을 하나로 합치므로, 소스 셀 이름(`wgray*`)으로 묶으면 그 비트가 빠진다(14fec6e부터 `e61e90d` 전까지 그랬다). 한 그레이 스텝의 비트들이 한 주기 안에 도착하게 하려는 것이다. FIFO 데이터 → `clk`는 포인터가 싱크 두 단을 지난 뒤에 읽히므로 `set_max_delay 1.25`다.
- RDQS와 다른 클럭 사이에 비동기 clock group을 걸지 않는다. clock group은 false path처럼 동작해 위 `set_max_delay`보다 우선한다.
- `*_s1` → `*_s2`는 한 클럭 안의 경로라 예외를 두지 않는다.
- 포인터 경로를 `set_false_path`로 묶지 않는다. false path는 그 경로의 지연을 타이밍이 보지 않게 만든다.

## STA 결과

`bash syn/sta_chip.sh` (commit `e61e90d`, Nangate45 typical, 이상 클럭, 배선 없음):

| 클럭 · 검사 | 결과 |
| --- | --- |
| `clk_phy` 1.6 GHz | slack +0.044 ns (ECC 인코더: 원시 워드 레지스터 → TX 기어, 반 주기) |
| `rdqs` | slack +0.106 ns (입력 지연 0.25 ns 포함) |
| 읽기 FIFO 크로싱 | Gray 포인터 세 비트 최대 0.112 / 0.625 ns, 데이터 0.402 / 1.25 ns |
| `clk` 800 MHz, HSL 로직 | 통과 |
| `clk` 800 MHz, 컨트롤러 | −0.930 ns, 최소 주기 2.18 ns (459 MHz), 실패 끝점 1,971개 |
| RDQS 리셋 recovery | +0.499 ns (`u_rst_rdqs` → 캡처 플롭) |
| hold · removal | −0.048 ns RDQS 쪽 리셋 핀, −0.017 ns `rst_sync_n` 쪽(CSR · 1500 포트) 리셋 핀 (CTS 뒤 수리) |

- 준정적 설정: CTRL · REMAP 설정 → TX 워드 레지스터 데이터 핀은 2클럭 multicycle이다. 설정은 컨트롤러가 idle일 때만 바뀐다. 리셋 핀은 이 예외에 들어가지 않는다.
- 컨트롤러의 임계 경로는 큐 엔트리 → 스케줄러 후보 · FR-FCFS 선택 → 뱅크 타이머 갱신의 한 클럭 루프다. 호스트 입력 → `req_ready`는 컨트롤러 안에서 조합으로 이어지는 feedthrough다.
- PD에 넘기기 전에 정할 것: 컨트롤러를 DFI 1 : 2(400 MHz, 클럭마다 명령 두 개)로 갈지, 800 MHz에 맞는 라이브러리를 전제로 할지. 이 저장소는 1 : 2가 맞는 방향이라고 본다.

## 핀

디지털이 책임지는 값:

- 1500 시험 포트 `wrck`, `wrstn`, `selectwir`, `shiftwr`, `capturewr`, `updatewr`, `wsi`, `wso`: 칩 안에서 clk로 동기화하므로 WRCK는 클럭 트리가 필요 없는 느린 신호다(clk의 1/8 이하)
- `pin_cke`, 행 · 열 CA(`pin_rca`, `pin_cca`), 쓰기 beat(`pin_tx_beat`, `pin_tx_ecc`, `pin_tx_dqs`, `pin_tx_dv`)의 논리값과 `rx_dly_code`
- 쓰기 beat가 없으면 `pin_tx_beat = 0`, `pin_tx_dv = 0`(드라이버 enable의 근거)
- `pin_ck`의 게이트(`phy_en`, PHY 하강 엣지에서 잡은 enable)
- repair 표 `rep_tab`과 fuse 포트(`fz_addr`, `fz_rd`, `fz_pgm`, `fz_wdata`)의 논리값. fuse 프로그램 전압과 시간은 fuse 매크로 몫이다

아날로그와 풀커스텀이 책임지는 것:

- 드라이버 세기, 터미네이션, VREF, ZQ, 지연 셀
- 범프까지의 클럭 스파인. `pin_ck`는 그 스파인의 출력이다.

PD가 맞춰야 하는 의도:

- DQ 레인 사이의 배선 길이 차이는 deskew 범위 안에 둘 것. N은 4단이다. 0단은 조합 통과이고 1–4단은 플롭이다. 한 단은 PHY beat 하나고, PHY beat는 `DDR_BITS` = 2 UI다. 허용 스큐는 `4 * 2 = 8 UI`다. `delay_sel`이 4보다 크면 4로 자른다.
- DQS와 DQ 그룹은 같이 묶는다.

## Floorplan

컴파일된 SRAM 매크로는 없다. 읽기 FIFO는 깊이 4 플롭이고, 컨트롤러의 큐(읽기 8 · 쓰기 8)와 응답 버퍼도 플롭이다(컨트롤러 FF 2,004개, 칩 4,846개 중). 큐는 엔트리마다 주소를 비교하고 나이 행렬을 갖고 있어 매크로로 옮기기 어렵다. DFD의 trace buffer(16 × 32 bit)도 플롭 512개다. 실제 칩이라면 작은 SRAM이나 레지스터 파일 매크로로 둔다.

배치 의도만 적으면:

- PHY 핀 로직은 채널 범프 쪽에 둔다.
- CSR, FSM, 컨트롤러는 그 안쪽에 둔다. 컨트롤러는 칩 면적의 44%다(Nangate45, `e61e90d`. DFT · DFD를 더하기 전 `8af801b`에서는 73%).
- ECC 핀(`pin_tx_ecc`, `pin_rx_ecc`)은 데이터 핀과 같은 바이트 그룹, 같은 스트로브로 묶는다. RDQS 캡처 플롭과 읽기 FIFO의 쓰기 쪽은 RDQS 핀 가까이 둔다.
- fuse 포트(`fz_*`)는 fuse(OTP) 매크로 옆에 둔다. 읽기 데이터는 입력 지연 0.5 ns를 가정하고 칩 안에서 레지스터로 먼저 받는다.
- repair 표(`rep_tab`)는 배열의 spare 쪽으로 가는 사이드밴드다. `hsl_repair`는 그 출력이 나가는 쪽(core die로 가는 TSV 영역)과 fuse 매크로 사이에 둔다.
- 1500 포트 핀은 칩 경계 어디에 있어도 된다. 입력은 칩 안에서 2-FF로 동기화한 뒤 `clk`로 샘플한다.
- TSV keep-out 좌표는 스택 설계가 준다. 디지털은 keep-out 안에 매크로를 두지 않는다. 좌표가 생기기 전에는 "매크로 없음"이 이 가이드의 답이다.

나중에 응답 버퍼나 큐 데이터를 SRAM 매크로로 바꾸면, 그 매크로 이름과 halo를 이 절에 추가한다. Logic/Macro floorplan의 디지털 측 입력은 이 목록이다.

## PD가 디지털에 되묻는 항목

구현이 이 질문의 답을 바꾸면 가이드를 갱신한다.

1. 클럭이 여전히 `clk`와 2배 `clk_phy` 둘인가.
2. 리셋 싱크러나이저(`clk` 하나, RDQS 하나) 플롭은 어느 셀인가.
3. 매크로가 생겼는가.
4. 레인당 deskew 범위는 몇 단인가.
5. 컨트롤러 클럭을 800 MHz 그대로 둘 것인가, DFI 1 : 2로 나눌 것인가.
6. trace buffer와 컨트롤러 응답 버퍼를 SRAM 매크로로 바꿀 것인가.
7. fuse 매크로와 TSV(repair 표가 가는 곳)는 어디에 있는가.
