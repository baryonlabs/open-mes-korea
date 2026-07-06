---
type: 개발가이드
---

# 확장 개발 가이드 (Extension Development Guide)

Open MES Korea는 **최소 코어 + 확장 모듈** 구조다. 회사의 현장 요구(특정 설비, 특정 리포트,
특정 라벨, 특정 외부 도구 연동)는 코어를 건드리지 않고 **확장(Extension)** 으로 직접 만들 수 있다.

이 문서는 "우리 회사에 맞는 확장을 직접 만든다"를 위한 실전 가이드다. 사람과 **LLM 코딩
에이전트** 모두가 이 문서만 읽고 확장을 자기완결로 추가할 수 있도록 명령형·정확·복붙 가능하게 썼다.

확장은 두 가지 방식으로 만들 수 있다:

- **in-tree 애드온** (§2~9) — `open_mes` 저장소 안 `lib/open_mes_addons/{name}/` 에 직접 추가.
  코어 데이터를 읽는 회사 맞춤 리포트/위젯에 가장 빠르다.
- **외부 repo 확장** (§10) — 별도 git 저장소로 만들어 `open_mes/mix.exs` 에 deps **한 줄**만
  추가하면 코어 소스 0 수정으로 자동 노출된다. 확장 시스템 디커플링(설계 30)으로 가능해졌다.

어느 쪽이든 `OpenMes.Extension` behaviour(계약 패키지 `open_mes_extension_api`)만 구현하면 된다.

---

## 0. LLM 개발자에게 (먼저 읽을 것)

당신은 **읽기 전용 애드온**을 추가한다. 다음 불변 규칙을 위반하지 마라:

- **[코어 비침투]** 코어 도메인(`lib/open_mes/`, `lib/open_mes_web/`(addons 제외), `config/` 의
  코어 영역)의 **기존 줄을 수정하지 마라.** in-tree 애드온의 새 코드는 오직
  `lib/open_mes_addons/{name}/` 아래에만 만든다. 외부 repo 확장은 별도 저장소에 두므로
  코어를 아예 건드리지 않는다(§10). **단방향 의존은 유지** — 확장 → 코어(읽기)만, 코어 →
  확장 참조는 절대 없다.
  (in-tree config 등록: `:extensions` 리스트에 "한 줄 추가"와 enabled 게이트 "한 줄 추가". `:auto`
  발견이 켜져 있으면 이마저 자동 발견되어 생략 가능 — §4)
- **[읽기 전용 우선]** 코어 데이터는 컨텍스트 공개 함수(`OpenMes.Production.list_work_orders/1` 등)로
  **읽기만** 한다. DB 쓰기 / 마이그레이션 / 새 테이블 **금지**. (쓰기가 꼭 필요하면 멈추고 §6 절차 + qa-auditor 검토)
- **[AI 경계]** AI 호출 확장이면 **직접 쓰기 금지** — `propose_*` 후보 제안 + 근거 표시 + 사람 승인만.
- **[pi]** 과설계 금지. 확장 안에서 GenServer / 동적 모듈 스캔 도입 금지. **함수 + behaviour
  구현만.** (라우트는 `route_spec/0` 데이터 선언으로 충분 — 직접 매크로를 쓰지 마라.)

**개발 완료의 정의(DoD):**

```
mix ext.verify OpenMes.Addons.{Name}.Extension   # 모든 항목 ✅ (종료코드 0)
mix compile --warnings-as-errors                  # 경고 0
mix test                                           # 전부 green
```

세 명령이 모두 통과해야 완료다. 자기완결 루프는 §8 참고.

---

## 1. 확장이란

확장은 코어 위에 얹는 독립 모듈이다. 세 가지 약속만 지키면 된다.

- **코어 비침투**: 코어 도메인(`OpenMes.Production` / `WorkOrder` / `Audit` / `Outbox`)은
  확장을 참조하지 않는다. 의존 방향은 단방향이다 — 확장 → 코어(읽기), 확장 → 계약 패키지.
  코어를 수정하지 않으므로 코어 업그레이드와 충돌하지 않는다. 외부 repo 확장도 코어
  (`:open_mes`)에 의존하지 않고 계약 패키지 `open_mes_extension_api` 에만 의존한다(§10).
- **자동 발견 + config on/off**: 확장은 `:auto` 모드(기본)에서 **로드된 OTP 앱을 스캔해
  자동 발견**된다 — deps 한 줄이면 끝, config 등록 불필요. 명시 목록
  (`config :open_mes, :extensions`)은 `:manual` 모드로 되돌리거나 발견을 보강할 때 쓰는
  escape hatch다(§4). 각 확장은 `enabled?/0` 게이트로 켜고 끄며, 끄면 카탈로그에 '비활성'
  배지로만 남는다.
- **카탈로그·라우트 자동 노출**: `Extension` behaviour만 구현하면 `/extensions` 카탈로그에
  카드가 **자동으로** 뜬다. `route_spec/0` 을 선언하면 라우트도 **자동 주입**된다 — 코어
  router.ex / 카탈로그 / 메뉴 코드를 따로 수정할 필요가 없다.

> 레지스트리는 "설치 시스템"이 아니다. DB/GenServer/ETS 없이 config 조회 + behaviour 콜백
> 호출만으로 동작하는 순수 조회 계층이다 (pi 원칙). `:auto` 발견은 `Application.loaded_applications/0`
> introspection 으로 behaviour 구현 모듈을 모으며, 상태를 갖지 않는다.

> **네임스페이스**: 계약은 `OpenMes.Extension` / `OpenMes.Extension.Definition` /
> `OpenMes.Extension.Registry` (계약 패키지 `open_mes_extension_api`)다. 구 네임스페이스
> `OpenMes.Extensions.*` 는 호환 shim으로 동작하지만 **신규 코드는 신규 네임스페이스를 쓴다**.

---

## 2. Extension behaviour 계약

확장 메타데이터는 `OpenMes.Extension` behaviour(계약 패키지 `open_mes_extension_api`)로
계약된다. 이 behaviour는 **메타데이터 + 라우트 데이터 선언만** 약속한다. 확장의 실제 동작
(파이프라인/연산/화면)은 확장 내부 책임이다.

> 구 네임스페이스 `OpenMes.Extensions.Extension` 은 호환 shim으로 살아 있지만 신규 코드는
> `OpenMes.Extension` 을 직접 쓴다.

### 필수 콜백 6개

| 콜백 | 타입 | 설명 |
|------|------|------|
| `id/0` | `atom()` | 확장 고유 식별자(영문 atom, 안정적). 예: `:addon_wo_csv_export` |
| `name/0` | `String.t()` | 사람이 읽는 이름(한국어). 예: `"작업지시 CSV 내보내기"` |
| `description/0` | `String.t()` | 한 줄 설명(한국어) |
| `category/0` | `category()` | 분류 atom (카탈로그 필터에 사용) |
| `version/0` | `String.t()` | 버전 문자열. 예: `"0.1.0"` |
| `enabled?/0` | `boolean()` | 활성 여부(config 게이트) |

### 선택 콜백 3개 (`Definition`이 기본값 `nil` 주입)

| 콜백 | 타입 | 설명 |
|------|------|------|
| `home_path/0` | `String.t() \| nil` | 자체 화면 경로. 화면이 있으면 override. 없으면 `nil` |
| `icon/0` | `String.t() \| nil` | 카탈로그 카드 아이콘. 없으면 `nil`(기본 아이콘) |
| `route_spec/0` | `route_spec() \| nil` | 라우트 데이터 선언. 라우트를 기여하면 override, 없으면 `nil`(라우트 0) |

카탈로그는 `home_path != nil` 이고 `enabled? == true` 일 때만 카드에 "열기" 링크를 노출한다.

`use OpenMes.Extension.Definition` 한 줄이 세 선택 콜백의 기본값(`nil`)을 주입하므로,
필수 6개만 구현하면 카탈로그에 뜨는 최소 확장이 완성된다. 화면/라우트가 있는 확장만
`home_path/0` 와 `route_spec/0` 을 override 한다.

### `route_spec/0` 형태 (라우트 데이터 선언)

라우트는 **순수 데이터**로 선언한다 — 외부 확장이 자기 Router 모듈을 만들 필요가 없다.
`OpenMes.Extension.RouterMount` 매크로가 코어 router.ex에서 이 데이터를 컴파일 타임에
Phoenix 라우트로 펼친다(§2.6 E, §10).

```elixir
@type route_spec :: %{
        scope: String.t(),              # 예: "/extensions"
        pipeline: atom() | [atom()],    # 예: :browser  또는  [:api, :require_device_token]
        routes: [route_entry()]
      }

@type route_entry ::
        {:live, String.t(), module(), atom()}   # {:live, path, live_module, action}
        | {:get,  String.t(), module(), atom()}  # {:get,  path, controller, action}
        | {:post, String.t(), module(), atom()}  # {:post, path, controller, action}
```

- **단일 화면**: `routes: [{:live, "/my-report", OpenMesWeb.Addons.MyReportLive, :index}]`
- **다중 라우트**: 튜플을 리스트에 여러 개 — 별도 Routes 모듈 불필요.
  예) EXT-1 설비수집은 `pipeline: [:api, :require_device_token]` + `{:post, .../equipment}` +
  `{:get, .../health}` 두 라우트를 한 spec에 담는다.
- **화면 없는 확장**(예: EXT-2 멀티미디어 — 백그라운드 NAS watch)은 `route_spec/0` 미구현(`nil`)
  → 라우트 0.
- 라우트 기여 확장의 `enabled?/0` 는 컴파일 타임 결정값(`Application.compile_env`)을 권장한다
  — 라우트는 컴파일 타임에 확정되므로(off면 라우트 테이블에 흔적 0).

### 카테고리(`category/0`) 값 — 개방형 `atom()`

타입은 `atom()` 으로 **개방**되어 있다(설계 30 §2.2). 외부 repo 확장이 코어를 건드리지 않고
자유 카테고리를 쓸 수 있게 하기 위함이다. 코어가 **한국어 라벨/아이콘/필터 칩을 제공하는**
카테고리는 `OpenMes.Extension.known_categories/0` 에 모은다:

`:ingest`(설비수집) · `:media`(멀티미디어) · `:production`(생산) · `:quality`(품질) ·
`:traceability`(추적) · `:analytics`(분석) · `:integration`(연동 허브)

`known_categories/0` 는 **검증 게이트가 아니라** "알려진 라벨" 목록일 뿐이다. 여기에 없는
카테고리(예: 외부 확장의 `:demo`)도 정상이며, 카탈로그는 atom을 폴백 라벨로 렌더한다.
`mix ext.verify` 의 C6은 atom이기만 하면 통과하고, known 미포함이면 ⚠️ **정보성 안내**만
낸다(실패 아님 — §8).

> 구 `OpenMes.Extensions.Extension.categories/0` 는 `known_categories/0` 로 위임하는 deprecated
> shim이다. 신규 코드는 `OpenMes.Extension.known_categories/0` 를 쓴다.

---

## 2.5 6단계 개발 절차 (LLM은 위→아래 그대로 실행)

각 단계의 **정확한 산출물 경로**를 지킨다. 네이밍 규약(아래)을 위반하면 `mix ext.verify` 가 잡는다.

| 단계 | 행동 | 정확한 산출물 경로 |
|---|---|---|
| 1 | 디렉토리 생성 | `lib/open_mes_addons/{name}/` (snake_case) |
| 2 | 퍼사드 + 게이트 작성 | `lib/open_mes_addons/{name}.ex` |
| 3 | 로직 모듈(읽기/직렬화) 작성 | `lib/open_mes_addons/{name}/{logic}.ex` |
| 4 | (화면 있으면) LiveView 작성 | `lib/open_mes_addons/{name}/live/{name}_live.ex` |
| 5 | `extension.ex`(behaviour 구현 + 화면 시 `route_spec/0`) 작성 | `lib/open_mes_addons/{name}/extension.ex` |
| 6 | (선택) config 등록 — `:auto` 발견이면 생략 가능, `:manual` 이면 2줄 | `config/config.exs` |
| 7 | 검증 | `mix ext.verify` → `mix ext.list` → `mix compile --warnings-as-errors` → `mix test` |

> **라우트는 router.ex를 건드리지 않는다.** `route_spec/0` 만 선언하면 코어 router.ex의
> `mount_extension_routes()` 매크로가 컴파일 타임에 자동 주입한다(과거 "router.ex에 if 블록
> 복제" 절차는 폐기됨 — §2.6 E).

**네이밍 규약 (강제):**

| 대상 | 규약 | 예 |
|---|---|---|
| 퍼사드 모듈 | `OpenMes.Addons.{PascalName}` | `OpenMes.Addons.MyReport` |
| behaviour 모듈 | `OpenMes.Addons.{PascalName}.Extension` | `OpenMes.Addons.MyReport.Extension` |
| LiveView | `OpenMesWeb.Addons.{PascalName}Live` | `OpenMesWeb.Addons.MyReportLive` |
| id atom | `:addon_{snake_name}` | `:addon_my_report` |
| home_path | `/extensions/{kebab-name}` | `/extensions/my-report` |

근거 골격: `lib/open_mes_addons/wo_csv_export/`(읽기 전용, 새 테이블 0의 전형).

---

## 2.6 완전 동작 골격 (복붙 후 `{Name}`/`{name}` 치환)

아래 4~5파일이 **읽기 전용 최소 확장**의 전부다. placeholder만 치환하면 카탈로그에 뜨고 화면이 열린다.

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

  @doc "코어 데이터를 읽어 화면용 데이터를 만든다(읽기 전용, 순수 함수)."
  def summary(filters \\ %{}) when is_map(filters) do
    OpenMes.Production.list_work_orders(filters)
    # ... 집계/가공 ...
  end
end
```

**(B) behaviour — `lib/open_mes_addons/{name}/extension.ex`** (필수 6 + home_path + route_spec)
```elixir
defmodule OpenMes.Addons.MyReport.Extension do
  @moduledoc "MyReport 애드온의 Extension behaviour 구현(메타데이터 + 라우트 데이터)."
  use OpenMes.Extension.Definition

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

  # 화면이 있으면 home_path + route_spec 을 override. 없으면 두 콜백 모두 생략(기본값 nil).
  @impl true
  def home_path, do: "/extensions/my-report"
  @impl true
  def route_spec do
    %{
      scope: "/extensions",
      pipeline: :browser,
      routes: [{:live, "/my-report", OpenMesWeb.Addons.MyReportLive, :index}]
    }
  end
end
```

**(C) LiveView (화면 있을 때만) — `lib/open_mes_addons/{name}/live/{name}_live.ex`**
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

**(D) 활성화 게이트 — `config/config.exs`** (`:auto` 발견 모드 기준)
```elixir
config :open_mes, OpenMes.Addons.MyReport, enabled: true   # ← enabled 게이트(1줄)
```
- `:auto` 발견(기본)이면 **이게 전부다.** behaviour 모듈은 로드된 앱 스캔으로 자동 발견된다 —
  `:extensions` 목록 등록 불필요.
- `:manual` 모드(또는 발견 보강)면 명시 목록에 한 줄 더 추가한다:
  ```elixir
  config :open_mes, :extensions, [
    # ... 기존 항목 유지 ...
    OpenMes.Addons.MyReport.Extension   # ← 추가(1줄)
  ]
  ```

**(E) 라우트 — router.ex 수정 0 (`route_spec/0` 만 선언)**

과거에는 화면마다 `lib/open_mes_web/router.ex` 에 `if X.enabled?() do scope ... end` 블록을
복제해야 했다. **이 절차는 폐기됐다.** 이제 (B)의 `route_spec/0` 만 선언하면 코어 router.ex의
다음 한 줄이 컴파일 타임에 모든 확장 라우트를 자동 주입한다:

```elixir
# lib/open_mes_web/router.ex (코어 — 확장 개발자는 건드리지 않는다)
OpenMes.Extension.RouterMount.mount_extension_routes()
```

매크로가 `enabled? == true` 인 확장의 `route_spec/0` 만 순회해 `{:live|:get|:post, path, mod, action}`
튜플을 Phoenix 라우트로 펼친다. off면 라우트 테이블에 흔적이 남지 않는다(컴파일 타임 게이트).

---

## 3. 최소 확장 만들기

`use OpenMes.Extension.Definition` 한 줄로 선택 콜백 기본값(nil)이 주입되므로,
**필수 6개만** 구현하면 카탈로그에 뜨는 최소 확장이 완성된다.

```elixir
defmodule OpenMes.Addons.MyReport.Extension do
  @moduledoc "우리 회사 맞춤 리포트 확장(메타데이터)."
  use OpenMes.Extension.Definition

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

  # 자체 화면이 있으면 home_path + route_spec 을 override (없으면 생략하면 nil).
  @impl true
  def home_path, do: "/extensions/my-report"
  @impl true
  def route_spec do
    %{
      scope: "/extensions",
      pipeline: :browser,
      routes: [{:live, "/my-report", OpenMesWeb.Addons.MyReportLive, :index}]
    }
  end
end
```

`enabled?/0`는 관례상 확장의 퍼사드 게이트에 위임한다:

```elixir
defmodule OpenMes.Addons.MyReport do
  @doc "config :open_mes, MyReport, enabled: true 일 때만 동작."
  def enabled?, do: Application.get_env(:open_mes, __MODULE__, [])[:enabled] == true
end
```

---

## 4. 등록 — 자동 발견(`:auto`) + escape hatch

발견 모드는 `config :open_mes, :extension_discovery` 로 정한다(기본 `:auto`).

```elixir
config :open_mes, :extension_discovery, :auto   # 기본. 로드된 OTP 앱 스캔으로 자동 발견.
```

**`:auto` 모드(기본)** — `Extension` behaviour를 구현한 모듈이 로드된 앱에 있으면 자동 발견된다.
in-tree 애드온은 코드를 두면 잡히고, 외부 repo 확장은 `mix.exs` deps 한 줄이면 잡힌다.
`:extensions` 목록 등록은 **불필요**하다. 활성화 게이트 한 줄만 둔다:

```elixir
config :open_mes, OpenMes.Addons.MyReport, enabled: true   # enabled 게이트(1줄)
```

**escape hatch (두 모드 공통):**

```elixir
config :open_mes, :extra_extensions,   [SomeMod]   # 발견 못 한 모듈 강제 등록
config :open_mes, :exclude_extensions, [SomeMod]   # 발견됐지만 제외
```

**`:manual` 모드** — 자동 발견을 끄고 `config :open_mes, :extensions` **명시 목록**만 쓴다
(완전 보수적·되돌리기 포인트). 이 경우 만든 확장의 `Extension` 모듈을 목록에 한 줄 추가한다:

```elixir
config :open_mes, :extension_discovery, :manual
config :open_mes, :extensions, [
  # ... 기존 확장들 ...
  OpenMes.Addons.MyReport.Extension   # ← 우리 확장 추가
]
```

> 테스트 환경(`config/test.exs`)은 fixture 결정성을 위해 `:manual` 로 고정돼 있다.

**무엇이 발견됐는지 확인** — `mix ext.list`:

```bash
mix ext.list
# 발견된 확장 (9): 출처 앱 · enabled · 라우트 · [외부] 여부를 한눈에 출력
```

추가 후 서버를 재시작하면 `/extensions` 카탈로그에 카드가 자동으로 나타난다.
끄고 싶으면 `enabled: false` 로 바꾸면 '비활성' 배지로 남고 화면/라우트는 등록되지 않는다.

---

## 5. 재사용 가능한 빌딩블록

확장을 처음부터 만들 필요는 없다. 코어가 제공하는 재사용 블록을 활용한다.

- **SVG 차트** — `OpenMesWeb.ChartComponents`: 막대/라인 등 의존성 0의 순수 SVG 차트 컴포넌트.
  외부 차트 라이브러리 없이 분석 위젯을 그린다.
- **관리자 UI** — `OpenMesWeb.AdminComponents`: `admin_shell`(사이드바·상단바 레이아웃),
  `page_header`, `active_badge`, `status_badge`, `empty_state` 등. 확장 화면도
  `use OpenMesWeb.Admin.AdminLive` 한 줄로 코어와 동일한 룩앤필을 공유한다.
- **컨텍스트 읽기 함수** — 코어 도메인 컨텍스트(`OpenMes.Production` 등)의 조회 함수를
  그대로 호출해 작업지시/실적/LOT/불량 데이터를 읽는다.
- **레지스트리** — `OpenMes.Extension.Registry.all/0` · `enabled/0` · `by_category/0`.

---

## 6. 데이터 접근 원칙

확장의 데이터 취급은 안전 경계를 지켜야 한다.

- **읽기 위주**: 대부분의 애드온은 코어 데이터를 **읽기만** 한다(새 테이블 0, 쓰기 0).
  기존 애드온 5개가 모두 이 패턴이다.
- **쓰기는 컨텍스트 경유 + AuditLog**: 도메인 트랜잭션을 쓰는 확장은 코어 테이블을 직접
  건드리지 않고 **컨텍스트 함수를 경유**한다. 모든 쓰기는 AuditLog를 남기고, 상태 변경은
  동일 트랜잭션 안에서 Outbox 이벤트를 삽입한다. 자재 소비는 LotConsumption을 경유한다.
- **AI는 propose → 승인**: AI 연동 확장은 직접 쓰기를 하지 않는다. `propose_*`로 후보를
  제안하고, 근거를 표시하며, 사람이 승인할 때만 컨텍스트 경유로 반영한다. 모든 AI 상호작용은
  AiInteraction으로 기록한다. (자세히는 `docs/ai-native-architecture.md`)

### 명령형 체크리스트 (LLM 강제)

- **금지**: 코어 파일 수정 · 새 DB 테이블/마이그레이션 · GenServer/동적 모듈 스캔 · AI 직접 쓰기
- **필수**: `lib/open_mes_addons/` 격리 · 컨텍스트 공개 함수 경유 읽기 · `use OpenMes.Extension.Definition` ·
  enabled 게이트(`:auto`면 1줄, `:manual`이면 +등록 1줄) · `mix ext.verify` 통과
- **쓰기가 불가피하면(드묾)**: 컨텍스트 함수 경유 + AuditLog + 동일 트랜잭션 Outbox + (자재) LotConsumption.
  이 경우 **LLM은 자동 진행을 멈추고 qa-auditor `audit-verify` 검토를 요청**한다.
  `mix ext.verify` 의 C7(코어 비침투)은 grep 휴리스틱이라 **명백한 Repo 직접 쓰기만** 잡는다 —
  매크로 우회 등은 못 잡으므로, **도메인 쓰기 확장은 C7 통과해도 audit-verify 가 필수**다(정직 표기).

---

## 7. 레퍼런스 — 기존 확장 8개

처음 만들 때는 가장 가까운 기존 확장을 복사해서 시작하는 것이 빠르다.

| 확장 | 카테고리 | 패턴 | 위치 |
|------|---------|------|------|
| 설비 데이터 수집(EXT-1) | ingest | HTTP push → Broadway → 시계열 | `lib/open_mes_ingest/` |
| 멀티미디어 수집(EXT-2) | media | NAS watch → object storage (라우트 0) | `lib/open_mes_media/` |
| 작업지시 CSV 내보내기 | production | 읽기 → CSV export | `lib/open_mes_addons/wo_csv_export/` |
| 불량 통계 위젯 | quality | 읽기 → 집계 + 차트 | `lib/open_mes_addons/defect_stats/` |
| LOT QR 라벨 생성 | traceability | 읽기 → QR 라벨 | `lib/open_mes_addons/lot_qr_label/` |
| 설비 가동률 OEE | analytics | 읽기 → OEE 계산 | `lib/open_mes_addons/equipment_oee/` |
| 일일 생산 요약 | production | 읽기 → 요약 리포트 | `lib/open_mes_addons/daily_production_summary/` |
| DureClaw 연동 허브(EXT-5) | integration | 버스 REST 읽기 → fleet 관측 | `lib/open_mes_connect/dureclaw/` |

가장 단순한 시작점은 **작업지시 CSV 내보내기**(`wo_csv_export`)다 — 읽기 전용, 새 테이블 0,
`Extension` behaviour 구현 + 화면 + 컨텍스트 읽기의 전형이다.

**외부 repo 확장의 레퍼런스**는 형제 디렉토리 `open_mes_ext_demo/` 다 — 코어 `:open_mes` 무의존,
계약 패키지만 의존하며 deps 한 줄로 자동 노출되는 최소 골격(§10).

확장 생태계 전체 로드맵(EXT-3~12, 연동 허브, 업종 플러그인)은 `docs/extension-roadmap.md`를 참고한다.

---

## 8. 자동 검증 — `mix ext.verify`

확장을 만든 뒤 **사람/LLM 모두 파싱 가능한** 정적 검증을 돌린다. introspection + grep만 사용하며
(외부 deps·dialyzer·서버/Repo 기동 0), 컴파일만 보장한다.

```bash
mix ext.verify OpenMes.Addons.MyReport.Extension   # 단일 확장
mix ext.verify                                       # :extensions 전체 스캔
```

**체크 8종:**

| # | 검사 | 방법 |
|---|---|---|
| C1 | 필수 6 콜백 구현 | behaviour introspection 으로 유도(하드코딩 0) |
| C2 | behaviour 채택 | `@behaviour OpenMes.Extension` |
| C3 | 등록 | `Registry.modules()` 포함(`:manual` 명시 / `:auto` 발견) |
| C4 | 카탈로그 노출 가능 | `Registry.all()` 에서 raise 없이 엔트리화 |
| C5 | id 고유성 | 발견된 확장 전체 간 id 중복 0 + atom(외부 확장 충돌 탐지) |
| C6 | category(정보성) | atom이면 통과. `known_categories/0` 미포함이면 ⚠️ 정보성 안내만(실패 아님) |
| C7 | 코어 비침투(휴리스틱) | `module_info(:compile)[:source]` 기반 확장 소스의 Repo 직접 쓰기 grep(외부 dep 대응) |
| C8 | route_spec 형태 | `route_spec/0` 이 있으면 scope/pipeline/routes 형태 검증(nil이면 라우트 미기여로 통과) |

**샘플 리포트 (LLM 파싱 친화):**

```
ext.verify: OpenMes.Addons.MyReport.Extension
  ✅ C1 필수 콜백 6개 구현
  ✅ C2 Extension behaviour 채택
  ❌ C3 config :extensions 미등록
      → config :open_mes, :extensions 리스트에 모듈 한 줄 추가 (또는 :auto 발견 — 가이드 §4)
  ✅ C4 카탈로그 노출 가능
  ✅ C5 id 고유 (:addon_my_report)
  ✅ C6 category 유효 (:analytics)
  ✅ C7 코어 비침투 (직접 쓰기 0건; 도메인 쓰기 확장은 audit-verify 필수)
  ✅ C8 route_spec 유효 (1개 라우트, scope /extensions)

결과: 7/8 통과 ❌  (종료코드 1)
다음: 위 → 안내대로 수정 후 재실행
```

실패 항목마다 `→ 수정 안내` 한 줄이 붙는다. 종료코드: **전체 통과 0 / 위반 1.**
C7 한계: 매크로 우회 등은 못 잡고, Extension 모듈 자기 소스 트리만 스캔하므로 **도메인 쓰기
확장은 C7 통과해도 qa-auditor `audit-verify` 가 필수**다(§6).

---

## 9. LLM 자기완결 개발 루프

LLM은 사람 개입 없이 아래 루프를 **수렴까지** 돌린다:

```
1. 확장 코드 작성 (§2.5 1~6단계, §2.6 골격 복붙·치환)
2. mix ext.verify OpenMes.Addons.{Name}.Extension
3. ❌ 있으면 → 안내(→ 줄) 따라 수정 → 2 재실행 (수렴까지 반복)
4. 전부 ✅ → mix compile --warnings-as-errors
5. mix test  (실패 시 수정 → 4)
6. 모두 통과 = 개발 완료(DoD §0)
```

---

## 10. 외부 repo 확장 (별도 저장소로 배포)

회사 고유 기능을 `open_mes` 저장소 안에 두지 않고 **별도 git/Hex 저장소**로 배포할 수 있다.
확장 시스템 디커플링(설계 30) 덕분에, 외부 확장은 호스트 코어를 **0줄** 수정하고 `mix.exs`
deps **한 줄**만으로 붙는다. 동작하는 레퍼런스는 형제 디렉토리 `open_mes_ext_demo/` 다.

### in-tree 애드온(§2~9) vs 외부 repo 확장(§10) — 선택 기준

- **in-tree 애드온**: 이 회사 인스턴스 전용 리포트/위젯, 코어 데이터 읽기가 주목적, 빠른 추가.
  `lib/open_mes_addons/` 에 두고 코어와 함께 빌드된다.
- **외부 repo 확장**: 독립 배포·버전·재사용(여러 공장/고객에 배포), 별도 팀 소유, 코어와
  릴리스 주기 분리가 필요할 때. 코어 `:open_mes` 에 의존하지 않고 계약 패키지에만 의존한다.

### 10.1 확장 repo 쪽 (`my_ext/`)

**`mix.exs`** — 코어 `:open_mes` 가 아니라 **계약 패키지만** 의존한다(단방향):

```elixir
defp deps do
  [
    {:open_mes_extension_api, "~> 0.1"},     # 또는 git/path. 계약(behaviour/Definition/Registry/RouterMount).
    {:phoenix_live_view, "~> 1.0.0-rc.1"}    # 자기 LiveView 화면이 있을 때만(호스트 web 컨텍스트에서 펼쳐짐)
    # 코어(:open_mes)에는 의존하지 않는다. 코어 데이터는 코어의 공개 HTTP API 로만 접근.
  ]
end
```

**`lib/my_ext/extension.ex`** — `OpenMes.Extension` behaviour 구현. in-tree와 동일하되 코어
참조가 없다:

```elixir
defmodule MyExt.Extension do
  use OpenMes.Extension.Definition

  @impl true
  def id, do: :my_ext
  @impl true
  def name, do: "외부 확장 예시"
  @impl true
  def description, do: "별도 repo 로 배포되는 확장."
  @impl true
  def category, do: :analytics      # known 이든 자유 atom(:my_cat)이든 가능(§2 카테고리)
  @impl true
  def version, do: "0.1.0"
  @impl true
  def enabled? do
    :my_ext |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, false)
  end
  @impl true
  def home_path, do: "/extensions/my-ext"

  # 라우트도 데이터 선언 — 호스트 router.ex 를 건드리지 않는다.
  @impl true
  def route_spec do
    %{
      scope: "/extensions",
      pipeline: :browser,
      routes: [{:live, "/my-ext", MyExtWeb.MyExtLive, :index}]
    }
  end
end
```

### 10.2 호스트 쪽 (`open_mes/`) — 단 한 줄

```elixir
# open_mes/mix.exs deps 에 한 줄 추가 (이것이 유일한 호스트 편집)
{:my_ext, "~> 0.1"}   # 또는 git: "https://...", path: "../my_ext"
```

- `:auto` 발견(기본)이면 **이게 전부다.** `mix deps.get && mix compile` 후 확장이 카탈로그 카드 +
  라우트(`/extensions/my-ext`)에 자동 노출된다. `router.ex` / `config :extensions` /
  `extension.ex` 어느 것도 수정하지 않는다.
- 보수적으로 `:manual` 을 쓰면 `config :open_mes, :extra_extensions, [MyExt.Extension]` 한 줄을 더한다.
- 활성화: `config :my_ext, MyExt.Extension, enabled: true`.

### 10.3 확인

```bash
mix ext.list      # MyExt.Extension 이 [외부] 로 발견되는지 + 출처 앱 + 라우트 확인
mix ext.verify    # 외부 확장 포함 전체 C1~C8 그린
mix phx.routes    # /extensions/my-ext 가 자동 마운트됐는지
```

### 10.4 경계 (외부 확장도 동일하게 준수)

- **단방향 의존**: 코어 → 확장 참조는 없고, 확장 → 코어는 **공개 HTTP API** 로만(외부 repo는
  `:open_mes` 모듈을 직접 부르지 않는다). 계약 패키지는 메타/라우팅 통로일 뿐 데이터 통로가 아니다.
- **쓰기·AI 경계**: §6 과 동일 — 도메인 쓰기는 컨텍스트(코어 API) 경유 + AuditLog, AI는 propose→승인.
  `mix ext.verify` C7 은 외부 dep 소스(`deps/my_ext/lib/...`)도 `module_info(:compile)` 로 스캔한다.
- **id 충돌**: 외부 확장의 `id/0` 가 코어/타 확장과 겹치면 C5가 잡는다 — 고유한 atom을 쓴다.
