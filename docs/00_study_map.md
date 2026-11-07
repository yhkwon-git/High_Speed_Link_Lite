# 스터디 맵

이 저장소는 HBM base die 디지털 RTL의 작업 순서를 한 채널 슬라이스에 옮겨 놓은 것이다. 고객 요구를 스펙으로 적고, PPA로 구조를 고르고, RTL로 구현한 뒤 검증하고, Physical Design에 넘길 가이드를 쓴다. 다루는 블록은 고속 디지털 PHY, DRAM 메모리 컨트롤러, DFT/DFD다.

| 항목 | 이 프로젝트에서 보는 곳 |
| --- | --- |
| 요구를 구체화하고 상세 스펙을 쓴다 | `docs/01_requirements.md` |
| PPA로 아키텍처를 고른다 | `docs/02_architecture.md` |
| RTL 설계와 기능 검증 | `rtl/`, `tb/`, `docs/04_verification_plan.md` |
| Physical Design용 가이드, floorplan 관점 | `docs/05_pd_guide.md`, `syn/constraints/` |
| 웨이퍼 테스트와 실리콘 이슈를 볼 수 있는 상태 | `docs/06_dft_plan.md`, `rtl/dft/` |
| High-Speed Digital PHY | `rtl/phy/` |
| DRAM 메모리 컨트롤러 | `rtl/mc/` |
| DFT / DFD | `rtl/dft/`, CSR의 `ERRCNT`와 `STATUS` |
| 저전력 | CKE, DBI(E6), 놀고 있는 구간의 드라이버 enable |
| 고신뢰성 | 레인 리페어(E10), 포화 에러 카운터 |
| 풀커스텀과의 경계 | 핀 리스트. 디지털은 값과 enable, 아날로그는 드라이버와 샘플러 |

## 3분 설명

1. Base die 디지털은 호스트와 DRAM 코어 다이 사이에 있다. 스터디 슬라이스는 DQ 8비트, 버스트 4, 뱅크 4개다.
2. 스펙을 먼저 적고, 컨트롤러와 PHY를 버스트 단위로 나눴다. 시뮬 클럭은 컨트롤러 800 MHz, PHY 1.6 GHz다. 뱅크 타이밍을 먼저 닫은 뒤 기어박스와 비동기 FIFO를 그 클럭에 올렸다.
3. 지금 도는 것은 CSR, 리셋 동기화, done 펄스 트레이닝, 깊이 4 큐, 뱅크 타이밍, bypass 채널 트래픽, DBI(DC · AC), shift 레인 리페어와 레인 BIST, 읽기 레벨링, PRBS 병렬 루프백이다.
4. 회귀는 `sim/run_smoke.ps1` 한 번이다. 스모크와 T1–T11이 같이 돈다. PD 가이드의 포인터 경로는 `set_max_delay`이고 false path가 아니다.
5. 컨트롤러 항목은 큐, in-order 스케줄러, 뱅크 FSM이다. REF는 아직 발행하지 않는다.

## 공개 HBM과 이 모델의 거리

HBM은 base logic die 위에 DRAM core die를 쌓고 TSV로 연결한다. 호스트와는 인터포저 위의 넓은 소스 동기 인터페이스로 붙는다. 클럭을 데이터에 실어 CDR로 복구하는 SerDes와 다르다. 스트로브를 함께 보내고, 수신측은 그 스트로브로 샘플한다.

공개 자료에서 자주 인용되는 헤드라인은 HBM2의 1024-bit I/O, HBM3의 채널 16개와 핀당 6.4 Gb/s, 피크 약 819 GB/s다. 채널과 pseudo-channel의 정확한 폭, 뱅크 수, CA 폭은 문서로 다시 확인한다. 이 저장소의 숫자는 그 헤드라인을 축소한 스터디 값이다.

LLM/EDA 자동화 툴은 따로 만들지 않는다. LLM은 E2 이후 디렉티드 테스트를 추가할 때 테스트 스케치와 SDC 문장을 리뷰받는 용도로만 쓰고, 생성 결과는 시뮬레이터와 파형으로 확인한다.
