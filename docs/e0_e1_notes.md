# E0 / E1 노트

## E0. 계층과 `cmd_ready`

`hsl_base_die_lite` 아래 트리다.

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

E3 이전 스텁에서 `cmd_ready`가 MISSION에서도 0이었던 이유:

- `hsl_mc_top`은 `cmd_ready = mission_mode & push_ready` 다.
- 그때 `hsl_cmd_queue`는 `push_ready`를 0에 묶어 두었다.
- 그래서 mission이 1이어도 ready는 0이었다. 빈 큐가 비트를 삼키지 않게 하려는 스텁 규칙이다.

E3가 그 묶음을 지웠다. 지금 `push_ready`는 링에 빈 슬롯이 있을 때 1이다. 스모크는 리셋 직후와 깊이 4가 가득 찼을 때 0을 보고, MISSION에서 슬롯이 있으면 1을 본다.

## E1. 리셋

`docs/05_pd_guide.md`의 리셋 절과 같은 구조다. 핀 `rst_n`이 0이 되면 `hsl_rst_sync`의 두 플롭이 클럭을 기다리지 않고 0이 된다. 해제는 핀이 1로 돌아온 뒤 컨트롤러 클럭 두 번을 지난 다음에야 `rst_sync_n`이 1이 된다.

```text
clk          __/‾‾\__ /‾‾\__ /‾‾\__ /‾‾\__
rst_n        ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
sync_r[0]    ________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
rst_sync_n   ____________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
```

assert는 비동기, deassert는 2플롭 동기다. 나머지 블록은 이 핀을 직접 리셋으로 쓰지 않는다.

CSR의 리셋은 `rst_sync_n`만이다. `soft_rst`는 `rst_logic_n = rst_sync_n & ~soft_rst` 로 큐, FSM, PHY, DFT에만 들어간다. CSR까지 soft reset에 넣으면 CTRL 비트 0이 자기 레지스터를 지운다. 쓴 다음 사이클에 비트가 0이 되어 리셋을 유지할 수 없다.
