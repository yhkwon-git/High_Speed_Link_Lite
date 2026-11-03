# 검증 계획

## 계층

| 계층 | 담당 | 상태 |
| --- | --- | --- |
| 스모크 | 섀시가 살아 있고 명령을 버리지 않음 | `tb/tb_hsl_smoke.sv` |
| 블록 | 리페어, deskew, PRBS, 스케줄러, MC, 기어박스, FIFO | `tb/tb_hsl_blocks.sv` |
| 채널 | 호스트 트래픽과 `dram_channel_behav` | T4, T5, T7 |

스코어보드는 기대 버스트 비교다. T4가 `32'hA5A5_5A5A` 한 워드를 본다.

## 스모크가 보는 것

1. ID, VERSION, 타이밍 리셋값
2. 미정의 주소 `0x24`는 0
3. 리셋 해제 직후 상태는 RESET, CKE는 0, `cmd_ready`는 0, CK와 DQ OE는 0, 응답은 없음
4. `train_bypass` 후 상태는 MISSION, CKE는 1, 큐에 빈 슬롯이 있으면 `cmd_ready`는 1. 깊이 4를 채우면 0
5. `soft_rst` 동안 상태는 RESET, CKE는 0, STATUS에 soft_rst가 보임
6. soft_rst만 지우면 bypass가 남아 있어 MISSION으로 돌아옴

E3가 항목 4를 바꿨다. 스텁은 `push_ready`를 0에 묶어서 MISSION에서도 `cmd_ready`가 0이었다. 링이 빈 슬롯을 알려 주게 된 뒤에도 그 기대를 두면, 받는 큐를 실패로 본다. 리셋 직후와 큐가 가득 찼을 때의 0은 남아 있다.

## 이후 테스트

| ID | 내용 | 실습 |
| --- | --- | --- |
| T1 | `train_start`로 상태가 순서대로 걷고, ZQ/WRLVL/RDLVL/DESKEW는 각자의 done 펄스 전에는 다음 상태로 가지 않음 | E2 |
| T2 | 뱅크가 tRCD 전에 RD를 거절하고, tRP 전에 ACT를 거절 | E4 |
| T3 | tCCD 간격 전에 다음 컬럼 명령을 거절 | E4 |
| T4 | ACT-WR-RD가 DRAM 모델과 일치 | E5 |
| T5 | DBI on에서 1이 5개인 beat는 반전되고 DBI 핀이 1, 4개인 beat는 그대로 | E6 |
| T6 | 두 클럭으로 나눈 FIFO가 버스트를 유지 | E8 |
| T7 | 리페어 레인 하나가 리던던트 핀과 치환 | E10 |
| T8 | PRBS 루프백 후 에러 카운트가 불일치를 셈 | E11 |

## 통과 규칙

- 기대와 다르면 `[SMOKE] FAIL` 또는 해당 테스트 이름이 보이고, 프로세스가 0이 아닌 코드로 끝난다.
- 타임아웃은 실패다.
- X를 데이터로 샘플하지 않는다. 구동하지 않는 핀은 0이다.
- 비교는 `!==`/`===`로 한다. X나 Z가 나오면 통과가 아니라 실패다.
- 리셋은 클럭 negedge에서 푼다. posedge와 같은 시각에 풀면 첫 싱크러나이저 플롭과 레이스가 생긴다.
