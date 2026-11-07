# 용어

스터디 중 헷갈리기 쉬운 것만 적었다. 표준 정의의 대체본이 아니다.

| 용어 | 이 프로젝트에서의 뜻 |
| --- | --- |
| Base die | HBM 스택 맨 아래의 로직 다이. 표준 HBM에서는 인터페이스 PHY, TSV 연결, 테스트 로직(IEEE 1500, MBIST)을 담고, 메모리 컨트롤러는 호스트 SoC에 있다. 이 저장소는 컨트롤러까지 base die에 둔 custom HBM 구조를 모델링한다 |
| Custom HBM | HBM4 세대부터 base die를 로직 공정으로 만들면서 나온, 고객 로직(메모리 컨트롤러 등)을 base die에 넣는 HBM. 이 저장소의 전제 |
| Core die | 위에 쌓인 DRAM 다이. 여기서는 `dram_channel_behav` |
| TSV | 다이를 수직으로 잇는 비아. 디지털 RTL 밖 |
| 인터포저 | 호스트와 HBM을 얹는 실리콘 기판 |
| 소스 동기 | 스트로브가 데이터와 함께 온다. 클럭 복원(CDR)형 SerDes와 구분한다 |
| Gearbox (TX 기어) | 느린 넓은 버스와 빠른 좁은 버스 사이의 폭 변환. 여기서는 컨트롤러 클럭 워드 하나를 `clk_phy` beat 두 개로 |
| Write leveling | DRAM 입력에서 쓰기 스트로브 엣지를 CK 엣지에 맞추는 절차. 데이터를 스트로브 eye 중앙에 두는 것은 write training |
| Read leveling | 읽기 데이터가 컨트롤러 캡처 윈도우에 들어오도록 맞추는 절차 |
| Deskew | 레인마다 다른 비행 시간을 지연으로 흡수 |
| DBI | 바이트 단위 반전. 이 저장소의 규칙은 `docs/01_requirements.md` |
| DFI | DDR PHY 인터페이스 규격. 역할 분리만 참고했고, 이 포트는 DFI가 아니다 |
| DFI 형태 경계 | 이 저장소의 컨트롤러 ↔ PHY 신호: 행 · 열 명령 매 클럭, WL 뒤 `wrdata_en`과 쓰기 데이터, `rddata_valid`와 읽기 데이터 |
| WDQS / RDQS | 쓰기 / 읽기 데이터 스트로브. HBM3처럼 방향별로 나뉜다. 여기서 RDQS는 CK + tDQSCK |
| Posted write | 쓰기를 받는 즉시 응답하고 데이터는 큐에 두었다가 나중에 DRAM에 쓰는 방식 |
| Forwarding | 쓰기 큐에 있는 주소를 읽으면 DRAM 대신 큐의 가장 최근 쓰기로 답하는 것 |
| FR-FCFS | 열린 row에 맞는 요청(row hit)을 먼저, 같은 조건이면 오래된 요청을 먼저 고르는 스케줄링 |
| Bank group | 뱅크 묶음. 같은 그룹 안의 명령은 긴 간격(_L), 다른 그룹 사이는 짧은 간격(_S)을 쓴다. 여기서는 2 × 2 |
| REFpb | per-bank refresh. 한 뱅크만 tRFCpb 동안 막고 다른 뱅크는 계속 일한다 |
| RFM | Refresh management. 뱅크마다 ACT를 세어 한도에 닿으면 추가 refresh를 내는 RowHammer 대책 |
| 스코어보드 | 응답이 가져야 할 값을 참조 모델로 계산해 실제 응답과 비교하는 테스트벤치 부품 |
| PPA | Performance, Power, Area. 구조를 고를 때 같이 적는 세 축 |
| DFT / DFD | 테스트 용이성 / 디버그 용이성. 루프백은 DFT, 상태와 에러 카운트는 DFD |
| Lane repair | 고장 핀을 건너뛰도록 레인을 한 칸씩 리던던트 핀 쪽으로 미는 디지털 먹스(핀마다 2:1) |
| Lane BIST | PRBS 데이터를 쓰고 읽어 레인별로 고장을 찾는 칩 안의 테스트 엔진 |
| Read leveling | 레인마다 읽기 지연선 코드를 스윕해 데이터를 바르게 읽는 구간(eye)을 찾고 그 중앙에 두는 트레이닝 |
| Eye | 샘플 시점(여기서는 지연선 코드)을 옮겨도 같은 UI를 바르게 읽는 구간 |
| ZQ | 드라이버 임피던스 보정. 회로는 아날로그, 순서는 디지털 FSM |
| tRCD, tRP, tRAS, tRC | ACT 후 컬럼 명령(RD/WR)까지, PRE 후 ACT까지, ACT 후 PRE까지, 같은 뱅크 ACT 사이 |
| tCCD_S / tCCD_L | 컬럼 명령 사이 간격(다른 / 같은 bank group) |
| tRRD, tFAW | 다른 뱅크 ACT 사이 간격, 어느 tFAW 구간에도 ACT는 4개까지 |
| tWTR, tRTW | 쓰기 후 읽기까지, 읽기 후 쓰기까지(데이터 버스 방향 전환) |
| tRFC, tREFI | refresh가 막는 시간, refresh 주기 |
| Pseudo-channel | HBM2 채널을 둘로 나눈 동작 단위. 이 모델은 그 단위 하나를 더 축소했다 |
| March 알고리즘 | 주소를 오름 · 내림 순서로 돌며 읽기(r0 · r1)와 쓰기(w0 · w1)를 정해진 순서로 하는 배열 시험. MATS+, March X, March C-가 쓰인다(`hsl_mbist`) |
| SA · TF · CF | stuck-at(값 고정), transition(한 방향 전이가 안 됨), coupling(다른 셀의 전이나 상태가 이 셀을 바꿈: inversion · idempotent · state) |
| BIRA | built-in redundancy analysis. 실패 목록으로 spare row · column을 어디에 쓸지 고른다(`hsl_bira`) |
| must-repair | spare column보다 많은 실패가 있는 row는 반드시 spare row로(반대도 같음) 고쳐야 한다는 규칙 |
| soft · hard repair | soft: 레지스터(repair 표)로 바로 적용, 리셋하면 사라짐. hard: fuse에 기록, 리셋 뒤 자동으로 다시 로드 |
| fuse (OTP) | 한 번 쓰면 0 → 1만 되는 저장소. 여기서는 TB의 모델, 워드마다 SECDED |
| SECDED | single error correct, double error detect. 여기서는 (39,32) 확장 Hamming 부호 |
| syndrome | 디코더가 계산한 검사 결과. 1 bit 오류면 그 비트의 위치를 가리킨다 |
| CE · UE | correctable(정정한) 오류 · uncorrectable(정정 못 한) 오류 |
| MISR | multiple-input signature register. 긴 데이터 스트림을 32 bit 값 하나로 압축해 비교한다 |
| trace buffer · trigger | 신호를 ring에 계속 기록하다가 조건(trigger)이 오면 그 앞뒤를 남기고 멈추는 디버그 기록 장치 |
| IEEE 1500 | 코어 시험 접근 표준. WIR(명령 레지스터), WBY(bypass), WDR(데이터 레지스터)과 직렬 제어 신호로 시험 기능에 닿는다. HBM이 시험 포트로 쓴다 |
