# 29. LLM 친화 확장 개발 가이드 + 자동 검증 (Architect 설계)

작성: architect · 날짜: 2026-06-14
대상: domain-engineer (구현) · qa-auditor (검토)
선행 산출물: `_workspace/10_registry_catalog_impl/`, `_workspace/11_addon_*`, `_workspace/27_architect_okf_knowledge.md`

---

## 0. 목표와 범위

LLM(AI 코딩 에이전트)이 `docs/extension-development.md`를 읽고 **확장 개발 → 자기 검증 → (실패 시) 수정 → 재검증** 루프를 자기완결로 돌려, 사람 개입 없이 읽기 전용 애드온을 추가할 수 있게 한다.

**범위 4가지:**
1. `docs/extension-development.md`를 LLM 친화(명령형·정확·자기완결)로 강화
2. `mix ext.verify` 자동 검증 task 신설 (정적 검증 + 리포트)
3. `/extensions/guide`(GuideLive)에 LLM 가이드 + 검증 명령 섹션 반영
4. (선택/슬롯) OKF 지식베이스에 가이드를 `type: 개발가이드` 문서로 등록

**무손상 제약:** 기존 화면/라우트/확장/테스트/기존 mix task 전부 무영향. `mix ext.verify`는 **신규 task**로만 추가한다. 코어 도메인 코드 변경 0.

---

## 1. 정확한 계약 (코드 그대로 — LLM이 복붙·파싱)

### 1.1 Extension behaviour 필수 6 + 선택 2 (검증 기준의 단일 출처)

`OpenMes.Extensions.Extension` (실제 파일: `open_mes/lib/open_mes/extensions/extension.ex`):

```elixir
@type category :: :ingest | :media | :production | :quality | :traceability | :analytics

@callback id() :: atom()                     # 필수 — 고유 영문 atom (예: :addon_my_report)
@callback name() :: String.t()               # 필수 — 한국어 이름
@callback description() :: String.t()         # 필수 — 한 줄 설명(한국어)
@callback category() :: category()            # 필수 — 위 union 중 하나
@callback version() :: String.t()             # 필수 — 예 "0.1.0"
@callback enabled?() :: boolean()             # 필수 — config 게이트
@callback home_path() :: String.t() | nil     # 선택 — Definition이 nil 주입
@callback icon() :: String.t() | nil          # 선택 — Definition이 nil 주입

@optional_callbacks [home_path: 0, icon: 0]
```

**검증의 단일 출처 원칙:** `mix ext.verify`의 "필수 콜백 6" 목록과 "유효 카테고리" 목록은 이 behaviour에서 **유도**한다(하드코딩 금지). 즉:
- 필수 콜백: `OpenMes.Extensions.Extension.behaviour_info(:callbacks)` − `@optional_callbacks`. → `[id, name, description, category, version, enabled?]`.
- 유효 카테고리: 별도 함수 `Extension.categories/0`을 **신설**해 거기서 읽는다(§1.3). 이렇게 하면 behaviour 1곳만 고치면 가이드·검증·카탈로그가 함께 따라온다(pi: 진실의 단일 출처).

### 1.2 `use OpenMes.Extensions.Definition`

`use`하면 선택 콜백(`home_path/0`, `icon/0`)에 기본값 `nil`이 주입되고 `@behaviour`가 선언된다. → **필수 6개만** 구현하면 컴파일된다. 화면 있는 확장만 `home_path/0` override.

### 1.3 (신규) `Extension.categories/0` — 검증/가이드 공용 출처

domain-engineer는 `extension.ex`에 **읽기 전용 함수 1개**를 추가한다(behaviour 계약 무변경, 기존 호출부 무영향):

```elixir
@doc "유효 카테고리 목록(검증·카탈로그 라벨·가이드 공용 단일 출처)."
@spec categories() :: [category()]
def categories, do: [:ingest, :media, :production, :quality, :traceability, :analytics]
```

> pi 근거: 카테고리는 지금도 3곳(behaviour typedoc, 카탈로그 라벨맵, 가이드 문서)에 흩어져 있다. 검증을 붙이는 김에 **함수 1개로 수렴**시키되, 새 추상화는 만들지 않는다. `:integration`/`:industry`(로드맵 EXT-5/12) 확장 시 이 리스트 1줄만 늘린다.

---

## 2. LLM 친화 가이드 구조 (`docs/extension-development.md` 강화)

기존 문서는 사람용 설명체다. LLM이 **순서대로 실행**할 수 있게 다음 구조로 재편한다. 한국어 본문 + 영문 식별자/코드, 단계는 번호·명령형.

### 2.1 문서 상단에 LLM 실행 헤더 추가 (신규 §0)

문서 맨 앞에 LLM이 가장 먼저 읽는 **계약 요약 블록**을 둔다:

```markdown
## 0. LLM 개발자에게 (먼저 읽을 것)

당신은 읽기 전용 애드온을 추가한다. 다음 불변 규칙을 위반하지 마라:
- [코어 비침투] `lib/open_mes/`, `lib/open_mes_web/`(addons 제외), `config/` 의 기존 줄을
  수정하지 마라. 새 코드는 오직 `lib/open_mes_addons/{name}/` 아래에만 만든다.
  (예외: config 의 :extensions 리스트에 "한 줄 추가"와 enabled 게이트 "한 줄 추가"만 허용)
- [읽기 전용 우선] 코어 데이터는 컨텍스트 공개 함수(`OpenMes.Production.list_work_orders/1` 등)로
  읽기만 한다. DB 쓰기/마이그레이션/새 테이블 금지. (쓰기가 꼭 필요하면 중단하고 사람에게 보고)
- [AI 경계] AI 호출 확장이면 직접 쓰기 금지 — propose_* 후보 제안 + 사람 승인만.
- [pi] 과설계 금지. GenServer/매크로/동적 발견 도입 금지. 함수 + behaviour 구현만.

개발 완료의 정의(DoD): `mix ext.verify OpenMes.Addons.{Name}.Extension` 이 모든 항목 ✅,
그리고 `mix compile --warnings-as-errors` 와 `mix test` 통과.
```

### 2.2 절차 (번호 단계 — 각 단계에 정확한 파일 경로 + 코드 템플릿)

기존 §3~4를 다음 **6단계 절차**로 재구성한다. LLM이 위→아래로 그대로 실행:

| 단계 | 행동 | 정확한 산출물 경로 |
|---|---|---|
| 1 | 디렉토리 생성 | `lib/open_mes_addons/{name}/` (snake_case) |
| 2 | 퍼사드 + 게이트 작성 | `lib/open_mes_addons/{name}.ex` |
| 3 | 로직 모듈(읽기/직렬화) 작성 | `lib/open_mes_addons/{name}/{logic}.ex` |
| 4 | (화면 있으면) LiveView 작성 | `lib/open_mes_addons/{name}/live/{name}_live.ex` |
| 5 | extension.ex(behaviour 구현) 작성 | `lib/open_mes_addons/{name}/extension.ex` |
| 6 | config 등록(2줄) + 라우트(화면 시) | `config/config.exs`, `lib/open_mes_web/router.ex` |
| 7 | 검증 | `mix ext.verify` → `mix compile` → `mix test` |

> 네이밍 규약(LLM 강제): 모듈 `OpenMes.Addons.{PascalName}`, behaviour `OpenMes.Addons.{PascalName}.Extension`, LiveView `OpenMesWeb.Addons.{PascalName}Live`, id atom `:addon_{snake_name}`, home_path `/extensions/{kebab-name}`. **이 5개 규약은 `mix ext.verify`가 휴리스틱으로 점검한다(§3.3).**

### 2.3 완전 동작 골격 템플릿 (복붙 후 `{Name}`/`{name}` 치환)

가이드에 **읽기 전용 최소 확장**의 완전 골격 4파일을 싣는다. 근거: `wo_csv_export` 실제 구현. LLM은 placeholder만 치환한다.

**(A) 퍼사드 — `lib/open_mes_addons/{name}.ex`**
```elixir
defmodule OpenMes.Addons.MyReport do
  @moduledoc "우리 회사 리포트 애드온 — 퍼사드(읽기 전용)."

  @spec enabled?() :: boolean()
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
    |> case do
      true -> true
      _ -> false
    end
  end

  @doc "코어 데이터를 읽어 화면용 데이터를 만든다(읽기 전용)."
  def summary(filters \\ %{}) when is_map(filters) do
    OpenMes.Production.list_work_orders(filters)
    # ... 집계/가공(순수 함수) ...
  end
end
```

**(B) behaviour — `lib/open_mes_addons/{name}/extension.ex`** (필수 6 + home_path)
```elixir
defmodule OpenMes.Addons.MyReport.Extension do
  @moduledoc "MyReport 애드온의 Extension behaviour 구현(메타데이터)."
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :addon_my_report
  @impl true
  def name, do: "우리 회사 일일 리포트"
  @impl true
  def description, do: "현장 요구에 맞춘 일일 생산 리포트를 조회한다(읽기 전용)."
  @impl true
  def category, do: :analytics
  @impl true
  def version, do: "0.1.0"
  @impl true
  def enabled?, do: OpenMes.Addons.MyReport.enabled?()

  # 화면이 있으면 override, 없으면 이 줄 삭제(기본값 nil).
  @impl true
  def home_path, do: "/extensions/my-report"
end
```

**(C) LiveView(화면 있을 때만) — `lib/open_mes_addons/{name}/live/{name}_live.ex`**
```elixir
defmodule OpenMesWeb.Addons.MyReportLive do
  @moduledoc "MyReport 화면(읽기 전용, AuditLog/Outbox 무관)."
  use OpenMesWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "우리 회사 일일 리포트",
                 rows: OpenMes.Addons.MyReport.summary())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-8">
      <h1 class="text-2xl font-bold text-zinc-900">우리 회사 일일 리포트</h1>
      <%!-- ... OpenMesWeb.ChartComponents / 테이블 ... --%>
      <.link navigate="/extensions" class="text-sm text-zinc-500">← 확장 카탈로그로</.link>
    </div>
    """
  end
end
```

**(D) 등록 2줄 — `config/config.exs`** (기존 줄 수정 금지, 리스트에 추가만)
```elixir
config :open_mes, :extensions, [
  # ... 기존 항목 유지 ...
  OpenMes.Addons.MyReport.Extension   # ← 추가(1줄)
]

config :open_mes, OpenMes.Addons.MyReport, enabled: true   # ← 추가(1줄)
```

**(E) 라우트(화면 있을 때만) — `lib/open_mes_web/router.ex`** (기존 패턴 그대로 복제)
```elixir
if OpenMes.Addons.MyReport.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/my-report", MyReportLive, :index
  end
end
```

### 2.4 안전·원칙 (LLM 강제 — 명령형 체크리스트)

가이드 본문에 **금지/필수**를 명령형으로 못박는다(§2.1 헤더와 중복 강조):
- 금지: 코어 파일 수정 · 새 DB 테이블/마이그레이션 · GenServer/동적 모듈 스캔 · AI 직접 쓰기
- 필수: `lib/open_mes_addons/` 격리 · 컨텍스트 공개 함수 경유 읽기 · `use Definition` · config 2줄 등록 · 검증 통과
- 쓰기가 불가피하면(드묾): 컨텍스트 함수 경유 + AuditLog + 동일 트랜잭션 Outbox + (자재) LotConsumption. **이 경우 LLM은 자동 진행을 멈추고 qa-auditor 검토를 요청**한다.

### 2.5 재사용 빌딩블록 (기존 §5 유지, LLM용 호출 시그니처 명시)
- `OpenMesWeb.ChartComponents` — SVG 차트(deps 0)
- `OpenMesWeb.AdminComponents` — `admin_shell`/`page_header`/`status_badge`/`empty_state`
- 컨텍스트 읽기 — `OpenMes.Production.list_work_orders/1` 등(가이드에 자주 쓰는 함수 5개 표로 명시)
- `OpenMes.Extensions.Registry.all/0 · enabled/0 · by_category/0`

---

## 3. 자동 검증 — `mix ext.verify` (핵심 산출물)

### 3.1 설계 원칙 (pi)
- **순수 정적 + 런타임 introspection만.** 무거운 정적분석(AST 전수 분석, dialyzer)·외부 deps 0.
- 판정은 `function_exported?/3` · `Application.get_env/2` · `Registry.all/0` · `File.read` + 정규식 grep 휴리스틱.
- **신규 task** (`lib/mix/tasks/ext.verify.ex`). 기존 task·코어·런타임 무영향.
- 출력: 사람·LLM 모두 파싱 가능한 **✅/❌ 라인 리포트** + 실패 시 **수정 안내 1줄**. 종료코드: 전체 통과 0, 위반 1.

### 3.2 호출 형태
```bash
mix ext.verify OpenMes.Addons.MyReport.Extension   # 단일 확장
mix ext.verify                                       # 인자 없으면 :extensions 전체 스캔
```
구현은 `Mix.Task.run("app.start", [])` 대신 **컴파일만 보장**(`Mix.Task.run("compile")`)하고 모듈을 로드해 introspection한다(서버/Repo 기동 불필요 → 빠르고 부작용 0).

### 3.3 검증 항목 (체크 7종)

| # | 검사 | 방법 | ❌ 시 수정 안내 |
|---|---|---|---|
| C1 | 필수 6 콜백 구현 | `Extension`에서 유도한 필수 콜백마다 `function_exported?(mod, cb, 0)` | "extension.ex에 `def {cb}` 추가. §2.3 (B) 템플릿 참고" |
| C2 | behaviour 채택 | `mod.__info__(:attributes)[:behaviour]`에 `OpenMes.Extensions.Extension` 포함 | "`use OpenMes.Extensions.Definition` 추가" |
| C3 | config 등록 | `mod in Registry.modules()` | "config :open_mes, :extensions 리스트에 모듈 한 줄 추가(§2.3 D)" |
| C4 | 카탈로그 노출 가능 | `Enum.any?(Registry.all(), & &1.module == mod)`(= to_entry 호출이 raise 없이 성공) | "콜백이 raise. id/name/category 반환값 점검" |
| C5 | id 고유성 | `Registry.all()`의 id 빈도 1 + `id`가 atom | "다른 확장과 id 충돌. :addon_* 고유 atom으로 변경" |
| C6 | category 유효성 | `mod.category() in Extension.categories()` | "유효 카테고리(§1.1 union) 중 하나로. 새 분류면 categories/0에 추가" |
| C7 | 코어 비침투(휴리스틱) | `lib/open_mes_addons/{name}/` 및 퍼사드 파일 grep: 코어 Repo 직접 쓰기 패턴 부재 | "코어 직접 쓰기 발견. 컨텍스트 공개 함수 경유로 변경" |

**C7 grep 휴리스틱(명시 — 오탐 최소, 실용 우선):**
- 확장 소스 파일 집합 = `lib/open_mes_addons/{name}/**/*.ex` + `lib/open_mes_addons/{name}.ex` + (있으면) `lib/open_mes_web/controllers/{name}_controller.ex`.
- 위반 패턴(정규식): `Repo\.(insert|update|delete|insert_all|update_all|delete_all)` , `Ecto\.Multi` , `OpenMes\.Repo\.` 직접 호출.
- 단순 export/읽기 애드온은 0건이어야 한다. 1건 이상이면 ❌ + 해당 파일·라인 표시.
- **한계 명시(가이드에 기재):** grep은 완전하지 않다(매크로 우회 등). C7은 "명백한 코어 직접 쓰기"를 잡는 1차 가드다. 도메인 쓰기 확장은 C7 통과해도 **qa-auditor `audit-verify` 스킬 필수**(§5).

`mod` 인자가 `:extensions`에 없거나 모듈 로드 실패면 C3부터 ❌로 명확히 보고(추측 금지).

### 3.4 리포트 출력 형식 (LLM 파싱 친화)
```
ext.verify: OpenMes.Addons.MyReport.Extension
  ✅ C1 필수 콜백 6개 구현
  ✅ C2 Extension behaviour 채택
  ❌ C3 config :extensions 미등록
      → config :open_mes, :extensions 리스트에 모듈 한 줄 추가 (가이드 §2.3 D)
  ✅ C4 카탈로그 노출 가능
  ✅ C5 id 고유 (:addon_my_report)
  ✅ C6 category 유효 (:analytics)
  ✅ C7 코어 비침투 (직접 쓰기 0건)

결과: 6/7 통과 ❌  (종료코드 1)
다음: 위 → 안내대로 수정 후 `mix ext.verify OpenMes.Addons.MyReport.Extension` 재실행
```
전체 스캔(인자 없음) 시 확장별 한 줄 요약 + 마지막 합계.

### 3.5 LLM 자기완결 루프(가이드에 명시)
```
1. 확장 코드 작성(§2.2 1~6단계)
2. mix ext.verify OpenMes.Addons.{Name}.Extension
3. ❌ 있으면 → 안내(→ 줄) 따라 수정 → 2 재실행 (수렴까지 반복)
4. 전부 ✅ → mix compile --warnings-as-errors
5. mix test  (실패 시 수정 → 4)
6. 모두 통과 = 개발 완료(DoD)
```

---

## 4. `/extensions/guide`(GuideLive) 반영

기존 GuideLive를 무손상으로 확장한다. 7개 섹션 구조 유지 + **2개 섹션 추가/강화**:
- **§3.5(신규) "LLM 자기완결 개발 루프"** 섹션: §2.2 7단계 표 + §3.5 루프 박스. 모듈 속성 `@llm_steps`로 인라인.
- **§8(신규) "자동 검증 — mix ext.verify"** 섹션: §3.2 호출 2줄 + §3.3 체크 7종 표(`@verify_checks` 모듈 속성) + §3.4 샘플 리포트 `pre` 블록(`@sample_report`).
- 기존 §3 최소 확장 예제 옆에 "검증: `mix ext.verify {Extension}`" 한 줄 추가.

구현 방식은 기존과 동일 — 정적 모듈 속성 + `~H` 테이블/`pre`. 데이터 소스·도메인 쓰기 없음(AuditLog/Outbox 무관). `admin_shell` 레이아웃 유지. 라우트 `/extensions/guide` 그대로(신규 라우트 0).

---

## 5. qa-auditor 검토 지점

- 가이드/검증은 **읽기 전용 메타 작업** — AuditLog/LOT/Outbox 직접 관련 없음.
- 단 가이드가 "쓰기 확장은 컨텍스트 경유 + AuditLog + Outbox + LotConsumption"을 **정확히 안내**하는지, C7 휴리스틱 한계 문구가 "도메인 쓰기 확장은 audit-verify 필수"를 명시하는지 검토.
- `mix ext.verify` 자체가 도메인 코드를 건드리지 않는지(introspection·grep만), 코어 모듈 import 0인지 확인.

---

## 6. (선택/슬롯) OKF 연계

OKF(`OpenMes.Okf`, 산출물 27)는 frontmatter `type`을 자유 문자열(`okf_type`)로 수용한다(고정 enum 아님). 따라서:
- **슬롯만 확보:** `docs/extension-development.md` 상단 frontmatter에 `type: 개발가이드` 추가하면 OKF 번들이 이 가이드를 인덱싱 → AI investigate/개발 에이전트가 검색·인용 가능.
- **1차 범위 밖:** OKF 번들 재실행/색인 트리거는 이번 작업에서 하지 않는다(가이드 강화 + mix task + GuideLive가 1차). frontmatter 한 줄만 추가하고 후속에서 색인.
- 후속 작업 식별자: "OKF 색인에 extension-development.md(type:개발가이드) 포함" → 별도 티켓.

---

## 7. domain-engineer 구현 지침 (정확)

순서대로 구현. 각 단계 후 `mix compile` 확인.

**T1. `Extension.categories/0` 추가** (`open_mes/lib/open_mes/extensions/extension.ex`)
- 파일 끝 `@optional_callbacks` 앞/뒤에 §1.3의 `categories/0` 함수 추가. behaviour 콜백·기존 호출부 무변경. (카탈로그 라벨맵을 이 함수로 리팩터링하는 것은 선택 — 안 해도 됨, pi.)

**T2. `mix ext.verify` task 신규** (`open_mes/lib/mix/tasks/ext.verify.ex`)
- `defmodule Mix.Tasks.Ext.Verify do use Mix.Task ... end`. `@shortdoc "확장 정적 검증"`.
- `run/1`: `Mix.Task.run("compile")` → 인자 파싱(모듈명 있으면 1개, 없으면 `Registry.modules()` 전체).
- 모듈명 문자열 → `Module.concat`/`String.to_existing_atom` 안전 변환(미존재 시 ❌ 메시지).
- 체크 C1~C7을 §3.3대로 구현. 필수 콜백은 `OpenMes.Extensions.Extension.behaviour_info(:callbacks)`에서 `@optional_callbacks`(home_path/icon) 제외해 유도(하드코딩 금지).
- C7 grep: `File.read` + `Regex` (§3.3 패턴). 확장 파일 경로는 모듈 → `Macro.underscore`로 디렉토리 추정 + `lib/open_mes_addons/{name}*` 글롭.
- 출력 §3.4 형식. 위반 1건↑이면 `exit({:shutdown, 1})`(또는 `Mix.raise` 대신 종료코드 1). `Mix.shell().info/error` 사용.
- **순수 introspection + grep만.** 코어 도메인/Repo import 금지, 서버/Repo 기동 금지.

**T3. 테스트** (`open_mes/test/mix/tasks/ext_verify_test.exs`)
- 정상 확장(`OpenMes.Addons.WoCsvExport.Extension`)이 7/7 통과하는지.
- 필수 콜백 누락/미등록/잘못된 category fixture(`test/support/extension_fixtures.ex` 재사용)가 해당 체크에서 ❌ 나오는지.
- 종료코드/리포트 라인 형식 1건.

**T4. `docs/extension-development.md` 재편** — §2(이 문서 §2 전체)대로. 기존 §1~7 보존하되 상단에 §0 LLM 헤더, §3~4를 7단계 절차+골격 템플릿으로 강화, 검증 루프(§3.5) 섹션 추가. frontmatter에 `type: 개발가이드`(§6 슬롯) 추가.

**T5. `GuideLive` 반영** (`open_mes/lib/open_mes_web/live/guide_live.ex`) — §4대로 `@llm_steps`/`@verify_checks`/`@sample_report` 모듈 속성 + 2개 `<section>` 추가. 기존 섹션·라우트 무변경.

**검증(DoD):** `mix ext.verify` 전체 스캔이 기존 7개 확장 전부 통과 → `mix compile --warnings-as-errors` → `mix test`(기존 461+ 무회귀) 통과.

---

## 8. 핵심 결정 5가지

1. **검증의 단일 출처 = behaviour introspection.** 필수 콜백/유효 카테고리를 하드코딩하지 않고 `Extension.behaviour_info(:callbacks)` + 신규 `categories/0`에서 유도 → 계약이 바뀌면 검증이 자동으로 따라온다(진실 1곳, pi).
2. **`mix ext.verify`는 introspection + grep만(무거운 정적분석 0).** `function_exported?`/`Registry.all`/정규식 grep 휴리스틱. 외부 deps·dialyzer·AST 전수분석 금지. 신규 task로 기존 무영향.
3. **C7 코어 비침투는 1차 가드로 한정.** grep으로 "명백한 Repo 직접 쓰기"만 잡고, 도메인 쓰기 확장은 C7 통과해도 qa-auditor `audit-verify` 필수임을 가이드·리포트에 명시(휴리스틱 한계 정직 표기).
4. **LLM 자기완결 루프를 DoD로 못박는다.** 개발 → `mix ext.verify`(✅/❌ + 수정 안내 1줄) → 수정 → 재검증 → `mix compile --warnings-as-errors` → `mix test`. 종료코드(0/1)와 파싱 가능한 리포트로 LLM이 무한 수렴 없이 판정 가능.
5. **무손상 + 격리 강제.** 코어/기존 라우트/기존 task/기존 확장 변경 0(단 `categories/0` 추가 1함수). 가이드 §0 헤더가 "코어 파일 수정 금지, `lib/open_mes_addons/`만, config는 2줄 추가만"을 LLM에 명령형으로 강제. OKF 연계는 frontmatter 1줄 슬롯만, 색인은 후속.
