# 23. Architect — AI 자연어 생산라인 구성(propose→승인→실행) + 설정 카테고리(skill/mcp/connector)

대상: (A) 사용자가 자연어("건조 다음에 예열 공정 추가, 포장을 마지막으로")로 라인 구성 변경을 지시하면 AI가 **변경안(diff)만 제안** → 사람이 검토·승인 → 시스템이 실제 step 변경 적용. (B) 사이드바 "설정" 그룹에 생산라인 구성/AI 라인 구성/Skill/MCP/Connector 메뉴 통합.

선행: 22번(`ProductionLine` 컨텍스트 + `propose_line_config` 슬롯 예약 + 설정 메뉴 그룹 신설). 이 문서는 22번이 "주석으로 예약"만 한 AI 경로를 **실제로 구현**하고, 설정 그룹을 5개 항목으로 확장한다.

원칙: **CLAUDE.md·ai-native-architecture.md AI 안전 원칙 엄수**(AI 직접 쓰기 0, Context API 경유, propose→승인→실행 상태머신, AiInteraction 감사, 근거 표시). pi(1순위만 실구현, 2순위 스텁). 기존 화면/라우트/도메인 무손상. 한국어 UI/영문 식별자.

---

## 0. 핵심 설계 결정 (요약 5)

1. **AI는 ProductionLine 쓰기 함수를 절대 직접 호출하지 않는다 — `propose_line_config/2`는 `AiInteraction(proposed)` + diff만 만든다.** AI 경로의 산출물은 데이터(제안 레코드)일 뿐 부수효과 0. 실제 `create_step/update_step/delete_step/reorder_step`은 **오직 `apply_proposal/2`(actor=인간 승인자)** 에서만 호출된다. 이 분리가 "AI는 propose, 실행은 인간 승인 후 시스템"이라는 단일 불변식의 코드 경계다. 22번 docstring이 예약한 슬롯을 그대로 채운다(컨텍스트 소유자 = ProductionLine — MasterData 아님, 결정 22-#1 계승).

2. **AI는 DB를 보지 않는다 — `ProductionLine.ai_context/2`(권한 필터된 읽기 전용 컨텍스트)만 본다.** AI에 넘기는 입력은 (a) 현재 라인 step 목록(공정/설비 라벨), (b) 선택 가능한 활성 공정/설비 카탈로그뿐. actor의 role로 필터(예: production_manager/system_admin만 ai_context 호출 가능). AI Context API 패턴(`docs/ai-native-architecture.md`)을 **컨텍스트 함수**로 구현(MVP는 HTTP `/ai/context` 엔드포인트 불필요 — 내부 함수 호출이 동일 보증 제공, 과설계 금지). LLM 어댑터는 이 context map만 받고 Repo/Ecto에 접근 불가(인자로 못 받음).

3. **LLM 호출은 `OpenMes.Ai.Provider` behaviour 뒤에 둔다 — 구현체 2종(Mock 규칙파서 / Claude API).** 동일 인터페이스 `propose_line_diff(context, prompt) :: {:ok, %{diff, summary, referenced}} | {:error, _}`. **기본 = Mock**(키 없을 때 데모 동작, 외부 의존 0). `ANTHROPIC_API_KEY` 환경변수가 있으면 `ClaudeProvider`(claude-sonnet, `req` HTTP). config 게이트 `config :open_mes, OpenMes.Ai, provider: ...`. **MVP는 mock만으로 전 흐름(propose→승인→적용) 동작** — Claude 실호출은 키 있을 때만. 이것이 "데모 가능 + pi" 핵심.

4. **diff는 선언적 op 목록(추가/삭제/순서변경)이며, 적용 시 op→기존 컨텍스트 쓰기함수로 1:1 번역된다.** diff 형식: `[%{op: "add_step", process_code, equipment_code?, after_sequence?}, %{op: "remove_step", sequence|process_code}, %{op: "reorder", ...최종 순서...}]`. `apply_proposal/2`가 이 op들을 **하나의 `Ecto.Multi`** 안에서 `create_step/delete_step/update_step` 호출(각자 AuditLog 동반) + 마지막에 `AiInteraction` 상태 `approved→executed` 전이 + AuditLog(`ai_interaction.execute`). 부분 실패 시 전체 롤백 + `failed`. **새 쓰기 메커니즘 발명 0** — 22번 step 쓰기 재사용.

5. **설정 그룹 5항목 중 1개만 실동작(AI 라인 구성), 4개는 메뉴+스텁(skill 목록 / mcp 폼 / connector 카탈로그).** Skill = 등록된 tool action(`propose_line_config`) 목록 + on/off 표시(레지스트리 읽기, MVP는 토글 저장 X 또는 config 표시). MCP = 서버 URL/활성 폼 스텁(저장만, 실제 연결 후속). Connector = EXT-5 연동 허브 카탈로그 진입점(`/extensions` 재사용 또는 스텁 카드). 전부 `system_admin` role. **과구현 금지(pi)** — 자리+기본 화면, 외부 연결 코드 0.

---

## A. AI 자연어 생산라인 구성 (1순위 — 실구현)

### A.1 신규 엔티티 `AiInteraction` (도메인 모델 정의됨, 미구현)

`docs/domain-model.md` L117-128 정의를 구현. binary_id + AuditLog 연결. **모든 AI 상호작용의 감사 레코드이자 승인 흐름 상태 보유자.**

| 필드 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | binary_id | PK | |
| `actor_id` | string | required | 요청자(자연어 입력한 사람) |
| `intent` | string | required | 의도 분류(MVP: `"propose_line_config"`) |
| `prompt` | text | required | 사용자 자연어 원문 |
| `response_summary` | text | nullable | AI 응답 요약(근거 설명, 한국어) |
| `referenced_resources` | map(jsonb) | nullable | AI가 본 context 범위(라인 id, 공정/설비 카탈로그 스냅샷 — 근거 표시용) |
| `proposed_action` | map(jsonb) | nullable | 제안 diff(op 목록) + 대상 line_id |
| `approval_status` | string | required, default `"proposed"` | 상태머신(아래) |
| `provider` | string | nullable | `"mock"` / `"claude"`(+모델) — 감사(어떤 모델이 제안했나) |
| `reviewer_id` | string | nullable | 승인/거부자 |
| `reviewed_at` | utc_datetime_usec | nullable | 승인/거부 시각 |
| `execution_result` | map(jsonb) | nullable | 적용 결과(생성/삭제 step id, 또는 실패 사유) |
| `inserted_at`/`updated_at` | utc_datetime_usec | | created_at = inserted_at |

테이블 `ai_interactions`. 인덱스: `index(:approval_status)`, `index(:actor_id)`, `index(:inserted_at)`.

> pi: `provider`·`reviewer_id`·`reviewed_at`·`execution_result`는 도메인모델 8필드에 더한 **감사 필수 보강**(ai-native-architecture.md "Audit: 요청자/시각/데이터범위/모델/응답요약/제안액션/승인자/실행결과" 8항목과 1:1 대응 — 임의 추가 아님). 그 외 확장 금지.

### A.2 상태머신 (CLAUDE.md L61 — 절대 임의 전이 추가 금지)

```
proposed ──(검토 열람)──> reviewed ──(승인)──> approved ──(적용 성공)──> executed
   │                          │                     │
   └────(거부)──> rejected ◄───┘                     └──(적용 실패)──> failed
```

- `proposed`: AI가 막 제안(`propose_line_config` 결과). 부수효과 0.
- `reviewed`(선택): 승인자가 열람만 한 상태. MVP는 proposed→approved 직행 허용(reviewed는 단순화로 스킵 가능, 단 거부는 어느 상태서든 가능). **상태머신 정의는 유지**(전이 함수가 검증).
- `approved`: 승인 확정. **이 시점부터 apply 가능**.
- `rejected`: 거부(터미널). 적용 불가.
- `executed`: 실제 step 변경 적용 완료(터미널).
- `failed`: 적용 중 오류 → 전체 롤백, 사유 `execution_result`에 기록(터미널, 재시도는 새 제안).

전이 함수(컨텍스트): `approve_proposal/2`(proposed|reviewed→approved), `reject_proposal/3`(→rejected, 사유), `apply_proposal/2`(approved→executed|failed). **각 전이는 AuditLog + Outbox 이벤트 동반**(아래 A.6).

### A.3 AI 안전 흐름: context → propose → 승인 → 실행

```
[1] 사용자 자연어 입력 (LiveView /admin/settings/ai-line, actor=current_actor, role 인가)
        │
        ▼
[2] ProductionLine.ai_context(line_id, actor)        ← 권한 필터된 읽기 전용 컨텍스트(쓰기 0)
        │   반환: %{line: %{code,name}, current_steps: [...], available_processes: [...], available_equipment: [...]}
        ▼
[3] OpenMes.Ai.propose_line_config(context, prompt, actor)   ← AI 경로 진입점
        │   ├─ Provider.propose_line_diff(context, prompt)   ← behaviour(mock|claude). Repo 접근 불가.
        │   └─ AiInteraction 생성(status: proposed, proposed_action: diff, referenced_resources: context 요약, provider)
        │      + AuditLog(ai_interaction.propose) + Outbox(ai_action.proposed)
        ▼   반환: {:ok, %AiInteraction{}}  (← 부수효과: step 변경 0. 제안 레코드만)
[4] UI: diff 미리보기(추가/삭제/순서 step) + 근거(referenced_resources, response_summary) 표시
        │      [승인] [거부] 버튼
        ├──(거부)──> ProductionLine reject_proposal(id, reason, reviewer) → rejected
        └──(승인)──> approve_proposal(id, reviewer) → approved
                          │
                          ▼
[5] apply_proposal(id, reviewer)   ← 여기서 처음으로 실제 step 쓰기(actor=reviewer)
        │   단일 Ecto.Multi:
        │     ├─ diff op 들 → create_step/delete_step/update_step (각 AuditLog 동반, 22번 재사용)
        │     ├─ AiInteraction approved→executed + execution_result
        │     └─ AuditLog(ai_interaction.execute) + Outbox(ai_action.approved)
        ▼   성공 → executed / 실패 → 전체 롤백 + failed
[6] 라인 모니터(/admin/reports/production?line=...) 에 즉시 반영(22번 steps_for_monitor 그대로)
```

**불변식 코드 경계**:
- AI(Provider 구현체)는 `context`(plain map)와 `prompt`(string)만 받는다 → Repo/Ecto/컨텍스트 모듈을 인자로 받지 못함 → **구조적으로 쓰기 불가**.
- `create_step` 등 step 쓰기는 `apply_proposal` 외에서 AI 경로가 호출하는 지점이 0 (grep 검증 대상).
- `apply_proposal`은 `status == approved` 가드 — proposed/rejected/executed 직접 적용 차단.

### A.4 `ProductionLine.ai_context/2` (AI Context API — 권한 필터 읽기 전용)

22번 컨텍스트에 추가(소유자 일관). **쓰기 0**, role 인가 내장.

```elixir
@doc """
AI에 제공할 권한 필터된 라인 구성 컨텍스트(읽기 전용). AI는 DB 직접 접근 금지 —
이 함수가 반환한 plain map 만 LLM 어댑터에 전달된다(docs/ai-native-architecture.md AI Context API).

인가: actor_role 이 라인 구성 권한(system_admin|production_manager)일 때만 컨텍스트 반환.
그 외 {:error, :unauthorized}. (AI는 권한 없는 데이터를 볼 수 없음 — CLAUDE.md L85.)

반환: {:ok, %{
  line: %{id, line_code, name},
  current_steps: [%{sequence, process_code, process_name, equipment_code, equipment_name}],
  available_processes: [%{process_code, name}],   # 활성 공정 — AI가 add 대상 선택지
  available_equipment: [%{equipment_code, name}]  # 활성 설비
}}
"""
def ai_context(line_id, actor_role)
```

- 내부: `steps_for_monitor/1`(22번 재사용) + `MasterData.list_processes(active: true)` + `list_equipment(active: true)` 라벨만 추출. ID는 내부 매핑용으로만 보유(LLM에는 code/name 위주로 — 환각 시 code로 검증).
- **available_*는 "선택지 화이트리스트"**: AI가 제안한 process_code가 이 목록에 없으면 apply 단계에서 거부(A.5 검증).

### A.5 `OpenMes.Ai` 컨텍스트 + Provider behaviour

신규 바운디드 컨텍스트 `lib/open_mes/ai/`.

```
lib/open_mes/ai/
  ai.ex                  ← 컨텍스트: propose_line_config/3 (context→Provider→AiInteraction 생성)
                            + list_interactions/1, get_interaction/1 (조회)
  ai_interaction.ex      ← AiInteraction 스키마 + changeset + 상태 전이 검증(allowed_transition?)
  provider.ex            ← @behaviour: propose_line_diff(context, prompt) :: {:ok, result} | {:error, term}
                            + diff op 타입 문서. + 활성 provider 선택(config).
  provider/
    mock_provider.ex     ← 규칙 기반 자연어 파서(키 없을 때 — 기본). 외부 의존 0.
    claude_provider.ex   ← Claude API(req). ANTHROPIC_API_KEY 있을 때만. (스텁 가능 — 2순위)
```

**Provider behaviour**:
```elixir
defmodule OpenMes.Ai.Provider do
  @type context :: map()    # ProductionLine.ai_context/2 반환 (plain map — Repo 접근 불가)
  @type diff_op :: map()    # %{op: "add_step"|"remove_step"|"reorder", ...}
  @type result :: %{diff: [diff_op], summary: String.t(), referenced: map()}

  @callback propose_line_diff(context, prompt :: String.t()) :: {:ok, result} | {:error, term}

  # 활성 provider: ANTHROPIC_API_KEY 있고 config provider=claude 면 Claude, 아니면 Mock.
  def active, do: Application.get_env(:open_mes, __MODULE__, [])[:impl] || resolve_default()
  defp resolve_default do
    if System.get_env("ANTHROPIC_API_KEY"), do: ClaudeProvider, else: MockProvider
  end
end
```

**MockProvider (1순위 실구현 — 데모 핵심)**: 자연어를 정규식/키워드로 파싱해 diff 생성. 한국어 패턴 최소 셋:
- `"X 다음에 Y 추가"` / `"X 뒤에 Y 공정 추가"` → `add_step(process=Y, after=X)`. Y/X는 available_processes의 process_name/code 매칭(부분일치).
- `"Y를 마지막으로"` / `"Y 맨 뒤로"` → `reorder(Y → last)`.
- `"X 삭제"` / `"X 빼기"` → `remove_step(process=X)`.
- `"X를 Y 앞으로"` → `reorder`.
- 매칭 불가 토큰 → summary에 "해석 못한 지시" 명시(빈 diff 가능 — 안전). available_*에 없는 공정명 → summary 경고.
- referenced: 입력 context 요약(본 라인 + 카탈로그 크기). **근거 표시 필수(CLAUDE.md L88)** 충족.

> Mock은 "완벽한 NLU"가 목표 아님. **승인 흐름·diff·감사·적용 전 과정을 키 없이 데모**하는 게 목적(pi, 데이터 확보 우선과 동형 — 일단 동작).

**ClaudeProvider (2순위 — 키 있을 때만)**: `req`로 Anthropic Messages API 호출. system 프롬프트로 "context 안 available_processes에서만 골라 diff JSON 반환, 다른 공정 발명 금지" 강제 + tool/JSON 모드. 응답 JSON→diff op. 실패/타임아웃 → `{:error, _}` → UI "AI 제안 실패, 다시 시도". **MVP는 스텁(키 없으면 호출 안 됨)으로 두고 인터페이스만 확정 가능** — domain-engineer 판단(pi).

의존성: `mix.exs`에 `{:req, "~> 0.5"}` 추가(ex_aws가 이미 optional dep으로 가지므로 충돌 0). Mock 경로는 req 불사용.

### A.6 AuditLog / Outbox 트리거 (모든 AI 쓰기 — 예외 없음)

| 동작 | AuditLog action | resource_type | Outbox event | before/after |
|------|-----------------|---------------|--------------|--------------|
| AI 제안 생성 | `ai_interaction.propose` | ai_interaction | `ai_action.proposed` | nil / 제안 스냅샷 |
| 승인 | `ai_interaction.approve` | ai_interaction | `ai_action.approved` | {status: proposed} / {status: approved, reviewer} |
| 거부 | `ai_interaction.reject` | ai_interaction | (없음 또는 ai_action.rejected) | {proposed} / {rejected, reason} |
| 적용(실행) | `ai_interaction.execute` + **step별 production_line_step.create/update/delete** | ai_interaction / production_line_step | (step 변경은 기존 step 이벤트 없음 — 22번 동일) | {approved} / {executed, result} |
| 적용 실패 | `ai_interaction.fail` | ai_interaction | (없음) | {approved} / {failed, error} |

- Outbox 이벤트 `ai_action.proposed`/`ai_action.approved`는 **CLAUDE.md L79에 이미 명시된 주요 이벤트** — 신규 발명 아님, 정식 사용.
- 전부 `Audit.put_log`/`Outbox.put_event`(기존 Multi 스텝 헬퍼) 재사용. actor_id 필수(제안=요청자, 승인/거부/적용=reviewer).
- `apply_proposal`의 step 변경은 22번 `create_step` 등을 **같은 Multi에 합성**(각 함수가 이미 Multi 기반이 아니면, op→changeset을 apply_proposal 내부 Multi에 직접 인라인 — domain-engineer가 22번 create/update/delete의 Multi 조립을 재사용하도록 private 헬퍼 노출 또는 op 인라인). 핵심: **step AuditLog 누락 0**.

### A.7 승인 흐름 UI (`/admin/settings/ai-line`)

LiveView `Admin.Settings.AiLineLive`(AdminLive 베이스, 기존 admin_shell/page_header/modal 재사용).

화면 구성(단일 LiveView, live_action 불필요 또는 :index/:show):
- **상단**: 라인 선택 드롭다운(`ProductionLine.list_lines(active: true)`) — 어느 라인을 구성할지.
- **자연어 입력**: textarea + "AI 제안 받기" 버튼. placeholder 예시("건조 다음에 예열 공정 추가, 포장을 마지막으로").
- **제안 결과 패널**(제안 생성 후):
  - **diff 미리보기**: 추가(초록 +)/삭제(빨강 −)/순서변경(파랑) step을 현재 순서와 대비해 표 또는 before→after 2열.
  - **근거(referenced_resources)**: "참조: 라인 LINE-INJ 현재 10단계, 선택 가능 공정 12종" + `response_summary`(AI 설명) + **provider 배지**("Mock 파서" / "Claude sonnet").
  - **버튼**: [승인하고 적용] [거부]. 거부 시 사유 입력(선택).
- **이력 목록**: 이 라인의 최근 AiInteraction(상태 배지 proposed/approved/executed/rejected/failed + 시각 + actor). 감사 가시성.
- 승인 클릭 → `approve_proposal` → `apply_proposal` 연속(또는 승인 후 별도 "적용" 버튼 2단계 — pi: 승인=적용 1버튼이 단순, 단 상태는 approved→executed 정확히 기록). 성공 시 flash + 모니터 링크. 실패 시 flash(사유) + 상태 failed 표시.

**안전 UI 규칙**: 제안 패널은 항상 **근거를 diff와 함께** 노출(CLAUDE.md L88). 적용 버튼은 status=approved(또는 승인 직후)에서만 활성. AI가 직접 "적용됨"으로 보이는 표현 금지 — 항상 "제안"과 "승인 후 적용" 구분.

### A.8 권한 / role 인가

- `/admin/settings/ai-line` role: `system_admin` + `production_manager`(라인 구성 권한자 — 22번 라인 구성과 동일 권한자).
- `ai_context/2`·`propose_line_config`도 동일 role 게이트(이중 방어: 화면 인가 + 컨텍스트 함수 인가).
- 승인/적용(`approve_proposal`/`apply_proposal`)도 동일 role. MVP는 "요청자=승인자 동일인 허용"(단일 사용자 데모), 단 **AiInteraction에 actor_id≠reviewer_id 구분 필드는 유지**(향후 분리 승인 대비, 이미 A.1에 있음).

---

## B. 설정 카테고리 — skill / mcp / connector 메뉴 통합 (2순위 대부분 스텁)

### B.1 사이드바 "설정" 그룹 확장 (admin_components.ex `@menu`)

22번이 만든 "설정" 그룹(현재 "생산라인 구성" 1항목)에 4항목 추가:

```elixir
%{
  group: "설정",
  items: [
    %{label: "생산라인 구성", path: "/admin/settings/lines", enabled: true,
      roles: ["production_manager"]},                                    # 22번(기존)
    %{label: "AI 라인 구성", path: "/admin/settings/ai-line", enabled: true,
      roles: ["production_manager"]},                                    # A — 실동작(1순위)
    %{label: "Skill 설정", path: "/admin/settings/skills", enabled: true,
      roles: []},                                                        # 스텁 — system_admin 전용
    %{label: "MCP 설정", path: "/admin/settings/mcp", enabled: true,
      roles: []},                                                        # 스텁
    %{label: "Connector 설정", path: "/admin/settings/connectors", enabled: true,
      roles: []}                                                         # 스텁(EXT-5 진입)
  ]
}
```

- `roles: []` = `system_admin` 전용(Authorization이 항상 system_admin 포함). Skill/MCP/Connector는 시스템 구성이라 system_admin만.
- 메뉴 한 줄 추가로 `Authorization.roles_for_path` 자동 결정(별도 매핑 0 — 22번 단일 원천 원칙 유지).
- `enabled: true`지만 화면은 스텁 — "준비중"이 아니라 "기본 화면 + 후속 안내"로 둔다(자리+기본 동작, pi).

### B.2 Skill 설정 (`/admin/settings/skills`) — 등록 액션 목록 (2순위)

AI가 쓸 수 있는 **Tool Action(skill) 화이트리스트**를 보여준다. CLAUDE.md L93 "허용된 Tool Action만 등록 가능: propose_*/draft_*/suggest_*".

- **레지스트리**: `OpenMes.Ai.SkillRegistry` (얇은 모듈, 상태 없음 — 확장 레지스트리 패턴 차용). 등록 액션 목록을 코드/ config로 보유:
  ```elixir
  @skills [
    %{id: "propose_line_config", name: "AI 라인 구성 제안", category: "production_line",
      level: "Level 3 (승인 필요)", writes: false, enabled: true,
      description: "자연어 라인 구성 변경안 제안. 직접 쓰기 없음, 승인 후 적용."}
  ]
  ```
- **화면**: 표(액션명 | 카테고리 | AI 레벨 | 쓰기여부 | 상태 토글). MVP는 **목록 표시 + on/off 토글(표시용 또는 config 반영)**. 실제 토글 저장은 후속(pi — 1개 액션뿐이라 목록 표시가 핵심).
- **안전 표기**: 각 skill의 "writes: false(제안만)" / AI 레벨을 명시 → AI 안전 원칙 가시화. propose_* 만 등록 가능(write 액션 등록 차단은 레지스트리 정책 주석).

### B.3 MCP 설정 (`/admin/settings/mcp`) — 폼 스텁 (2순위)

외부 MCP 서버 연결 설정 자리. **실제 MCP 연결 코드 0(후속).**

- **화면**: 폼 스텁 — 서버 이름 / URL / 활성 체크 / (선택)인증 토큰. "저장" 버튼은 config 또는 단순 테이블에 저장(MVP는 저장 없이 placeholder도 허용 — pi). 안내문: "MCP(Model Context Protocol) 서버 연결은 후속 단계에서 활성화됩니다. AI는 등록된 MCP 도구도 propose→승인 흐름을 거칩니다."
- **저장 시(선택 구현)**: `mcp_servers` 테이블(name, url, active, inserted_at) — system_admin AuditLog. **단, pi상 MVP는 스텁 폼(저장 미연동)으로 시작 권장**, 저장 필요해지면 테이블 추가.
- **안전 경계 명시**: MCP로 들어온 외부 도구도 "AI 직접 쓰기 금지·승인 흐름" 동일 적용(화면 안내문 + 설계 주석).

### B.4 Connector 설정 (`/admin/settings/connectors`) — EXT-5 진입점 (2순위)

EXT-5 연동 허브(CSV/REST/디지털트윈/시뮬레이션) 진입점. `docs/extension-roadmap.md` EXT-5.

- **화면**: 연동 카탈로그/스텁 — EXT-5 어댑터 분류(파일 CSV/Excel, REST/Webhook, 산업 프로토콜, 디지털트윈, 시뮬레이션) 카드 목록 + 각 상태(MVP-1 실동작/MVP-2/후순위 배지). 실제 연결 설정은 후속.
- **재사용**: 기존 `/extensions` 카탈로그 LiveView가 EXT-5를 카드로 노출하므로, MVP는 **`/admin/settings/connectors`를 EXT-5 안내 + `/extensions` 링크**로 두는 것이 최소(별도 화면 안 만들고 진입점만). 또는 간단 스텁 LiveView. domain-engineer 판단(pi — 진입점 확보가 목적).
- 안내문: "외부 시스템(ERP/디지털트윈/CSV) 연동은 EXT-5 연동 허브에서 관리됩니다. 인바운드 데이터는 EXT-1 수집 경로로 합류합니다."

### B.5 라우트 (router.ex 기존 Settings scope 확장)

```elixir
scope "/admin", OpenMesWeb.Admin.Settings do
  pipe_through :browser
  # 22번(기존)
  live "/settings/lines", ProductionLineLive, :index
  live "/settings/lines/new", ProductionLineLive, :new
  live "/settings/lines/:id/edit", ProductionLineLive, :edit
  live "/settings/lines/:id/steps", ProductionLineStepLive, :index
  live "/settings/lines/:id/steps/new", ProductionLineStepLive, :new
  live "/settings/lines/:id/steps/:step_id/edit", ProductionLineStepLive, :edit
  # 23번 신규
  live "/settings/ai-line", AiLineLive, :index            # A — 실동작
  live "/settings/skills", SkillSettingsLive, :index       # 스텁 목록
  live "/settings/mcp", McpSettingsLive, :index            # 스텁 폼
  live "/settings/connectors", ConnectorSettingsLive, :index  # 스텁 카탈로그
end
```

`use OpenMesWeb.Admin.AdminLive`(on_mount 인가 자동). prefix 매칭으로 메뉴 트리 role이 인가 커버.

---

## 우선순위 (pi)

| 순위 | 항목 | 깊이 |
|:---:|------|------|
| **1순위 (실동작)** | AiInteraction 엔티티 + 마이그레이션 + 상태머신 | 완전 구현 |
| | `ProductionLine.ai_context/2` (권한 필터 컨텍스트) | 완전 구현 |
| | `OpenMes.Ai` 컨텍스트 + Provider behaviour + **MockProvider** | 완전 구현 |
| | `propose_line_config` / `approve` / `reject` / `apply_proposal` (+AuditLog+Outbox) | 완전 구현 |
| | `AiLineLive` 승인 흐름 UI(입력→diff+근거→승인/거부→적용) | 완전 구현 |
| **2순위 (스텁)** | ClaudeProvider (키 있을 때만; 없으면 인터페이스만) | 스텁/조건부 |
| | Skill 설정(등록 액션 목록 + 토글 표시) | 목록 화면 |
| | MCP 설정(서버 URL/활성 폼 스텁) | 폼 스텁 |
| | Connector 설정(EXT-5 카탈로그/진입점) | 진입점 스텁 |

**검증 기준**: `ANTHROPIC_API_KEY` 없이 `/admin/settings/ai-line`에서 "건조 다음에 예열 공정 추가, 포장을 마지막으로" 입력 → Mock이 diff 제안 → 근거 표시 → 승인 → step 변경 적용 → `/admin/reports/production`에 반영. 이 1순위 전 흐름이 mock으로 동작해야 완료.

---

## 디렉토리 / 모듈 경계

```
lib/open_mes/
  ai/                                   ← [신규] AI 컨텍스트
    ai.ex                                ← propose_line_config/3, approve/reject/apply_proposal, list/get_interaction
    ai_interaction.ex                    ← 스키마 + changeset + 상태 전이 검증
    provider.ex                          ← @behaviour + active provider 선택
    provider/mock_provider.ex            ← 규칙 파서(1순위, 외부 의존 0)
    provider/claude_provider.ex          ← Claude API req(2순위, 키 있을 때)
    skill_registry.ex                    ← [신규] 등록 tool action 목록(얇은 모듈)
  production_line/
    production_line.ex                   ← [수정] ai_context/2 추가(읽기 전용 컨텍스트). 쓰기 함수 무변경.
                                            apply 시 step 쓰기 Multi 합성용 헬퍼 노출(또는 op 인라인).
lib/open_mes_web/
  admin/settings/
    ai_line_live.ex                      ← [신규] 승인 흐름 UI(1순위)
    skill_settings_live.ex               ← [신규] skill 목록 스텁
    mcp_settings_live.ex                 ← [신규] mcp 폼 스텁
    connector_settings_live.ex           ← [신규] connector 카탈로그 스텁
  components/admin_components.ex         ← [수정] @menu "설정" 그룹 4항목 추가
  router.ex                              ← [수정] Settings scope 4 라우트 추가
priv/repo/
  migrations/XXXX_create_ai_interactions.exs  ← [신규] ai_interactions 테이블
config/
  config.exs                             ← [수정] config :open_mes, OpenMes.Ai.Provider, impl: nil(기본 mock)
mix.exs                                  ← [수정] {:req, "~> 0.5"}(ClaudeProvider용 — mock은 미사용)
test/open_mes/
  ai_test.exs                            ← [신규] propose(mock)→상태머신→apply→AuditLog/Outbox→실패 롤백
  production_line_test.exs               ← [수정] ai_context/2 권한 필터·읽기전용 케이스 추가
```

경계:
- `OpenMes.Ai` = AI 상호작용 소유(제안 생성/상태전이/조회). step 쓰기는 **ProductionLine 컨텍스트 경유**(직접 Repo step insert 금지).
- `ProductionLine` = 22번 그대로 + `ai_context/2`(읽기) 추가. AI는 이 컨텍스트의 **읽기(ai_context)·쓰기(create/update/delete_step via apply)** 두 경로만, 쓰기는 인간 승인 후.
- Provider 구현체 = context map + prompt만 → Repo 불가(구조적 안전).
- LiveView = 컨텍스트 경유만(Repo 직접 0).

---

## domain-engineer 구현 지침 (순서)

1. **마이그레이션** — `ai_interactions`(binary_id PK; actor_id, intent, prompt(text), response_summary(text), referenced_resources(jsonb), proposed_action(jsonb), approval_status(default "proposed"), provider, reviewer_id, reviewed_at, execution_result(jsonb); index: approval_status, actor_id, inserted_at; utc_datetime_usec).
2. **`AiInteraction` 스키마+changeset** — required(actor_id, intent, prompt, approval_status). 상태 전이 검증 `allowed_transition?(from, to)`(A.2 그래프만 허용 — 임의 전이 차단). 한국어 메시지.
3. **`OpenMes.Ai.Provider` behaviour + active/0** — A.5. `MockProvider` 규칙 파서 완전 구현(한국어 패턴 셋 + available_* 화이트리스트 검증 + 근거 summary). `ClaudeProvider`는 키 없으면 호출 안 되므로 스텁 허용(인터페이스만, 또는 req 구현 — pi 판단).
4. **`ProductionLine.ai_context/2`** — 읽기 전용, role 인가(system_admin|production_manager만, 그 외 {:error, :unauthorized}). steps_for_monitor + 활성 공정/설비 라벨 조립. **쓰기 0.**
5. **`OpenMes.Ai` 컨텍스트**:
   - `propose_line_config(line_id, prompt, actor)` — ai_context 호출(인가) → Provider.propose_line_diff → AiInteraction(proposed) 생성 Multi + AuditLog(ai_interaction.propose) + Outbox(ai_action.proposed). **step 쓰기 0.**
   - `approve_proposal(id, reviewer)` — proposed|reviewed→approved, 전이검증, AuditLog(approve)+Outbox(ai_action.approved).
   - `reject_proposal(id, reason, reviewer)` — →rejected, AuditLog(reject).
   - `apply_proposal(id, reviewer)` — **status==approved 가드**. 단일 Multi: proposed_action op들 → ProductionLine step 쓰기(create/update/delete, **각 AuditLog 필수**) + AiInteraction approved→executed(execution_result) + AuditLog(execute). op 중 available_* 화이트리스트 외 process_code → 검증 실패 → 전체 롤백 + failed(execution_result에 사유) + AuditLog(fail). 부분 적용 절대 금지(원자성).
   - `list_interactions/1`(라인/상태 필터), `get_interaction/1`.
6. **`SkillRegistry`** — 등록 액션 목록(propose_line_config 1건). 얇은 모듈.
7. **LiveView 4종** — `AiLineLive`(1순위 완전: 라인선택+입력+제안 diff/근거 미리보기+승인/거부/적용+이력목록, 안전 UI 규칙) / `SkillSettingsLive`(목록 표) / `McpSettingsLive`(폼 스텁) / `ConnectorSettingsLive`(EXT-5 카탈로그/`/extensions` 링크). admin_shell/page_header/modal/empty_state/status_badge 재사용.
8. **admin_components.ex** — "설정" 그룹에 4항목 추가(B.1).
9. **router.ex** — Settings scope 4 라우트(B.5).
10. **config + mix.exs** — `config :open_mes, OpenMes.Ai.Provider, impl: nil`(기본 mock). `{:req, "~> 0.5"}` 추가.
11. **검증** — `mix compile` 무경고 / `mix test`(ai_test: mock propose→approve→apply→executed, AuditLog 4종+step AuditLog, Outbox ai_action.proposed/approved, reject→rejected, 화이트리스트 외 process→failed 롤백, ai_context 인가 거부 / production_line_test 무손상) / `ANTHROPIC_API_KEY` 없이 실서버 `/admin/settings/ai-line` 전 흐름 데모 / 기존 라우트·메뉴·22번 라인구성 무손상.

### 제약 (재강조)
- **AI 직접 쓰기 0**: Provider는 context map+prompt만(Repo 불가). step 쓰기는 `apply_proposal`(actor=승인자)에서만. grep으로 AI 경로의 step 쓰기 호출 0 검증.
- **모든 AI 상호작용 AiInteraction 기록 + AuditLog**: propose/approve/reject/execute/fail 전부. step 변경도 22번 step AuditLog 누락 0.
- **근거 표시 필수**: referenced_resources + response_summary + provider를 UI에 diff와 함께.
- **상태머신 전이 검증**: A.2 그래프 외 전이 차단. apply는 approved에서만.
- **pi**: 1순위만 실구현, 2순위(Claude 실호출/skill 토글 저장/mcp 연결/connector 연결)는 스텁. mock으로 전 흐름 데모.
- 컨텍스트 경유(LiveView Repo 직접 0). binary_id. 한국어 UI/영문 식별자. 기존 무손상.

---

## AI 안전 체크포인트 (ai-safety-guardian 검증 대상)

| # | 안전 원칙 (출처) | 이 설계의 충족 지점 |
|:--:|------------------|---------------------|
| 1 | AI 권한 없는 데이터 열람 금지 (CLAUDE.md L85) | `ai_context/2` role 인가(system_admin\|production_manager만), 그 외 :unauthorized |
| 2 | AI Context API 경유, DB 직접 접근 금지 (L91) | Provider는 plain map context만 받음 — Repo/Ecto 인자 없음(구조적 차단) |
| 3 | AI 기본 쓰기 권한 없음 (L86) | `propose_line_config`는 AiInteraction만 생성, step 쓰기 0 |
| 4 | 중요 변경은 인간 승인 (L88, L117) | `apply_proposal` status==approved 가드, 승인자=reviewer actor |
| 5 | propose→reviewed→approved→executed/failed 상태머신 (L61) | `allowed_transition?` 검증, 임의 전이 차단 |
| 6 | 모든 AI 상호작용 AiInteraction 기록 (L89) | propose/approve/reject/execute/fail 전부 AiInteraction + AuditLog |
| 7 | AI 제안에 근거 데이터 동반 표시 (L88) | referenced_resources + response_summary + provider, UI에 diff와 함께 노출 |
| 8 | Tool Action 화이트리스트(propose_*만) (L93) | SkillRegistry에 propose_line_config(writes:false)만. available_* 외 process 거부 |
| 9 | 적용 원자성/감사 | apply는 단일 Multi(부분 적용 금지), 실패 시 전체 롤백+failed+사유 기록 |
| 10 | Outbox 이벤트 (CLAUDE.md L79) | ai_action.proposed / ai_action.approved(기존 명시 이벤트) 발행 |

---

## 부록. diff op 스키마 (proposed_action)

```json
{
  "line_id": "<binary_id>",
  "ops": [
    {"op": "add_step", "process_code": "P-PREHEAT", "equipment_code": null, "after_sequence": 3},
    {"op": "reorder", "process_code": "P-PACK", "to": "last"},
    {"op": "remove_step", "process_code": "P-OLD"}
  ]
}
```
- `add_step`: after_sequence 뒤에 삽입(이후 step sequence +1 시프트 — apply가 처리). process_code/equipment_code는 available_* 화이트리스트 검증.
- `reorder`: to="last"|"first"|정수 sequence. 22번 swap이 아닌 "최종 순서로 정렬" 의미 — apply가 sequence 재배열(임시 양수 park 경유, 22번 swap_sequence 패턴 차용).
- `remove_step`: process_code 또는 sequence로 식별 → delete_step.
- **모든 op는 apply_proposal에서 기존 ProductionLine 쓰기함수로 번역** — 새 step 쓰기 경로 0.
