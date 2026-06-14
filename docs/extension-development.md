---
type: 개발가이드
---

# 확장 개발 가이드 (Extension Development Guide)

Open MES Korea는 **최소 코어 + 확장 모듈** 구조다. 회사의 현장 요구(특정 설비, 특정 리포트,
특정 라벨, 특정 외부 도구 연동)는 코어를 건드리지 않고 **확장(Extension)** 으로 직접 만들 수 있다.

이 문서는 "우리 회사에 맞는 확장을 직접 만든다"를 위한 실전 가이드다. 사람과 **LLM 코딩
에이전트** 모두가 이 문서만 읽고 확장을 자기완결로 추가할 수 있도록 명령형·정확·복붙 가능하게 썼다.

---

## 0. LLM 개발자에게 (먼저 읽을 것)

당신은 **읽기 전용 애드온**을 추가한다. 다음 불변 규칙을 위반하지 마라:

- **[코어 비침투]** `lib/open_mes/`, `lib/open_mes_web/`(addons 제외), `config/` 의 **기존 줄을
  수정하지 마라.** 새 코드는 오직 `lib/open_mes_addons/{name}/` 아래에만 만든다.
  (예외: `config/config.exs` 의 `:extensions` 리스트에 "한 줄 추가"와 enabled 게이트 "한 줄 추가"만 허용)
- **[읽기 전용 우선]** 코어 데이터는 컨텍스트 공개 함수(`OpenMes.Production.list_work_orders/1` 등)로
  **읽기만** 한다. DB 쓰기 / 마이그레이션 / 새 테이블 **금지**. (쓰기가 꼭 필요하면 멈추고 §6 절차 + qa-auditor 검토)
- **[AI 경계]** AI 호출 확장이면 **직접 쓰기 금지** — `propose_*` 후보 제안 + 근거 표시 + 사람 승인만.
- **[pi]** 과설계 금지. GenServer / 매크로 / 동적 모듈 발견 도입 금지. **함수 + behaviour 구현만.**

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
  확장을 참조하지 않는다. 의존 방향은 단방향이다 — 확장 → 코어(읽기), 확장 → Registry.
  코어를 수정하지 않으므로 코어 업그레이드와 충돌하지 않는다.
- **config on/off**: 확장은 `config :open_mes, :extensions` 명시 목록으로 등록되고,
  각자 `enabled?/0` 게이트로 켜고 끈다. 끄면 카탈로그에 '비활성' 배지로만 남는다.
- **카탈로그 자동 노출**: `Extension` behaviour만 구현하면 `/extensions` 카탈로그에
  카드가 **자동으로** 뜬다. 카탈로그/메뉴 코드를 따로 수정할 필요가 없다.

> 레지스트리는 "설치 시스템"이 아니다. 동적 모듈 스캔/DB/GenServer 없이 config 목록 +
> behaviour 콜백 호출만으로 동작하는 순수 조회 계층이다 (pi 원칙).

---

## 2. Extension behaviour 계약

확장 메타데이터는 `OpenMes.Extensions.Extension` behaviour로 계약된다. 이 behaviour는
**메타데이터 노출만** 약속한다. 확장의 실제 동작(파이프라인/연산/화면)은 확장 내부 책임이다.

### 필수 콜백 6개

| 콜백 | 타입 | 설명 |
|------|------|------|
| `id/0` | `atom()` | 확장 고유 식별자(영문 atom, 안정적). 예: `:addon_wo_csv_export` |
| `name/0` | `String.t()` | 사람이 읽는 이름(한국어). 예: `"작업지시 CSV 내보내기"` |
| `description/0` | `String.t()` | 한 줄 설명(한국어) |
| `category/0` | `category()` | 분류 atom (카탈로그 필터에 사용) |
| `version/0` | `String.t()` | 버전 문자열. 예: `"0.1.0"` |
| `enabled?/0` | `boolean()` | 활성 여부(config 게이트) |

### 선택 콜백 2개 (`Definition`이 기본값 `nil` 주입)

| 콜백 | 타입 | 설명 |
|------|------|------|
| `home_path/0` | `String.t() \| nil` | 자체 화면 경로. 화면이 있으면 override. 없으면 `nil` |
| `icon/0` | `String.t() \| nil` | 카탈로그 카드 아이콘. 없으면 `nil`(기본 아이콘) |

카탈로그는 `home_path != nil` 이고 `enabled? == true` 일 때만 카드에 "열기" 링크를 노출한다.

### 카테고리(`category/0`) 값

`:ingest`(설비수집) · `:media`(멀티미디어) · `:production`(생산) · `:quality`(품질) ·
`:traceability`(추적) · `:analytics`(분석)

새 분류가 필요하면 `Extension.categories/0` 함수(검증·카탈로그·가이드 단일 출처)에 한 줄 추가한다.
`mix ext.verify` 의 C6(category 유효성)은 이 함수를 기준으로 판정한다.

---

## 2.5 6단계 개발 절차 (LLM은 위→아래 그대로 실행)

각 단계의 **정확한 산출물 경로**를 지킨다. 네이밍 규약(아래)을 위반하면 `mix ext.verify` 가 잡는다.

| 단계 | 행동 | 정확한 산출물 경로 |
|---|---|---|
| 1 | 디렉토리 생성 | `lib/open_mes_addons/{name}/` (snake_case) |
| 2 | 퍼사드 + 게이트 작성 | `lib/open_mes_addons/{name}.ex` |
| 3 | 로직 모듈(읽기/직렬화) 작성 | `lib/open_mes_addons/{name}/{logic}.ex` |
| 4 | (화면 있으면) LiveView 작성 | `lib/open_mes_addons/{name}/live/{name}_live.ex` |
| 5 | `extension.ex`(behaviour 구현) 작성 | `lib/open_mes_addons/{name}/extension.ex` |
| 6 | config 등록(2줄) + (화면 시) 라우트 | `config/config.exs`, `lib/open_mes_web/router.ex` |
| 7 | 검증 | `mix ext.verify` → `mix compile --warnings-as-errors` → `mix test` |

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

**(D) 등록 2줄 — `config/config.exs`** (기존 줄 수정 금지, 리스트에 추가만)
```elixir
config :open_mes, :extensions, [
  # ... 기존 항목 유지 ...
  OpenMes.Addons.MyReport.Extension   # ← 추가(1줄)
]

config :open_mes, OpenMes.Addons.MyReport, enabled: true   # ← 추가(1줄)
```

**(E) 라우트 (화면 있을 때만) — `lib/open_mes_web/router.ex`** (기존 패턴 그대로 복제)
```elixir
if OpenMes.Addons.MyReport.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/my-report", MyReportLive, :index
  end
end
```

---

## 3. 최소 확장 만들기

`use OpenMes.Extensions.Definition` 한 줄로 선택 콜백 기본값(nil)이 주입되므로,
**필수 6개만** 구현하면 카탈로그에 뜨는 최소 확장이 완성된다.

```elixir
defmodule OpenMes.Addons.MyReport.Extension do
  @moduledoc "우리 회사 맞춤 리포트 확장(메타데이터)."
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

  # 자체 화면이 있으면 home_path 를 override (없으면 이 줄을 생략하면 nil).
  @impl true
  def home_path, do: "/extensions/my-report"
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

## 4. 등록 (config :open_mes, :extensions)

레지스트리는 동적 발견이 아니라 **config 명시 목록**을 읽는다. 만든 확장의
`Extension` 모듈을 목록에 한 줄 추가하면 끝이다.

```elixir
# config/config.exs (또는 환경별 config)
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  OpenMes.Addons.WoCsvExport.Extension,
  # ... 기존 확장들 ...
  OpenMes.Addons.MyReport.Extension   # ← 우리 확장 추가
]

# 활성화 게이트
config :open_mes, OpenMes.Addons.MyReport, enabled: true
```

추가 후 서버를 재시작하면 `/extensions` 카탈로그에 카드가 자동으로 나타난다.
끄고 싶으면 `enabled: false` 로 바꾸면 '비활성' 배지로 남고 화면/연산은 등록되지 않는다.

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
- **레지스트리** — `OpenMes.Extensions.Registry.all/0` · `enabled/0` · `by_category/0`.

---

## 6. 데이터 접근 원칙

확장의 데이터 취급은 안전 경계를 지켜야 한다.

- **읽기 위주**: 대부분의 애드온은 코어 데이터를 **읽기만** 한다(새 테이블 0, 쓰기 0).
  기존 7개 확장이 모두 이 패턴이다.
- **쓰기는 컨텍스트 경유 + AuditLog**: 도메인 트랜잭션을 쓰는 확장은 코어 테이블을 직접
  건드리지 않고 **컨텍스트 함수를 경유**한다. 모든 쓰기는 AuditLog를 남기고, 상태 변경은
  동일 트랜잭션 안에서 Outbox 이벤트를 삽입한다. 자재 소비는 LotConsumption을 경유한다.
- **AI는 propose → 승인**: AI 연동 확장은 직접 쓰기를 하지 않는다. `propose_*`로 후보를
  제안하고, 근거를 표시하며, 사람이 승인할 때만 컨텍스트 경유로 반영한다. 모든 AI 상호작용은
  AiInteraction으로 기록한다. (자세히는 `docs/ai-native-architecture.md`)

### 명령형 체크리스트 (LLM 강제)

- **금지**: 코어 파일 수정 · 새 DB 테이블/마이그레이션 · GenServer/동적 모듈 스캔 · AI 직접 쓰기
- **필수**: `lib/open_mes_addons/` 격리 · 컨텍스트 공개 함수 경유 읽기 · `use OpenMes.Extensions.Definition` ·
  config 2줄 등록 · `mix ext.verify` 통과
- **쓰기가 불가피하면(드묾)**: 컨텍스트 함수 경유 + AuditLog + 동일 트랜잭션 Outbox + (자재) LotConsumption.
  이 경우 **LLM은 자동 진행을 멈추고 qa-auditor `audit-verify` 검토를 요청**한다.
  `mix ext.verify` 의 C7(코어 비침투)은 grep 휴리스틱이라 **명백한 Repo 직접 쓰기만** 잡는다 —
  매크로 우회 등은 못 잡으므로, **도메인 쓰기 확장은 C7 통과해도 audit-verify 가 필수**다(정직 표기).

---

## 7. 레퍼런스 — 기존 확장 7개

처음 만들 때는 가장 가까운 기존 확장을 복사해서 시작하는 것이 빠르다.

| 확장 | 카테고리 | 패턴 | 위치 |
|------|---------|------|------|
| 설비 데이터 수집(EXT-1) | ingest | HTTP push → Broadway → 시계열 | `lib/open_mes/ingest/` |
| 멀티미디어 수집(EXT-2) | media | NAS watch → object storage | `lib/open_mes/media/` |
| 작업지시 CSV 내보내기 | production | 읽기 → CSV export | `lib/open_mes_addons/wo_csv_export/` |
| 불량 통계 위젯 | quality | 읽기 → 집계 + 차트 | `lib/open_mes_addons/defect_stats/` |
| LOT QR 라벨 생성 | traceability | 읽기 → QR 라벨 | `lib/open_mes_addons/lot_qr_label/` |
| 설비 가동률 OEE | analytics | 읽기 → OEE 계산 | `lib/open_mes_addons/equipment_oee/` |
| 일일 생산 요약 | production | 읽기 → 요약 리포트 | `lib/open_mes_addons/daily_summary/` |

가장 단순한 시작점은 **작업지시 CSV 내보내기**(`wo_csv_export`)다 — 읽기 전용, 새 테이블 0,
`Extension` behaviour 구현 + 화면 + 컨텍스트 읽기의 전형이다.

확장 생태계 전체 로드맵(EXT-3~12, 연동 허브, 업종 플러그인)은 `docs/extension-roadmap.md`를 참고한다.

---

## 8. 자동 검증 — `mix ext.verify`

확장을 만든 뒤 **사람/LLM 모두 파싱 가능한** 정적 검증을 돌린다. introspection + grep만 사용하며
(외부 deps·dialyzer·서버/Repo 기동 0), 컴파일만 보장한다.

```bash
mix ext.verify OpenMes.Addons.MyReport.Extension   # 단일 확장
mix ext.verify                                       # :extensions 전체 스캔
```

**체크 7종:**

| # | 검사 | 방법 |
|---|---|---|
| C1 | 필수 6 콜백 구현 | behaviour introspection 으로 유도(하드코딩 0) |
| C2 | behaviour 채택 | `@behaviour OpenMes.Extensions.Extension` |
| C3 | config :extensions 등록 | `Registry.modules()` 포함 |
| C4 | 카탈로그 노출 가능 | `Registry.all()` 에서 raise 없이 엔트리화 |
| C5 | id 고유성 | 등록 확장 간 id 중복 0 + atom |
| C6 | category 유효성 | `Extension.categories()` 기준 |
| C7 | 코어 비침투(휴리스틱) | 확장 소스의 명백한 Repo 직접 쓰기 grep |

**샘플 리포트 (LLM 파싱 친화):**

```
ext.verify: OpenMes.Addons.MyReport.Extension
  ✅ C1 필수 콜백 6개 구현
  ✅ C2 Extension behaviour 채택
  ❌ C3 config :extensions 미등록
      → config :open_mes, :extensions 리스트에 모듈 한 줄 추가 (가이드 §2.6 D)
  ✅ C4 카탈로그 노출 가능
  ✅ C5 id 고유 (:addon_my_report)
  ✅ C6 category 유효 (:analytics)
  ✅ C7 코어 비침투 (직접 쓰기 0건)

결과: 6/7 통과 ❌  (종료코드 1)
다음: 위 → 안내대로 수정 후 재실행
```

실패 항목마다 `→ 수정 안내` 한 줄이 붙는다. 종료코드: **전체 통과 0 / 위반 1.**
C7 한계: 매크로 우회 등은 못 잡으므로 **도메인 쓰기 확장은 qa-auditor `audit-verify` 가 필수**다(§6).

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
