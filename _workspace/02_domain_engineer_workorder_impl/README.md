# 02. domain-engineer 구현: WorkOrder API

- **구현자**: domain-engineer
- **기반 설계**: `_workspace/01_architect_workorder_design.md`
- **기술 스택**: Phoenix (Elixir) + Ecto + PostgreSQL
- **수신자(검증)**: qa-auditor

> 디렉토리는 Phoenix 표준 구조를 그대로 반영한다. 실제 `open_mes` 앱에 스캐폴딩(`mix phx.new open_mes --no-mailer --no-dashboard --binary-id`) 후 동일 경로에 그대로 배치하면 동작한다.

## 파일 목록 및 역할

### 마이그레이션 (priv/repo/migrations/)
- `20260613000001_create_audit_logs.exs` — audit_logs 테이블. append-only(updated_at 없음), before/after jsonb.
- `20260613000002_create_outbox_events.exs` — outbox_events 테이블. status CHECK(pending/published).
- `20260613000003_create_work_orders.exs` — work_orders 테이블. status/quantity CHECK, unique(work_order_no). item_id 는 FK 없이 컬럼만(후속).

### 도메인 (lib/open_mes/)
- `production/work_order_state_machine.ex` — 허용 전이표 + `can_transition?/2` (순수 함수).
- `production/work_order.ex` — 스키마 + create/update/transition changeset 분리.
- `production/production.ex` — 컨텍스트. 6개 쓰기 함수가 모두 단일 Ecto.Multi(상태변경+AuditLog+Outbox).
- `audit/audit_log.ex`, `audit/audit.ex` — AuditLog 스키마 + Multi 스텝 헬퍼(`put_log/3`).
- `outbox/event.ex`, `outbox/outbox.ex` — Outbox 스키마 + Multi 스텝 헬퍼(`put_event/3`).

### 웹 (lib/open_mes_web/)
- `plugs/require_actor.ex` — X-Actor-Id 헤더 강제(누락/공백 422).
- `controllers/work_order_controller.ex` — 얇은 컨트롤러. create/index/show/update + 동사형 전이(release/start/complete/cancel).
- `controllers/work_order_json.ex` — JSON 직렬화(decimal→문자열).
- `controllers/fallback_controller.ex` — {:error,...} → 404/422 매핑.
- `router.ex` — 읽기/쓰기 파이프라인 분리(쓰기에만 require_actor).

### 테스트 (test/)
- `open_mes/production/work_order_test.exs` — 상태머신, 정상/불법 전이, AuditLog/Outbox 생성, 롤백 원자성, update 제약.
- `open_mes_web/controllers/work_order_controller_test.exs` — 201/200/422/404, actor 누락 거부.
- `support/data_case.ex`, `support/conn_case.ex` — 테스트 케이스 템플릿(SQL Sandbox).

## 핵심 불변식 (qa-auditor 검증 포인트)

1. 모든 쓰기 6종이 단일 `Ecto.Multi` + `Repo.transaction()` — 상태변경+AuditLog(+Outbox) 원자적.
2. AuditLog 7요소(actor_id/action/resource_type/resource_id/before/after/created_at(=inserted_at)) 충족.
3. 상태 전이는 `transition_changeset` 경유로만. 허용 전이표 외 거부(422 changeset 에러).
4. Outbox 는 `work_order.released` 단일 이벤트만 발행(설계 §6 결정).
5. actor 없는 쓰기 거부(RequireActor plug).
6. Audit/Outbox 는 append-only(update/delete 함수 미작성).

## qa-auditor 확인 요청 사항 (architect 결정 사항)

- **`draft→cancelled`, `released→cancelled` 허용**: audit-verify 스킬의 좁은 전이 목록에는 `in_progress→cancelled` 만 명시되어 있으나, 본 구현은 architect 설계 §3.1의 명시적 결정("현장에서 작업지시 취소는 흔함")에 따라 진행 중 모든 상태에서 cancel 을 허용한다. CLAUDE.md L35(`draft → released → in_progress → completed / cancelled`)와도 모순되지 않음. 이 전이가 의도된 것임을 확인 바람.
- **item_id FK 미적용**: items 테이블 부재로 컬럼만 생성(설계 §2.1, 후속 마이그레이션 예정).
