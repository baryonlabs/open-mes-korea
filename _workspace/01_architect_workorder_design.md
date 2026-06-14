# 01. Architect 설계: WorkOrder API

- **작성자**: architect
- **작성일**: 2026-06-13
- **대상**: WorkOrder 엔티티 전체 API (생성, 조회, 상태 전이)
- **기술 스택 (확정)**: Phoenix (Elixir) + Ecto + PostgreSQL
- **참고 문서**: docs/domain-model.md, docs/system-architecture.md, CLAUDE.md, docs/mvp-scope.md
- **수신자**: domain-engineer (구현), qa-auditor (검토)

---

## 0. 설계 원칙 요약 (이 설계가 지켜야 하는 불변 규칙)

1. **모든 쓰기는 AuditLog 생성** — WorkOrder 생성/상태전이 예외 없음 (CLAUDE.md L49-51)
2. **상태 머신 임의 전이 금지** — `draft → released → in_progress → completed/cancelled` 외 전이 차단 (CLAUDE.md L33-39)
3. **Event Outbox는 동일 트랜잭션** — 상태 변경과 이벤트 삽입을 하나의 `Ecto.Multi`로 묶음 (CLAUDE.md L57-59)
4. **모든 쓰기에 actor_id 필수** — actor 없는 쓰기 호출은 거부 (system-architecture.md L62)
5. **MVP 범위 준수** — 인증/권한 미들웨어, 메시지 큐, 소프트삭제 등 과설계 금지. Operation/LOT 연동은 별도 기능으로 분리(이 설계 범위 밖).

---

## 1. Phoenix 프로젝트 디렉토리 구조

이번이 첫 코드이므로 Phoenix 앱 스캐폴딩을 포함한다. 단 본 설계는 **WorkOrder 관련 모듈에 집중**하고, 나머지 엔티티는 동일 패턴을 따른다.

### 1.1 스캐폴딩 명령 (domain-engineer가 최초 1회 실행)

```bash
# API 전용 앱 (LiveView 화면은 후속 단계). HTML/asset 제외로 단순화.
mix phx.new open_mes --app open_mes --no-mailer --no-dashboard --binary-id

# --binary-id: 모든 PK를 UUID(binary_id)로. LOT/감사 추적 시스템에서 ID 추측 방지 + 분산 친화.
```

- **OTP 앱 이름**: `open_mes`
- **웹 모듈**: `OpenMesWeb`
- **컨텍스트 모듈**: `OpenMes`
- **PK 타입**: `binary_id` (UUID v4) — 전 엔티티 공통

### 1.2 디렉토리 구조 (WorkOrder 집중)

```text
open_mes/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs
├── lib/
│   ├── open_mes/
│   │   ├── application.ex
│   │   ├── repo.ex
│   │   │
│   │   ├── production/                         # ← 생산관리 바운디드 컨텍스트
│   │   │   ├── production.ex                   # 컨텍스트 퍼사드(공개 API 함수)
│   │   │   ├── work_order.ex                   # Ecto 스키마 + changeset
│   │   │   └── work_order_state_machine.ex     # 상태 전이 규칙 (순수 함수)
│   │   │
│   │   ├── audit/                              # ← 감사 컨텍스트 (공용)
│   │   │   ├── audit.ex                        # AuditLog 기록 헬퍼
│   │   │   └── audit_log.ex                    # Ecto 스키마
│   │   │
│   │   └── outbox/                             # ← 이벤트 아웃박스 (공용)
│   │       ├── outbox.ex                       # 이벤트 삽입 헬퍼(Multi용)
│   │       └── event.ex                        # Ecto 스키마 (outbox_events)
│   │
│   └── open_mes_web/
│       ├── endpoint.ex
│       ├── router.ex
│       ├── controllers/
│       │   ├── work_order_controller.ex
│       │   ├── work_order_json.ex              # 응답 직렬화 (JSON view)
│       │   ├── fallback_controller.ex          # {:error, changeset} 등 공통 변환
│       │   └── error_json.ex
│       └── plugs/
│           └── require_actor.ex                # actor_id 추출/검증 plug
│
├── priv/
│   └── repo/
│       └── migrations/
│           ├── 20260613000001_create_audit_logs.exs
│           ├── 20260613000002_create_outbox_events.exs
│           └── 20260613000003_create_work_orders.exs
└── test/
    ├── open_mes/production/work_order_test.exs        # 컨텍스트/상태머신 테스트
    └── open_mes_web/controllers/work_order_controller_test.exs
```

**모듈 경계와 책임**

| 모듈 | 책임 | 비고 |
|------|------|------|
| `OpenMes.Production` | WorkOrder 유스케이스의 **유일한 공개 진입점**. 트랜잭션 조립(Ecto.Multi), 상태전이 호출, AuditLog/Outbox 결합. | 컨트롤러는 이 모듈만 호출 |
| `OpenMes.Production.WorkOrder` | 스키마 + changeset (필드 검증). 상태전이 검증은 위임. | DB 매핑 책임만 |
| `OpenMes.Production.WorkOrderStateMachine` | 허용 전이표 + `can_transition?/2`. 순수 함수, DB 의존 없음. | 테스트 용이성 |
| `OpenMes.Audit` | `log/2` 헬퍼. before/after diff 구성. **Multi에 끼워 넣는 형태** 제공. | 공용 |
| `OpenMes.Outbox` | `emit/2` 헬퍼. 이벤트를 Multi에 추가. | 공용 |
| `OpenMesWeb.WorkOrderController` | 파라미터 파싱, actor 추출, 컨텍스트 호출, 상태코드 매핑. | 비즈니스 로직 금지 |

> **핵심 규칙**: AuditLog와 Outbox는 컨트롤러가 아니라 **`OpenMes.Production` 컨텍스트 함수 내부의 동일 `Ecto.Multi`**에서 생성한다. 컨트롤러에서 감사로그를 남기면 트랜잭션 원자성이 깨지므로 금지.

---

## 2. DB 테이블 설계 (Ecto 마이그레이션 관점)

### 2.1 `work_orders`

| 필드 | 타입 | 제약 | 비고 |
|------|------|------|------|
| `id` | `binary_id` | PK | UUID |
| `work_order_no` | `string` | NOT NULL, **UNIQUE** | 작업지시번호 (예: `WO-20260613-0001`) |
| `item_id` | `binary_id` | NOT NULL, FK→`items(id)` | 생산 대상 품목 |
| `planned_quantity` | `decimal` | NOT NULL, CHECK > 0 | 계획 수량. 정수 아닌 단위(kg 등) 고려 → decimal |
| `due_date` | `date` | NULL 허용 | 납기일 |
| `status` | `string` | NOT NULL, DEFAULT `'draft'`, CHECK IN (5종) | 상태 머신 |
| `released_at` | `utc_datetime_usec` | NULL | released 전이 시각 |
| `started_at` | `utc_datetime_usec` | NULL | in_progress 전이 시각 |
| `completed_at` | `utc_datetime_usec` | NULL | completed 전이 시각 |
| `cancelled_at` | `utc_datetime_usec` | NULL | cancelled 전이 시각 |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | Ecto timestamps |
| `updated_at` | `utc_datetime_usec` | NOT NULL | Ecto timestamps |

> **참고**: `item_id` FK는 `items` 테이블이 아직 없으므로, **이번 마이그레이션에서는 `references` 없이 컬럼만 생성**하고, items 구현 시 FK 제약을 추가하는 후속 마이그레이션으로 분리한다. (MVP 구현 순서: 기준정보 → 작업지시. 단 WorkOrder를 먼저 짜는 현 상황에서 부재 테이블 참조 회피.) → domain-engineer는 컬럼만 생성하고 코드 주석으로 "FK 후속 추가" 명시.

**인덱스**
- `unique_index(:work_orders, [:work_order_no])` — 작업지시번호 유일성 (앱 레벨 + DB 레벨 이중 보장)
- `index(:work_orders, [:status])` — 현황 조회(상태별 필터) 빈번
- `index(:work_orders, [:item_id])` — 품목별 조회
- `index(:work_orders, [:due_date])` — 납기 정렬/조회

**CHECK 제약 (마이그레이션 `execute`로 추가)**
```sql
ALTER TABLE work_orders
  ADD CONSTRAINT work_orders_status_check
  CHECK (status IN ('draft','released','in_progress','completed','cancelled'));
ALTER TABLE work_orders
  ADD CONSTRAINT work_orders_planned_quantity_positive
  CHECK (planned_quantity > 0);
```
> CHECK은 changeset 검증 우회(직접 SQL 등)에 대한 **최후 방어선**. 상태전이 규칙 자체는 CHECK으로 표현 불가하므로 앱 레벨(state machine)이 1차 책임.

### 2.2 `audit_logs` (공용, WorkOrder보다 먼저 생성)

domain-model.md L105-115 기준.

| 필드 | 타입 | 제약 | 비고 |
|------|------|------|------|
| `id` | `binary_id` | PK | |
| `actor_id` | `string` | NOT NULL | 행위자 식별자 (MVP: 인증 미구현 → 헤더/파라미터 문자열) |
| `action` | `string` | NOT NULL | 예: `work_order.create`, `work_order.release` |
| `resource_type` | `string` | NOT NULL | 예: `work_order` |
| `resource_id` | `binary_id` | NOT NULL | 대상 레코드 id |
| `before` | `map` (jsonb) | NULL | 변경 전 스냅샷 (생성 시 null) |
| `after` | `map` (jsonb) | NULL | 변경 후 스냅샷 |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | domain-model의 `created_at`에 대응. Ecto 관례상 inserted_at 사용 |

- **append-only**: UPDATE/DELETE 미제공. 컨텍스트에 update 함수 자체를 만들지 않음.
- 인덱스: `index(:audit_logs, [:resource_type, :resource_id])`, `index(:audit_logs, [:actor_id])`, `index(:audit_logs, [:action])`

### 2.3 `outbox_events` (공용)

system-architecture.md L42-57 기준. PostgreSQL outbox 패턴.

| 필드 | 타입 | 제약 | 비고 |
|------|------|------|------|
| `id` | `binary_id` | PK | |
| `event_type` | `string` | NOT NULL | 예: `work_order.released` |
| `aggregate_type` | `string` | NOT NULL | 예: `work_order` |
| `aggregate_id` | `binary_id` | NOT NULL | 이벤트 대상 id |
| `payload` | `map` (jsonb) | NOT NULL | 이벤트 본문 |
| `status` | `string` | NOT NULL, DEFAULT `'pending'` | `pending` / `published` (MVP는 발행자 미구현, 적재만) |
| `occurred_at` | `utc_datetime_usec` | NOT NULL | 이벤트 발생 시각 |
| `published_at` | `utc_datetime_usec` | NULL | 발행 시각 (후속) |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | |

- 인덱스: `index(:outbox_events, [:status])` (미발행 폴링용), `index(:outbox_events, [:aggregate_type, :aggregate_id])`
- **MVP 범위 명시**: outbox **발행 워커는 이번 범위 밖**. 이벤트가 동일 트랜잭션에 안전하게 적재되는 것까지만 보장한다. (과설계 금지 원칙)

---

## 3. WorkOrder 상태 머신

### 3.1 허용 전이표

```text
draft       → released, cancelled
released    → in_progress, cancelled
in_progress → completed, cancelled
completed   → (종료 상태, 전이 없음)
cancelled   → (종료 상태, 전이 없음)
```

> 문서의 주 흐름은 `draft→released→in_progress→completed/cancelled`. cancelled는 종료 직전 어느 진행 상태에서도 가능하도록 허용(현장에서 작업지시 취소는 흔함). completed/cancelled는 **종료 상태**로 어떤 전이도 불가. 이 표 외 전이는 전부 거부.

### 3.2 `WorkOrderStateMachine` (순수 함수)

```elixir
defmodule OpenMes.Production.WorkOrderStateMachine do
  @transitions %{
    "draft"       => ["released", "cancelled"],
    "released"    => ["in_progress", "cancelled"],
    "in_progress" => ["completed", "cancelled"],
    "completed"   => [],
    "cancelled"   => []
  }

  def can_transition?(from, to), do: to in Map.get(@transitions, from, [])
  def allowed_from(from), do: Map.get(@transitions, from, [])
end
```

### 3.3 Ecto changeset에서 전이 강제

전이는 **별도 전용 changeset**으로 강제한다. 일반 `update`로 status를 못 바꾸게 한다.

- `WorkOrder.create_changeset/2`: `status`를 캐스트 대상에서 **제외**. 항상 `draft`로 강제(`put_change`).
- `WorkOrder.transition_changeset/2`: `status` 하나만 받음. `validate_change`로 전이 유효성 검사.

```elixir
def transition_changeset(%WorkOrder{status: from} = wo, to) do
  wo
  |> cast(%{status: to}, [:status])
  |> validate_required([:status])
  |> validate_inclusion(:status,
       ["draft","released","in_progress","completed","cancelled"])
  |> validate_change(:status, fn :status, new ->
       if WorkOrderStateMachine.can_transition?(from, new),
         do: [],
         else: [status: "허용되지 않은 상태 전이입니다: #{from} → #{new}"]
     end)
  |> put_timestamp_for(to)   # released_at/started_at/... 자동 세팅
end
```

- **불변식**: 일반 수정 API에서 status 변경 차단. status 변경은 오직 전용 전이 엔드포인트를 통해서만.

---

## 4. API 엔드포인트 목록

라우터: `scope "/api", OpenMesWeb`. 모든 쓰기 라우트에 `require_actor` plug 적용.

| 메서드 | 경로 | 컨트롤러 액션 | 설명 | 상태전이 |
|--------|------|--------------|------|---------|
| POST | `/api/work_orders` | `:create` | 작업지시 생성 (항상 draft) | — |
| GET | `/api/work_orders` | `:index` | 목록 조회 (status/item_id/due_date 필터, 페이지네이션) | — |
| GET | `/api/work_orders/:id` | `:show` | 단건 조회 | — |
| PATCH | `/api/work_orders/:id` | `:update` | 필드 수정 (planned_quantity, due_date). **draft에서만 허용**, status 변경 불가 | — |
| POST | `/api/work_orders/:id/release` | `:release` | draft → released | ✅ |
| POST | `/api/work_orders/:id/start` | `:start` | released → in_progress | ✅ |
| POST | `/api/work_orders/:id/complete` | `:complete` | in_progress → completed | ✅ |
| POST | `/api/work_orders/:id/cancel` | `:cancel` | * → cancelled | ✅ |

**상태전이는 동사형 하위 리소스(POST action)로 분리.** `PATCH {status: ...}` 방식은 금지 — 전이 의미가 URL에 드러나고, 감사 action명/이벤트명과 1:1 매핑되어 추적이 명확해진다.

### actor_id 처리 방식

- MVP는 인증 미들웨어가 없으므로 **`X-Actor-Id` HTTP 헤더**로 전달받는다.
- `RequireActor` plug가 헤더를 읽어 `conn.assigns.actor_id`에 주입. 없으면 **422 (또는 400) 거부** — actor 없는 쓰기 금지(system-architecture.md L62).
- 읽기(GET)에는 plug 미적용.
- 컨트롤러는 `conn.assigns.actor_id`를 컨텍스트 함수 인자로 명시 전달: `Production.release_work_order(id, actor_id)`.
- **후속 확장 지점**: 인증 도입 시 plug만 교체하면 됨(컨텍스트 시그니처 유지). 이 분리가 향후 인증 통합의 단일 변경점.

### 응답 규약 (FallbackController)

| 결과 | HTTP | 본문 |
|------|------|------|
| 생성 성공 | 201 | work_order JSON |
| 조회/전이 성공 | 200 | work_order JSON |
| 검증 실패(changeset) | 422 | `{errors: {...}}` |
| 잘못된 상태 전이 | 422 | `{errors: {status: ["..."]}}` (changeset 에러로 자연 매핑) |
| actor 누락 | 422 | `{errors: {actor: ["actor_id가 필요합니다"]}}` |
| 미존재 | 404 | `{errors: {detail: "찾을 수 없습니다"}}` |

> 잘못된 상태전이가 changeset 에러(422)로 흐르도록 설계 → 컨트롤러 분기 단순화. (404 vs 422 분기만 처리)

---

## 5. AuditLog 생성 트리거 지점

**원칙**: WorkOrder를 변경하는 모든 컨텍스트 함수는 동일 트랜잭션 안에서 AuditLog를 1건 생성한다. 누락 시 qa-auditor 검증 실패.

| 컨텍스트 함수 | AuditLog `action` | before | after |
|--------------|-------------------|--------|-------|
| `Production.create_work_order/2` | `work_order.create` | `nil` | 생성된 WO 스냅샷 |
| `Production.update_work_order/3` | `work_order.update` | 수정 전 WO | 수정 후 WO |
| `Production.release_work_order/2` | `work_order.release` | `%{status: "draft"}` | `%{status: "released"}` |
| `Production.start_work_order/2` | `work_order.start` | `%{status: "released"}` | `%{status: "in_progress"}` |
| `Production.complete_work_order/2` | `work_order.complete` | `%{status: "in_progress"}` | `%{status: "completed"}` |
| `Production.cancel_work_order/2` | `work_order.cancel` | `%{status: <이전>}` | `%{status: "cancelled"}` |

**생성 위치**: 각 컨텍스트 함수 내부의 `Ecto.Multi`에 `Audit.log_step/...`로 끼워 넣는다. before/after는 전이 전 레코드(`%WorkOrder{}`)와 전이 후 changeset 결과에서 추출. 스냅샷은 상태 전이의 경우 `status` + 타임스탬프 위주로 슬림하게, create/update는 주요 필드 전체.

> **금지**: 컨트롤러나 별도 트랜잭션에서 AuditLog 생성. WorkOrder 저장과 AuditLog 저장은 **반드시 같은 Multi/트랜잭션**. 하나 실패 시 둘 다 롤백.

---

## 6. Event Outbox 이벤트 발행 지점

**원칙**: 상태 변경 시 outbox에 이벤트를 **동일 트랜잭션**으로 적재한다(CLAUDE.md L57-59).

| 컨텍스트 함수 | 이벤트 발행 | event_type |
|--------------|-----------|-----------|
| `create_work_order` | ❌ (생성은 outbox 이벤트 없음 — 문서 이벤트 목록에 없음) | — |
| `release_work_order` | ✅ | `work_order.released` |
| `start_work_order` | ⚠️ 선택 | (문서 이벤트 목록엔 work_order 시작 이벤트 없음. operation.started가 별개 존재) → **MVP에서는 미발행** |
| `complete_work_order` | ⚠️ 선택 | 문서 목록 없음 → **MVP에서는 미발행** |
| `cancel_work_order` | ⚠️ 선택 | 문서 목록 없음 → **MVP에서는 미발행** |

> **결정**: system-architecture.md / CLAUDE.md의 명시 이벤트 목록에 있는 `work_order.released`만 발행한다. start/complete/cancel 이벤트는 문서에 정의되어 있지 않으므로 **임의 추가하지 않는다**(과설계 금지). 추후 이벤트 정의가 추가되면 동일 패턴으로 확장. → 이 결정은 사용자/문서 변경 시 재검토 대상.

**`work_order.released` payload**
```json
{
  "work_order_id": "<uuid>",
  "work_order_no": "WO-20260613-0001",
  "item_id": "<uuid>",
  "planned_quantity": "100",
  "released_at": "2026-06-13T...Z",
  "actor_id": "<actor>"
}
```

**발행 위치**: `release_work_order/2`의 `Ecto.Multi` 안에서 `Outbox.emit_step(...)`으로 추가. WorkOrder 상태 변경 + AuditLog + Outbox = **단일 Multi 3스텝**.

---

## 7. domain-engineer 전달 구현 지침

### 7.1 트랜잭션 구조 (가장 중요 — 이 패턴을 모든 전이에 동일 적용)

`release_work_order/2`를 표준 레퍼런스로 구현:

```elixir
def release_work_order(id, actor_id) do
  Ecto.Multi.new()
  |> Ecto.Multi.run(:work_order, fn repo, _ ->
       case repo.get(WorkOrder, id) do
         nil -> {:error, :not_found}
         wo  -> {:ok, wo}
       end
     end)
  |> Ecto.Multi.update(:transition, fn %{work_order: wo} ->
       WorkOrder.transition_changeset(wo, "released")
     end)
  |> Ecto.Multi.insert(:audit, fn %{work_order: wo, transition: updated} ->
       Audit.changeset(%{
         actor_id: actor_id,
         action: "work_order.release",
         resource_type: "work_order",
         resource_id: wo.id,
         before: %{status: wo.status},
         after:  %{status: updated.status, released_at: updated.released_at}
       })
     end)
  |> Ecto.Multi.insert(:event, fn %{transition: updated} ->
       Outbox.changeset(%{
         event_type: "work_order.released",
         aggregate_type: "work_order",
         aggregate_id: updated.id,
         occurred_at: DateTime.utc_now(),
         payload: %{
           work_order_id: updated.id,
           work_order_no: updated.work_order_no,
           item_id: updated.item_id,
           planned_quantity: updated.planned_quantity,
           released_at: updated.released_at,
           actor_id: actor_id
         }
       })
     end)
  |> Repo.transaction()
  |> normalize_transaction_result()  # {:ok, %{transition: wo}} → {:ok, wo}
end
```

- `start/complete/cancel`은 위와 동일 구조에서 **target status·action명만 변경**, `:event` 스텝은 제외(MVP 결정 §6).
- `create_work_order/2`는 `:event` 제외, `:audit`는 `before: nil` 포함.

### 7.2 구현 순서 (마이그레이션 의존성)

1. `audit_logs` 마이그레이션 + `OpenMes.Audit.AuditLog` 스키마 + `Audit` 헬퍼
2. `outbox_events` 마이그레이션 + `OpenMes.Outbox.Event` 스키마 + `Outbox` 헬퍼
3. `work_orders` 마이그레이션 (item_id는 FK 없이 컬럼만, 주석 명시)
4. `WorkOrderStateMachine` (순수 함수, 테스트 먼저 가능)
5. `WorkOrder` 스키마 + `create_changeset` / `update_changeset` / `transition_changeset`
6. `OpenMes.Production` 컨텍스트 함수 6종 (Multi 패턴)
7. `RequireActor` plug + 라우터 + 컨트롤러 + JSON view + FallbackController
8. 테스트 (상태전이 단위 + 컨트롤러 통합)

### 7.3 세부 규칙

- **work_order_no 생성**: 클라이언트가 보내거나, 미지정 시 서버가 `WO-{YYYYMMDD}-{시퀀스}` 생성. MVP는 **클라이언트 필수 입력**으로 단순화하고, unique 제약 위반 시 422. (자동 채번 시퀀스는 후속.) → domain-engineer는 우선 필수 입력으로 구현.
- **update_work_order**: `draft` 상태에서만 `planned_quantity`, `due_date` 수정 허용. 다른 상태에서 호출 시 changeset 에러(422). `status`는 캐스트 대상 제외.
- **타임스탬프 세팅**: 전이 시 해당 `*_at` 컬럼을 `put_change`로 현재시각 기록(`released_at` 등).
- **planned_quantity 타입**: Ecto `:decimal`. JSON 응답은 문자열로 직렬화(정밀도 보존).
- **언어**: 에러 메시지·주석은 한국어(CLAUDE.md L22-24). 식별자·필드명은 영문.
- **actor_id 검증**: 빈 문자열/공백도 거부. plug에서 trim 후 검증.
- **append-only 보장**: Audit/Outbox 컨텍스트에 update/delete 함수 미작성.

### 7.4 테스트 필수 케이스 (qa-auditor 검증 대비)

- 정상 전이 4종 성공 + 상태/타임스탬프 검증
- 불법 전이 거부: `draft→in_progress`, `completed→released`, `cancelled→*` 등 422
- 각 전이마다 **AuditLog 1건 생성** 확인 (action명 일치)
- `release` 시 **outbox_events 1건** (`work_order.released`) 생성 확인
- 전이 실패 시 AuditLog/Outbox **롤백** 확인 (Multi 원자성)
- actor_id 누락 쓰기 요청 거부
- draft 외 상태에서 update 거부

---

## 8. 미해결/사용자 확인 필요 항목

1. **work_order_no 채번**: MVP는 클라이언트 필수 입력으로 진행. 자동 채번 규칙 필요 시 확정 요망.
2. **start/complete/cancel 이벤트**: 문서 미정의로 outbox 미발행. 이벤트 필요 시 system-architecture.md 이벤트 목록에 추가 후 재설계.
3. **item_id FK**: items 테이블 미존재로 FK 제약 후속 추가. 기준정보 구현 후 보강 마이그레이션 필요.
4. **권한/인증**: MVP는 `X-Actor-Id` 헤더. 실제 인증 도입 시 plug 교체.
