# 30 · 확장 시스템 디커플링 설계 — 별도 repo 확장이 코어 소스 0 수정으로 붙도록

작성: architect · 2026-06-15
대상 구현자: domain-engineer
상태: 설계 (구현 금지)

관련 문서: CLAUDE.md(pi 원칙·확장 구조), docs/extension-roadmap.md(확장 레지스트리·카탈로그), docs/system-architecture.md(Outbox 이벤트)
대상 코드(현행):
- `open_mes/lib/open_mes/extensions/{extension,definition,registry}.ex`
- `open_mes/lib/open_mes_web/router.ex` (209~274행 하드코딩 if 블록)
- `open_mes/config/config.exs` (58~103행)
- `open_mes/lib/mix/tasks/ext.verify.ex` (`addon_source_files/1`)

---

## 0. 요약 (결론 먼저)

현행은 단일 Phoenix 앱(`:open_mes`) 안에 확장 7개가 인-트리로 존재하고, **router.ex / category union / ext.verify 소스경로 / config 목록** 4곳이 코어 소스를 잡고 있다. 외부 repo 확장이 코어 수정 0으로 붙으려면:

1. **router** → `mount_extension_routes()` **단일 컴파일타임 매크로**로 교체. 각 확장이 `route_spec/0`(선택 콜백)으로 자기 라우트를 **데이터로** 선언하고, 매크로가 `Application.compile_env(:open_mes, :extensions)` 목록을 컴파일 타임에 순회해 주입. 외부 확장은 코어 router.ex를 건드리지 않는다.
2. **category** → 닫힌 union을 `atom()`으로 개방, `categories/0`은 "알려진 카테고리(라벨/필터용)"로 격하(`known_categories/0`). 미지 카테고리는 카탈로그가 atom 그대로 렌더.
3. **ext.verify C7** → `lib/` 경로 추정을 버리고 `mod.module_info(:compile)[:source]` 기반 실제 컴파일 소스 경로 사용. 외부 dep(`deps/.../lib`)도 자동 대응.
4. **config 목록** → (B) 얇은 계약 패키지 `open_mes_extension_api` 추출 + (C) 자동 발견으로 명시 목록 제거. 단 발견 트레이드오프 보완(가시화 `mix ext.list`, config override/제외 escape hatch, 견고성).

**가장 어려운 지점**(컴파일타임 라우트 vs 런타임 발견)의 해법: **라우트 기여 확장 목록은 컴파일 타임에 확정**한다. 자동 발견은 두 모드로 나눈다 — (a) **메타데이터/카탈로그**(런타임 발견 OK), (b) **라우트 기여**(컴파일 타임 발견 필수). 라우트는 `Application.loaded_applications/0`를 **컴파일 타임에** 스캔해 behaviour 구현 모듈을 모으거나(완전 자동), 그게 무거우면 **mix.exs deps 목록 기반 앱 스캔**으로 확정한다. §2.1·§2.4에 코드 스케치.

**in-repo 분리 방식 권고: umbrella 전환 대신 path dep `apps/open_mes_extension_api`.** 이유는 §3.3.

**pi 균형**: 자동 발견은 config 명시(pi)를 뒤집으므로, "최소"는 (A)+(B)까지로 보고 (C) 자동 발견은 **opt-in 보완책과 함께** 도입한다. 명시 목록은 사라지지 않고 **override/제외 escape hatch**로 잔존한다(완전 마법 금지).

---

## 1. 목표 상태 — 외부 repo 확장 추가 end-to-end (코어 수정 0 증명)

외부 개발자가 `my_mes_oee_pro`라는 별도 git repo로 확장을 만들어 호스트(`open_mes`)에 붙이는 절차:

### 1.1 확장 repo 쪽 (`my_mes_oee_pro/`)

```elixir
# mix.exs
def deps do
  [
    {:open_mes_extension_api, "~> 0.1"}   # 또는 git/path. 계약 패키지에만 의존.
    # 코어(:open_mes)에는 의존하지 않는다. 데이터는 코어가 노출하는 공개 API/HTTP로만.
  ]
end
```

```elixir
# lib/my_mes_oee_pro/extension.ex
defmodule MyMesOeePro.Extension do
  use OpenMes.Extension.Definition   # 계약 패키지 네임스페이스(§3.1)

  @impl true
  def id, do: :oee_pro
  @impl true
  def name, do: "OEE 고도화"
  @impl true
  def description, do: "설비 종합효율 상세 분석"
  @impl true
  def category, do: :analytics        # 알려진 카테고리. 새 분류면 자유 atom(§4)
  @impl true
  def version, do: "0.1.0"
  @impl true
  def enabled?, do: Application.get_env(:my_mes_oee_pro, :enabled, true)
  @impl true
  def home_path, do: "/extensions/oee-pro"

  # 라우트 기여(선택 콜백). 데이터로 선언 — 코어 router.ex를 건드리지 않는다.
  @impl true
  def route_spec do
    %{
      scope: "/extensions",
      pipeline: :browser,
      router_module: MyMesOeeProWeb.Router.Routes,   # live/get 매크로 호출 모듈(§2.1)
      mount: {MyMesOeeProWeb.OeeProLive, :index, "/oee-pro"}
    }
  end
end
```

### 1.2 호스트 쪽 (`open_mes/`) — 단 한 줄

```elixir
# open_mes/mix.exs deps 에 한 줄 추가 (이것이 유일한 호스트 편집)
{:my_mes_oee_pro, "~> 0.1"}   # 또는 git: "..."
```

- (C) 자동 발견이 켜져 있으면 **이것으로 끝.** config·router·extension.ex·ext.verify 어느 것도 수정하지 않는다.
- 자동 발견을 끈(보수적) 모드면 config override 한 줄 추가:
  ```elixir
  config :open_mes, :extra_extensions, [MyMesOeePro.Extension]
  ```

### 1.3 코어 수정 0 증명 체크리스트

| 결합 지점(현행) | 외부 확장이 건드려야 하나? | 해소 |
|---|---|---|
| `router.ex` if 블록 | ❌ 아니오 | `route_spec/0` 데이터 선언 + mount 매크로(§2.1) |
| `extension.ex` category union | ❌ 아니오 | `atom()` 개방(§2.2) |
| `ext.verify.ex` 소스경로 | ❌ 아니오 | `module_info(:compile)` 기반(§2.3) |
| `config.exs` :extensions 목록 | ❌ 아니오(자동발견) / △ 1줄(override) | 발견 + escape hatch(§2.4) |

→ deps 한 줄을 제외하면 **호스트 코어 소스 0 수정**. deps 추가는 "확장 설치"의 본질적 행위이지 코어 침투가 아니다.

---

## 2. 4개 결합 지점별 해소 설계 + 코드 스케치

### 2.1 결합①: router.ex — 단일 mount 매크로 (가장 핵심)

**제약 인식**: Phoenix 라우트는 컴파일 타임 매크로(`live/3`, `get/3`)다. 라우트 테이블은 컴파일 시점에 확정되어야 한다 → "어떤 확장이 라우트를 기여하는가"의 목록도 **컴파일 타임에** 알아야 한다. 이것이 자동 발견과 충돌하는 지점이며 §2.4에서 정합성을 다룬다.

**설계**: 코어 router.ex의 7개 if 블록(209~274행)을 다음 한 줄로 대체.

```elixir
# open_mes/lib/open_mes_web/router.ex
defmodule OpenMesWeb.Router do
  use OpenMesWeb, :router
  require OpenMes.Extension.RouterMount   # 계약 패키지

  # ... 파이프라인, 코어 scope 그대로 ...

  # 확장 라우트 일괄 주입. if 블록 7개 → 이 한 줄.
  OpenMes.Extension.RouterMount.mount_extension_routes()

  # dev_routes 등 그대로
end
```

**매크로 구현 스케치** (`open_mes_extension_api`에 위치):

```elixir
defmodule OpenMes.Extension.RouterMount do
  @moduledoc "확장 라우트를 컴파일 타임에 일괄 주입하는 매크로."

  defmacro mount_extension_routes do
    # ── 컴파일 타임에 '라우트 기여 확장 목록' 확정 ──
    # route_modules/0 은 컴파일 타임에 평가된다(매크로 본문 = 컴파일 타임 코드).
    specs =
      OpenMes.Extension.Discovery.route_specs()   # [%{scope, pipeline, router_module, mount}, ...]

    for %{scope: scope, pipeline: pipe, router_module: rmod, mount: mount} <- specs do
      quote do
        scope unquote(scope) do
          pipe_through unquote(pipe)
          # 각 확장이 자기 라우트 매크로 호출을 모아둔 모듈을 import 해 호출.
          # (Phoenix live/3 는 Router 컨텍스트 안에서만 유효하므로 unquote 로 인라인)
          unquote(rmod).__routes__()
        end
      end
    end
  end
end
```

**`route_spec/0` 두 가지 형태 — pi에 따라 단순형 우선**:

- **단순형(권장)**: `mount: {LiveModule, :action, "/path"}` 단일 LiveView. 매크로가 `live "/path", LiveModule, :action`로 펼친다. 외부 확장이 별도 Routes 모듈을 안 만들어도 됨. EXT-2 같이 화면 없는 확장은 `route_spec/0` 미구현(nil) → 라우트 0.
- **복합형**: 여러 라우트가 필요하면 `router_module`에 라우트 매크로 호출을 담은 모듈을 두고, 매크로가 그 모듈의 라우트 정의를 인라인. (DureClaw, EXT-1처럼 health+create 다중 라우트일 때)

  실무 단순화: 복합형은 `mount`를 라우트 튜플 **리스트**로 받게 한다 — 별도 Routes 모듈 없이도 다중 라우트 표현 가능.

```elixir
# 권장 최종 형태 — route_spec 은 순수 데이터(매크로 호출 모듈 불필요)
def route_spec do
  %{
    scope: "/ingest",
    pipeline: :require_device_token,
    routes: [
      {:post, "/equipment", OpenMesWeb.IngestController, :create},
      {:get,  "/health",    OpenMesWeb.IngestController, :health}
    ]
  }
end
```

매크로는 `{:live, path, mod, action}` / `{:post, path, ctrl, action}` / `{:get, ...}` 튜플을 각 Phoenix 매크로로 펼친다. **이렇게 하면 외부 확장은 자기 Router 모듈을 만들 필요 없이 데이터만 제공**한다(pi: 추상화 최소).

```elixir
defmacro mount_extension_routes do
  specs = OpenMes.Extension.Discovery.route_specs()

  for %{scope: scope, pipeline: pipe, routes: routes} <- specs do
    route_asts =
      for r <- routes do
        case r do
          {:live, path, mod, action} -> quote(do: live(unquote(path), unquote(mod), unquote(action)))
          {:get,  path, ctrl, action} -> quote(do: get(unquote(path), unquote(ctrl), unquote(action)))
          {:post, path, ctrl, action} -> quote(do: post(unquote(path), unquote(ctrl), unquote(action)))
        end
      end

    quote do
      scope unquote(scope) do
        pipe_through unquote(pipe)
        unquote_splicing(route_asts)
      end
    end
  end
end
```

**enabled? 게이트는 어디서?** 현행은 `if X.enabled?()` 컴파일 타임 게이트(off면 라우트 테이블에 흔적 없음). 자동 발견 + 매크로에서는:
- `Discovery.route_specs/0`가 **`enabled? == true`인 확장만** 반환하도록 한다. `enabled?`가 `Application.compile_env` 기반이면 컴파일 타임 평가 → 현행과 동등(off=흔적 없음).
- 단 `enabled?`가 런타임 env(`System.get_env`) 기반이면 컴파일 타임에 false로 평가될 수 있다 → **계약 명시**: "라우트 기여 확장의 `enabled?`는 컴파일 타임 결정값(`Application.compile_env`)을 써야 한다". 이는 현행 EXT-1(`OpenMes.Ingest.enabled?()` → compile_env)과 동일 관례.
- `Discovery`가 `Application.compile_env`를 읽으므로, env 변경 시 라우트 반영은 재컴파일 필요(현행과 동일 — 컴파일 타임 게이트의 본질적 성질).

### 2.2 결합②: extension.ex category — union 개방

```elixir
# extension.ex
@type category :: atom()   # 개방. 외부 확장이 자유 카테고리 사용 가능.

@callback category() :: category()

@doc "알려진(코어가 라벨/필터 UI를 제공하는) 카테고리. 검증 게이트 아님."
@spec known_categories() :: [atom()]
def known_categories,
  do: [:ingest, :media, :production, :quality, :traceability, :analytics, :integration]
```

- `categories/0` → `known_categories/0`로 개명(의미 명확화: "유효성 판정"이 아니라 "알려진 라벨").
- **ext.verify C6 변경**: "category가 `known_categories`에 있어야 통과" → "category가 atom이면 통과, **known에 없으면 ⚠️ 정보성 경고**(실패 아님)". 미지 카테고리는 정상이다(외부 확장의 자유).
- **카탈로그 렌더**: known이면 한국어 라벨 매핑, 미지면 atom을 그대로 제목화(`:my_cat` → "my cat"). 카테고리 필터는 `Registry.all()`에서 등장한 카테고리를 **동적으로** 모아 칩을 생성(하드코딩 제거) → 외부 카테고리 자동 수용.

### 2.3 결합③: ext.verify C7 소스경로 — 실제 컴파일 소스 기반

현행 `addon_source_files/1`은 `Macro.underscore(mod)` → `lib/...` 글롭으로 **추정**한다. 외부 dep는 `deps/my_mes_oee_pro/lib/...`에 있어 잡지 못한다.

**수정**: 모듈이 실제로 컴파일된 소스 파일 경로를 BEAM 메타데이터에서 얻는다.

```elixir
defp addon_source_files(mod) do
  Code.ensure_loaded(mod)

  case mod.module_info(:compile)[:source] do
    src when is_list(src) or is_binary(src) ->
      ext_file = to_string(src)          # 예: ".../deps/my_mes_oee_pro/lib/.../extension.ex"
      root = Path.dirname(ext_file)      # 확장 모듈이 사는 디렉토리
      # 같은 디렉토리(+하위)의 .ex 를 확장 소스로 간주. lib/ 추정 폐기.
      Path.wildcard(Path.join(root, "**/*.ex"))

    _ ->
      []   # 소스 정보 없음(예: 핫로드 모듈) → C7 스킵, 정보성 표기
  end
end
```

- `module_info(:compile)[:source]`는 컴파일 시 절대경로를 담는다. in-tree·deps·umbrella 모두 동작.
- 한계: 다른 모듈로 분산된 확장(컨트롤러가 `open_mes_web/`에 있는 등 in-tree 잔재)은 디렉토리가 다를 수 있음 → C7은 "Extension 모듈 디렉토리 트리"만 스캔하는 1차 가드임을 moduledoc에 명시(현행도 휴리스틱이라 동일 성격). 도메인 쓰기 확장은 qa-auditor `audit-verify` 필수(현행 정책 유지).
- **C3·C5 조정**: 자동 발견 도입 시 "config :extensions 등록" 의미가 바뀐다 → §2.4 참조.

### 2.4 결합④: config 목록 — 자동 발견 + escape hatch (가장 신중하게)

**핵심 정합성 문제**: 라우트는 컴파일 타임, 발견은 런타임이 자연스럽다. 해결책 — **두 발견 경로 분리**.

```elixir
defmodule OpenMes.Extension.Discovery do
  @moduledoc """
  확장 발견. 두 경로:
    - all/0       : 런타임 발견 OK (카탈로그·메타데이터). 로드된 앱 스캔.
    - route_specs/0 : 컴파일 타임 확정 필요(라우트). all/0 결과를 컴파일 타임에 평가.
  """

  # ── (a) 메타데이터/카탈로그 — 런타임 발견 ──
  @doc "로드된 모든 OTP 앱에서 Extension behaviour 구현 모듈을 수집."
  def all do
    discovered = discover_modules()
    extra = Application.get_env(:open_mes, :extra_extensions, [])    # override
    exclude = Application.get_env(:open_mes, :exclude_extensions, []) # 제외
    (discovered ++ extra) |> Enum.uniq() |> Enum.reject(&(&1 in exclude))
  end

  defp discover_modules do
    for {app, _, _} <- Application.loaded_applications(),
        {:ok, mods} = :application.get_key(app, :modules),
        mod <- mods,
        implements_extension?(mod) do
      mod
    end
  rescue
    _ -> []   # 발견 실패 시 빈 목록(견고성 — safe_enabled? 정신 확장)
  end

  # behaviour 채택 여부를 introspection 으로 판정(현행 ext.verify C2 로직 재사용).
  defp implements_extension?(mod) do
    Code.ensure_loaded?(mod) and
      function_exported?(mod, :id, 0) and
      OpenMes.Extension in (mod.module_info(:attributes)[:behaviour] || [])
  rescue
    _ -> false
  end

  # ── (b) 라우트 — 컴파일 타임 확정 ──
  @doc "enabled? 이고 route_spec/0 을 가진 확장의 스펙. 매크로에서 컴파일 타임 평가."
  def route_specs do
    for mod <- all(),
        safe_enabled?(mod),
        spec = safe_route_spec(mod),
        not is_nil(spec) do
      spec
    end
  end
end
```

**컴파일 타임 정합성 — `Application.loaded_applications/0`가 컴파일 시점에 동작하나?**

- 매크로 본문은 **호스트(`open_mes`) 컴파일 시점**에 실행된다. 이때 deps는 이미 컴파일·로드되어 있다(컴파일 순서: deps 먼저). 따라서 `Application.loaded_applications/0`는 deps 앱들을 포함한다. **단** 일부 환경에서 dep 앱이 `:application.load`되지 않았을 수 있다 → 매크로에서 **명시적으로 deps 앱을 load**한 뒤 스캔하는 안전판을 둔다:

```elixir
# RouterMount.mount_extension_routes 진입부
def ensure_apps_loaded do
  # mix.exs deps 의 app 들을 컴파일 타임에 load (스캔 대상 확정).
  Mix.Project.deps_apps() |> Enum.each(&Application.load/1)
rescue
  _ -> :ok
end
```

- **대안 비교(컴파일 타임 확정 메커니즘)**:
  | 방식 | 컴파일 타임 신뢰성 | 명시성 | 권고 |
  |---|---|---|---|
  | `Application.loaded_applications` 스캔 | 보통(load 보장 필요) | 낮음 | (C) 자동, 안전판과 함께 |
  | `Mix.Project.deps_apps` → 각 앱 모듈 스캔 | 높음(mix.exs가 진실) | 중간 | **권고 기본** |
  | config `:extensions` 명시 목록(현행) | 매우 높음 | 높음(pi) | escape hatch로 잔존 |

  → **권고: `Mix.Project.deps_apps()` + 호스트 자체 모듈 스캔으로 후보 앱을 모으고, 각 앱 모듈에서 behaviour 구현을 introspection.** mix.exs가 "무엇이 설치됐나"의 단일 진실이므로 컴파일 타임에 가장 신뢰할 수 있고, deps 한 줄 추가로 끝나는 UX와도 정합.

**발견 트레이드오프 보완(필수)**:

1. **가시화 — `mix ext.list`** (신규 task, ext.verify와 별도 또는 통합):
   ```
   mix ext.list
   발견된 확장 (5):
     ✅ :ext_ingest         (app: open_mes)        enabled=false  route=/ingest
     ✅ :addon_wo_csv_export(app: open_mes)        enabled=true   route=/extensions/wo-csv-export
     ✅ :oee_pro            (app: my_mes_oee_pro)  enabled=true   route=/extensions/oee-pro   [외부]
     ⊘ :addon_daily_summary(app: open_mes)        enabled=false  route=-
   override(extra): []   제외(exclude): []
   ```
   "출처 앱 + enabled + 라우트 + 외부 여부"를 출력 → 발견의 불투명성 해소.

2. **escape hatch**:
   - `config :open_mes, :extra_extensions, [Mod, ...]` — 발견 못 한 모듈 강제 등록.
   - `config :open_mes, :exclude_extensions, [Mod, ...]` — 발견됐지만 제외.
   - `config :open_mes, :extension_discovery, :auto | :manual` — `:manual`이면 발견 끄고 `:extensions` 명시 목록만 사용(현행 동작 = 완전 되돌리기 포인트). **기본은 보수적으로 `:manual` 유지하고, 검증 후 `:auto` 전환 권고**(§7 단계).

3. **견고성**: 발견 중 한 모듈이 raise해도 전체가 죽지 않도록 `discover_modules`·`safe_enabled?`·`safe_route_spec` 모두 rescue. 중복 id는 `Enum.uniq` + ext.verify C5(id 고유성)가 잡는다.

**Registry 변경**: `Registry.modules/0`가 `Application.get_env(:extensions)` 대신 `Discovery.all()`을 호출(모드에 따라). 카탈로그·ext.verify는 `Registry`만 보므로 하류 변경 없음.

---

## 3. 패키지 경계 — `open_mes_extension_api`

### 3.1 패키지에 들어가는 것 (계약 + 무상태 유틸만)

| 모듈 | 역할 | 현행 위치 |
|---|---|---|
| `OpenMes.Extension` | behaviour(콜백 + `known_categories/0` + `route_spec/0` 선택 콜백) | extensions/extension.ex |
| `OpenMes.Extension.Definition` | `use` 매크로(선택 콜백 nil 주입) | extensions/definition.ex |
| `OpenMes.Extension.Registry` | 메타데이터 조회(상태 없음) | extensions/registry.ex |
| `OpenMes.Extension.Discovery` | 발견(런타임 + 컴파일 타임 경로) | 신규 |
| `OpenMes.Extension.RouterMount` | `mount_extension_routes/0` 매크로 | 신규 |

- 네임스페이스를 `OpenMes.Extensions.*` → `OpenMes.Extension.*`로 정리(패키지명과 정합). 현행 모듈은 deprecate alias로 호환(§6).
- 의존: `open_mes_extension_api`는 **Phoenix Router 매크로를 호출하지 않는다** — `RouterMount`는 quote AST만 생성하고, 실제 `live/get/post`는 호스트 Router의 `use OpenMesWeb, :router` 컨텍스트에서 펼쳐진다. 따라서 패키지의 컴파일 의존은 **없음**(순수 Elixir + `Mix.Project` introspection만). Phoenix를 dep로 끌지 않아 가볍다.

### 3.2 의존 방향 (단방향 엄수)

```
외부 확장(my_mes_oee_pro) ──┐
코어 내 확장(ingest/addons)──┼──▶ open_mes_extension_api ──▶ (코어 무참조)
호스트 Router/Catalog ───────┘

코어 도메인(Production/WorkOrder/Audit/Outbox) ──▶ (extension_api 무참조)  ← 단방향 유지
```

- **코어 도메인은 `open_mes_extension_api`를 참조하지 않는다.** 참조하는 것은 Web 계층(Router, CatalogLive)과 확장 모듈뿐. CLAUDE.md "코어 도메인은 레지스트리 미참조(단방향)" 원칙 그대로.
- 확장은 데이터가 필요하면 코어의 **공개 컨텍스트 함수 또는 HTTP API**로 접근(현행 애드온과 동일). extension_api는 데이터 통로가 아니다(메타/라우팅만).

### 3.3 in-repo 분리 방식 — **path dep 권고 (umbrella 비채택)**

| 방식 | 장점 | 비용 | 평가 |
|---|---|---|---|
| **path dep** `apps/open_mes_extension_api`, 루트는 `open_mes` 그대로 | 디렉토리 1개 추가 + deps 1줄. 기존 구조 보존. Hex 배포는 그 디렉토리만 패키징 | 빌드 설정 소폭 | **권고** |
| umbrella 전환 | 다중 앱 표준 | `open_mes`를 `apps/open_mes`로 이동(대공사), config·release·CI 전면 수정. 현행 282+ 테스트·release 경로 흔들림 | 비채택(과함, pi 위반) |
| git dep | repo 분리 명확 | 개발 중 두 repo 동기 부담, in-repo 반복 빠른 수정 어려움 | 추출 후 Hex 배포 단계에서 |

**권고 절차**:
1. **1단계(in-repo path dep)**: `open_mes/`와 형제로 `open_mes_extension_api/` 디렉토리 생성. `open_mes/mix.exs`에 `{:open_mes_extension_api, path: "../open_mes_extension_api"}`. umbrella 아님 — 단순 path dep.
2. **2단계(Hex 배포)**: 계약이 안정되면 `open_mes_extension_api`만 Hex publish. 외부 확장은 `{:open_mes_extension_api, "~> 0.1"}`.

→ umbrella의 비용(앱 이동·release 재구성)은 "확장 계약 패키지 1개 분리"라는 목적에 과하다. path dep로 충분하고 되돌리기 쉽다.

---

## 4. category 개방 설계 (상세)

- 타입: `@type category :: atom()`.
- `known_categories/0`: 코어가 한국어 라벨·아이콘·필터 칩을 **제공하는** 카테고리 목록(현행 7종). 검증 게이트 아님.
- 카탈로그 렌더 규칙:
  - 카테고리 칩 = `Registry.all()`의 distinct category 합집합(동적). known 우선 정렬, 미지는 뒤에.
  - 라벨: known이면 매핑 테이블, 미지면 `atom |> to_string |> String.replace("_", " ")` 폴백.
  - 아이콘: known이면 지정, 미지면 기본 아이콘.
- ext.verify C6: atom이면 ✅, known에 없으면 정보성 라인(`ℹ️ C6 미등록 카테고리 :foo (정상 — 라벨은 폴백)`), 실패 아님.

---

## 5. ext.verify 수정 설계 (상세)

- **C7 소스경로**: `module_info(:compile)[:source]` 기반(§2.3). lib/ 추정 폐기.
- **C3 의미 재정의**: `:manual` 모드에선 현행대로 "config :extensions 등록". `:auto` 모드에선 "`Discovery.all()`에 포함"으로 판정(자동 발견되면 통과). 메시지에 모드 표기.
- **C5 id 고유성**: `Discovery.all()` 전체에 대해 빈도 1 검사(외부 확장 포함) — 외부 확장과 코어 확장 간 id 충돌 탐지. 자동 발견의 최대 위험(중복)을 여기서 잡는다.
- **신규 C8(선택, 라우트 정합)**: `route_spec/0`이 있으면 scope/pipeline/routes 형태 검증(잘못된 튜플 조기 발견). 컴파일 타임 매크로 실패를 verify에서 먼저 잡아 디버깅 난이도↓.
- **`mix ext.list`**: 발견 가시화(§2.4-1). ext.verify와 분리 task(검증≠목록).

---

## 6. 기존 7개 확장 마이그레이션 단계

원칙: **마이그레이션 후에도 7개 전부 그대로 동작.** 단계마다 `mix test` + `mix ext.verify` 그린 유지.

| # | 확장 | 현행 라우트 | 마이그레이션 작업 |
|---|---|---|---|
| 1 | EXT-1 Ingest | `/ingest` post+get | `route_spec/0` 추가: scope `/ingest`, pipeline `:require_device_token`, routes 2개 |
| 2 | EXT-2 Media | 없음(백그라운드) | `route_spec/0` 미구현(nil) → 라우트 0. 변경 없음 |
| 3 | Addon WoCsvExport | `/extensions/wo-csv-export` live+get | `route_spec/0`: live 1 + get 1 |
| 4 | Addon DefectStats | `/extensions/defect-stats` live | `route_spec/0`: live 1 |
| 5 | Addon LotQrLabel | `/extensions/lot-qr-label` live | `route_spec/0`: live 1 |
| 6 | Addon EquipmentOee | `/extensions/equipment-oee` live | `route_spec/0`: live 1 |
| 7 | Addon DailyProductionSummary | `/extensions/daily-production-summary` live | `route_spec/0`: live 1 |
| 8 | DureClaw(EXT-5) | `/extensions/dureclaw` live | `route_spec/0`: live 1. category `:integration`(known) 유지 |

공통 작업:
1. 각 Extension 모듈에 `route_spec/0` 추가(데이터 선언). `home_path/0`는 그대로 둠(라우트와 별개 — 카탈로그 링크용).
2. 네임스페이스 정리: `use OpenMes.Extensions.Definition` → `use OpenMes.Extension.Definition`(alias 호환 제공 시 무변경도 가능).
3. `enabled?/0`가 `Application.compile_env` 기반인지 확인(라우트 컴파일 타임 게이트 정합). 현행 EXT-1은 compile_env, 애드온은 `Application.get_env` → **애드온 enabled?를 compile_env로 통일**(off=라우트 흔적 없음 보장). 런타임 토글이 필요 없으므로 영향 없음.

호환 단계(점진):
- (M1) extension_api 패키지 추출 + 구 모듈 deprecate alias(`OpenMes.Extensions.Extension` → 새 모듈 위임). 컴파일 경고만, 동작 동일.
- (M2) router.ex의 if 블록 7개 → `mount_extension_routes()` 1줄 교체. 이 시점 `route_spec/0` 8개 모두 존재해야 함.
- (M3) `:manual` 모드로 자동발견 도입(현행 `:extensions` 목록 그대로 사용 = 동작 불변). 그린 확인.
- (M4) `:auto` 전환 + `mix ext.list`로 7개 발견 확인. config `:extensions` 목록은 escape hatch로 잔존(또는 제거).

---

## 7. 단계적 구현 순서 (domain-engineer 작업 분해) + 검증

> 각 단계는 독립 커밋. 단계 끝마다 `mix compile --warnings-as-errors` + `mix test`(현행 502 passed 유지) + `mix ext.verify` 그린.

**S0. 준비 — category 개방 (가장 안전, 위험 0)**
- extension.ex: `category :: atom()`, `categories/0` → `known_categories/0`.
- ext.verify C6: known 미포함을 정보성으로 격하.
- 카탈로그: 동적 카테고리 칩 + 폴백 라벨.
- 검증: `mix test`, 카탈로그 화면에 7개 그대로 노출. DureClaw `:integration` 여전히 표시.

**S1. extension_api 패키지 추출 (path dep)**
- `open_mes_extension_api/` 디렉토리 생성, mix.exs(Phoenix 미의존), 모듈 4개 이동(`OpenMes.Extension.*`).
- `open_mes/mix.exs`에 path dep 추가. 구 `OpenMes.Extensions.*`는 위임 alias로 호환.
- 검증: `mix deps.compile`, `mix test`, `mix ext.verify` 그린. **코어 도메인이 패키지 미참조** grep 확인(`grep -r "OpenMes.Extension" lib/open_mes/{production,work_order,audit,outbox}` → 0건).

**S2. ext.verify C7 소스경로 수정**
- `addon_source_files/1` → `module_info(:compile)[:source]` 기반.
- 검증: in-tree 7개 C7 그대로 통과. (가능하면) 더미 deps 확장으로 외부경로 스캔 확인.

**S3. route_spec/0 도입 + RouterMount 매크로 (라우트는 아직 if 블록 병존 금지 — 한 번에 교체)**
- 8개 Extension에 `route_spec/0` 추가.
- `OpenMes.Extension.RouterMount.mount_extension_routes/0` 구현(route_specs 컴파일 타임 순회).
- `Discovery.route_specs/0` 구현(이 단계는 아직 명시 목록 기반: `Registry.modules()` 사용 → 발견 미도입).
- router.ex if 블록 7개 → 매크로 1줄 교체.
- 검증: `mix phx.routes`로 라우트 테이블이 **교체 전후 동일**함을 diff. `mix test`(컨트롤러/LiveView 테스트가 라우트 깨짐 잡음). off 확장(daily_summary, ingest)은 라우트 미존재 확인.

**S4. 자동 발견 — :manual 기본 도입**
- `Discovery.all/0`(런타임 발견) + override/exclude/mode config.
- `Registry.modules/0` → 모드 분기(`:manual`=현행 목록, `:auto`=발견).
- 기본 `:manual` → 동작 불변.
- 검증: `:manual`에서 7개 그대로. `mix ext.list` 출력 확인.

**S5. :auto 전환 + 컴파일 타임 정합 안전판**
- `RouterMount`에 `ensure_apps_loaded`(deps_apps load) 추가.
- `Discovery.route_specs/0`를 `Discovery.all()` 기반으로 전환(`Mix.Project.deps_apps` + 호스트 모듈 스캔).
- config 기본 `:auto`.
- 검증: `mix ext.list`로 7개 발견(출처 app=open_mes). `mix phx.routes` diff 0. 더미 외부 확장(path dep) 추가 시 deps 1줄만으로 라우트·카탈로그 노출 확인 → **목표 상태 §1 증명**.

**S6. 마이그레이션 마감**
- 구 `OpenMes.Extensions.*` alias 제거(또는 1버전 유지 후 제거).
- 문서: docs/extension-development.md에 "외부 repo 확장 추가 가이드"(§1 절차) 반영. CLAUDE.md 변경 이력 1줄.

---

## 8. 리스크 / 되돌리기 포인트

| 리스크 | 영향 | 완화 / 되돌리기 |
|---|---|---|
| 컴파일 타임 앱 미로드로 발견 누락 → 라우트 빠짐 | 외부 확장 화면 404 | `ensure_apps_loaded`(deps_apps load) 안전판. `mix ext.list`로 사전 확인. 되돌리기: `:manual` 모드 |
| 자동 발견 명시성↓·디버깅↑ (pi 역행) | 운영 혼란 | `mix ext.list` 가시화 + escape hatch + 기본 `:manual` 단계 도입. 완전 되돌리기: config `:extension_discovery, :manual` |
| 외부↔코어 id 충돌(자동발견 부작용) | 라우트/카탈로그 중복 | ext.verify C5가 `Discovery.all()` 전체 빈도 검사. uniq |
| route_spec 오타 → 컴파일 타임 매크로 raise | 빌드 실패 | ext.verify C8(route_spec 형태 검증)로 조기 탐지 |
| umbrella 유혹(과설계) | 대공사·되돌리기 어려움 | path dep 채택(§3.3). umbrella 비채택 |
| enabled? 런타임 env → 컴파일 타임 false | 라우트 누락 | 계약 명시(라우트 기여 확장 enabled?는 compile_env). 애드온 통일(M3) |
| extension_api가 Phoenix 끌어옴 | 패키지 비대 | RouterMount는 AST만 생성, live/get은 호스트 컨텍스트에서 펼침 → Phoenix 미의존 유지 |

**가장 안전한 중단점**: S0~S2(category·패키지·verify)는 라우트를 안 건드려 독립적으로 가치 있고 되돌리기 쉽다. S3(라우트 매크로)부터가 진짜 변경이며, S4 이후 자동발견은 언제든 `:manual`로 되돌릴 수 있다.

---

## 9. domain-engineer 전달 지침 (핵심 요약)

1. **순서 엄수**: S0→S6. S3는 "if 블록 ↔ 매크로 병존" 금지(라우트 중복) — 한 커밋에 교체하고 `mix phx.routes` diff로 검증.
2. **단방향 의존 grep 게이트**: 매 단계 `grep -rn "OpenMes.Extension" open_mes/lib/open_mes/{production,work_order,audit,outbox}` 0건 유지.
3. **pi**: `route_spec/0`는 순수 데이터(맵+튜플). 외부 확장이 Router 모듈을 만들게 하지 마라. 단일 호출 헬퍼는 인라인.
4. **계약 안정성**: `OpenMes.Extension`의 콜백 시그니처는 외부 확장의 ABI다. `route_spec/0`는 **선택 콜백**(Definition이 nil 주입)으로 추가 — 기존 확장 강제 변경 없음.
5. 라우트 컴파일 타임 게이트 정합: 라우트 기여 확장의 `enabled?`는 `Application.compile_env` 기반이어야 함(애드온 통일).
6. 모든 발견/콜백 호출은 rescue 방어(현행 `safe_enabled?` 수준 유지·확장).
