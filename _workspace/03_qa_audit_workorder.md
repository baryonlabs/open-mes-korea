# 03. QA 감사: WorkOrder 구현

- **감사자**: qa-auditor
- **감사일**: 2026-06-13
- **대상**: `_workspace/02_domain_engineer_workorder_impl/` 전체
- **기준**: docs/domain-model.md, 01_architect_workorder_design.md, CLAUDE.md
- **최종 판정**: **NEEDS_FIX** (불변식은 모두 준수 / 멱등 전이 1건 보강 필요 + 구조 단순화 권고)

---

## 검증 1 — 도메인 불변식

### 1.1 AuditLog 원칙 — ✅ 통과

| 항목 | 결과 | 근거 |
|------|------|------|
| 생성(create) AuditLog | ✅ | production.ex:94-103 `work_order.create`, before:nil |
| 수정(update) AuditLog | ✅ | production.ex:118-127 `work_order.update`, before/after 전체 스냅샷 |
| release 전이 AuditLog | ✅ | transition_multi production.ex:198-207 `work_order.release` |
| start 전이 AuditLog | ✅ | transition_multi 공통 경로 `work_order.start` |
| complete 전이 AuditLog | ✅ | 공통 경로 `work_order.complete` |
| cancel 전이 AuditLog | ✅ | 공통 경로 `work_order.cancel` |
| 동일 트랜잭션 보장 | ✅ | 모든 AuditLog가 `Audit.put_log`로 같은 Multi 스텝에 삽입 (audit.ex:34-40). 컨트롤러에서 직접 로그 생성 없음 |
| 7요소 충족 | ✅ | actor_id, action, resource_type, resource_id, before, after + inserted_at(=created_at 대응). audit_log.ex:14-24, 마이그레이션 audit_logs:18-29 |

- `created_at`은 Ecto 관례상 `inserted_at`으로 매핑 (마이그레이션 주석 명시, 설계 §2.2와 일치) — **허용**.
- actor_id 공백/빈문자 거부: audit_log.ex:38-42 + plug require_actor.ex:40-45 이중 방어 — 우수.

### 1.2 상태 머신 원칙 — ✅ 통과 (멱등 전이 1건 ⚠️, 아래 1.5 참조)

| 항목 | 결과 | 근거 |
|------|------|------|
| 허용 전이표만 코드화 | ✅ | work_order_state_machine.ex:19-25. 설계 §3.1과 1:1 일치 |
| 일반 update로 status 변경 차단 | ✅ | update_changeset가 status를 cast 대상에서 제외 (work_order.ex:84) |
| 전이 전용 경로 강제 | ✅ | transition_changeset만 status cast (work_order.ex:104-117) |
| 불허 전이 거부 | ✅ | validate_change → :status 에러 → 422. 테스트 다수 커버 |
| DB CHECK 최후방어선 | ✅ | work_orders:49-51 status IN (5종) |

### 1.3 Event Outbox 원칙 — ✅ 통과

| 항목 | 결과 | 근거 |
|------|------|------|
| 상태변경+AuditLog+Outbox 동일 트랜잭션 | ✅ | release_work_order production.ex:137-160 — transition_multi(load+transition+audit)에 `Outbox.put_event` 스텝을 같은 Multi에 추가 후 단일 `Repo.transaction` |
| work_order.released만 발행 | ✅ | release만 put_event. start/complete/cancel은 미발행 (설계 §6 결정 준수). 테스트 work_order_test.exs:142-143이 검증 |
| 이벤트 타입이 정의 목록과 일치 | ✅ | CLAUDE.md L59 주요 이벤트 목록의 `work_order.released`와 일치 |
| 원자성(롤백) | ✅ | work_order_test.exs:199-211 — 불법 전이 시 AuditLog/Outbox 모두 롤백 검증 |

### 1.4 이력성 원칙 — ✅ 통과

| 항목 | 결과 | 근거 |
|------|------|------|
| audit_logs append-only(updated_at 없음) | ✅ | audit_log.ex:23 `updated_at: false`, 마이그레이션 audit_logs:29 동일 |
| outbox_events append-only | ✅ | event.ex:26, 마이그레이션 outbox_events:32 |
| Audit/Outbox에 update/delete 함수 없음 | ✅ | audit.ex / outbox.ex 모두 put_*/changeset만 제공 |
| 생산 데이터 DELETE 없음 | ✅ | Production 컨텍스트에 delete 함수 자체 없음 |

> 참고: work_orders는 `updated_at`을 가지며 status 외 필드(planned_quantity 등)를 draft에서 수정한다. 이는 마스터성 작업지시 데이터로 "생산 실적/LOT/불량"의 append-only 대상이 아니므로 이력성 원칙 위반 아님. 모든 수정은 AuditLog로 before/after 추적됨 (production.ex:118-127).

### 1.5 ⚠️ 보강 필요 — 멱등(no-op) 전이가 통과하는 엣지 케이스

**위치**: `work_order.ex:104-117` `transition_changeset/2` + `production.ex:192-208` `transition_multi`

**문제**: `to == from`(예: 이미 `released`인 WO에 `release_work_order` 재호출)인 경우:
1. `cast(%{status: to})`가 변경 없음(no change)으로 판단 → Ecto `validate_change(:status, ...)`는 **필드가 실제로 변경됐을 때만 실행**되므로 전이 검증 콜백이 호출되지 않음 (work_order.ex:109).
2. 상태머신 전이표에 `released → released`는 없지만, 검증 자체가 스킵되어 changeset이 valid가 됨.
3. 결과: 같은 상태로의 멱등 호출이 성공하며, `put_transition_timestamp`가 `released_at`을 **현재 시각으로 덮어쓰고**(work_order.ex:121-126, put_change는 항상 실행) **불필요한 AuditLog 1건**이 생성됨.

`completed`/`cancelled`(종료 상태)에서 같은 전이를 재호출해도 동일하게 통과되어, "종료 상태는 전이 불가" 불변식이 멱등 경로로 우회됨.

**영향도**: 중. 데이터 무결성 직접 손상은 아니나 (a) 종료 상태 불변식 우회, (b) 타임스탬프 정정 이력 없이 덮어쓰기 → 이력성 약화, (c) 의미 없는 AuditLog 누적.

**수정 방법** (둘 중 하나):
- (권장) `transition_changeset`에 `from == to` 가드 추가. 예: 함수 진입부에서
  `if from == to, do: add_error(cast(...), :status, "이미 #{to} 상태입니다")` 처리,
  또는 `can_transition?(from, to)` 검사를 `validate_change`가 아닌 **무조건 실행되는 검사**로 빼서 changes 유무와 무관하게 평가.
- (대안) `WorkOrderStateMachine.can_transition?/2`를 transition_multi의 `Multi.run` 단계에서 changeset 이전에 명시 호출하여 불허 시 `{:error, :invalid_transition}` 반환.
- 회귀 테스트 추가: `release → release 재호출 거부`, `completed → complete 재호출 거부`.

---

## 검증 2 — 최소 구현 원칙 (pi: YAGNI / 인라인 헬퍼 / 최소 코어)

> 전제: AuditLog / Outbox / 상태머신 / FallbackController는 MES 도메인 핵심 불변식 또는 Phoenix 표준이므로 **기능 제거 대상 아님**. 아래는 "구조의 과도한 분리"만 식별한다. 어느 것도 BLOCKED 사유가 아니며 권고 수준이다.

### 2.1 과도한 분리로 볼 수 있는 항목

| 항목 | 현 구조 | 호출처 | 평가 | 권고 |
|------|---------|--------|------|------|
| `OpenMes.Audit` (audit.ex) | AuditLog 스키마와 별도 헬퍼 모듈 | `put_log`는 production.ex 3곳(create/update/transition_multi)에서 호출 | 호출처 복수 + Multi 스텝 추상화에 실질 가치 있음 | **유지 권장**. 단 `changeset/1`(audit.ex:45)은 테스트/직접용 주석만 있고 프로덕션 호출처 0 → put_log가 내부에서 `AuditLog.changeset` 직접 호출하므로 **삭제 가능**(YAGNI) |
| `OpenMes.Outbox` (outbox.ex) | Event 스키마와 별도 헬퍼 모듈 | `put_event`는 release 1곳에서만 호출 | **호출처 1곳** → pi 원칙상 인라인 후보 | 기능 유지하되 `put_event`를 release_work_order 안에 인라인하거나 `Outbox` 모듈을 `Event` 스키마에 흡수 가능. 단 향후 operation/material_lot 이벤트로 호출처 증가 예정이면 유지 타당 → **현 시점 1곳이므로 인라인 권고, 보류 가능** |
| `Outbox.changeset/1`(outbox.ex:43) | 미사용 헬퍼 | 호출처 0 | YAGNI 위반 | **삭제 권고** |
| `WorkOrderStateMachine.allowed_from/1` | 순수 함수 | 프로덕션 호출처 0 (테스트만) | 선제 API | 테스트 가독성에 쓰이므로 경미. 유지 무방 |

### 2.2 "과한가?" 질문에 대한 명시 판정

- **`fallback_controller.ex`**: ❌ 과하지 않음. Phoenix `action_fallback` 표준 패턴이고 404/422 분기를 한 곳에 모아 컨트롤러를 얇게 유지(WorkOrderController가 17줄 수준). 컨트롤러마다 분기 복붙하는 것보다 단순. **유지**.
- **`work_order_json.ex`**: ⚠️ 경미한 과설계. JSON view 분리는 Phoenix 관례지만, MVP에서 컨트롤러가 1개뿐이라 인라인 render도 가능. 단 decimal 직렬화 로직(planned_quantity 문자열화)이 응답 표현의 단일 지점이라 분리 가치 있음. **유지 무방**, 강한 단순화 대상 아님.
- **`require_actor.ex` plug**: ❌ 과하지 않음. actor 필수는 CLAUDE.md L88 핵심 원칙이고, 쓰기 라우트 6곳이 공유 → 인라인하면 중복. 인증 도입 시 단일 교체점(설계 §4 후속 확장 지점). **유지**.

### 2.3 핵심 단순화 제안 (기능 100% 보존)

1. **미사용 헬퍼 삭제** (확실): `Audit.changeset/1`(audit.ex:42-45), `Outbox.changeset/1`(outbox.ex:40-43) — 프로덕션 호출처 0. 삭제해도 동작 불변, 테스트가 이를 쓰면 `*.AuditLog.changeset` 직접 호출로 교체.
2. **Outbox 헬퍼 인라인 검토** (선택): `put_event` 호출처가 release 1곳뿐 → pi 인라인 원칙 적용 가능. 단 로드맵상 operation.started/material_lot.consumed 등 이벤트 확장이 예정이면 유지가 합리적. **architect 판단 권고**.

> 결론: 검증 2에서 발견된 것은 "기능 과잉"이 아니라 미사용 헬퍼 2건 + 단일 호출 모듈 1건의 경미한 선제 구조뿐이다. 도메인 불변식 구조(Audit/Outbox/StateMachine 분리)는 정당하다.

---

## domain-engineer 확인 요청 2건 판정

### 확인 1 — draft→cancelled, released→cancelled 전이 허용 (CLAUDE.md L35 vs 구현)

**판정: ✅ 승인 (구현 정당, 위반 아님)**

- CLAUDE.md L35는 `draft → released → in_progress → completed / cancelled`로 **주 흐름**을 표기한 것이며, 어느 단계에서 cancelled로 가는지 배타적으로 규정하지 않음.
- architect 설계 **§3.1**이 명시적으로 결정: *"cancelled는 종료 직전 어느 진행 상태에서도 가능하도록 허용(현장에서 작업지시 취소는 흔함)"* (설계 문서 L186-193).
- 구현(work_order_state_machine.ex:19-25)은 이 설계 결정과 **정확히 일치**. CLAUDE.md L33 "임의 전이 추가 금지"는 설계서에 근거 없는 전이를 막는 규칙이며, 본 전이는 설계서에 명문화되어 있으므로 "임의"가 아님.
- 종료 상태(completed/cancelled)는 전이표 `[]`로 막혀 있어 안전.

> 단, 위 1.5의 멱등 전이 보강이 적용되어야 "종료 상태 전이 불가"가 멱등 경로로도 보장됨.

### 확인 2 — item_id FK 미설정 (items 테이블 미존재)

**판정: ✅ 승인 (MVP 범위 내 정당한 결정)**

- 설계 §2.1 L123 + §8 항목3이 "items 테이블 미존재 → 이번 마이그레이션은 컬럼만, FK는 후속 마이그레이션"으로 명시 결정.
- 구현이 이를 준수: work_orders:21 `add :item_id, :binary_id, null: false`(FK references 없음) + 주석으로 후속 추가 명시. work_order.ex:27 동일 주석.
- `null: false`로 누락은 막고, `index(:work_orders, [:item_id])`로 조회 성능 확보. 참조 무결성만 후속 보강 → MVP 구현 순서(기준정보→작업지시 역순 상황)상 합리적.
- **후속 액션 필요**: Item 엔티티 구현 시 `references` FK 추가 마이그레이션 누락되지 않도록 백로그 등록 권고. (현 단계 위반 아님)

---

## 최종 판정: NEEDS_FIX

도메인 4대 불변식(AuditLog / 상태머신 / Outbox / 이력성)은 **모두 준수**하며 트랜잭션 원자성·append-only·actor 강제·이벤트 화이트리스트까지 견고하게 구현됨. 확인 요청 2건은 모두 설계 근거가 있어 **승인**.

다만 다음 1건의 보강이 필요하여 APPROVED 대신 NEEDS_FIX로 판정한다:

**[필수] 멱등 전이 차단** (검증 1.5): `from == to` 재호출이 검증을 우회해 종료 상태 불변식을 뚫고 타임스탬프를 덮어쓰며 불필요 AuditLog를 생성함. transition_changeset에 from==to 가드 또는 can_transition? 무조건 평가로 수정 + 회귀 테스트 추가.

**[권고, 비차단]**
- 미사용 헬퍼 `Audit.changeset/1`, `Outbox.changeset/1` 삭제 (YAGNI).
- `Outbox.put_event` 인라인 여부는 이벤트 확장 로드맵 고려해 architect 판단.

수정 후 **1.5 항목과 멱등 회귀 테스트만 재검증**하면 APPROVED 가능 (나머지 전면 재검증 불필요).

---

## 재검증 (Round 2)

- **재검증일**: 2026-06-13
- **범위**: Round 1의 NEEDS_FIX 사유(멱등 전이 버그 + YAGNI 헬퍼)만 한정 재검증. 4대 불변식 전면 재검증은 생략(Round 1 통과).
- **대상 파일**: work_order.ex, audit.ex, outbox.ex, work_order_test.exs

### R2-1. [필수 버그] 멱등 전이 차단 — ✅ 해결됨

| 확인 항목 | 결과 | 근거 |
|-----------|------|------|
| `from == to` 가드 추가 | ✅ | work_order.ex:119-123 `cond` 첫 분기에서 `from == to` 시 무조건 `add_error(:status, ...)`. cast 변경 유무와 무관하게 함수 진입부에서 평가됨 |
| 종료 상태(completed/cancelled) 전이 시도 차단 | ✅ | completed→completed·cancelled→cancelled 는 `from==to` 분기로 거부. completed→다른상태 는 `true` 분기의 `validate_change`+`can_transition?`(전이표 `[]`)로 거부. 양 경로 모두 봉쇄 |
| `validate_change` 스킵 문제 해결 | ✅ | 핵심 수정: 동일 상태는 `validate_change`(changes 있을 때만 실행)에 의존하지 않고 `cond`의 별도 분기에서 선검사. 실제 상태가 바뀌는 정상 전이만 `validate_change` 경로로 흐름 |
| 타임스탬프 덮어쓰기 방지 | ✅ | `put_transition_timestamp`(work_order.ex:134)는 `true` 분기에서만 호출. `from==to` 분기는 add_error만 하고 put_change 미실행 → `released_at`/`completed_at` 보존 |

판정: 가드가 정확히 의도대로 동작. 자기 전이가 전이표에 존재하지 않는다는 불변(주석 work_order.ex:110)도 사실과 일치하므로 무조건 거부가 안전.

### R2-2. [회귀 테스트] 동작 실검증 — ✅ 통과

| 테스트 | 검증 내용 | 결과 |
|--------|-----------|------|
| (a) "이미 released 인 WO 에 release 재호출 거부 + 타임스탬프/AuditLog 불변" (test:202-217) | `{:error, cs}` + `errors_on(cs)[:status]` 단언, `reloaded.released_at == first_released_at`(덮어쓰기 없음), `audit_count == audit_before`(누적 없음) 3가지를 모두 검증 | ✅ 명세된 회귀를 정확히 커버 |
| (b) "completed 상태에서 어떤 전이도 거부" (test:219-237) | completed→complete 멱등 거부(errors_on :status), completed→release/start/cancel 전부 `{:error}`, `completed_at` 불변 단언 | ✅ 종료 상태 불변식의 멱등 우회까지 검증 |

- 테스트는 단순 `{:error}` 매칭에 그치지 않고 **부작용 부재(타임스탬프 불변 + AuditLog 카운트 불변)** 까지 단언하여 버그의 본질(덮어쓰기/로그 누적)을 정조준함 — 우수.
- `WorkOrder` alias(test:19), `Repo`(test:21) 모두 import/alias 되어 있어 신규 테스트 참조 정상.

### R2-3. [YAGNI] 미사용 헬퍼 삭제 — ✅ 적정

| 확인 항목 | 결과 | 근거 |
|-----------|------|------|
| `Audit.changeset/1` 삭제 | ✅ | audit.ex 현재 `put_log/3`만 존재(audit.ex:34-40). context 레벨 `changeset/1` 제거됨 |
| `Outbox.changeset/1` 삭제 | ✅ | outbox.ex 현재 `put_event/3`만 존재(outbox.ex:32-38). 제거됨 |
| `put_log`/`put_event` 헬퍼 유지 | ✅ | 둘 다 유지. production.ex create/update/transition_multi(put_log 3곳), release(put_event 1곳)에서 호출 |
| 스키마 내부 changeset 호출 유지 | ✅ | `put_log`→`AuditLog.changeset()`(audit.ex:38), `put_event`→`Event.changeset()`(outbox.ex:36) 호출. 대상 정의 존재: audit_log.ex:34, event.ex:35 |
| 삭제로 인한 깨진 참조 | ✅ 없음 | `grep -rn "Audit.changeset\|Outbox.changeset"` lib/test 결과 0건. 삭제된 것은 context 레벨 wrapper뿐이며 schema 레벨 `changeset/1`은 보존됨 |

- 삭제 범위가 정확: 호출처 0이던 context 레벨 `changeset/1` 2건만 제거, put_*가 내부적으로 의존하는 schema 레벨 `changeset/1`은 그대로 유지. 깨진 참조 없음 확인.

### Round 2 판정: APPROVED

Round 1의 NEEDS_FIX 사유였던 [필수] 멱등 전이 버그가 `from == to` 가드(work_order.ex:119-123)로 정확히 해소되었고, 종료 상태 불변식의 멱등 우회 경로까지 봉쇄됨. 회귀 테스트 2종이 거부 + 부작용(타임스탬프/AuditLog) 불변까지 검증한다. YAGNI 권고였던 context 레벨 `changeset/1` 2건 삭제도 깨진 참조 없이 안전하게 적용됨.

4대 불변식(AuditLog/상태머신/Outbox/이력성)은 Round 1에서 이미 통과. 추가 차단·수정 사유 없음.

> 비차단 잔여: `Outbox.put_event` 인라인 여부는 이벤트 확장 로드맵 관련 architect 판단 사항으로 남김(기능/안전과 무관, APPROVED에 영향 없음).
