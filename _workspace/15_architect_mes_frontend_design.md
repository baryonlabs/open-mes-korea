# 15. Architect 설계: MES 운영 프론트엔드 + 코어 도메인 엔티티

- **작성자**: architect
- **작성일**: 2026-06-13
- **대상**: 미구현 코어 엔티티 11개 + MES 운영 LiveView 프론트엔드 + 정보구조(IA) + 병렬 구현 분해
- **기술 스택 (확정)**: Phoenix(Elixir) + Ecto + LiveView + PostgreSQL/TimescaleDB
- **참고**: docs/domain-model.md, docs/mvp-scope.md, docs/system-architecture.md, CLAUDE.md, `_workspace/01_architect_workorder_design.md`, 실제 코어 코드(`lib/open_mes/production/`, `lib/open_mes/audit/`, `lib/open_mes/outbox/`), 애드온 읽기 스키마(`lib/open_mes_addons/`)
- **수신자**: 하네스 팀(domain-engineer 다수 — 메뉴 그룹별 병렬), qa-auditor

---

## 0. 설계 원칙 요약 (불변 규칙 — WorkOrder 패턴 그대로 승계)

WorkOrder 코어 코드를 정독해 확정한 **실제 컨벤션**을 전 엔티티에 동일 적용한다.

1. **PK는 binary_id(UUID)**: `@primary_key {:id, :binary_id, autogenerate: true}` + `@foreign_key_type :binary_id`, `timestamps(type: :utc_datetime_usec)`.
2. **모든 도메인 쓰기는 단일 `Ecto.Multi`로 AuditLog 동반**: `OpenMes.Audit.put_log/3` 를 Multi에 끼워 넣는다. 컨트롤러/LiveView는 절대 AuditLog를 직접 만들지 않는다.
3. **상태 머신은 순수 함수 모듈 + 전용 transition_changeset**: `can_transition?/2`, `allowed_from/1`, `statuses/0`. 일반 update changeset은 status 캐스트 제외. 동일 상태(no-op) 전이는 진입부에서 거부.
4. **Outbox는 동일 트랜잭션**: `OpenMes.Outbox.put_event/3`. 단 **문서(CLAUDE.md L79 / system-architecture.md)에 명시된 이벤트만 발행**한다. 문서에 없는 이벤트는 임의 추가 금지.
5. **모든 쓰기에 actor_id 필수**: 컨텍스트 함수 시그니처에 `actor_id`를 명시 인자로. LiveView는 세션 actor를 컨텍스트에 전달.
6. **이력성**: ProductionResult / DefectRecord / LotConsumption은 **append-only**(수정·삭제 미제공, 정정은 새 레코드). 기준정보(Item/Process/BOM/Routing/Equipment/Worker)는 CRUD 허용하되 변경 시 AuditLog 필수.
7. **pi(최소 구현)**: CRUD는 단순하게. 외부 차트/JS 라이브러리 도입 금지(서버 집계 + CSS). 인증은 MVP 임시안만. 미정의 이벤트·소프트삭제·권한 매트릭스 등 과설계 금지.
8. **비침투/계약 일치**: 애드온이 이미 읽고 있는 테이블·컬럼명을 **정확히** 맞춘다(§7 — 500 해결의 핵심). 코어 마이그레이션이 그 테이블을 만들면 애드온이 자동 동작한다.
9. **한국어 UI / 영문 식별자**: 화면 텍스트·주석·에러메시지 한국어, 엔티티·필드·모듈은 영문.

---

## 1. 코어 도메인 엔티티 설계 (미구현 11개)

### 1.1 컨텍스트(바운디드 컨텍스트) 분할

| 컨텍스트 모듈 | 책임 엔티티 | 비고 |
|--------------|------------|------|
| `OpenMes.MasterData` | Item, BillOfMaterial, Process, Routing, Equipment, Worker | 기준정보. CRUD + AuditLog. |
| `OpenMes.Production` | WorkOrder(기존), **Operation**, **ProductionResult**, **DefectRecord** | 생산 실행. 기존 모듈 확장. |
| `OpenMes.Lots` | MaterialLot, LotConsumption | LOT 추적/genealogy. |
| `OpenMes.Audit` / `OpenMes.Outbox` | (기존) | 공용. 그대로 사용. |

> Worker / Equipment는 domain-model.md 본문엔 엔티티 정의가 없으나 ProductionResult가 `worker_id`/`equipment_id`를 참조하고 mvp-scope "설비 관리·작업자 관리"가 필수다. 애드온(OEE)도 `equipment_id`로 그룹화한다. 따라서 **기준정보 엔티티로 신설**하되 필드는 최소(코드/이름/활성)로 둔다. → §8 사용자 확인 항목.

### 1.2 엔티티 의존성 그래프 (마이그레이션/구현 순서의 근거)

```
[기준정보 — 의존 없음 먼저]
  Item ──┬─> BillOfMaterial (parent_item_id, child_item_id → Item)
         ├─> Routing (item_id → Item, process_id → Process)
         └─> MaterialLot (item_id → Item)
  Process ─> Routing (process_id)
  Equipment (독립)
  Worker (독립)

[생산 실행 — 기준정보 위에]
  WorkOrder (item_id → Item)            ← 기존 구현, FK 보강 대상
    └─> Operation (work_order_id, process_id → Process)
          └─> ProductionResult (operation_id, worker_id → Worker, equipment_id → Equipment)
                └─> DefectRecord (production_result_id)

[LOT — 생산 실행과 교차]
  MaterialLot (item_id → Item)
    └─> LotConsumption (operation_id → Operation, input_lot_id → MaterialLot)
  Operation ─(produced lot)─> MaterialLot.source_operation_id  ← genealogy 연결
```

**FK 부재 회피 규칙**: WorkOrder가 그랬듯, 참조 대상 테이블이 같은 라운드에 없으면 FK 없이 컬럼만 만들고 후속 보강 마이그레이션으로 FK를 추가한다. 단 본 설계는 **기준정보를 라운드1에서 먼저 만들므로**, Operation·ProductionResult 등은 FK를 바로 걸 수 있다(라운드2). WorkOrder→Item FK는 라운드1 기준정보 완성 후 보강.

### 1.3 엔티티별 스키마/마이그레이션 명세

각 표의 컬럼명은 **애드온 읽기 스키마와 1:1 일치**(§7 계약)시켰다. 추가 컬럼은 애드온이 모르는 것이므로 안전하게 더할 수 있으나, **기존 컬럼명은 절대 변경 금지**.

#### (1) `items` — Item (기준정보, CRUD+AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| item_code | string | NOT NULL, **UNIQUE** |
| name | string | NOT NULL |
| item_type | string | NOT NULL, CHECK IN (`raw`,`semi`,`product`) — 원자재/반제품/제품 |
| unit | string | NOT NULL (예: EA, kg) |
| active | boolean | NOT NULL DEFAULT true |
| timestamps | utc_datetime_usec | |

인덱스: unique(item_code), index(item_type), index(active).
> 애드온 계약: `items(item_code,name,item_type,unit,active)` — defect_stats/daily_summary가 읽음.

#### (2) `bills_of_material` — BillOfMaterial (CRUD+AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| parent_item_id | binary_id | NOT NULL, FK→items |
| child_item_id | binary_id | NOT NULL, FK→items |
| quantity | decimal | NOT NULL, CHECK > 0 |
| loss_rate | decimal | NOT NULL DEFAULT 0, CHECK 0..1 |
| timestamps | | |

인덱스: index(parent_item_id), unique(parent_item_id, child_item_id) — 동일 부모-자식 중복 방지.
> 테이블명은 `bills_of_material`(복수 관용). 애드온 미참조 → 자유.

#### (3) `processes` — Process (CRUD+AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| process_code | string | NOT NULL, UNIQUE |
| name | string | NOT NULL |
| description | text | NULL |
| active | boolean | NOT NULL DEFAULT true |

인덱스: unique(process_code), index(active).

#### (4) `routings` — Routing (CRUD+AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| item_id | binary_id | NOT NULL, FK→items |
| process_id | binary_id | NOT NULL, FK→processes |
| sequence | integer | NOT NULL, CHECK > 0 |
| standard_cycle_time | decimal | NULL (초/개) |

인덱스: index(item_id), unique(item_id, sequence) — 품목 내 순서 유일.
> 애드온 계약(OEE): `routings(item_id,process_id,sequence,standard_cycle_time)`. **컬럼명 일치 필수.**

#### (5) `equipment` — Equipment (기준정보 신설, CRUD+AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| equipment_code | string | NOT NULL, UNIQUE |
| name | string | NOT NULL |
| active | boolean | NOT NULL DEFAULT true |

> 테이블명 `equipment`(불가산, 단수). ProductionResult.equipment_id가 참조. OEE 애드온은 production_results.equipment_id로 그룹화하므로 이 테이블 자체는 직접 안 읽지만 라벨용 조인 가능.

#### (6) `workers` — Worker (기준정보 신설, CRUD+AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| worker_code | string | NOT NULL, UNIQUE |
| name | string | NOT NULL |
| active | boolean | NOT NULL DEFAULT true |

#### (7) `operations` — Operation (상태머신, AuditLog+Outbox)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| work_order_id | binary_id | NOT NULL, FK→work_orders |
| process_id | binary_id | NOT NULL, FK→processes |
| sequence | integer | NOT NULL |
| status | string | NOT NULL DEFAULT `pending`, CHECK IN (6종) |
| started_at | utc_datetime_usec | NULL |
| completed_at | utc_datetime_usec | NULL |

인덱스: index(work_order_id), index(status), unique(work_order_id, sequence).
상태머신: `pending → ready → running → paused → completed/skipped` (§1.4).
> 애드온 계약: `operations(work_order_id,process_id,sequence,status,started_at,completed_at)` — daily_summary/OEE가 조인. **일치 필수.**

#### (8) `production_results` — ProductionResult (append-only, AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| operation_id | binary_id | NOT NULL, FK→operations |
| worker_id | binary_id | NULL, FK→workers |
| equipment_id | binary_id | NULL, FK→equipment |
| good_quantity | decimal | NOT NULL DEFAULT 0, CHECK >= 0 |
| defect_quantity | decimal | NOT NULL DEFAULT 0, CHECK >= 0 |
| started_at | utc_datetime_usec | NULL |
| ended_at | utc_datetime_usec | NULL |

인덱스: index(operation_id), index(equipment_id), index(ended_at).
**append-only**: update/delete 미제공. 정정은 새 음수/보정 레코드 또는 상위 정정 정책(MVP는 새 레코드 추가만).
> 애드온 계약(3개 애드온이 읽음): `production_results(operation_id,worker_id,equipment_id,good_quantity,defect_quantity,started_at,ended_at)`. **가장 중요한 일치 대상.**

#### (9) `defect_records` — DefectRecord (append-only, AuditLog)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| production_result_id | binary_id | NOT NULL, FK→production_results |
| defect_code | string | NOT NULL |
| quantity | decimal | NOT NULL, CHECK > 0 |
| note | text | NULL |

인덱스: index(production_result_id), index(defect_code).
> 애드온 계약(defect_stats): `defect_records(production_result_id,defect_code,quantity,note)`. **일치 필수.**

#### (10) `material_lots` — MaterialLot (상태머신, AuditLog+Outbox)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| lot_no | string | NOT NULL, UNIQUE |
| item_id | binary_id | NOT NULL, FK→items |
| lot_type | string | NOT NULL, CHECK IN (`raw`,`semi`,`product`) |
| quantity | decimal | NOT NULL, CHECK >= 0 |
| status | string | NOT NULL DEFAULT `available`, CHECK IN (6종) |
| source_operation_id | binary_id | NULL, FK→operations — **생산된 Operation 연결(genealogy)** |
| timestamps | | |

인덱스: unique(lot_no), index(item_id), index(status), index(source_operation_id).
상태머신: `available → reserved → consumed/produced/quarantined/scrapped` (§1.4).
> 애드온 계약(lot_qr_label): `material_lots(lot_no,item_id,lot_type,quantity,status)`. **컬럼명 일치 필수.** `source_operation_id`는 신규 추가 컬럼(애드온 무관, 안전).
> CLAUDE.md L74 "모든 LOT는 생산된 Operation과 연결" → `source_operation_id`로 구현. 원자재 LOT(외부 입고)은 NULL 허용.

#### (11) `lot_consumptions` — LotConsumption (append-only, AuditLog+Outbox)
| 필드 | 타입 | 제약 |
|------|------|------|
| id | binary_id | PK |
| operation_id | binary_id | NOT NULL, FK→operations |
| input_lot_id | binary_id | NOT NULL, FK→material_lots |
| quantity | decimal | NOT NULL, CHECK > 0 |
| timestamps | | |

인덱스: index(operation_id), index(input_lot_id).
**append-only**. LOT 투입은 이 테이블 경유만(암묵적 소비 금지, CLAUDE.md L73).
> 테이블명 `lot_consumptions`(애드온 미참조 → 자유). genealogy 조회: 제품LOT.source_operation_id → operation → lot_consumptions → input_lot.

### 1.4 상태 머신 (순수 함수 모듈 2종 — WorkOrderStateMachine와 동형)

**`OpenMes.Production.OperationStateMachine`**
```
pending     → ready, skipped
ready        → running, skipped
running      → paused, completed
paused       → running, completed
completed    → (종료)
skipped      → (종료)
```
- 타임스탬프: `running` 최초 진입 시 `started_at`, `completed` 시 `completed_at`.
- no-op 전이 거부(진입부), 종료 상태 재전이 차단 — WorkOrder 패턴 그대로.

**`OpenMes.Lots.MaterialLotStateMachine`**
```
available    → reserved, quarantined, scrapped
reserved     → consumed, available, quarantined
quarantined  → available, scrapped
produced     → available, reserved, quarantined   # 생산 직후 가용화/예약
consumed     → (종료)
scrapped     → (종료)
```
- `produced`는 생성 시 초기 상태가 될 수 있음(생산 LOT). `available`은 입고 원자재 초기 상태.
- 소비(consumed)는 LotConsumption 기록과 동반 — 컨텍스트에서 LotConsumption insert + MaterialLot 상태전이를 **단일 Multi**.

> 두 머신 모두 `@transitions` map + `can_transition?/2` + `allowed_from/1` + `statuses/0` 시그니처를 WorkOrderStateMachine와 동일하게. domain-engineer는 그 파일을 템플릿으로 복제.

### 1.5 Outbox 이벤트 매핑 (문서 정의분만 — 임의 추가 금지)

CLAUDE.md L79 / system-architecture.md 정의 이벤트와 컨텍스트 함수 연결:

| 컨텍스트 함수 | event_type | 발행 |
|--------------|-----------|------|
| `start_operation` (→running) | `operation.started` | ✅ |
| `complete_operation` (→completed) | `operation.completed` | ✅ |
| `consume_lot` | `material_lot.consumed` | ✅ |
| `produce_lot` | `material_lot.produced` | ✅ |
| `record_defect` | `defect.recorded` | ✅ |
| Operation ready/pause/skip | (문서 미정의) | ❌ 미발행 |
| Item/BOM/Process/Routing/Equipment/Worker CRUD | (이벤트 없음) | ❌ AuditLog만 |
| ProductionResult 생성 | (문서 미정의) | ❌ AuditLog만 |

> aggregate_type/aggregate_id/payload 구조는 WorkOrder release 구현(`production.ex` L141)을 템플릿으로. decimal은 `Decimal.to_string/1`로 직렬화.

### 1.6 AuditLog 대상 구분

| 분류 | 엔티티 | AuditLog |
|------|--------|----------|
| 생산/이력 데이터 | WorkOrder, Operation, ProductionResult, DefectRecord, MaterialLot, LotConsumption | **모든 쓰기 필수** (action: `operation.start`, `production_result.create`, `lot.consume` 등) |
| 기준정보 | Item, BOM, Process, Routing, Equipment, Worker | **변경(create/update/deactivate) 시 필수** (action: `item.create`, `item.update` 등). 조회는 없음. |

> 기준정보도 AuditLog 대상(CLAUDE.md L49 "모든 쓰기"). 단순 CRUD라도 Multi에 put_log를 끼운다. domain-engineer는 generic `MasterData.create/update/3` 헬퍼에 AuditLog를 내장해 반복 제거.

---

## 2. MES 프론트 정보구조(IA) + 네비게이션

### 2.1 영역 분리 (system-architecture.md "관리자 화면 / 현장 화면")

| 영역 | 경로 prefix | 레이아웃 | 대상 | UX |
|------|------------|---------|------|-----|
| **관리자 영역** | `/admin/...` | 사이드바 + 상단바(데스크탑) | 생산관리자/품질/자재/시스템관리자 | 표·폼·필터 중심 |
| **현장 영역** | `/shopfloor/...` | 큰 버튼 단일 컬럼(태블릿) | 현장 작업자 | 대형 터치 버튼·최소 입력·LOT 스캔 |
| **확장 카탈로그** | `/extensions`, `/` | 기존 CatalogLive(유지) | 전체 | 카드형 카탈로그 |

> 기존 `/` 와 `/extensions`(CatalogLive)는 **그대로 유지**. MES 운영은 `/admin`·`/shopfloor` 새 네임스페이스로 분리해 공존(충돌 0). 카탈로그 홈은 관리자 사이드바 "확장" 메뉴에서 `/extensions`로 링크.

### 2.2 관리자 메뉴 트리 (사이드바)

```
Open MES (상단바: 로고 · 현재 actor · 현장모드 전환 링크)
└ 관리자 (/admin)
   ├ 기준정보
   │   ├ 품목         /admin/items
   │   ├ BOM          /admin/boms
   │   ├ 공정         /admin/processes
   │   ├ 라우팅       /admin/routings
   │   ├ 설비         /admin/equipment
   │   └ 작업자       /admin/workers
   ├ 생산관리
   │   ├ 작업지시     /admin/work-orders            (목록/생성/상태전이)
   │   └ 공정 실적    /admin/work-orders/:id/operations  (Operation·실적 입력)
   ├ LOT 추적
   │   ├ 자재 LOT     /admin/lots
   │   └ LOT 계보     /admin/lots/:id/genealogy
   ├ 조회/대시보드
   │   ├ 생산 현황    /admin/dashboard
   │   ├ 공정별 실적  /admin/reports/production
   │   ├ 불량 현황    /admin/reports/defects
   │   └ 재고 흐름    /admin/reports/inventory
   ├ 관리자
   │   ├ 사용자/권한  /admin/users
   │   └ 감사 로그    /admin/audit-logs
   └ 확장            /extensions  (CatalogLive — 외부 링크)
```

### 2.3 현장 메뉴 트리 (대형 버튼)

```
현장 (/shopfloor)
   ├ 오늘 작업      /shopfloor                    (오늘 내 작업지시/Operation 목록)
   ├ 작업 상세      /shopfloor/operations/:id     (시작/일시정지/완료 큰 버튼)
   ├ 실적 입력      /shopfloor/operations/:id/result  (양품/불량 숫자패드)
   └ LOT 스캔       /shopfloor/scan               (QR/바코드 input → 투입 기록)
```

### 2.4 공통 레이아웃 모듈

- `OpenMesWeb.Layouts` 에 `:admin` / `:shopfloor` 레이아웃 추가(기존 `:root`/`:app` 유지).
- `OpenMesWeb.AdminComponents` — 사이드바, 페이지헤더, 데이터테이블, 폼필드, 상태배지, 페이지네이션(서버 집계, 외부 JS 0).
- `OpenMesWeb.ShopfloorComponents` — 대형버튼, 숫자패드, 스캔input.
- **인증 임시안(§2.5)**: `mount`에서 세션 actor 확인 → 없으면 간이 actor 선택 화면.

### 2.5 인증/권한 MVP 임시안 (과설계 금지)

- API는 기존 `X-Actor-Id` 헤더 + `RequireActor` plug **유지**.
- LiveView는 **세션 기반 간이 actor**: `/login`에서 worker_code/이름 입력 → 세션에 `actor_id` 저장. 비밀번호·역할 매트릭스 없음.
- `OpenMesWeb.Plugs.PutSessionActor`(browser 파이프라인) + `on_mount` 훅(`OpenMesWeb.LiveActor`)으로 LiveView socket에 `current_actor` 주입. 미설정이면 `/login` 리다이렉트.
- 권한: MVP는 영역 구분만(관리자/현장). 세밀한 RBAC는 후속. `/admin/users`는 worker 목록 + actor 전환 수준으로 단순.

---

## 3. 메뉴별 화면 명세 + 병렬 구현 분해

### 3.1 메뉴 그룹 분해표

| 그룹 | 라운드 | 담당 LiveView 화면 | 코어 엔티티(R=읽기/W=쓰기) | 의존(선행 그룹) | 병렬가능 |
|------|--------|-------------------|---------------------------|----------------|---------|
| **G0 코어 엔티티(기반)** | 1 | (화면 없음 — 스키마/마이그레이션/컨텍스트만) | 11개 전부 W | — | 단독 선행 |
| **G1 기준정보** | 1 | items/boms/processes/routings/equipment/workers Index·Form·Show | Item·BOM·Process·Routing·Equipment·Worker (W) | G0 | G2와 병렬 |
| **G2 생산관리** | 1 | WorkOrder Index/Form/Show, Operation 목록, 공정 실적 입력 | WorkOrder(W,기존), Operation(W), ProductionResult(W), DefectRecord(W), Item·Process(R) | G0 | G1과 병렬 |
| **G3 LOT 추적** | 2 | 자재 LOT Index/Form, LOT 계보 조회 | MaterialLot(W), LotConsumption(W), Operation(R), Item(R) | G0,G2(Operation) | G4·G5·G6과 병렬 |
| **G4 현장 화면** | 2 | 오늘작업, 작업상세(시작/정지/완료), 실적입력, LOT스캔 | Operation(W), ProductionResult(W), DefectRecord(W), LotConsumption(W), MaterialLot(R/W) | G0,G2,G3 | G5·G6과 병렬 |
| **G5 조회/대시보드** | 2 | 생산현황, 공정별실적, 불량현황, 재고흐름 | 전부 R(읽기 전용) | G0,G2,G3 | G3·G4·G6과 병렬 |
| **G6 관리자** | 2 | 사용자/권한, 감사로그 조회 | AuditLog(R), Worker(R/W) | G0 | G3·G4·G5과 병렬 |

### 3.2 그룹별 라우트/네임스페이스

| 그룹 | 모듈 네임스페이스 | 라우트 scope |
|------|------------------|-------------|
| G1 | `OpenMesWeb.Admin.MasterData.*Live` | `/admin/{items,boms,processes,routings,equipment,workers}` |
| G2 | `OpenMesWeb.Admin.Production.*Live` | `/admin/work-orders`, `/admin/work-orders/:id/operations` |
| G3 | `OpenMesWeb.Admin.Lots.*Live` | `/admin/lots`, `/admin/lots/:id/genealogy` |
| G4 | `OpenMesWeb.Shopfloor.*Live` | `/shopfloor/...` |
| G5 | `OpenMesWeb.Admin.Reports.*Live` | `/admin/dashboard`, `/admin/reports/*` |
| G6 | `OpenMesWeb.Admin.System.*Live` | `/admin/users`, `/admin/audit-logs` |

라우터는 기존 `router.ex`에 scope 추가만(애드온 `if enabled?` 게이트는 그대로). `:admin`/`:shopfloor` 파이프라인은 `:browser` + 세션 actor plug.

### 3.3 그룹별 화면 상세

- **G1 기준정보**: 각 엔티티마다 IndexLive(목록+검색+활성필터+페이지네이션), FormLive(생성/수정 — `live_action :new/:edit`), 필요시 ShowLive. BOM/Routing은 부모 엔티티(Item) 선택 + 하위 행 관리. 모두 컨텍스트 `MasterData.create_*/update_*/3`(AuditLog 내장) 호출. 삭제 대신 `active=false`(비활성화)로 — 이력 보존.
- **G2 생산관리**: WorkOrder는 기존 코어 API/컨텍스트 재사용(LiveView는 `Production.list_work_orders/1` 등 호출). 작업지시 상세에서 Operation 자동/수동 생성(Routing 기반 — 라우팅 순서대로 Operation 펼침). 공정 실적 입력 화면에서 ProductionResult + DefectRecord 등록(append-only).
- **G3 LOT 추적**: 원자재 LOT 등록(available), 생산 LOT 생성(produce_lot → produced, source_operation_id 연결), 투입 기록(consume_lot → LotConsumption + 상태전이). 계보 화면은 재귀 조회(제품LOT → operation → 투입 LOT → 그 LOT의 source_operation → ...).
- **G4 현장**: G2/G3 컨텍스트 함수 재사용, UI만 대형 버튼·숫자패드·스캔. 새 비즈니스 로직 없음(컨텍스트 호출 wrapper). LOT 스캔은 input 텍스트(하드웨어 스캐너=키보드 입력) → lot_no 조회 → consume.
- **G5 조회**: 읽기 전용 집계. 일부는 **기존 애드온과 중복** — 불량현황은 defect_stats 애드온 재사용 가능(또는 코어 리포트로 별도). 재고흐름은 MaterialLot 상태별 집계. 외부 차트 금지(CSS 막대 — defect_stats_live 패턴).
- **G6 관리자**: 감사로그는 `audit_logs` 읽기 전용 조회(resource_type/actor/기간 필터). 사용자/권한은 Worker 목록 + 간이 actor 관리.

---

## 4. 구현 순서 / 의존성

### 라운드 1 (기반 — 반드시 먼저, G0는 단독 선행)

1. **G0 코어 엔티티** (domain-engineer 1명 집중, 순서 = §1.2 그래프):
   1. 기준정보 마이그레이션+스키마+컨텍스트: items → processes → equipment → workers → bills_of_material(FK items) → routings(FK items,processes)
   2. WorkOrder→Item FK 보강 마이그레이션
   3. operations(FK work_orders,processes) + OperationStateMachine + 컨텍스트(start/complete/pause/skip/ready, Outbox: started/completed)
   4. production_results(FK operations,workers,equipment) + 컨텍스트(create, append-only, AuditLog)
   5. defect_records(FK production_results) + 컨텍스트(record_defect, Outbox: defect.recorded)
   6. material_lots(FK items, source_operation_id→operations) + MaterialLotStateMachine + 컨텍스트(produce/consume/reserve/quarantine/scrap, Outbox: consumed/produced)
   7. lot_consumptions(FK operations,material_lots) — consume_lot이 Multi로 LotConsumption insert + MaterialLot 전이
2. **G1 기준정보 + G2 생산관리** — G0 완료 후 **병렬**(서로 다른 테이블/화면, 충돌 없음). G2의 Operation 생성은 G1 Routing에 의존하나, Routing 없이도 수동 Operation 생성 경로를 두면 완전 병렬 가능.

→ **라운드1 종료 시점에 애드온 500이 전부 해소된다**(items/operations/production_results/defect_records/material_lots/routings 테이블 생성됨).

### 라운드 2 (병렬 4그룹)

- **G3 LOT / G4 현장 / G5 조회 / G6 관리자** 모두 병렬. 공유 컨텍스트(Lots/Production)는 라운드1에서 완성됐으므로 화면 충돌 없음. 라우터 scope만 각자 추가(merge 충돌은 라우터 한 파일 → 그룹별 PR 순차 머지 권장).

### 의존 요약

- 코어 엔티티(G0)가 **모든 메뉴의 전제**.
- Routing(G1) → Operation 자동 생성(G2) — 선택적.
- Operation(G2/G0) → LotConsumption·ProductionResult(G3/G4).
- 모든 조회(G5)·감사(G6)는 위 데이터가 쌓인 뒤 의미 있으나 구현 자체는 G0만 있으면 가능.

---

## 5. domain-engineer 전달 구현 지침 (요점)

1. **WorkOrder 코드를 템플릿으로 복제**: `work_order.ex`(changeset 3종 분리), `work_order_state_machine.ex`(@transitions map), `production.ex`(Multi+put_log+put_event+normalize_result)를 그대로 본떠 Operation/MaterialLot에 적용.
2. **AuditLog/Outbox는 컨텍스트 Multi 내부에서만**. LiveView/컨트롤러 금지.
3. **append-only 엔티티**(ProductionResult/DefectRecord/LotConsumption)는 컨텍스트에 update/delete 함수 자체를 만들지 않는다.
4. **테이블/컬럼명은 §7 계약 고정** — 오타 1자도 애드온 500 유발. 마이그레이션 작성 후 `mix compile` + 애드온 LiveView 수동 접속으로 회귀 확인.
5. **LiveView 컨벤션**: `use OpenMesWeb, :live_view`, 서버 집계, 외부 JS/차트 금지(defect_stats_live 패턴), 한국어 텍스트.
6. **MasterData 제네릭 헬퍼**: 6개 기준정보 CRUD 반복 → `MasterData.create(schema_mod, attrs, actor, audit_action)` 공통 함수로 AuditLog 내장(pi: 단, 인라인이 더 단순하면 인라인 우선).
7. **FK 순서**: §1.2 그래프 역순으로 마이그레이션. 부재 참조는 컬럼만+주석.

---

## 6. qa-auditor 검증 포인트

- Operation/MaterialLot 각 전이마다 AuditLog 1건 + 정의된 Outbox 이벤트 생성, 전이 실패 시 롤백.
- LotConsumption 경유 없는 자재 소비 경로 부재(암묵 소비 금지).
- 생산 LOT가 `source_operation_id`로 Operation에 연결되는지(genealogy).
- 불법 전이 거부(no-op·종료상태 재전이 포함).
- append-only 엔티티에 update/delete 컨텍스트 함수 부재.
- 기준정보 변경도 AuditLog 남기는지.

---

## 7. 애드온 500 해결 — 맞춰야 할 테이블/컬럼 계약 (최우선)

애드온 읽기 스키마(`lib/open_mes_addons/`)가 **이미 기대 중인** 테이블·컬럼. 코어 마이그레이션이 아래를 정확히 생성하면 애드온이 자동 동작한다(**컬럼명 변경 절대 금지, 추가는 가능**).

| 테이블 | 필수 컬럼(애드온 기대) | 읽는 애드온 |
|--------|----------------------|------------|
| `items` | item_code, name, item_type, unit, active (+timestamps, id binary_id) | daily_production_summary |
| `operations` | work_order_id, process_id, sequence, status, started_at, completed_at | daily_production_summary, equipment_oee |
| `production_results` | operation_id, worker_id, equipment_id, good_quantity, defect_quantity, started_at, ended_at | daily_production_summary, defect_stats, equipment_oee |
| `defect_records` | production_result_id, defect_code, quantity, note | defect_stats |
| `material_lots` | lot_no, item_id, lot_type, quantity, status | lot_qr_label |
| `routings` | item_id, process_id, sequence, standard_cycle_time | equipment_oee |

> 모든 PK `id binary_id`, `timestamps(type: :utc_datetime_usec)`. decimal 컬럼(good_quantity 등)은 `:decimal`. `ended_at`(production_results)와 `completed_at`(operations) 명칭 구분 주의 — 애드온이 정확히 그 이름으로 읽는다.

---

## 8. 미해결 / 사용자 확인 필요

1. **Equipment/Worker 필드**: domain-model.md 미정의. 본 설계는 최소(code/name/active)로 신설. 추가 속성(설비유형/공정능력, 작업자 소속/교대) 필요 시 확정 요망.
2. **item_type / lot_type 값 집합**: `raw/semi/product` 가정. 한국 현장 코드(원자재/반제품/제품/부자재 등) 확정 요망.
3. **Operation 자동 생성 규칙**: 작업지시 release 시 Routing 기반 Operation 자동 펼침 여부(MVP는 수동 생성 우선 가정).
4. **ProductionResult 정정 정책**: append-only에서 오입력 정정 방식(역분개 레코드 vs 정정 플래그) — MVP는 새 레코드 추가만. 정책 확정 요망.
5. **LOT 소비 시 수량 검증**: input_lot quantity 초과 소비 차단 여부(MVP 권장: 차단). 확정 요망.
6. **인증**: MVP 세션 간이 actor + `X-Actor-Id` 헤더 유지. 실제 로그인/RBAC 도입 시점 확정 요망.
