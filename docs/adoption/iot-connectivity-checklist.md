# IoT/설비 연결 점검표

이 문서는 설비, 센서, 바코드, 계측기 연결 가능성을 도입 전에 확인하기 위한 문서다.

## 핵심 원칙

Open MES Korea는 모든 PLC 드라이버를 직접 포함하지 않는다.

권장 구조:

```text
설비/센서/PLC
→ Edge Connector
→ MQTT/HTTP/Webhook
→ Open MES Korea ingestion API
→ MES 이벤트/후보 데이터
```

## 설비별 조사표

| 항목 | 답변 |
|---|---|
| 설비명 |  |
| 설비코드 |  |
| 제조사/모델 |  |
| 연결 가능 방식 | OPC UA / Modbus / MQTT / Serial / File / API / 없음 |
| 읽고 싶은 데이터 | 생산 카운터 / 상태 / 온도 / 압력 / 알람 / 기타 |
| 쓰기 제어 필요 여부 | 없음 / 제한적 / 필요 |
| 데이터 주기 | 실시간 / 초 단위 / 분 단위 / 작업 종료 시 |
| 설비망 위치 | 내부망 / 분리망 / 인터넷 가능 / 불명 |
| 담당자 |  |

## 연결 방식별 점검

| 방식 | 확인할 것 | Open MES Korea 접근 |
|---|---|---|
| 바코드/QR | 스캐너가 키보드 입력처럼 동작하는가 | MVP에서 우선 지원 |
| 라벨 프린터 | 프린터 언어, 네트워크/USB 연결 | 템플릿 기반 출력 |
| OPC UA | endpoint, node id, 인증 방식 | Node-RED/edge bridge 권장 |
| Modbus | TCP/RTU, register map, 단위 | 현장별 mapping 필요 |
| MQTT | broker, topic, payload schema | 표준 topic schema 제공 |
| HTTP API | 인증, payload, 호출 주기 | ingestion API 직접 연동 |
| Serial/RS-232 | baud rate, delimiter, 값 형식 | edge connector 필요 |
| CSV/File | 파일 위치, 생성 주기, 컬럼 | batch import 가능 |

## 도입 전 반드시 확인할 질문

| 질문 | 이유 |
|---|---|
| 설비 데이터를 읽을 권한이 있는가? | 장비 vendor나 보전팀 협조 필요 |
| register map 또는 tag list가 있는가? | 없으면 수집 개발이 지연됨 |
| 설비망에서 MES 서버로 outbound 통신이 가능한가? | 보안 정책 확인 |
| 데이터가 생산실적을 확정할 만큼 신뢰 가능한가? | counter 오류나 reset 가능성 확인 |
| 작업지시와 설비 이벤트를 어떻게 매칭할 것인가? | 설비 데이터만으로 MES 실적이 되지 않음 |
| 설비 제어 write가 필요한가? | 초기에는 금지하는 것이 안전 |
| 네트워크 단절 시 데이터를 보관해야 하는가? | edge buffering 필요 |

## 우선순위

| 단계 | 연결 대상 | 이유 |
|---|---|---|
| 1 | 바코드/QR | 비용이 낮고 LOT 추적 효과가 큼 |
| 2 | 라벨 프린터 | LOT 운영에 바로 필요 |
| 3 | 설비 생산 카운터 | 생산실적 보조 검증 |
| 4 | 설비 상태 running/idle/fault | downtime/OEE 기반 |
| 5 | 공정 파라미터 온도/압력/속도 | 품질/AI 분석 기반 |
| 6 | PLC command write | 안전 검토 후 제한적으로만 |

## 판정

| 상태 | 판정 |
|---|---|
| 바코드/QR만 가능 | MES MVP 도입 가능 |
| 설비 데이터 없음 | 수동/바코드 기반으로 시작 |
| OPC UA/Modbus 가능, mapping 있음 | edge connector PoC 가능 |
| 설비망 접근 불가 | IoT 연동은 보류, MES core 먼저 도입 |
| command write 요구 | 별도 안전 검토와 승인 구조 필요 |

