# E12. 클럭이 가리키는 곳

E7의 식과 E8의 FIFO 클럭이 문서, 패키지, 테스트벤치, PHY 클럭 생성, SDC에서 같은 주기인지 대조한 표다. 하나라도 다르면 이 실습은 끝난 것이 아니다.

식은 `docs/02_architecture.md`에 있다.

```text
데이터율 3.2 Gb/s/DQ
CK = 3.2 / 2 = 1.6 GHz = 625 ps
컨트롤러 = CK / 2 = 800 MHz = 1250 ps
PHY beat = 16 bit, 버스트당 2 beat
```

| 항목 | 문서 | `hsl_pkg` | 시뮬레이션 | SDC |
| --- | --- | --- | --- | --- |
| 컨트롤러 주기 | 1250 ps, 800 MHz | `CTRL_PERIOD_PS = 1250` | `tb_hsl_smoke` 반주기 `#625ps` | `clk` 1.25 ns |
| PHY / CK 주기 | 625 ps, 1.6 GHz | `PHY_PERIOD_PS = 625` | 기어박스 검사 반주기 `#312.5ps` | `clk_phy` 0.625 ns |
| 관계 | 컨트롤러 = CK/2, PHY = 컨트롤러 x2 | PHY 주기 = 컨트롤러 주기 / 2 | `hsl_phy_clk`가 컨트롤러 엣지마다 `#312.5ps` 네 번 | `create_generated_clock -multiply_by 2`, 소스 `clk` |
| 생성 위치 | `u_phy/u_phy_clk` | | `hsl_phy_clk` | 핀 `u_phy/u_phy_clk/clk_phy` |
| `pin_ck` | 생성 클럭 아님 | 0에 고정 | 0 | 생성 클럭으로 선언하지 않음 |

`#312.5ps`는 `PHY_PERIOD_PS/2`다. 정수 나눗셈 312 ps를 쓰면 네 구간이 1248 ps가 되어 1250 ps와 어긋난다.

E8 포인터 제약도 같은 주기를 쓴다. false path는 없다.

| 싱크 플롭 | 목적지 클럭 | `set_max_delay` |
| --- | --- | --- |
| `wptr_g_s1` → `wptr_g_s2` | 컨트롤러 `clk` | 1.25 ns |
| `rptr_g_s1` → `rptr_g_s2` | PHY `clk_phy` | 0.625 ns |

입력/출력 delay는 컨트롤러 주기의 40%인 0.5 ns다. v0.1의 4.0 ns는 10 ns 클럭의 40%였고, 그 클럭은 빼었다.
