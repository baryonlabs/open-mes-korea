# IoT 연결부 오픈소스 전략

조사일: 2026-06-13

## 결론

Open MES Korea의 IoT 연결부는 전부 오픈소스로 만들 수 있다. 다만 MES core 안에 모든 PLC/센서/설비 프로토콜을 직접 넣으면 유지보수와 보안 부담이 커진다.

권장 구조는 다음이다.

```text
설비/센서/PLC
  → Edge Connector
  → MQTT / HTTP / Webhook / OPC UA bridge
  → Open MES Korea ingestion API
  → 검증/매핑/이벤트 저장
  → 작업지시/공정/LOT/설비 상태와 연결
```

즉, Open MES Korea는 **설비 연결 전체를 직접 구현하는 제품**이 아니라, **오픈소스 edge connector와 안전하게 연결되는 MES event hub**가 되어야 한다.

## 왜 분리해야 하는가

IoT/설비 연결은 일반 웹 애플리케이션과 다르다.

- PLC, 센서, 계측기, 바코드 리더, 저울, 온습도계, 비전 장비마다 프로토콜이 다르다.
- 같은 Modbus라도 register map은 현장마다 다르다.
- OPC UA node 구조도 설비 벤더마다 다르다.
- 설비망은 보안상 MES 서버나 인터넷과 직접 연결하면 안 되는 경우가 많다.
- 설비 데이터는 초당 수십~수천 건으로 들어올 수 있어 MES 트랜잭션 데이터와 저장 방식이 다르다.
- 잘못된 command write는 설비 안전 문제로 이어질 수 있다.

따라서 MVP에서 해야 할 일은 "모든 설비 드라이버 구현"이 아니라 "설비 데이터를 받아들일 표준 경계"를 만드는 것이다.

## 오픈소스로 만들 수 있는 범위

| 구성요소 | 오픈소스 가능 여부 | 설명 |
|---|---:|---|
| MQTT topic schema | O | 설비/작업/공정 이벤트 표준화 |
| HTTP ingestion API | O | edge에서 MES로 이벤트 전송 |
| Webhook receiver | O | 외부 시스템 이벤트 수신 |
| OPC UA bridge 예제 | O | Node-RED, ThingsBoard Gateway 등으로 예제 제공 |
| Modbus bridge 예제 | O | register map 템플릿과 변환 예제 제공 |
| CSV/manual import | O | IoT 미설치 공장도 시작 가능 |
| Edge connector SDK | O | Python/Node.js 기반 connector 작성 도구 |
| Device mapping UI | O | 설비 tag를 MES entity에 매핑 |
| Event validation rules | O | 단위, 범위, 중복, 시간 역전 검증 |
| 설비 telemetry 저장소 | O | PostgreSQL/TimescaleDB/InfluxDB 선택 가능 |
| OEE 계산 로직 | O | 설비 이벤트와 작업 실적 기반 계산 |
| AI anomaly 후보 생성 | O | read-only 분석과 제안 |
| PLC command write | 제한적 | 안전상 기본 비활성화, 승인/정책/현장별 plugin 필요 |
| 특정 벤더 SDK wrapper | 조건부 | SDK 라이선스가 허용할 때만 공개 |
| 고객사 register map | X | 영업비밀/현장 정보로 비공개 |
| 실제 설비 인증서/비밀번호 | X | 절대 공개 금지 |

## 권장 아키텍처

### Layer 1: Field Device

현장 장비다.

- PLC
- 센서
- 계측기
- 바코드/QR 스캐너
- 라벨 프린터
- 저울
- 비전 검사기
- 온습도 기록계
- 설비 컨트롤러

### Layer 2: Edge Connector

설비망 가까이에서 데이터를 수집하고 변환한다.

역할:

- OPC UA/Modbus/Serial/MQTT/HTTP 수집
- 현장별 tag/register map 적용
- 단위 변환
- timestamp 부여
- 버퍼링
- 재전송
- 네트워크 단절 대응
- MES 표준 event schema로 변환

초기 추천:

- Node-RED 예제 connector
- Python lightweight connector
- ThingsBoard IoT Gateway 연동 예제

### Layer 3: Message Transport

MES와 edge 사이의 전송 계층이다.

초기 우선순위:

1. HTTP ingestion API
2. MQTT subscriber
3. Webhook receiver
4. File/CSV drop

장기:

- Kafka
- NATS
- OPC UA subscription 직접 수신
- Sparkplug B

### Layer 4: MES Ingestion

Open MES Korea 내부 수신 계층이다.

책임:

- 인증
- device key 검증
- schema validation
- idempotency key 처리
- timestamp normalization
- event 저장
- MES entity 매핑
- 감사 로그
- 이상 데이터 quarantine

### Layer 5: MES Domain Binding

수집된 이벤트를 MES 도메인과 연결한다.

예시:

- 설비 가동 이벤트 → `EquipmentStateEvent`
- 생산 카운터 → `ProductionResultCandidate`
- 불량 신호 → `DefectCandidate`
- 온도/압력 → `ProcessParameterReading`
- 바코드 스캔 → `LotScanEvent`
- 저울 값 → `MaterialConsumptionCandidate`

중요 원칙:

수집 이벤트가 곧바로 생산실적이나 LOT 소비로 확정되면 안 된다. 초기에는 candidate로 저장하고, 작업지시/공정/작업자/LOT와 매칭한 후 확정한다.

## 표준 이벤트 스키마 초안

### 공통 필드

```json
{
  "event_id": "edge-uuid-or-ulid",
  "event_type": "equipment.state.changed",
  "source": {
    "site_code": "KR-PLANT-01",
    "line_code": "LINE-01",
    "equipment_code": "PRESS-01",
    "device_code": "EDGE-01"
  },
  "occurred_at": "2026-06-13T10:15:30+09:00",
  "received_at": "server-generated",
  "payload": {},
  "quality": {
    "confidence": 1.0,
    "raw_source": "opcua",
    "mapping_version": "v1"
  }
}
```

### 설비 상태 이벤트

```json
{
  "event_type": "equipment.state.changed",
  "payload": {
    "state": "running",
    "reason_code": null
  }
}
```

상태 후보:

- running
- idle
- stopped
- fault
- maintenance
- offline

### 생산 카운터 이벤트

```json
{
  "event_type": "production.counter.changed",
  "payload": {
    "counter_name": "good_count",
    "value": 128,
    "unit": "ea",
    "counter_mode": "cumulative"
  }
}
```

### 공정 파라미터 이벤트

```json
{
  "event_type": "process.parameter.recorded",
  "payload": {
    "parameter": "temperature",
    "value": 182.4,
    "unit": "celsius",
    "spec_min": 175,
    "spec_max": 190
  }
}
```

### LOT 스캔 이벤트

```json
{
  "event_type": "lot.scanned",
  "payload": {
    "barcode": "LOT-20260613-001",
    "scan_type": "material_input",
    "quantity": 25,
    "unit": "kg"
  }
}
```

## 오픈소스 IoT 도구 분석

| 도구 | 성격 | 라이선스/공개성 | 강점 | 약점 | Open MES Korea 활용 |
|---|---|---|---|---|---|
| Node-RED | flow-based integration | Apache-2.0 | OPC UA, MQTT, Modbus, HTTP 등 연결 예제가 많고 현장 PoC가 빠름 | flow 관리가 커지면 운영 통제가 어려움 | 공식 예제 connector 1순위 |
| ThingsBoard IoT Gateway | Python IoT gateway | Apache-2.0 계열로 공개 | MQTT, OPC-UA, Modbus connector, remote config, ThingsBoard 연동 | ThingsBoard 중심 구조가 될 수 있음 | gateway 예제와 MQTT/HTTP bridge 참고 |
| ThingsBoard | IoT platform | Community + PE | device management, telemetry, dashboard, rule chain | MES와 겹치는 기능이 많고 플랫폼이 큼 | 설비 telemetry 플랫폼으로 선택 연동 |
| Eclipse Kura | Java/OSGi edge framework | Eclipse Public License 2.0 | industrial gateway, device management, MQTT/cloud connector | Java/OSGi 복잡도, MES 개발자에게 무거움 | 대규모 edge gateway 참고 또는 고급 연동 |
| Libre | MES/performance monitoring | Apache-2.0 | Grafana/Influx/Postgres, downtime, OEE | 작업지시/LOT 중심 MES는 아님 | OEE/설비 모니터링 연동 참고 |
| Eclipse Mosquitto | MQTT broker | EPL/EDL | 가볍고 표준적 | broker일 뿐 business logic 없음 | 기본 MQTT broker 후보 |
| EMQX | MQTT broker/platform | 오픈소스 + enterprise | 대규모 MQTT, rule engine | 운영 복잡도 증가 | 규모 커질 때 선택 후보 |
| Telegraf | metric collector | MIT | 다양한 input/output plugin | MES 도메인 매핑은 별도 필요 | 설비 metric 수집 후보 |

## 프로토콜별 전략

| 프로토콜/방식 | 우선순위 | 전략 |
|---|---:|---|
| HTTP API | 1 | 가장 단순한 ingestion 경계. 모든 edge가 호출 가능 |
| MQTT | 1 | 설비/edge 이벤트 전송의 기본 transport |
| CSV/File drop | 1 | IoT 미설치 또는 레거시 설비 대응 |
| Barcode keyboard input | 1 | 별도 드라이버 없이 바로 사용 |
| OPC UA | 2 | Node-RED/ThingsBoard Gateway bridge부터 제공 |
| Modbus TCP/RTU | 2 | register map 템플릿과 edge connector 예제 제공 |
| Serial/RS-232 | 3 | 저울/계측기 대응, 현장별 plugin |
| PLC vendor protocol | 3 | Siemens S7, Mitsubishi MC 등은 connector plugin |
| Sparkplug B | 4 | MQTT 산업 표준 확장, 고도화 단계 |
| Direct PLC write | Later | 기본 금지. 승인/권한/안전 정책 이후 제한 허용 |

## MES core에 넣을 것과 넣지 않을 것

### Core에 넣을 것

- device registry
- edge connector registry
- ingestion API
- MQTT topic schema
- event validation
- event quarantine
- device-to-MES mapping
- equipment state event
- production counter candidate
- lot scan event
- process parameter reading
- audit log
- AI context for equipment/process events

### Core에 넣지 않을 것

- 모든 PLC 드라이버
- 벤더별 register map
- 설비 제어 command write
- SCADA 화면 전체
- 고주파 time-series 전체 분석
- 고객사별 설비 프로그램
- 폐쇄형 SDK 의존 코드

## 보안 원칙

IoT 연결부는 OT와 IT 경계에 있으므로 보안을 기본 설계로 둔다.

| 위험 | 대응 |
|---|---|
| 설비망 직접 노출 | edge connector가 outbound로 MES에 전송 |
| 임의 데이터 주입 | device key, mTLS 또는 signed payload |
| 중복 이벤트 | idempotency key와 event_id |
| 시간 오류 | occurred_at/received_at 분리 |
| 잘못된 생산실적 확정 | candidate 저장 후 MES context와 매칭 |
| PLC 오동작 | direct write 기본 금지 |
| 비밀 유출 | register map, 인증서, API key는 비공개 |
| AI 오판 | AI는 read-only 분석과 승인 요청까지만 |

## AI native와 IoT의 연결

IoT 데이터는 AI에 매우 유용하지만, 그대로 AI에 던지면 위험하다.

AI가 읽을 수 있는 것은 정제된 context여야 한다.

예시:

- 최근 24시간 설비 상태 요약
- 작업지시별 실제 cycle time
- 공정 파라미터 spec out 후보
- 불량 발생 전후의 설비 이벤트
- LOT별 온도/압력 이력 요약

AI가 직접 하면 안 되는 것:

- PLC 값 쓰기
- 설비 시작/정지
- 생산실적 확정
- LOT 소비 확정
- 품질 판정 확정

AI가 할 수 있는 것:

- 이상 후보 제안
- 원인 후보 설명
- 확인할 LOT/공정/설비 목록 제안
- 작업자에게 확인 질문 생성
- 승인 요청 초안 생성

## 오픈소스로 했을 때 이점

### 1. 설비 연결 노하우가 쌓인다

국내 공장은 장비 구성이 매우 다양하다. 오픈소스로 connector 예제와 mapping template을 공개하면 업종별 노하우가 축적된다.

예:

- 사출기 shot counter
- 저울 계량값
- 온습도 기록계
- 비전 검사 OK/NG
- 포장 라인 카운터
- CNC 가동 상태

### 2. 벤더 종속이 줄어든다

설비 연결은 특정 SI나 장비 업체에 묶이기 쉽다. 오픈소스 schema와 connector SDK가 있으면 고객사는 최소한 데이터 경계를 이해하고 유지보수할 수 있다.

### 3. 보안 검증이 가능하다

OT/IT 연결은 보안상 민감하다. 오픈소스는 인증, 권한, 로깅, command 금지 정책을 외부에서 검토할 수 있다.

### 4. AI 데이터 품질이 좋아진다

AI는 깨끗한 event schema와 timestamp, mapping 정보가 있어야 의미 있는 분석을 한다. 오픈소스 표준 schema는 여러 공장에서 반복적으로 개선될 수 있다.

### 5. 교육과 확산이 쉽다

Node-RED, MQTT, Docker Compose 기반 예제는 교육용으로 좋다. 대학, 연구소, 스마트공장 공급기업이 쉽게 PoC를 만들 수 있다.

## 라이선스 주의점

IoT 연결부는 외부 라이브러리와 장비 SDK를 많이 쓰므로 라이선스 검토가 필수다.

권장:

- core: AGPL-3.0 또는 Apache-2.0 중 프로젝트 전략에 맞춰 선택
- connector examples: Apache-2.0 선호
- schema/docs: CC BY 4.0 또는 repo 라이선스와 동일
- closed vendor SDK wrapper: 별도 plugin으로 분리

주의:

- GPL/AGPL 라이브러리를 proprietary connector와 섞으면 배포 조건이 복잡해질 수 있다.
- 장비 vendor SDK는 재배포 금지가 많다.
- 고객사 register map은 소스가 아니라 고객 설정/비밀로 취급해야 한다.

## 권장 구현 순서

### Phase 1: 수동/바코드 기반

- 바코드 keyboard input
- CSV import
- 수동 생산실적 입력
- LOT scan event

### Phase 2: 표준 ingestion

- `POST /iot/events`
- device registry
- event schema validation
- idempotency
- event quarantine
- production counter candidate

### Phase 3: MQTT

- Mosquitto 기반 docker compose 예제
- topic schema
- MQTT subscriber worker
- retained message 금지/허용 정책
- reconnect/retry 문서

### Phase 4: Node-RED bridge

- OPC UA → MQTT 예제
- Modbus → HTTP 예제
- barcode/scale → HTTP 예제
- sample flows 공개

### Phase 5: 설비/공정 분석

- equipment state timeline
- downtime reason
- cycle time
- OEE 후보
- AI anomaly candidate

### Phase 6: 고급 edge

- ThingsBoard Gateway 연동
- Eclipse Kura 연동
- Sparkplug B
- TimescaleDB/InfluxDB 선택 저장소

## 첫 번째 MVP API 초안

```http
POST /api/iot/events
Authorization: Bearer <device-token>
Idempotency-Key: <event-id>
Content-Type: application/json
```

```json
{
  "event_id": "01JZEDGE8W9R7A2H5J7F4",
  "event_type": "production.counter.changed",
  "source": {
    "site_code": "MAIN",
    "line_code": "LINE-01",
    "equipment_code": "PRESS-01",
    "device_code": "EDGE-01"
  },
  "occurred_at": "2026-06-13T10:15:30+09:00",
  "payload": {
    "counter_name": "good_count",
    "value": 128,
    "unit": "ea",
    "counter_mode": "cumulative"
  }
}
```

응답:

```json
{
  "accepted": true,
  "event_id": "01JZEDGE8W9R7A2H5J7F4",
  "status": "queued",
  "mapping_status": "pending"
}
```

## 결론

IoT 연결부는 오픈소스로 가는 것이 맞다. 하지만 MES core가 모든 설비 프로토콜을 직접 품으면 프로젝트가 무거워지고 실패 가능성이 커진다.

Open MES Korea의 올바른 전략은 다음이다.

```text
Core는 안정적인 MES event hub
Edge는 오픈소스 connector 생태계
설비별 차이는 mapping/config/plugin
생산 확정은 MES context와 승인 규칙
AI는 read-only 분석과 승인 요청
```

이렇게 하면 한국 제조 현장의 다양한 설비를 받아들이면서도, 프로젝트의 핵심인 현장 실행, LOT 추적, AI context/approval layer를 흐리지 않을 수 있다.

## 참고 자료

- [Node-RED OPC UA to MQTT guide](https://flowfuse.com/blog/2024/08/opc-ua-to-mqtt-with-node-red/)
- [Eclipse Kura](https://eclipse.dev/kura/)
- [Eclipse Kura GitHub repositories](https://github.com/orgs/eclipse-kura/repositories)
- [ThingsBoard open-source IoT platform](https://thingsboard.io/)
- [ThingsBoard IoT Gateway GitHub](https://github.com/thingsboard/thingsboard-gateway)
- [ThingsBoard IoT Gateway OPC-UA docs](https://thingsboard.io/docs/iot-gateway/config/opc-ua/)
- [ThingsBoard Edge](https://thingsboard.io/products/thingsboard-edge/)
- [Libre GitHub](https://github.com/Spruik/Libre)

