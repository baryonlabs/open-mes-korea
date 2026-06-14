# 26. AI 안전 감사 — AI 종합 조사 환경(시계열+미디어+생산, Level 1 Read-only)

**감사자:** ai-safety-guardian (독립 검증)
**일자:** 2026-06-14
**기준 문서:** `docs/ai-native-architecture.md`(Level 1 Read-only Assistant), `CLAUDE.md`, `_workspace/25_architect_ai_investigation.md`(체크포인트 10개)
**검증 방법:** 실제 코드 grep + 파일 정독 + `mix compile` + `mix test`(21 passed)

---

## 최종 판정: **APPROVED** ✅

8개 검증 항목 전부 충족. AI 안전 위반 **0건**. Level 1 Read-only 경계가 코드 수준에서 구조적으로 강제되며, 모든 조사가 전수 감사된다. NEEDS_FIX/BLOCKED 사유 없음. 경미한 개선 권고 1건(차단 아님)만 존재.

---

## 검증 결과 요약표

| # | 항목 | 결과 | 핵심 근거 |
|:--:|------|:--:|----------|
| 1 | AI DB 직접 접근 0 | ✅ | Provider investigate는 plain map + query만 받음. Repo/Ecto 인자 0. build_context만 DB 조회 + role 필터 |
| 2 | 쓰기 0 (Level 1 핵심) | ✅ | investigate 경로 유일 insert = AiInteraction(감사). Multi에 update/delete/Outbox 0 |
| 3 | 전수 감사 | ✅ | 모든 조사 = AiInteraction(intent="query", answered) + AuditLog(ai_interaction.query) 단일 Multi |
| 4 | 권한 role 필터 | ✅ | 삼중 방어: on_mount(Authorization.allowed?) + 메뉴 roles + build_context authorize/1 |
| 5 | 근거 표시 | ✅ | referenced(소스/규모/role)가 §(5) 패널에 AI 분석과 항상 동반 노출 |
| 6 | 대량 집계+샘플 | ✅ | 시계열 DB 집계(GROUP BY)+다운샘플 ≤60. raw 전량 함수 부재. 미디어 메타+링크만(바이너리 0) |
| 7 | 상태머신 무손상 | ✅ | answered는 @transitions 그래프 밖 평행 경로. changeset 직접 생성(transition_changeset 미경유) |
| 8 | 삭제 경로 부재 | ✅ | investigate 경로에 delete/destroy 0. 읽기 함수만 |

**mix test 결과:** `21 passed` (ai_investigation_test.exs + ingest_query_test.exs), `mix compile` 무관 경고만.

---

## 체크포인트별 상세

### ✅ 1. AI DB 직접 접근 0

- `Provider.investigate/2` 콜백 시그니처: `investigate(context(), query :: String.t())` — 인자는 plain map + 문자열뿐(`provider.ex:40`). 구현체가 Repo를 인자로 받을 방법이 구조적으로 없음.
- grep `Repo|Ecto|from(|alias OpenMes.(Production|Media|Ingest|MasterData)` on `mock_provider.ex`/`claude_provider.ex` → **모든 매치가 주석(moduledoc)뿐**, 실코드 0.
- `MockProvider.investigate/2`(`mock_provider.ex:53`)·`ClaudeProvider.investigate/2`(`claude_provider.ex:32`)는 `Map.get(context, ...)`로만 데이터 접근. DB 호출 0.
- DB 조회는 `Investigation.build_context/3`에 격리. 시계열은 `Ingest.summarize_metrics/downsample`, 미디어는 `Media.list_assets_by_equipment/count_by_type`, 생산은 `Reports.defect_summary/defects_by_code`를 호출 후 plain map으로만 Provider에 전달(`investigation.ex:254-255`).
- `build_context`는 role 인가 후에만 조회: `authorize(role)` → `fetch_equipment` → 조립(`investigation.ex:64-93`).

### ✅ 2. 쓰기 0 (Level 1 핵심)

- grep `Repo.(insert|update|delete|...)|Multi.(update|delete)` on `investigation.ex` → **매치 0**.
- investigate의 유일한 부수효과는 `Multi.insert(:record, AiInteraction.changeset(...))` + `Audit.put_log(:audit, ...)`(`investigation.ex:269-285`). 즉 감사 레코드 1건 + AuditLog 1건뿐.
- ProductionResult/LOT/DefectRecord/시계열/미디어 **쓰기 0**. Outbox(Event) 미생성 — 테스트가 `Repo.aggregate(Event, :count) == outbox_before`로 직접 검증(test:171).
- 테스트 "조사는 AiInteraction(query) 외 도메인 쓰기 0"(test:174): 조사 후 `equipment_measurements` count 불변, AiInteraction은 +1만 증가 확인.

### ✅ 3. 전수 감사

- `investigate/3`가 단일 `Repo.transaction(Multi)`로 AiInteraction + AuditLog를 원자 기록(`investigation.ex:269-286`).
- AiInteraction 필드 충족: `actor_id`, `intent="query"`, `prompt`(질의), `response_summary`(분석 요약), `referenced_resources`(근거 stringify), `proposed_action: nil`, `approval_status="answered"`, `provider`.
- AuditLog: `action="ai_interaction.query"`, `resource_type="ai_interaction"`, `resource_id=rec.id`, `after`에 intent/status/equipment_code/provider 포함(`investigation.ex:271-285`).
- 테스트 검증(test:142): AuditLog +1, action="ai_interaction.query" 1건, proposed_action=nil, referenced_resources["role"] 기록 확인.

### ✅ 4. 권한 role 필터 (삼중 방어)

- **함수 인가**: `build_context/3` → `authorize(role)`, `@investigation_roles = ~w(system_admin production_manager quality_manager)`, 그 외 `{:error, :unauthorized}`(`investigation.ex:313-314`). 화면 우회 직접 호출도 차단.
- **라우트(on_mount)**: `AdminLive.track_path_and_authorize`가 `Authorization.allowed?(role, path)` 미충족 시 `{:halt, redirect}` + 한국어 flash(`admin_live.ex:59-73`).
- **메뉴 roles**: `/admin/ai/investigate` 항목 `roles: ["production_manager", "quality_manager"]`, system_admin은 `Authorization.allowed?("system_admin", _) → true`로 항상 포함(`admin_components.ex:116-121`, `authorization.ex:97`).
- referenced.role에 조사 권한 기록(`investigation.ex:88`) — 누가 어떤 권한으로 봤나 감사.
- 테스트: operator role 거부(build_context + investigate 양쪽), admin/quality 허용 확인(test:82-95).

### ✅ 5. 근거 표시

- `build_context`가 referenced 맵 생성: sources, timeseries_points_sampled, timeseries_metric_count, media_assets_count, role, generated_at(`investigation.ex:82-90`).
- Provider 결과의 referenced = context.referenced 그대로 통과(MockProvider:72, ClaudeProvider:92) — 근거 일관.
- UI §(5) 패널: "측정값 N건을 M개 지표로 요약(다운샘플 ≤60), 미디어 N건, 생산 실적·불량. 권한: {role}. 소스: ..."를 AI 분석과 **항상 함께** 노출(`investigate_live.ex:287-296`). 추가로 시계열 차트·미디어 표·생산 gauge로 본 데이터 직접 시각화.

### ✅ 6. 대량 집계+샘플 (토큰/환각 방어)

- `Ingest.summarize_metrics/3`: DB측 `GROUP BY metric_key` 집계(count/avg/min/max) + DISTINCT ON last값. raw 행을 컨텍스트로 반환하지 않음(`ingest.ex:91-123`).
- `Ingest.downsample/5`: TimescaleDB `time_bucket` 버킷 평균, 버킷 폭 = span/buckets로 **포인트 ≤ buckets(기본 60)** 보장(`ingest.ex:146-168`). raw 전량 조회 함수 자체가 부재.
- 미디어: `list_assets_by_equipment`는 limit ≤20, 반환 필드는 메타(id/type/captured_at/object_key/state/file_size/meta/reference)뿐 — 바이너리/썸네일 0(`media.ex:86-97`, `investigation.ex:182-194`). `reference_for`는 "bucket/object_key" 문자열만(`media.ex:123-129`).
- defect_limit 20(`investigation.ex:34`)으로 recent_defects 상한.
- 테스트: 측정값 200행 시딩 → sample ≤60, total_points=200(요약 명시) 확인(test:104-116). 미디어 메타만 노출 확인(test:119-129).

### ✅ 7. 상태머신 무손상

- `@statuses`에 "answered" 추가되었으나 `@transitions` 전이 그래프에는 미등장(터미널, 진입 전이 없음)(`ai_interaction.ex:29-40`).
- answered는 `changeset/2`(직접 생성)로만 진입, `transition_changeset/3`(propose 상태머신 검증)을 거치지 않음 — 23번 `proposed→reviewed→approved→executed/failed` 전이 그래프 무손상(`ai_interaction.ex:26-28` 주석 명시 + 코드 일치).
- investigate는 intent="query"로 23번 `propose_line_diff` 경로와 완전 분리(별 함수·별 Provider 콜백).

### ✅ 8. 삭제 경로 부재

- grep `delete|destroy` on investigation/mock/claude → 실코드 0(주석 1건뿐).
- 조사 경로 전체가 읽기 + 단일 감사 insert. ProductionResult/시계열/미디어에 대한 update/delete API가 investigate 경로에 존재하지 않음.

---

## 경미한 개선 권고 (차단 아님 — APPROVED 유지)

1. **(낮음) 생산 컨텍스트의 설비별 세분 미적용** — `build_production/3`(`investigation.ex:204-223`)는 `_equipment`를 무시하고 `Reports.defect_summary(%{from, to})`로 **기간 전체** 생산 실적을 요약한다. 설계 §1.5의 "키 브리지로 equipment.id 기준 생산 조회"가 MVP에서 미구현(주석에 "설비별 세분은 후속"으로 명시). 안전 위반은 아니나(여전히 role 필터된 집계, 권한 없는 데이터 노출 아님), referenced의 sources에 "특정 설비"라는 인상을 줄 수 있어 AI 분석이 "이 설비의 불량률"로 오해될 여지가 있다. 후속에서 equipment.id FK 필터 추가 권장. **근거 표시 정확성** 차원의 개선이며 Level 1 쓰기·권한 경계와 무관.

2. **(정보) ClaudeProvider는 context 전체를 JSON 직렬화해 전송**(`claude_provider.ex:48`). build_context가 이미 집계+다운샘플(≤60)·메타만 담으므로 raw 폭발 위험은 차단됨. equipment_id(binary_id)가 프롬프트에 포함되나 식별자일 뿐(설계 §1.2 합치). 문제 없음.

---

## 검증 명령 로그

```
$ grep -nE "Repo\.(insert|update|delete|...)|Multi\.(update|delete)" lib/open_mes/ai/investigation.ex
  → (매치 0)
$ grep -nE "Repo|Ecto|from\(|alias OpenMes\.(Production|Media|Ingest|MasterData)" \
    lib/open_mes/ai/mock_provider.ex lib/open_mes/ai/claude_provider.ex
  → 전부 주석(moduledoc)
$ grep -nE "delete|destroy" investigation/mock/claude
  → 주석 1건뿐 (실코드 0)
$ mix compile
  → 성공 (조사 관련 무경고)
$ mix test test/open_mes/ai_investigation_test.exs test/open_mes_ingest/ingest_query_test.exs
  → 21 passed
```

테스트가 직접 검증한 안전 불변식: 미인가 role 거부(build_context+investigate), 다운샘플≤60, 미디어 메타-only, AiInteraction(query/answered/proposed_action=nil)+AuditLog 1건+Outbox 0, 도메인 쓰기 0.

---

## 결론

AI 종합 조사 환경은 `ai-native-architecture.md`의 **Level 1 Read-only Assistant** 원칙을 코드 수준에서 정확히 구현한다. AI는 권한 필터된 plain map만 보고(DB 직접 접근 0), 쓰기·삭제·승인흐름이 구조적으로 부재하며, 모든 조사가 AiInteraction+AuditLog로 전수 감사되고, 대량 시계열은 집계+다운샘플로, 미디어는 메타만으로 토큰/환각을 방어한다. 23번 propose 상태머신은 answered 평행 경로로 무손상이다.

**최종 판정: APPROVED** ✅
