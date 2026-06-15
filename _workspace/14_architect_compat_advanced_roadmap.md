# 14. Architect 설계: (A)이종 외부 도구 호환성/연동 계층 + (B)제조 고도화 기능 모듈군 통합 로드맵

- **작성자**: architect
- **작성일**: 2026-06-13
- **대상**:
  - (A) 이종 외부 프로그램 호환성/연동 계층 아키텍처 — 디지털 트윈/시뮬레이션/CAE/IoT/MES·ERP 연동 생태계
  - (B) 제조 고도화 기능 모듈군 7개의 확장 카탈로그 등록 + 연계 아키텍처
  - 1차 타깃 업종: **사출 성형(injection molding)** — 온도/압력/속도/냉각시간/금형
- **기술 스택 (확정)**: Phoenix(Elixir) + Ecto + PostgreSQL + Broadway + TimescaleDB + MinIO/S3 + Phoenix LiveView (기존 EXT-1/2/레지스트리 스택 그대로)
- **참고 문서**: CLAUDE.md, docs/extension-roadmap.md, `_workspace/04(EXT-1)`, `_workspace/05(EXT-2)`, `_workspace/09(레지스트리/카탈로그)`, docs/domain-model.md
- **수신자**: domain-engineer(후속 구현), qa-auditor(검토)
- **목표(pi)**: **지금은 카탈로그 등록 + 연동 아키텍처 골격까지.** 7개 모듈/연동 어댑터의 전체 구현은 후속. 기존 EXT-1/2/코어/레지스트리를 최대한 재활용하고, 새로 만들 최소만 식별한다. 선제 추상화 금지.

---

## 0. 설계 원칙 (이 설계가 지켜야 하는 불변 규칙)

1. **코어 비침투 단방향 의존**: 모든 연동 어댑터·고도화 모듈은 별도 네임스페이스로 격리. 의존 방향은 **확장 → 코어**만. 코어(`lib/open_mes/`)는 어떤 어댑터/모듈에도 의존하지 않는다(어댑터를 전부 들어내도 코어는 동작).
2. **behaviour 계약으로만 코어에 닿는다**: 기존 3대 확장 경계 패턴을 그대로 승계 — `DomainSink`(EXT-1, 텔레메트리→도메인 신호), `ObjectStore`(EXT-2, 바이너리 저장 추상화), `MediaSink`(EXT-2, 저장 후처리/EXT-3 연계). 연동 계층은 여기에 **`SourceAdapter`(외부→내부 수집)** 와 **`ExportTarget`(내부→외부 제공)** 두 계약을 추가한다(아래 §1.1).
3. **데이터 확보 우선**: 어떤 외부 도구든 **일단 받아들이는 것**이 최우선. 정교한 양방향 동기화·실시간 트윈은 후순위. "가장 편한 확보 도구"(파일/CSV/HTTP push)부터 채택하고 정교한 프로토콜은 필요가 실증되면 교체.
4. **데이터 성격별 저장 분리 승계**(extension-roadmap 표): 도메인 트랜잭션→PostgreSQL(AuditLog 필수) / 고빈도 시계열 스칼라→TimescaleDB hypertable(AuditLog 불필요) / 대용량 바이너리→object storage + 메타데이터 / 대규모 분석→ClickHouse(후순위).
5. **등록 = 카탈로그 노출, 활성 = `enabled?/0`**: 모든 신규 모듈/어댑터는 `Extension` behaviour 메타데이터 모듈 1개를 가지고 config `:extensions` 리스트에 등록된다. config on/off로 코어 영향 0.
6. **AuditLog 경계 승계**: 고빈도 텔레메트리(설비/금형 센서)는 hypertable append-only가 이력성 보장 → 건건 AuditLog 비대상. **도메인 트랜잭션(생산계획 확정, 구매발주, 최적조건 승인, 불량 원인 기록)은 AuditLog 필수.** 이 경계가 (B) 모듈 분류의 핵심 기준이다.
7. **새 코어 엔티티는 "최소"에 한해 코어로, 나머지는 확장 테이블로**: 생산계획/MRP처럼 도메인 트랜잭션성이 강하고 LOT/WorkOrder와 직접 결합하는 것은 **코어 인접 엔티티군**, 금형·성형조건처럼 업종 특화인 것은 **업종 플러그인 확장 테이블**로 분리(§3).
8. MVP 범위 준수, 과설계 금지. 한국어 우선(주석/UI/에러), 영문 식별자.

---

## (A) 이종 외부 도구 호환성 / 연동 계층 아키텍처

### A.1 표준 연동 인터페이스 — 두 개의 새 behaviour 계약

연동은 본질적으로 **방향**이 있다. 데이터가 **밖에서 안으로**(수집) 오는가, **안에서 밖으로**(제공/export) 가는가. 기존 EXT-1의 `DomainSink`, EXT-2의 `ObjectStore`/`MediaSink`와 **일관**되게, 코어는 어댑터에 의존하지 않고 어댑터가 계약을 구현하는 방향으로 둔다.

```text
                       ┌─────────────── 코어(불변) ───────────────┐
                       │  PostgreSQL · WorkOrder · LOT · Outbox    │
                       │  TimescaleDB(EXT-1) · ObjectStore(EXT-2)  │
                       └───────────────────────────────────────────┘
                            ▲ (수집: 어댑터→코어/EXT)        │ (제공: 코어 읽기→어댑터)
   외부 →  SourceAdapter ──┘                                └──▶ ExportTarget  → 외부
   (OPC-UA/MQTT/CSV/REST/                                       (CSV/JSON/Parquet/
    Webhook/트윈 스트림)                                          REST push/dataset)
```

#### `SourceAdapter` behaviour (외부 → 내부 수집) — 신규

위치: `lib/open_mes_connect/source/source_adapter.ex` (신규 격리 네임스페이스 `OpenMes.Connect`)

```elixir
defmodule OpenMes.Connect.Source.SourceAdapter do
  @moduledoc """
  외부 이종 도구/프로토콜에서 데이터를 받아 내부 정규 형식으로 변환하는 어댑터 계약.

  핵심: 어댑터는 외부 포맷을 '내부 정규 measurement/이벤트 맵'으로 변환만 한다.
  적재는 어댑터가 직접 하지 않고, 기존 EXT-1 수집 경로(Ingest.push/1) 또는
  코어 Outbox로 흘려보낸다. 즉 어댑터는 '번역기'이지 '저장소'가 아니다(데이터 확보 우선).
  """

  @doc "어댑터 식별/메타(프로토콜, 방향). 카탈로그 노출용."
  @callback info() :: %{protocol: atom(), direction: :inbound, name: String.t()}

  @doc """
  외부 raw 입력(파일 경로/프로토콜 페이로드/스트림 청크)을 받아
  내부 정규 measurement row 리스트로 변환. EXT-1 Validator 가 받을 수 있는 형식.
  """
  @callback to_measurements(raw :: term()) :: {:ok, [map()]} | {:error, term()}
end
```

> **재활용 핵심**: `SourceAdapter`가 만든 정규 measurement는 **EXT-1의 `OpenMes.Ingest.push/1` → Broadway → Validator → TimescaleDB** 경로를 그대로 탄다. 새 적재 파이프라인을 만들지 않는다. 어댑터는 "외부 포맷 → EXT-1 입력 포맷" 번역만 담당. (CSV 어댑터든 OPC-UA 어댑터든 동일.)

#### `ExportTarget` behaviour (내부 → 외부 제공) — 신규

위치: `lib/open_mes_connect/export/export_target.ex`

```elixir
defmodule OpenMes.Connect.Export.ExportTarget do
  @moduledoc """
  내부 데이터(시계열/도메인 집계)를 외부 도구가 읽을 수 있는 형식으로 내보내는 계약.
  시뮬레이션/트윈/CAE 도구가 소비할 dataset export, MES/ERP push 등.

  코어 데이터는 '읽기'만 한다(애드온 규칙 승계). 쓰기/도메인 변경 없음.
  """

  @callback info() :: %{format: atom(), direction: :outbound, name: String.t()}

  @doc "쿼리/기간/설비 필터를 받아 외부 포맷 산출물(파일 경로/스트림/HTTP push 결과) 생성."
  @callback export(query :: map()) :: {:ok, term()} | {:error, term()}
end
```

> **재활용 핵심**: export 대상 데이터는 코어 컨텍스트 공개 조회 함수 + EXT-1 hypertable 읽기 쿼리로 충분. 새 저장소 없음. 애드온 ①(WO CSV export)이 이미 이 패턴의 최소 사례 — `ExportTarget`은 그 일반화다.

### A.2 데이터 교환 방식 분류 + 우선순위

| 분류 | 방식 | 대표 외부 도구 | 방향 | 기반 재활용 | 우선순위 |
|------|------|---------------|------|-----------|---------|
| (b) **파일 기반** | CSV/Excel watch·업로드 | 레거시 설비, 수기 데이터, Python 데이터셋 | inbound/outbound | EXT-2 NAS watch + EXT-1 push + ExportTarget | **MVP-1 (최우선)** |
| (c) **REST/Webhook** | HTTP pull/push | 삼성SDS Nexplant, ERP, 외부 MES | 양방향 | 코어 `/api` + ExportTarget + Outbox | **MVP-1** |
| (a) **표준 산업 프로토콜** | OPC-UA, MQTT | PLC, OPC 서버, IoT 게이트웨이 | inbound | SourceAdapter → EXT-1 push | **MVP-2** |
| (d) **디지털 트윈 동기화** | 센서 스트림 ↔ 가상모델 | AWS IoT TwinMaker, Azure Digital Twins | 양방향(우선 outbound) | EXT-1 텔레메트리 재활용 + ExportTarget | **후순위-1** |
| (e) **시뮬레이션 데이터셋 export** | 도구별 dataset 포맷 | Python(에뮬), Plant Sim, Arena, AnyLogic, DELMIA | outbound | ExportTarget(Parquet/CSV/JSON) | **후순위-1** |
| (f) **CAE 해석 입력/결과** | 해석 입력셋 / 결과 import | ANSYS/Simcenter, Simufact | 양방향(배치) | ExportTarget + SourceAdapter(결과 import) | **후순위-2** |

**우선순위 근거 (데이터 확보 우선 원칙)**:

- **MVP-1 = 파일(CSV/Excel) + REST/Webhook**: "가장 편한 확보 도구". 레거시 사출 설비/수기 데이터를 **지금 당장** 받아들일 수 있다. CSV 어댑터는 EXT-2 NAS watch(파일 감시) + EXT-1 push(적재)를 조립만 하면 된다 — 새 인프라 0. Nexplant 등 MES/ERP는 REST가 표준 접점.
- **MVP-2 = OPC-UA/MQTT**: 실시간성이 필요한 PLC/설비. SourceAdapter로 EXT-1 경로에 합류. 단 OPC-UA 클라이언트 라이브러리(Elixir 생태계 빈약 → 사이드카/브리지 가능성) 검토가 필요해 MVP-1보다 뒤.
- **후순위 = 트윈 동기화/시뮬레이션 export/CAE**: **양방향·정교한 동기화는 데이터 확보 우선 원칙상 후순위**. 단 트윈 "센서→가상모델" 한 방향(outbound export)은 EXT-1 텔레메트리를 그대로 흘리면 되므로 비교적 일찍 가능. 가상모델→실설비 역방향 제어는 안전성 검토가 커서 가장 뒤.

### A.3 연동 어댑터 카탈로그 등록 (EXT-5 연동 계층)

연동 계층 전체를 **EXT-5(연동 허브)** 로 카탈로그에 단일 등록하되, 내부에 어댑터를 둔다. 어댑터 하나하나를 개별 Extension으로 쪼개지 않는다(YAGNI — 카탈로그 카드 폭증 방지). EXT-5는 `category: :integration`(신규 카테고리) 카드 1개로 노출되고, 화면에서 "활성 어댑터 목록"을 보여준다.

```text
lib/open_mes_connect/                      # EXT-5 격리 네임스페이스 (신규)
├── connect.ex                             # 퍼사드: enabled?/0, 활성 어댑터 목록
├── extension.ex                           # OpenMes.Connect.Extension (behaviour 메타데이터, 카탈로그 카드)
├── source/
│   ├── source_adapter.ex                  # behaviour 계약 (A.1)
│   ├── csv_file_adapter.ex                # (b) CSV/Excel → measurements  [MVP-1]
│   ├── rest_pull_adapter.ex               # (c) 외부 REST pull → measurements/events  [MVP-1]
│   ├── opcua_adapter.ex                   # (a) OPC-UA → measurements  [MVP-2, 스켈레톤]
│   └── mqtt_adapter.ex                    # (a) MQTT → measurements  [MVP-2, 스켈레톤]
└── export/
    ├── export_target.ex                   # behaviour 계약 (A.1)
    ├── csv_export_target.ex               # (b/e) CSV/Parquet dataset  [MVP-1]
    ├── rest_push_target.ex                # (c) MES/ERP push (Nexplant 등)  [MVP-1, 스켈레톤]
    └── twin_stream_target.ex             # (d) 트윈 동기화 outbound  [후순위, 스켈레톤]
```

- **코어/EXT 접점**: `CsvFileAdapter`는 EXT-2의 watch + EXT-1의 `Ingest.push/1`를 호출(둘 다 기존). `RestPushTarget`은 코어 Outbox 이벤트를 구독해 외부로 push(도메인 이벤트 연계 — `OutboxSink` 패턴 일반화). 코어는 EXT-5를 모른다.
- **MVP 구현 깊이**: MVP-1 어댑터(CSV inbound/outbound, REST)는 실동작, MVP-2/후순위는 **behaviour 구현 스켈레톤 + 카탈로그 등록만**(EXT-1의 `OutboxSink` 스켈레톤 처리 방식 승계).
- **인증**: inbound는 EXT-1의 `RequireDeviceToken` 재활용. outbound(ERP push)는 대상별 토큰을 config로.

---

## (B) 제조 고도화 기능 모듈 카탈로그 등록 — EXT 번호 배정

현재 EXT-1~4 + 애드온 5개 + 레지스트리가 존재. 7개 고도화 기능에 **EXT-5~12** 를 이어서 배정한다(EXT-5는 위 연동 허브, EXT-6~12가 7개 기능). 사용자 비전의 #3(설비 실시간 수집)은 EXT-1 특화이므로 새 번호 대신 **EXT-1의 사출 프로파일**로 처리한다.

### B.1 EXT 번호 배정표

| 사용자 비전 # | 기능 | EXT 번호 | 기반(재활용) | 새 코어 엔티티 | 읽기/쓰기 | 저장 계층 | 우선순위 |
|:---:|------|:---:|------|:---:|:---:|------|:---:|
| (A) | **연동 허브**(이종 도구 호환) | **EXT-5** | EXT-1 push, EXT-2 watch, Outbox | 없음 | 양방향 | 기존 계층 경유 | MVP-1 |
| 3 | 설비 데이터 실시간 수집(사출 특화) | **EXT-1 프로파일** | EXT-1 그대로 | 없음 | 쓰기(텔레메트리) | TimescaleDB | **이미 완료** |
| 4 | 금형 온도 모니터링 + 이상 알림 | **EXT-6** | EXT-1 + 알림 + LiveView | 없음(metric_key 활용) | 읽기+알림 | TimescaleDB 읽기 | MVP-2 |
| 5 | 생산 이력·품질 추적(조건↔LOT↔불량) | **EXT-7** | 코어 LOT/불량 + EXT-1 join | 없음(읽기 조인) | 읽기 | PostgreSQL+TimescaleDB | MVP-2 |
| 6 | 최적 성형 조건 관리 | **EXT-8** | EXT-7 분석 + EXT-3 계열 | **MoldingConditionProfile**(확장 테이블) | 읽기+쓰기(승인) | PostgreSQL(AuditLog) | 후순위-1 |
| 7 | 통합 모니터링(DID/PC/모바일) | **EXT-9** | EXT-4 + LiveView | 없음 | 읽기(실시간) | 전 계층 읽기 | MVP-2 |
| 1 | 생산계획 자동화 | **EXT-10** | 코어 WorkOrder + Outbox | **ProductionPlan, DemandForecast** | 읽기+쓰기 | PostgreSQL(AuditLog) | 후순위-1 |
| 2 | 자재·구매 관리(MRP) | **EXT-11** | 코어 BOM/LOT + EXT-10 | **MaterialRequirement, PurchaseOrder** | 읽기+쓰기 | PostgreSQL(AuditLog) | 후순위-2 |
| 6의 예지보전 축 | 예지보전 | **EXT-3**(기존) | EXT-1/2 시계열 | 없음 | 읽기+제안 | TimescaleDB 읽기 | 후순위-1 |

> **금형 마스터(`Mold`)** 는 EXT-6/EXT-8이 공유하는 업종 특화 엔티티 → §3의 업종 플러그인(`OpenMes.Injection`)에 둔다. EXT-12는 **업종 플러그인(사출) 자체**에 배정(§3.4).

### B.2 각 모듈 명세

#### EXT-1 프로파일: 설비 데이터 실시간 수집 — 사출 성형 특화 (이미 완료, 프로파일만 추가)

- **재활용**: EXT-1 파이프라인 **무변경**. 사출 성형 특화는 **데이터(metric_key 표준 사전)** 로만 표현 — 코드 변경 없음. 이것이 핵심 설계 결정(데이터로 업종 표현, 스키마는 일반).
- **사출 표준 metric_key 사전**(어댑터/디바이스가 보내는 약속): `barrel_temp_zone{n}`(배럴 온도대), `nozzle_temp`, `injection_pressure`, `holding_pressure`(보압), `injection_speed`, `injection_velocity`, `cooling_time`, `cycle_time`, `mold_temp_core`/`mold_temp_cavity`(금형 코어/캐비티 온도), `clamp_force`(형체력), `cushion`(쿠션량), `screw_position`. 단위: `degC`/`bar`/`mm/s`/`s`/`kN`.
- **저장**: 기존 `equipment_measurements` hypertable 그대로. `meta`에 `mold_id`/`cavity_no`/`shot_no` 등 사출 컨텍스트 보존.
- **쓰기/AuditLog**: 텔레메트리 → AuditLog 비대상(§0-6 경계). 정상.
- **새 엔티티**: 0. **새 코드**: metric_key 표준 문서 1장(데이터 계약)만.

#### EXT-6: 금형 온도 모니터링 + 이상 알림

| 항목 | 내용 |
|------|------|
| **목적** | 금형 코어/캐비티 온도 실시간 감시 + 임계 이탈 시 알림 |
| **기반(재활용)** | EXT-1 `equipment_measurements`(`mold_temp_*` metric) 읽기 + EXT-1 `DomainSink`(임계 초과 → Outbox) + LiveView 실시간 화면 |
| **새 코어 엔티티** | 없음. 임계 규칙은 config/업종 플러그인 `Mold`의 `temp_min/temp_max` 필드 참조(§3) |
| **읽기/쓰기** | 읽기(텔레메트리 조회) + **알림 발행**(도메인 신호) |
| **저장** | TimescaleDB 읽기. 알림 이벤트는 코어 Outbox(`equipment.threshold_breached` 정식 등록 후) |
| **AuditLog** | 텔레메트리 읽기는 무관. **임계치 설정 변경**은 도메인 트랜잭션 → AuditLog 필수 |
| **사출 특화점** | 금형 코어/캐비티 온도 편차(불균일 = 성형 불량 직결), 온도 안정화 시간 |
| **구현 깊이(MVP)** | EXT-1 `OutboxSink`를 `MoldTempSink`로 교체(임계 규칙) + LiveView 1 + 알림(우선 화면 배지/이메일). SMS/모바일 push는 EXT-9와 통합 |
| **우선순위** | MVP-2 (EXT-1 위에 바로 올림) |

> **선결 조건**: EXT-1 §8.4에서 미정인 `equipment.threshold_breached` 이벤트를 docs/system-architecture.md 이벤트 목록에 **정식 등록**해야 OutboxSink 활성 가능. 임계 규칙(어느 metric이 몇이면 알림)은 사용자/금형별 정의 필요.

#### EXT-7: 생산 이력·품질 추적 (설비조건 ↔ LOT ↔ 불량 연결, 원인 추적)

| 항목 | 내용 |
|------|------|
| **목적** | "이 LOT는 어떤 성형조건에서 만들어졌고 왜 불량인가"를 추적 |
| **기반(재활용)** | 코어 `MaterialLot`/`LotConsumption`/`ProductionResult`/`DefectRecord`(읽기) + EXT-1 `equipment_measurements`(시간·설비·work_order_id로 join) |
| **새 코어 엔티티** | **없음**(읽기 조인 분석). 코어 LOT Genealogy + 텔레메트리를 **시간창 join**으로 연결 |
| **읽기/쓰기** | **읽기 전용**(분석/추적 뷰). 코어 데이터 변경 0 |
| **저장** | PostgreSQL(LOT/불량) + TimescaleDB(조건) 교차 읽기 |
| **AuditLog** | 읽기 전용 → 신규 AuditLog 대상 없음(애드온 규칙 승계) |
| **사출 특화점** | 불량(쇼트, 플래시, 싱크마크 등)을 **그 LOT 생산 시점의 온도/압력/냉각시간 시계열**과 연결 |
| **연결 키** | `equipment_measurements.work_order_id` ↔ 코어 WorkOrder, `meta.shot_no`/`mold_id` ↔ LOT 생산 Operation 시간창 |
| **구현 깊이(MVP)** | 읽기 조인 쿼리 모듈 + 추적 LiveView 1(LOT 검색 → 그 LOT의 조건 시계열 + 불량 표시) |
| **우선순위** | MVP-2 |

> **핵심 가치**: 이 모듈이 (B)의 중심. LOT Genealogy(코어 불변식)와 설비 텔레메트리(EXT-1)를 **읽기 조인**으로 잇는다 — 새 쓰기·새 엔티티 없이 이력성 원칙 위에서 추적 가능. `work_order_id`를 텔레메트리에 보존해둔 EXT-1 설계가 여기서 보상된다.

#### EXT-8: 최적 성형 조건 관리

| 항목 | 내용 |
|------|------|
| **목적** | 양품 이력 분석 → 제품/금형별 최적 성형조건 도출·제시·승인 |
| **기반(재활용)** | EXT-7(조건↔LOT↔불량 데이터) + EXT-3 예지보전 계열(분석) + AI 승인 흐름(Level 2 의사결정 지원) |
| **새 코어 엔티티** | **`MoldingConditionProfile`(업종 플러그인 확장 테이블, 코어 아님)** — 제품/금형별 최적 조건 세트 |
| **읽기/쓰기** | 읽기(이력 분석) + **쓰기(조건 프로파일 승인·확정 = 도메인 트랜잭션)** |
| **저장** | PostgreSQL(프로파일, **AuditLog 필수**). 분석 입력은 EXT-7 읽기 |
| **AuditLog** | **필수**. 최적조건 제안→검토→승인→확정은 상태머신 + AuditLog. AI 제안 시 AiInteraction 기록 |
| **사출 특화점** | 온도/압력/속도/보압/냉각시간/쿠션의 조합을 "양품률 최대" 기준으로 도출. 금형별 |
| **AI 경계** | AI는 `propose_molding_condition`만 가능(쓰기 직접 금지). 승인은 사람. 근거(양품 이력) 함께 표시 |
| **구현 깊이(MVP)** | **분석은 후순위**. MVP는 `MoldingConditionProfile` 스키마 + 수동 등록/승인 흐름(상태머신 proposed→approved) + AuditLog. 자동 도출은 EXT-3 분석 엔진과 함께 후속 |
| **우선순위** | 후순위-1 |

> **분리 결정**: 자동 조건 도출(분석)과 조건 프로파일 관리(트랜잭션)를 분리. 트랜잭션(승인·이력·AuditLog)을 먼저, 분석(AI/통계)은 EXT-3 위에 후속. 새 엔티티 `MoldingConditionProfile`은 **코어가 아니라 업종 플러그인**(§3) — 일반 MES엔 성형조건 개념이 없으므로.

#### EXT-9: 통합 모니터링 (현장 DID / 사무실 PC / 관리자 모바일)

| 항목 | 내용 |
|------|------|
| **목적** | 동일 데이터를 3개 표면(현장 대형 DID, 사무실 PC, 관리자 모바일)에 맞춰 표시 |
| **기반(재활용)** | EXT-4(생산관리 고도화 대시보드) + 애드온(OEE/일일요약/불량통계) + LiveView + PubSub |
| **새 코어 엔티티** | 없음 |
| **읽기/쓰기** | 읽기(실시간 집계) |
| **저장** | 전 계층 읽기. 실시간 갱신은 Phoenix PubSub(Outbox 이벤트 구독) |
| **AuditLog** | 읽기 전용 → 무관 |
| **사출 특화점** | DID에 금형 온도/사이클타임/양품률 현황, 모바일에 알림(EXT-6 임계 이벤트) |
| **구현 깊이(MVP)** | 표면별 LiveView 레이아웃 3종(반응형 분기로 시작 — 별도 앱 금지, pi). 기존 애드온 위젯 조합 |
| **우선순위** | MVP-2 (애드온/EXT-4 위에 레이아웃 레이어) |

> **결정**: 3개 표면을 별도 앱으로 만들지 않는다. LiveView 반응형 + 표면별 레이아웃/밀도 분기. 모바일 push는 EXT-6 알림과 공유(이메일/웹push 우선, 네이티브 앱 후순위).

#### EXT-10: 생산계획 자동화

| 항목 | 내용 |
|------|------|
| **목적** | 주문/수요예측 → 생산계획 자동 수립, 변경 대응 → WorkOrder 생성 연계 |
| **기반(재활용)** | 코어 `WorkOrder`(계획→작업지시) + Outbox + 연동(EXT-5로 주문/포캐스트 유입) |
| **새 코어 엔티티** | **`ProductionPlan`, `DemandForecast`(코어 인접 엔티티군)** — WorkOrder의 상류. 도메인 트랜잭션성 강함 |
| **읽기/쓰기** | 읽기+**쓰기(계획 수립/확정 = 도메인 트랜잭션, WorkOrder 발행)** |
| **저장** | PostgreSQL, **AuditLog 필수**. 계획→확정→WO발행 상태머신 |
| **AuditLog** | **필수**. 계획 변경 이력은 정정 이력으로 보존(이력성 원칙). Outbox: `production_plan.confirmed`, `work_order.released`(기존) |
| **사출 특화점** | 금형 가용성(동시 사용 불가)·교체시간을 계획 제약으로(후속). MVP는 일반 계획 |
| **AI 경계** | AI는 `propose_production_plan`/`suggest_plan_adjustment`만. 확정은 사람 |
| **구현 깊이(MVP)** | `ProductionPlan` 스키마 + 수동 계획→WO 발행 흐름 + AuditLog + Outbox. 자동 수립(MRP 역전개·포캐스트)은 EXT-11/AI와 후속 |
| **우선순위** | 후순위-1 |

> **코어 인접 결정**: `ProductionPlan`/`DemandForecast`는 WorkOrder와 직접 결합(계획→작업지시)하고 도메인 트랜잭션성이 강해 **업종 무관**이다. 따라서 업종 플러그인이 아니라 **코어 인접 확장 엔티티군**(`lib/open_mes_planning/`, 코어 컨벤션 binary_id + AuditLog + Outbox 그대로)으로 둔다. 단 코어 13개 엔티티에 즉시 합치지 않고 **확장 테이블 + 코어 패턴 준수**로 시작(검증 후 코어 승격 가능).

#### EXT-11: 자재·구매 관리 (MRP)

| 항목 | 내용 |
|------|------|
| **목적** | BOM 역전개로 소요량 산출(MRP) → 구매계획/발주 자동 연결 |
| **기반(재활용)** | 코어 `BillOfMaterial`/`MaterialLot`/`Item`(읽기) + EXT-10 계획(소요량 입력) + EXT-5(ERP 발주 push) |
| **새 코어 엔티티** | **`MaterialRequirement`(소요량), `PurchaseOrder`(구매발주)** — 코어 인접 엔티티군 |
| **읽기/쓰기** | 읽기(BOM/재고)+**쓰기(소요 산출/발주 = 도메인 트랜잭션)** |
| **저장** | PostgreSQL, **AuditLog 필수**(발주는 책임 추적 핵심) |
| **AuditLog** | **필수**. 발주 생성/변경/취소 전건. Outbox: `purchase_order.created` 등(정식 등록 필요) |
| **사출 특화점** | 원료(수지) 로트·건조조건, 마스터배치(색소) 배합비. MVP는 일반 BOM 기준 |
| **구현 깊이(MVP)** | **MRP 엔진은 후순위.** MVP는 `PurchaseOrder` 스키마 + 수동 발주 + AuditLog. BOM 역전개 자동 MRP는 EXT-10 확정 후 |
| **우선순위** | 후순위-2 (EXT-10 의존) |

> **코어 인접 결정**: EXT-10과 동일 — 도메인 트랜잭션성·업종 무관 → `lib/open_mes_procurement/`, 코어 패턴 준수. EXT-10에 의존하므로 그 뒤.

#### EXT-3 (기존): 예지보전 — 재확인

- 변경 없음. EXT-8(최적 조건 자동 도출)의 분석 엔진을 EXT-3와 공유. EXT-1/2 시계열·멀티미디어 입력 → 이상 점수/정비·조건 권고 → AI 승인 흐름. 후순위-1.

---

## (3) 업종 특화 메모 — 사출 성형 업종 플러그인

### 3.1 문제: 업종 특화를 코어에 섞으면 안 된다

사출 성형이 1차 타깃이지만, Open MES Korea는 **일반 MES 코어**다. 금형(`Mold`)·성형조건(`MoldingConditionProfile`)·사출 metric은 **사출 업종에만 의미**가 있다. 이걸 코어 13개 엔티티에 넣으면 다른 업종(가공·조립·식품)에 사용할 때 사역(死域) 필드가 된다. → **업종 특화는 플러그인 확장으로 분리.**

### 3.2 분리 기준 (이 설계의 핵심 판단)

| 성격 | 위치 | 예 |
|------|------|---|
| 모든 제조업 공통, 도메인 트랜잭션 | **코어** 또는 **코어 인접 확장** | WorkOrder, LOT, 생산계획(EXT-10), 구매(EXT-11) |
| 고빈도 측정값(업종 무관 스키마, 업종은 metric_key로) | **EXT-1 hypertable** | 온도/압력 — `metric_key`만 사출용 |
| **업종 전용 마스터/개념** | **업종 플러그인 확장** | 금형(`Mold`), 성형조건(`MoldingConditionProfile`) |

> **결정**: "스키마는 일반, 업종은 데이터로"가 1순위(EXT-1이 metric_key로 사출을 표현하듯). **데이터로 표현 불가능한 업종 전용 개념(금형이라는 물리 자산 마스터, 성형조건 세트)만** 업종 플러그인 테이블로 만든다.

### 3.3 업종 플러그인 구조 (EXT-12)

```text
lib/open_mes_injection/                    # 사출 성형 업종 플러그인 (EXT-12)
├── injection.ex                           # 퍼사드 enabled?/0
├── extension.ex                           # 카탈로그 카드 (category: :industry)
├── mold.ex                                # Mold 스키마: mold_code, item_id, cavity_count,
│                                          #   temp_min/temp_max(코어/캐비티), max_shots, status
├── mold_lifecycle.ex                      # 금형 수명/유지보수(shot 카운트 — EXT-1 shot_no 집계)
├── molding_condition_profile.ex          # 제품/금형별 최적조건(EXT-8이 사용)
└── live/
    └── mold_dashboard_live.ex             # 금형 현황 화면
```

- `Mold`·`MoldingConditionProfile`은 **AuditLog 필수**(도메인 마스터 변경 추적). PK `binary_id`, 코어 패턴 준수.
- EXT-6(금형 온도)·EXT-8(최적조건)은 이 플러그인의 `Mold`/조건을 **읽어** 동작. 즉 업종 플러그인이 업종 마스터를 제공하고, 기능 모듈(EXT-6/8)이 그 위에 기능을 얹는다.
- **다른 업종 추가 시**: `open_mes_machining`(절삭)·`open_mes_assembly`(조립) 등 동일 패턴으로 병렬 추가. 코어/EXT-1~11은 무변경. 이것이 업종 플러그인 개념의 목적.

### 3.4 업종 플러그인 ↔ 기능 모듈 의존 그래프

```text
  코어(WorkOrder/LOT/불량/계획EXT-10/구매EXT-11)   ← 업종 무관
        ▲ 읽기                    ▲ 읽기
  EXT-12 사출 플러그인(Mold/조건)  │
   (업종 마스터)                   │
        ▲ 읽기            ┌────────┴────────┐
  EXT-6 금형온도   EXT-7 품질추적   EXT-8 최적조건   EXT-9 통합모니터링
   (Mold 읽기)    (LOT+EXT-1 join) (Mold+EXT-7+EXT-3) (전부 집계)
        ▲                                  ▲
  EXT-1 텔레메트리(metric_key=사출) ────────┘  EXT-3 예지보전(분석)

  EXT-5 연동허브 ── 외부도구 ↔ (EXT-1 push / Outbox / ExportTarget)
```

---

## (4) domain-engineer 구현 지침 (후속 — 카탈로그 등록 우선)

### 4.1 지금 할 것 (이번 범위, pi)

1. **카탈로그 등록만**: EXT-5~12 + EXT-12 각각의 `Extension` 메타데이터 모듈(`use OpenMes.Extensions.Definition`) 작성 + config `:extensions` 리스트 추가 + `enabled: false` 기본. → 카탈로그에 카드로 노출(레지스트리 §9 그대로).
2. **신규 카테고리 2종 추가**: `Extension.category`에 `:integration`(연동), `:industry`(업종)를 추가(타입 union 확장 1줄). 기존 카탈로그 필터가 자동 수용.
3. **두 behaviour 계약 정의만**: `SourceAdapter`, `ExportTarget`(@callback만). 구현체는 MVP-1만 실동작, 나머지 스켈레톤.
4. **데이터 계약 문서 1장**: 사출 표준 metric_key 사전(EXT-1 프로파일).

### 4.2 후속 구현 순서 (우선순위대로)

```text
[MVP-1] EXT-5 연동허브: CSV inbound(EXT-2 watch+EXT-1 push 조립) / CSV·REST export(ExportTarget)
[MVP-2] EXT-6 금형온도(EXT-1 OutboxSink 교체 + 임계 이벤트 정식등록) →
        EXT-7 품질추적(읽기 조인) → EXT-9 통합모니터링(애드온 조합) → EXT-12 사출플러그인(Mold)
[후순위-1] EXT-8 최적조건(MoldingConditionProfile + 승인 상태머신 + AuditLog) →
          EXT-10 생산계획(ProductionPlan + AuditLog + Outbox) → EXT-3 예지보전 분석
[후순위-2] EXT-11 MRP/구매(EXT-10 의존) → EXT-5 OPC-UA/MQTT/트윈/CAE 어댑터 실구현
```

### 4.3 qa-auditor 검증 대비 (경계 명시)

- ✅ **(정상)** EXT-5 어댑터가 만든 텔레메트리는 EXT-1 경로로 적재 → AuditLog 없음(EXT-1 경계 승계). 누락 아님.
- ✅ **(정상)** EXT-6/7/9는 읽기 위주 → 신규 AuditLog 대상 없음(애드온 규칙). 단 EXT-6 **임계치 설정 변경**은 쓰기 → AuditLog 필요.
- ⛔ **(검증)** EXT-8/10/11은 **도메인 트랜잭션 → AuditLog + 상태머신 + Outbox 필수**. 여기서 누락은 결함.
- ⛔ **(검증)** 코어 비침투: `lib/open_mes/` 변경은 `application.ex`/`router.ex` 배선 + `Extension.category` union 1줄 외 금지.
- ⛔ **(검증)** 의존 단방향: 코어가 `OpenMes.Connect.*`/`OpenMes.Injection.*` 참조 금지.
- ⛔ **(검증)** AI 경계: EXT-8/10의 AI는 `propose_*`만, 쓰기 직접 금지, AiInteraction 기록, 근거 표시.

### 4.4 사용자 확인 필요

1. `equipment.threshold_breached` 등 신규 Outbox 이벤트의 docs/system-architecture.md 정식 등록(EXT-6/10/11 선결).
2. `ProductionPlan`/`PurchaseOrder` 등 코어 인접 엔티티를 **확장 테이블로 시작 vs 코어 13개에 즉시 합류** — 본 설계는 확장 테이블 시작 권고.
3. OPC-UA Elixir 클라이언트 부재 시 사이드카(브리지) 허용 여부.
4. 사출 1차 업종 확정 시 다른 업종 플러그인 동시 골격 필요 여부(현재는 사출만).
