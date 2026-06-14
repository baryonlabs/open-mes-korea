# 24. AI Safety Audit — AI 자연어 생산라인 구성 (propose→승인→실행)

독립 검증 수행자: ai-safety-guardian
검증 일자: 2026-06-14
기준: `docs/ai-native-architecture.md`, `CLAUDE.md`(AI 안전 원칙), `_workspace/23_architect_ai_line_settings.md`(체크포인트 10개)
검증 방식: 실제 코드 grep + 함수 경계 분석 + `mix test`(20 케이스)

## 최종 판정: ✅ APPROVED

AI 안전 위반(BLOCKER) 0건. 모든 핵심 불변식(AI 직접 쓰기 0 / Context API 경유 / 인간 승인 가드 / 전수 감사 / 상태머신 / 화이트리스트 / 원자성 / 생산데이터 보호)이 코드 수준에서 강제됨. 경미한 운영 참고(NON-BLOCKING) 1건.

---

## 검증 대상 파일

- `lib/open_mes/ai/ai.ex` (컨텍스트: propose/approve/reject/apply)
- `lib/open_mes/ai/ai_interaction.ex` (스키마 + 상태머신)
- `lib/open_mes/ai/provider.ex` (behaviour + active 선택)
- `lib/open_mes/ai/mock_provider.ex` (규칙 파서, 기본)
- `lib/open_mes/ai/claude_provider.ex` (Claude API, 키 있을 때만)
- `lib/open_mes/ai/skill_registry.ex` (화이트리스트)
- `lib/open_mes/production_line/production_line.ex` (ai_context, multi_*_step)
- `lib/open_mes_web/admin/settings/ai_line_live.ex` (승인 UI)
- `test/open_mes/ai_test.exs`, `test/open_mes/production_line_test.exs`

---

## 체크포인트별 결과

### CP1 — AI 권한 없는 데이터 열람 금지 ✅
- `ProductionLine.ai_context/2`는 가드 절 `when actor_role in @ai_roles`(system_admin|production_manager)로 인가. 그 외 role은 별도 절 `ai_context(_line_id, _role) -> {:error, :unauthorized}`로 차단 (`production_line.ex:263, 298`).
- `OpenMes.Ai.propose_line_config/3`가 ai_context를 거쳐서만 컨텍스트 획득 → role 인가가 propose 진입의 전제 (`ai.ex:73`).
- LiveView는 AdminLive `on_mount` + `Authorization.allowed?` 라우트 prefix 인가 + 컨텍스트 함수 재인가(이중 방어).
- 테스트: `ai_test.exs` "권한 없는 role 은 :unauthorized", "권한 없는 role 의 propose 는 :unauthorized" 통과.

### CP2 — AI Context API 경유, DB 직접 접근 금지 ✅
- grep 결과: `mock_provider.ex` / `claude_provider.ex` / `provider.ex`에 `Repo`/`Ecto`/`alias OpenMes.*` 호출 0건 (주석 내 언급만 존재).
- Provider behaviour 시그니처: `propose_line_diff(context :: map(), prompt :: String.t())` — Repo/Ecto/컨텍스트 모듈을 **인자로 받지 못함 → 구조적으로 DB 접근 불가** (`provider.ex:27`).
- ai_context/2는 plain map만 반환(line/current_steps/available_processes/available_equipment) — Ecto 구조체 누출 없이 라벨만 추출 (`production_line.ex:269-294`).

### CP3 — AI 기본 쓰기 권한 없음 (직접 쓰기 0) ✅
- `propose_line_config/3`(ai.ex:68-118): `Multi.insert(:record, AiInteraction.changeset(...))` + Audit + Outbox만. **step 쓰기(multi_*_step / create_step / LineStep) 0건** — propose 함수 범위 grep 결과 매칭 없음.
- step 쓰기(`multi_create_step`/`multi_update_step`/`multi_delete_step`) 호출처 전수 grep: `ai.ex`에서는 **`apply_proposal` 경로(run_apply, ai.ex:420/448/453)에서만** 호출. 다른 호출처는 `production_line_step_live.ex`의 인간 직접 UI(AI 무관).
- 테스트: "propose 는 AiInteraction 만 만들고 step 쓰기 0"(라인 단계 수 불변 단언) 통과.

### CP4 — 인간 승인 가드 (apply는 approved에서만) ✅
- `apply_proposal/2`에 `guard_approved/1` 가드: `%AiInteraction{approval_status: "approved"} -> :ok`, 그 외 `{:error, :not_approved}` (`ai.ex:206-228`).
- UI는 propose→approve→apply 순으로만 호출(`ai_line_live.ex:72-73` approve 성공 후 apply). proposed 상태 직접 apply 불가.
- 테스트: "미승인(proposed) 상태 apply 는 차단"(:not_approved + step 변경 0 단언) 통과.

### CP5 — 승인 흐름 상태머신 ✅
- `ai_interaction.ex:29-37` `@transitions` 맵이 허용 전이만 정의:
  proposed→{reviewed,approved,rejected} / reviewed→{approved,rejected} / approved→{executed,failed} / rejected·executed·failed=터미널([]).
- `transition_changeset/3`이 `validate_transition`으로 비허용 전이에 changeset 에러 추가 → 차단 (`ai_interaction.ex:99-105`).
- 모든 상태 전이(approve/reject/apply/fail)가 transition_changeset 경유.
- 테스트: "허용 전이만 통과"(proposed→executed, rejected→approved, executed→approved 모두 refute), "거부 → rejected, 이후 승인 불가"(터미널 후 approve가 `%Ecto.Changeset{}` 에러) 통과.

### CP6 — AiInteraction 전수 감사 ✅
- 모든 AI 상호작용이 AiInteraction 레코드 + AuditLog 동반:
  - propose → AuditLog `ai_interaction.propose` + Outbox `ai_action.proposed` (ai.ex:93-111)
  - approve → AuditLog `ai_interaction.approve` + Outbox `ai_action.approved` (ai.ex:139-157)
  - reject  → AuditLog `ai_interaction.reject` (ai.ex:179-188)
  - execute → AuditLog `ai_interaction.execute` + step별 `production_line_step.create/update/delete` (ai.ex:327-336, multi_*_step 내부)
  - fail    → AuditLog `ai_interaction.fail` (ai.ex:467-476)
- AiInteraction 필드가 감사 8항목 1:1 충족: actor_id(요청자), inserted_at(시각), referenced_resources(데이터범위), provider(모델), response_summary(응답요약), proposed_action(제안액션), reviewer_id/reviewed_at(승인자), execution_result(실행결과) (`ai_interaction.ex:39-53`).
- 테스트: audit_count/event_count 단언으로 propose/approve/execute/reject/step create·delete 모두 검증.

### CP7 — 근거 표시 (referenced_resources UI 노출) ✅
- propose 시 `referenced_resources`에 context 요약 저장(라인/현재단계수/선택가능공정·설비수/파서) (`mock_provider.ex:39-45`, `ai.ex:85`).
- UI 제안 패널이 diff와 **항상 함께** 근거 노출: `response_summary`(ai_line_live.ex:210) + `ref_rows`(현재단계수/선택가능공정·설비/파서, ai_line_live.ex:261-268) + provider 배지(ai_line_live.ex:187). "안전 UI 규칙" 주석으로 명시(ai_line_live.ex:182).

### CP8 — Tool Action 화이트리스트 (propose_* 만) ✅
- `SkillRegistry`에 `propose_line_config`(writes:false, Level 3) 1건만 등록 (`skill_registry.ex:11-21`).
- `propose_line_config/3` 진입 시 `SkillRegistry.allowed?(@intent) || {:error, :skill_not_allowed}` 게이트 (`ai.ex:72`). 미등록 intent 거부.
- apply 시 2차 방어: `build_apply_plan`이 `available_processes`/`available_equipment`(활성 카탈로그) 화이트리스트 외 process_code/equipment_code를 `{:error, {:invalid_op, ...}}`로 거부 → failed 롤백 (`ai.ex:262-280`).
- 테스트: "SkillRegistry 는 propose_line_config 만 허용"(delete_everything refute), "화이트리스트 외 공정명은 diff 제외" 통과.

### CP9 — 적용 원자성 (단일 Multi, 부분 적용 금지) ✅
- `run_apply/4`가 단일 `Ecto.Multi`로 removes→park→final_order→interaction transition→audit를 합성, `Repo.transaction(multi)` 1회 실행 (`ai.ex:309-347`).
- 실패 시 `{:error, _step, reason, _}` → 전체 롤백(부분 적용 없음) + `mark_failed`로 approved→failed 전이 + 사유 `execution_result` 기록(별도 트랜잭션이라 본 트랜잭션 롤백과 독립적으로 상태 기록) (`ai.ex:342-346, 459-477`).
- park 패턴(임시 양수 sequence)으로 unique[line_id,sequence] 충돌 회피하며 단일 트랜잭션 유지 (`ai.ex:425-434`).

### CP10 — Outbox 이벤트 ✅
- `ai_action.proposed`(propose, ai.ex:103-110), `ai_action.approved`(approve, ai.ex:149-156) 발행 — CLAUDE.md L79 명시 이벤트, 신규 발명 0.
- 테스트: event_count("ai_action.proposed")==1, event_count("ai_action.approved")==1 통과.

### 추가 — 생산 데이터 보호 ✅
- AI 코드(`lib/open_mes/ai/`) + 승인 UI에서 ProductionResult/LotConsumption/DefectRecord 접근 grep 결과 **0건**. 이 기능은 ProductionLine step(라인 구성)만 다룸. CLAUDE.md "ProductionResult/LotConsumption/DefectRecord AI 직접 삭제 불가" 충족.

---

## mix test 결과

```
mix test test/open_mes/ai_test.exs test/open_mes/production_line_test.exs
Finished in 0.3 seconds
Result: 20 passed
```

ai_test 커버리지: 상태머신 허용/비허용 전이, ai_context 인가/읽기전용, MockProvider 화이트리스트, propose(step 쓰기 0), approve→apply(executed + step AuditLog), 미승인 apply 차단, reject 터미널, 삭제 apply, SkillRegistry 화이트리스트, 권한 거부.

---

## 비차단 참고사항 (NON-BLOCKING)

⚠️ **CP-감사 (운영 참고, 안전 위반 아님)**: `claude_provider.ex:15` `@model "claude-opus-4-5"`.
- 영향: 키 없는 MVP에서는 `Provider.active/0`가 MockProvider를 선택하므로 ClaudeProvider는 **호출되지 않음** → 현재 안전/감사에 영향 0.
- 권고: `ANTHROPIC_API_KEY` 활성화 전, 모델 ID가 실재 모델인지 확인(감사 로그의 provider 라벨 정확성 목적). 이는 안전 불변식이 아닌 운영 정확성 항목이며 APPROVED 판정을 막지 않음.

ℹ️ `reviewed` 상태는 상태머신에 정의되어 있으나 UI/컨텍스트에 명시적 전이 핸들러 없음(MVP는 proposed→approved 직행). 설계 23번 §A.2가 "reviewed는 단순화로 스킵 가능"으로 허용 — 위반 아님.

---

## 결론

AI 안전 4대 불변식이 **구조적 경계**로 강제됨:
1. Provider는 plain map만 받아 Repo 접근 구조적 불가 (CP2)
2. propose는 데이터(AiInteraction)만 생성, step 쓰기는 apply_proposal(인간 승인자)에서만 (CP3, CP4)
3. 모든 상호작용 AiInteraction + AuditLog + Outbox 전수 기록 (CP6, CP10)
4. 상태머신/화이트리스트/원자성 코드 검증 (CP5, CP8, CP9)

**판정: APPROVED** — 차단 사유 없음.
