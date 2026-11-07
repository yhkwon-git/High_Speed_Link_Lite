# 용어

스터디 중 헷갈리기 쉬운 것만 적었다. 표준 정의의 대체본이 아니다.

| 용어 | 이 프로젝트에서의 뜻 |
| --- | --- |
| Base die | HBM 스택 맨 아래의 로직 다이. 이 저장소가 모델링하는 쪽 |
| Core die | 위에 쌓인 DRAM 다이. 여기서는 `dram_channel_behav` |
| TSV | 다이를 수직으로 잇는 비아. 디지털 RTL 밖 |
| 인터포저 | 호스트와 HBM을 얹는 실리콘 기판 |
| 소스 동기 | 스트로브가 데이터와 함께 온다. 클럭 복원(CDR)형 SerDes와 구분한다 |
| Gearbox | 느린 넓은 버스와 빠른 좁은 버스 사이의 폭 변환 |
| Write leveling | DRAM 입력에서 쓰기 스트로브 엣지를 CK 엣지에 맞추는 절차. 데이터를 스트로브 eye 중앙에 두는 것은 write training |
| Read leveling | 읽기 데이터가 컨트롤러 캡처 윈도우에 들어오도록 맞추는 절차 |
| Deskew | 레인마다 다른 비행 시간을 지연으로 흡수 |
| DBI | 바이트 단위 반전. 이 저장소의 규칙은 `docs/01_requirements.md` |
| DFI | DDR PHY 인터페이스 규격. 역할 분리만 참고했고, 이 포트는 DFI가 아니다 |
| PPA | Performance, Power, Area. 구조를 고를 때 같이 적는 세 축 |
| DFT / DFD | 테스트 용이성 / 디버그 용이성. 루프백은 DFT, 상태와 에러 카운트는 DFD |
| Lane repair | 고장 핀을 건너뛰도록 레인을 한 칸씩 리던던트 핀 쪽으로 미는 디지털 먹스(핀마다 2:1) |
| Lane BIST | PRBS 데이터를 쓰고 읽어 레인별로 고장을 찾는 칩 안의 테스트 엔진 |
| ZQ | 드라이버 임피던스 보정. 회로는 아날로그, 순서는 디지털 FSM |
| tRCD, tRP, tRAS | ACT 후 컬럼 명령(RD/WR)까지, PRE 후 ACT까지, ACT 후 PRE까지 |
| tCCD | 컬럼 명령 사이의 채널 간격 |
| tWTR | 쓰기 후 읽기까지의 간격 |
| Pseudo-channel | HBM2 채널을 둘로 나눈 동작 단위. 이 모델은 그 단위 하나를 더 축소했다 |
