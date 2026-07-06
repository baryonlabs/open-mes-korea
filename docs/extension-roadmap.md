# 확장 모듈 로드맵

Open MES Korea는 **최소 코어 + 확장 모듈** 구조를 따른다 (pi 원칙). 코어(PostgreSQL + outbox + 13개 도메인 엔티티)는 아래 확장 없이도 완전히 동작한다. 각 확장은 독립적으로 켜고 끌 수 있다.

## 데이터 확보 우선 원칙

> **데이터를 확보하기 위한 가장 편한 도구가 우선한다.**

완벽한 분석 파이프라인보다, 데이터를 쉽고 빠르게 모으는 것이 먼저다. 이유:

- 분석·모델은 나중에 바꿀 수 있지만, **수집하지 못한 데이터는 영원히 잃는다.**
- 현장 설비/디바이스가 데이터를 보내는 경로는 단순할수록 채택률이 높다.
- 따라서 수집 계층은 **인프라 의존 최소(브로커리스 HTTP push 우선)**, 외부 브로커(Kafka/MQTT)는 처리량이 실제로 필요해질 때 producer 교체로 전환한다.

데이터 성격별 저장 전략:

| 데이터 성격 | 예시 | 저장 계층 |
|-----------|------|---------|
| 도메인 트랜잭션 | 작업지시, 실적, LOT | PostgreSQL (코어, AuditLog 필수) |
| 고빈도 시계열 스칼라 | 소음 dB, 진동, 온도, 전류 | TimescaleDB hypertable (append-only, AuditLog 불필요) |
| 대용량 바이너리 | 소음 원음, 설비 영상, 이미지 | Object Storage(MinIO/S3) + 메타데이터 인덱스 |
| 대규모 분석/집계 | 장기 추세, 교차 분석 | ClickHouse (후순위) |

## 확장 모듈 카탈로그

### EXT-1: 설비 데이터 수집 (Broadway Ingest) — 설계 완료

브로커리스 HTTP push → Broadway 검증·변환 → TimescaleDB 적재. 고빈도 스칼라 텔레메트리 대상.
- 설계: `_workspace/04_architect_ingest_design.md`
- 구현: `_workspace/06_domain_engineer_ingest_impl/`
- 상태: ✅ 구현+검증 완료 (APPROVED). Phoenix 앱 통합 대기

### EXT-2: 멀티미디어 데이터 수집 (소음/영상)

소음 원음·설비 영상·이미지 등 대용량 바이너리 확보. EXT-1과 수집 경로(HTTP push)는 공유하되 저장은 object storage로 분기.
- 원본 → MinIO/S3 (object storage)
- 메타데이터(설비, 촬영시각, 길이, 추출 특징, 이상 점수) → PostgreSQL/hypertable
- 추출 스칼라 특징(소음 dB, 주파수 피크) → EXT-1의 equipment_measurements로 합류
- 수집 방식 확정: **NAS 공유폴더 watch** (디바이스 무수정, 데이터 확보 최우선)
- 설계: `_workspace/05_architect_media_ingest_design.md`
- 구현: `_workspace/07_domain_engineer_media_impl/`
- 상태: ✅ 구현+검증 완료 (APPROVED, W-1 해시 순서 수정 포함). Phoenix 앱 통합 대기

### EXT-3: 예지보전 (Predictive Maintenance)

EXT-1/EXT-2가 확보한 시계열·멀티미디어 데이터를 기반으로 설비 이상 징후 탐지·정비 시점 예측.
- 입력: equipment_measurements, 멀티미디어 추출 특징
- 출력: 이상 점수, 정비 권고 후보 → AI 승인 흐름(Level 2 의사결정 지원)으로 연계
- 코어 연계: behaviour 계약(DomainSink) 또는 outbox 경유 (직접 침투 금지)
- 상태: 미설계 (생각해둠)

### EXT-4: 생산관리 고도화

기본 생산관리(작업지시/실적)는 코어. 확장은 실시간 모니터링·집계·대시보드.
- 실시간 대시보드: Phoenix LiveView
- 설비 가동률(OEE), 실시간 생산 현황 집계
- 상태: 미설계 (생각해둠)

## (A) 이종 외부 도구 호환성 / 연동 계층 — EXT-5 연동 허브

디지털 트윈·시뮬레이션·CAE·IoT·MES/ERP 등 **이종 외부 프로그램을 받아들이는(우선)·내보내는** 연동 계층. 어댑터 하나하나를 개별 확장으로 쪼개지 않고 **EXT-5(연동 허브, `category: :integration`)** 카드 1개로 카탈로그에 등록하며, 내부에 방향별 어댑터를 둔다. 설계: `_workspace/14_architect_compat_advanced_roadmap.md`.

**표준 연동 인터페이스(behaviour)** — 기존 `DomainSink`(EXT-1)/`ObjectStore`·`MediaSink`(EXT-2)와 일관:
- `SourceAdapter`(외부→내부): 외부 포맷을 EXT-1 입력(measurement)으로 **번역만**. 적재는 기존 `Ingest.push/1`(EXT-1) 경로 재사용. 새 파이프라인 0.
- `ExportTarget`(내부→외부): 코어/EXT-1 데이터를 **읽기만** 해서 외부 포맷으로 export. 애드온① WO CSV export의 일반화.

**데이터 교환 방식 분류 + 우선순위** (데이터 확보 우선 — "일단 받아들이기"가 정교한 양방향 동기화보다 먼저):

| 분류 | 방식 | 대표 외부 도구 | 방향 | 기반 재활용 | 우선순위 |
|------|------|---------------|------|-----------|---------|
| (b) 파일 기반 | CSV/Excel watch·업로드 | 레거시 설비, Python 데이터셋 | 양방향 | EXT-2 watch + EXT-1 push + ExportTarget | **MVP-1** |
| (c) REST/Webhook | HTTP pull/push | 삼성SDS Nexplant, ERP, 외부 MES | 양방향 | 코어 `/api` + ExportTarget + Outbox | **MVP-1** |
| (a) 산업 프로토콜 | OPC-UA, MQTT | PLC, OPC 서버, IoT GW | inbound | SourceAdapter → EXT-1 | MVP-2 |
| (d) 디지털 트윈 | 센서↔가상모델 동기화 | AWS IoT TwinMaker, Azure Digital Twins | 양방향(우선 out) | EXT-1 텔레메트리 + ExportTarget | 후순위-1 |
| (e) 시뮬레이션 export | dataset 포맷 | Python·Plant Sim·Arena·AnyLogic·DELMIA | outbound | ExportTarget(CSV/Parquet/JSON) | 후순위-1 |
| (f) CAE 해석 | 입력셋/결과 import | ANSYS·Simcenter·Simufact | 양방향(배치) | ExportTarget + SourceAdapter | 후순위-2 |

- 네임스페이스: `lib/open_mes_connect/`(격리). 코어는 EXT-5 미참조(단방향).
- MVP 구현 깊이: MVP-1(CSV/REST)만 실동작, MVP-2/후순위는 behaviour 스켈레톤 + 카탈로그 등록.
- 상태: 설계 완료, 카탈로그 등록 대상. 구현 후속.

## (B) 제조 고도화 기능 모듈군 — EXT-6~12 (사출 성형 1차 타깃)

사용자 비전 7개 기능을 확장 모듈로 분류, EXT 번호 배정. **기존 EXT-1/2/코어/애드온 최대 재활용, 새 엔티티는 최소만 식별.**

| 비전# | 모듈 | EXT | 기반(재활용) | 새 엔티티 | 읽기/쓰기 | AuditLog | 우선순위 |
|:---:|------|:---:|------|------|:---:|:---:|:---:|
| 3 | 설비 실시간 수집(사출 특화) | **EXT-1 프로파일** | EXT-1 그대로 | 0 | 텔레메트리 | 비대상 | ✅완료 |
| 4 | 금형 온도 모니터링+알림 | **EXT-6** | EXT-1+OutboxSink+LiveView | 0 | 읽기+알림 | 임계설정만 | MVP-2 |
| 5 | 생산이력·품질추적(조건↔LOT↔불량) | **EXT-7** | 코어 LOT/불량 + EXT-1 join | 0(읽기조인) | 읽기 | 무관 | MVP-2 |
| 7 | 통합 모니터링(DID/PC/모바일) | **EXT-9** | EXT-4 + 애드온 + LiveView/PubSub | 0 | 읽기 | 무관 | MVP-2 |
| 6 | 최적 성형조건 관리 | **EXT-8** | EXT-7 + EXT-3 + AI승인 | MoldingConditionProfile(업종) | 읽기+쓰기 | **필수** | 후순위-1 |
| 1 | 생산계획 자동화 | **EXT-10** | 코어 WorkOrder + Outbox | ProductionPlan, DemandForecast(코어인접) | 읽기+쓰기 | **필수** | 후순위-1 |
| 2 | 자재·구매 관리(MRP) | **EXT-11** | 코어 BOM/LOT + EXT-10 | MaterialRequirement, PurchaseOrder(코어인접) | 읽기+쓰기 | **필수** | 후순위-2 |
| - | 예지보전 | **EXT-3**(기존) | EXT-1/2 시계열 | 0 | 읽기+제안 | 무관 | 후순위-1 |

- **EXT-12 사출 성형 업종 플러그인**(`category: :industry`, `lib/open_mes_injection/`): 금형(`Mold`)·성형조건 등 **업종 전용 마스터**를 제공. EXT-6/8이 이를 읽어 동작. "스키마는 일반, 업종은 데이터(metric_key)로" 1순위, 데이터로 표현 불가능한 업종 개념(금형 물리 자산)만 플러그인 테이블. 다른 업종은 `open_mes_machining` 등 동일 패턴 병렬 추가.
- **저장 분리 원칙 적용**: EXT-6/7/9는 시계열·LOT **읽기 조인**(새 쓰기 0) / EXT-8/10/11은 **도메인 트랜잭션**(PostgreSQL + AuditLog + 상태머신 + Outbox 필수).
- **AI 경계**: EXT-8/10은 `propose_*`만(쓰기 직접 금지), 근거 표시, AiInteraction 기록.
- 선결: `equipment.threshold_breached` 등 신규 Outbox 이벤트의 system-architecture.md 정식 등록(EXT-6/10/11).
- 상태: 설계 완료, 카탈로그 등록 대상. 구현 후속. 설계: `_workspace/14_architect_compat_advanced_roadmap.md`.

## 확장 레지스트리 + 홈페이지 카탈로그 — 구현 완료

모든 확장이 공통 `Extension` behaviour(id/name/description/category/version/enabled?/home_path/icon)를 구현하고, config 명시 목록(`config :open_mes, :extensions`)으로 레지스트리에 등록된다. 홈페이지 LiveView 카탈로그가 등록된 확장을 카드로 자동 렌더(활성/비활성 배지, 카테고리 필터, 화면 링크).
- 구현: `_workspace/10_registry_catalog_impl/` (✅ APPROVED)
- 레지스트리는 얇은 코어 유틸, 상태 없음(DB/GenServer/ETS 0). 코어 도메인은 레지스트리 미참조(단방향).

### 디커플링 — 별도 repo 확장이 코어 0수정으로 결합 (구현 완료)

확장 시스템을 별도 저장소 확장이 **deps 한 줄로** 붙도록 디커플링했다(설계 `_workspace/30`, qa `_workspace/31` APPROVED). 계약을 독립 패키지 **`open_mes_extension_api`**(path dep, Phoenix 미의존: `Extension` behaviour + Definition + Registry + Discovery + RouterMount)로 추출하고, `OpenMes.Extension.*` 네임스페이스로 정리(구 `OpenMes.Extensions.*` 는 호환 shim).

- **라우트**: 코어 router.ex의 하드코딩 if 블록을 `mount_extension_routes()` 단일 컴파일타임 매크로로 교체. 확장은 `route_spec/0`(순수 데이터)로 라우트 선언 — 외부 확장이 코어/자기 Router 모듈을 건드리지 않는다.
- **category**: 닫힌 union → `atom()` 개방, `known_categories/0`는 라벨/필터용(검증 게이트 아님).
- **발견**: 명시 목록 → 자동 발견(`:auto` 기본, `extra_extensions`/`exclude_extensions`/`:manual` escape hatch, `mix ext.list` 가시화). 메타데이터는 런타임 발견, 라우트는 컴파일타임 확정.
- **검증**: ext.verify C7을 `module_info(:compile)[:source]` 기반(외부 dep 대응)으로, C8(route_spec 형태) 신규.
- 코어 도메인은 확장 시스템 미참조 단방향 유지. 외부 repo 확장 가이드: `docs/extension-development.md §10`. 레퍼런스 외부 확장: `open_mes_ext_demo/`.

## 작은 도메인 애드온 (모두 읽기 전용, 새 테이블 0) — 구현 완료

| # | 애드온 | 카테고리 | 입력 | 구현 |
|---|--------|---------|------|------|
| ① | 작업지시 CSV 내보내기 | production | WorkOrder | `_workspace/11_addon_wo_csv_export/` ✅ |
| ② | 불량 통계 위젯 | quality | DefectRecord, ProductionResult | `_workspace/11_addon_defect_stats/` ✅ |
| ③ | LOT QR 라벨 생성 | traceability | MaterialLot | `_workspace/11_addon_lot_qr_label/` ✅ |
| ④ | 설비 가동률 OEE | analytics | ProductionResult, Operation, Routing | `_workspace/11_addon_equipment_oee/` ✅ |
| ⑤ | 일일 생산 요약 | production | WorkOrder, ProductionResult, Item | `_workspace/11_addon_daily_summary/` ✅ |

5개 전부 qa-auditor APPROVED. 읽기 전용(쓰기/AuditLog 0), 코어 비침투, config on/off, 카탈로그 자동 노출. 통합 가이드: `_workspace/10_registry_catalog_impl/README.md`.

## 기술 스택 확장 (필요 시점에만 도입)

| 도구 | 용도 | 도입 시점 |
|------|------|---------|
| Broadway | 대량 이벤트 수집·백프레셔 | EXT-1 |
| TimescaleDB | 시계열 스칼라 | EXT-1 (Docker 이미지 교체 필요) |
| MinIO/S3 | 대용량 바이너리 | EXT-2 |
| Kafka/MQTT | 외부 브로커 (처리량 실증 후) | EXT-1 producer 교체 / EXT-5 MQTT 어댑터 |
| ClickHouse | 대규모 분석 | EXT-3/4 후순위 |
| OPC-UA 클라이언트/브리지 | 산업 프로토콜 수집 | EXT-5 MVP-2 (Elixir 부재 시 사이드카) |
| Parquet/dataset export | 시뮬레이션·트윈 데이터셋 제공 | EXT-5 후순위 (ExportTarget) |

> **카탈로그 카테고리**: 기존 `:ingest/:media/:production/:quality/:traceability/:analytics`에 **`:integration`(연동 허브 EXT-5), `:industry`(업종 플러그인 EXT-12)** 2종 추가. `Extension.category` union 1줄 확장으로 기존 카탈로그 필터가 자동 수용.

## 원칙 재확인

- 확장은 코어에 침투하지 않는다 (config on/off, behaviour 계약).
- "가장 편한 데이터 확보 도구"를 먼저 채택하고, 정교한 도구는 필요가 실증되면 교체한다.
- 각 확장은 독립 구현·검증한다 (mes-build 하네스 팀).
