# 09. Architect 설계: 확장 레지스트리 + 홈페이지 확장 카탈로그 + MES 도메인 애드온 5개 + Phoenix 앱 통합

- **작성자**: architect
- **작성일**: 2026-06-13
- **대상**:
  1. 확장 레지스트리 메커니즘 (모든 확장이 공통으로 따르는 `Extension` behaviour 계약)
  2. 작고 독립적인 MES 도메인 애드온 5개 (코어 데이터 읽기 위주)
  3. 홈페이지 확장 카탈로그 (Phoenix LiveView)
  4. 지금까지의 `_workspace` 코드를 실제 Phoenix 앱으로 통합하는 전략
- **기술 스택 (확정)**: Phoenix (Elixir) + Ecto + PostgreSQL + **Phoenix LiveView**
- **참고 문서**: CLAUDE.md, docs/extension-roadmap.md, docs/domain-model.md, docs/mvp-scope.md, `_workspace/01_architect_workorder_design.md`, `_workspace/04_architect_ingest_design.md`(EXT-1), `_workspace/05_architect_media_ingest_design.md`(EXT-2)
- **수신자**: domain-engineer (구현, 병렬 분배 §7), qa-auditor (검토)

---

## 0. 설계 원칙 요약 (이 설계가 지켜야 하는 불변 규칙)

이 설계는 **새 도메인 트랜잭션을 거의 만들지 않는다**(애드온은 읽기 위주). 그래서 핵심 제약은 "코어 비침투 + 단순 등록 + 작은 애드온"이다.

### A. pi 최소 — 레지스트리는 "등록된 확장을 목록으로 보여준다"까지만

1. **마켓플레이스/설치 시스템 금지**: 동적 설치, 플러그인 다운로드, 버전 호환성 매트릭스, 의존성 해석기 같은 구조를 **만들지 않는다**(YAGNI). 지금 필요한 것은 (a) 확장이 자기 메타데이터를 노출하고, (b) 카탈로그가 그 목록을 읽어 카드로 그리는 것뿐.
2. **레지스트리는 얇은 코어 유틸**: §1.4 결정 — 확장들이 의존하는 공통 계약이므로 코어에 둔다. 단 **코어 도메인이 레지스트리에 의존하지 않는다**(의존 방향: 확장 → 레지스트리 ← 카탈로그. 코어 Production/WorkOrder는 레지스트리를 모른다).
3. **새 DB 테이블 0개**: 레지스트리는 컴파일 타임 정적 목록 + 런타임 config 게이트. 등록 상태를 DB에 저장하지 않는다(설치 시스템이 아니므로 영속 상태 불필요).

### B. 코어 비침투 (EXT-1/EXT-2 승계)

4. **별도 네임스페이스 격리**: 애드온은 `lib/open_mes_addons/{addon}/`. 레지스트리/카탈로그는 코어 `lib/open_mes/extensions/`(얇은 유틸) + `lib/open_mes_web/live/`(웹 화면).
5. **config on/off**: 각 확장은 `enabled?/0`로 게이트된다. 꺼지면 카탈로그에서 "disabled" 배지로만 보이고, 라우트/연산은 등록되지 않는다.
6. **코어 데이터는 읽기**: 애드온은 코어 컨텍스트의 **공개 조회 함수**(`OpenMes.Production.list_work_orders/1` 등)와 Ecto **읽기 쿼리**만 사용한다. 코어 스키마를 직접 수정하지 않는다.
7. **쓰기 시 AuditLog 경유**: 애드온 5개 중 4개는 **읽기 전용**(쓰기 0 → AuditLog 무관). 단 하나(③ LOT QR 라벨)가 LOT에 라벨 발행 이력을 남길 수 있는데, 이 역시 **MVP는 발행 이벤트만 기록하거나 읽기 전용으로 시작**하고, 코어 LOT 상태를 바꾸지 않는다(§2.3). 코어 도메인 데이터를 변경해야 하는 애드온은 이번 범위에 두지 않는다.

### C. 기존 컨벤션 승계

8. OTP 앱 이름 `open_mes`, 코어 컨텍스트 `OpenMes`, 웹 `OpenMesWeb`. 애드온은 `OpenMes.Addons.{Addon}`.
9. PK `binary_id`(코어 컨벤션). 단 애드온이 새 테이블을 거의 안 만들므로 대부분 무관.
10. 한국어 우선(주석/에러/UI 텍스트), 영문 식별자. MVP 최소만, 확장 경로는 남긴다.
11. EXT-1/EXT-2와 동일한 "config 게이트 + behaviour 계약 + 코어 단방향 의존" 패턴을 확장 5개도 그대로 따른다 — **카탈로그에 EXT-1/EXT-2/애드온 5개가 모두 동일 인터페이스로 노출**된다.

---

## 1. 확장 레지스트리 메커니즘 (핵심)

### 1.1 `Extension` behaviour 계약

모든 확장(EXT-1, EXT-2, 애드온 5개)이 구현하는 단일 behaviour. 위치: `lib/open_mes/extensions/extension.ex`.

```elixir
defmodule OpenMes.Extensions.Extension do
  @moduledoc """
  확장 모듈 공통 계약.

  EXT-1(설비수집), EXT-2(멀티미디어), 도메인 애드온 5개가 모두 이 behaviour 를 구현한다.
  레지스트리(§1.2)는 이 콜백들을 통해 각 확장의 메타데이터를 수집하고,
  홈페이지 카탈로그(§3)는 그 목록을 카드로 렌더한다.

  핵심: 이 behaviour 는 "메타데이터 노출"만 계약한다. 확장의 실제 동작(파이프라인/연산/화면)은
  각 확장 내부의 책임이며, 레지스트리는 동작을 알 필요가 없다(설치 시스템 아님 — pi).
  """

  @type category :: :ingest | :media | :production | :quality | :traceability | :analytics

  @doc "확장 고유 식별자(영문, 안정적). 예: :ext_ingest, :addon_wo_csv_export"
  @callback id() :: atom()

  @doc "사람이 읽는 이름(한국어). 예: \"설비 데이터 수집\""
  @callback name() :: String.t()

  @doc "한 줄 설명(한국어)."
  @callback description() :: String.t()

  @doc "분류. 카탈로그 필터에 사용."
  @callback category() :: category()

  @doc "버전 문자열. 예: \"0.1.0\""
  @callback version() :: String.t()

  @doc """
  활성화 여부. config 게이트.
  꺼져 있으면 카탈로그에 'disabled' 배지로 표시되고 라우트/연산은 등록되지 않는다.
  """
  @callback enabled?() :: boolean()

  @doc """
  (선택) 확장이 자체 화면을 가지면 홈페이지 내 경로를 반환. 없으면 nil.
  예: \"/extensions/wo-csv-export\" | \"/ingest/health\"
  """
  @callback home_path() :: String.t() | nil

  @doc "(선택) 카탈로그 카드 아이콘(heroicon 이름 등). 없으면 nil → 기본 아이콘."
  @callback icon() :: String.t() | nil

  # home_path / icon 은 선택 콜백 — 기본 구현 제공.
  @optional_callbacks [home_path: 0, icon: 0]
end
```

> **메타데이터 항목**: `id`(영문 식별자), `name`(한국어), `description`(한국어), `category`, `version`, `enabled?/0`(config 게이트), `home_path/0`(선택 홈페이지 경로), `icon/0`(선택 아이콘). 요구된 항목을 모두 포함한다.

**구현 보일러플레이트 최소화** — 각 확장 모듈 상단에 `use`로 기본값을 주입:

```elixir
defmodule OpenMes.Extensions.Definition do
  @moduledoc "Extension behaviour 의 선택 콜백 기본 구현을 주입하는 use 매크로."
  defmacro __using__(_opts) do
    quote do
      @behaviour OpenMes.Extensions.Extension
      @impl true
      def home_path, do: nil
      @impl true
      def icon, do: nil
      defoverridable home_path: 0, icon: 0
    end
  end
end
```

이렇게 하면 각 확장은 `use OpenMes.Extensions.Definition` 후 필수 5개(id/name/description/category/version) + `enabled?/0`만 구현하면 된다. 화면 있는 확장만 `home_path/0`를 override.

### 1.2 레지스트리 발견·등록 방식 — **config 명시 목록 (Application env) 채택**

> **결정 — 컴파일 타임 모듈 attribute 스캔도, 동적 발견도 아닌, `config.exs`의 명시 목록을 채택한다.**

세 후보 비교:

| 방식 | 동작 | pi 적합성 |
|------|------|----------|
| (A) **모듈 attribute 스캔**(`:application.get_key(:modules)` 순회 후 behaviour 구현 모듈 필터) | 런타임에 전 모듈을 훑어 `Extension`을 구현한 모듈을 자동 수집 | ❌ 마법적. 디버깅 어렵고, 컴파일된 모든 모듈을 순회하는 비용. "자동 발견"은 설치 시스템 냄새. |
| (B) **config 명시 목록** | `config :open_mes, :extensions, [모듈 리스트]`에 확장 모듈을 나열. 레지스트리는 이 리스트를 읽음. | ✅ **가장 단순·명시적**. 무엇이 등록되는지 한눈에. 추가는 리스트에 한 줄. |
| (C) **Application env + 동적 등록 API**(`Registry.register/1` 런타임 호출) | 부팅 시 각 확장이 자기를 등록 | ❌ 등록 순서/타이밍 의존, 상태 보유. 과설계. |

**(B) 채택 근거 (pi)**:
- 확장은 지금 7개(EXT-1, EXT-2, 애드온 5개)로 **유한하고 알려져 있다**. 자동 발견의 이득이 없다.
- 명시 목록은 "이 시스템에 어떤 확장이 있는가?"를 `config.exs` 한 곳에서 즉시 답한다.
- 새 확장 추가 = 모듈 작성 + config 리스트에 한 줄. 마법 없음.
- 각 확장의 on/off는 리스트 포함 여부가 아니라 **각 확장의 `enabled?/0`(자체 config)**가 결정한다. 즉 리스트에는 항상 다 넣고(카탈로그에 disabled로라도 보이게), 켜고 끄는 건 `enabled?`가 한다. → "등록 ≠ 활성". 카탈로그가 disabled 확장도 보여줘야 하므로 이 분리가 필요하다.

```elixir
# config/config.exs — 확장 명시 목록 (등록 = 카탈로그에 노출 대상)
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,                      # EXT-1
  OpenMes.Media.Extension,                       # EXT-2
  OpenMes.Addons.WoCsvExport.Extension,          # 애드온 ①
  OpenMes.Addons.DefectStats.Extension,          # 애드온 ②
  OpenMes.Addons.LotQrLabel.Extension,           # 애드온 ③
  OpenMes.Addons.EquipmentOee.Extension,         # 애드온 ④
  OpenMes.Addons.DailyProductionSummary.Extension # 애드온 ⑤
]
```

> **EXT-1/EXT-2 영향**: EXT-1/EXT-2는 현재 behaviour 메타데이터 모듈이 없다. 통합 시 각자 `OpenMes.Ingest.Extension` / `OpenMes.Media.Extension`(얇은 메타데이터 모듈)을 **추가**한다(기존 파이프라인 코드는 무변경, §4.4 매핑 참조). `enabled?/0`는 각자 이미 가진 `OpenMes.Ingest.enabled?()` / `OpenMes.Media.enabled?()`에 위임한다.

### 1.3 레지스트리 조회 API

위치: `lib/open_mes/extensions/registry.ex`. **상태 없는 순수 조회 모듈**(GenServer 아님 — 영속 상태 불필요, pi).

```elixir
defmodule OpenMes.Extensions.Registry do
  @moduledoc """
  확장 레지스트리 — config 명시 목록(:extensions)을 읽어 각 확장의 메타데이터를 제공.

  상태를 보유하지 않는다(GenServer/ETS 불필요). config 조회 + 각 모듈 콜백 호출뿐.
  카탈로그(LiveView)와 라우터가 유일한 소비자.
  """

  alias OpenMes.Extensions.Extension

  @type entry :: %{
          id: atom(),
          name: String.t(),
          description: String.t(),
          category: Extension.category(),
          version: String.t(),
          enabled: boolean(),
          home_path: String.t() | nil,
          icon: String.t() | nil,
          module: module()
        }

  @doc "config 에 등록된 모든 확장 모듈."
  def modules, do: Application.get_env(:open_mes, :extensions, [])

  @doc "등록된 모든 확장의 메타데이터 엔트리. (enabled 여부 무관 — 카탈로그가 disabled 도 표시)"
  @spec all() :: [entry()]
  def all do
    modules()
    |> Enum.map(&to_entry/1)
    |> Enum.sort_by(&{&1.category, &1.name})
  end

  @doc "enabled? == true 인 확장만."
  @spec enabled() :: [entry()]
  def enabled, do: Enum.filter(all(), & &1.enabled)

  @doc "카테고리별 그룹."
  def by_category, do: Enum.group_by(all(), & &1.category)

  defp to_entry(mod) do
    %{
      id: mod.id(),
      name: mod.name(),
      description: mod.description(),
      category: mod.category(),
      version: mod.version(),
      enabled: safe_enabled?(mod),
      home_path: maybe(mod, :home_path),
      icon: maybe(mod, :icon),
      module: mod
    }
  end

  # enabled? 가 config 미설정 등으로 raise 해도 카탈로그 전체가 깨지지 않도록 방어.
  defp safe_enabled?(mod) do
    mod.enabled?()
  rescue
    _ -> false
  end

  defp maybe(mod, fun) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: nil
  end
end
```

- 홈페이지가 "등록되고 enabled된 확장 목록"을 조회하는 API = `Registry.enabled/0`.
- 카탈로그가 "등록된 전체(disabled 포함)"를 보려면 `Registry.all/0` 또는 `Registry.by_category/0`.

### 1.4 레지스트리는 코어인가 별도인가? — **얇은 코어 유틸로 둔다**

> **결정 — 레지스트리/behaviour 는 코어(`lib/open_mes/extensions/`)에 둔다.**

근거:
- 모든 확장(EXT-1/2 + 애드온 5개)이 `Extension` behaviour에 **의존**한다. behaviour를 어느 한 확장에 두면 다른 확장이 그 확장에 의존하는 잘못된 방향이 생긴다. 공통 계약은 **공통(코어)**에 있어야 한다.
- 단 이것은 **얇은 유틸**이다: behaviour 정의 + config 리스트 조회 + 콜백 호출뿐. 도메인 로직 0, DB 0, 상태 0.
- **의존 방향 불변식**: 코어 도메인(`OpenMes.Production`, `WorkOrder`, `Audit`, `Outbox`)은 `OpenMes.Extensions.*`를 **참조하지 않는다**. 레지스트리는 "확장들이 코어 쪽에 두는 공통 계약 선반"이지 코어 도메인의 일부가 아니다. 의존 그래프:

```text
  코어 도메인(Production/WorkOrder/Audit/Outbox)   ← 애드온/카탈로그가 읽음
        ▲                          ▲
        │ (읽기 호출)               │
  애드온 5개 ──구현──▶ OpenMes.Extensions.Extension(behaviour, 얇은 코어 유틸)
  EXT-1/EXT-2 ─구현─▶        ▲
                              │ (조회)
  카탈로그 LiveView ──────────┘
```

- 코어 도메인은 레지스트리를 몰라도 완전히 동작한다(레지스트리/카탈로그를 전부 들어내도 WorkOrder API는 그대로). 이로써 "코어는 확장 없이 동작한다"(CLAUDE.md L37-39) 원칙 유지.

---

## 2. MES 도메인 애드온 5개 선정 + 명세

추천 5개를 검토한 결과 **모두 적합**하다(작고, 코어 데이터 읽기 위주, 독립적). 그대로 채택하되 각 규모를 "작게" 못 박는다. 공통 규칙:

- 네임스페이스: `lib/open_mes_addons/{addon}/`, 컨텍스트 `OpenMes.Addons.{Addon}`.
- 각 애드온은 `Extension` behaviour 구현 모듈 `OpenMes.Addons.{Addon}.Extension` 1개 필수.
- config on/off: `config :open_mes, OpenMes.Addons.{Addon}, enabled: false`(기본). `enabled?/0`가 읽는다.
- 코어 데이터는 **읽기**: 가능하면 코어 컨텍스트 공개 조회 함수 사용, 없으면 읽기 전용 Ecto 쿼리.
- **새 DB 테이블 0개 목표**. 부득이한 경우만 §2.3에서 명시.

> **결정 — 코어에 조회 함수가 부족하면 추가하지 않고 애드온에서 읽기 쿼리를 짠다.** 코어를 건드리지 않는 게 우선(비침투). 단 애드온이 코어 스키마 모듈(`OpenMes.Production.WorkOrder` 등)을 alias해 **읽기 쿼리에 사용하는 것은 허용**(읽기는 침투가 아님). 쓰기/스키마 변경만 금지.

### 애드온 ① 작업지시 CSV 내보내기 (WoCsvExport)

| 항목 | 내용 |
|------|------|
| **목적** | 작업지시 목록을 CSV로 다운로드(현장 보고/엑셀 분석용) |
| **입력 코어 엔티티** | `WorkOrder` (+ 선택적으로 `Item` 조인하여 품목명) — **읽기** |
| **읽기 경로** | `OpenMes.Production.list_work_orders/1`(이미 존재, filters 지원) 재사용 |
| **출력** | `text/csv` 스트리밍 다운로드. 컬럼: 작업지시번호, 품목, 계획수량, 납기일, 상태, 생성일 |
| **화면 유무** | 있음(작게). LiveView 폼 1개: status/기간 필터 → "CSV 다운로드" 버튼 → 컨트롤러가 CSV 스트리밍 |
| **쓰기/AuditLog** | 없음(읽기 전용). 단순 export는 감사 대상 아님 |
| **구현 규모** | 매우 작음. Extension 모듈 + CSV 직렬화 함수(NimbleCSV 또는 수동 인코딩) + LiveView 1 + 다운로드 컨트롤러 액션 1. ~3 파일 |
| **새 테이블** | 0 |

> NimbleCSV 의존성은 선택. CSV 이스케이프는 단순하므로 deps 없이 수동 인코딩도 가능(pi). domain-engineer 판단(권장: 의존성 0).

### 애드온 ② 불량 통계 위젯 (DefectStats)

| 항목 | 내용 |
|------|------|
| **목적** | 불량 유형별/기간별 집계 대시보드 위젯 |
| **입력 코어 엔티티** | `DefectRecord`(defect_code, quantity), `ProductionResult`(good/defect_quantity) — **읽기** |
| **읽기 경로** | 읽기 전용 Ecto 집계 쿼리(`group_by defect_code`, `sum(quantity)`). 코어에 집계 함수 없으므로 애드온 내 쿼리 모듈 |
| **출력** | 화면 위젯: 불량 유형별 막대(상위 N), 기간 불량률(defect/(good+defect)). 숫자+간단 바 |
| **화면 유무** | 있음. LiveView 1개(기간 선택 → 집계 갱신). 차트는 CSS 바(외부 차트 라이브러리 도입 안 함 — pi) |
| **쓰기/AuditLog** | 없음(읽기 전용 집계) |
| **구현 규모** | 작음. Extension 모듈 + 집계 쿼리 모듈(`Stats`) + LiveView 1. ~3 파일 |
| **새 테이블** | 0 |

### 애드온 ③ LOT QR 라벨 생성 (LotQrLabel)

| 항목 | 내용 |
|------|------|
| **목적** | MaterialLot의 lot_no를 QR 코드 라벨(인쇄용)로 생성 |
| **입력 코어 엔티티** | `MaterialLot`(lot_no, item_id, lot_type, quantity, status) — **읽기** |
| **읽기 경로** | 읽기 전용 Ecto 조회(lot 단건/목록). 코어에 LOT 조회 컨텍스트가 아직 없으므로(MVP 미구현) 애드온이 `MaterialLot` 스키마를 읽기로 alias |
| **출력** | QR 이미지(SVG) + 라벨 HTML(lot_no, 품목, 수량, 상태). 인쇄 가능한 라벨 뷰. SVG QR은 순수 Elixir 라이브러리(`eqrcode`)로 생성 |
| **화면 유무** | 있음. LiveView: lot 검색 → 라벨 미리보기 → 인쇄(브라우저 print). 화면 없는 다운로드 경로도 가능 |
| **쓰기/AuditLog** | **MVP는 읽기 전용**(라벨 생성은 LOT 상태를 바꾸지 않음). "라벨 발행 이력"이 필요해지면 별도 테이블+AuditLog로 후속(§8). 코어 LOT 상태/데이터는 절대 변경 안 함 |
| **구현 규모** | 작음. Extension 모듈 + QR 생성 래퍼 + 라벨 LiveView 1. ~3 파일 + `eqrcode` 의존성 1 |
| **새 테이블** | 0 (MVP) |

> **§0-B-7 적용**: 이 애드온이 유일하게 "쓰기 유혹"이 있는 애드온이다. **MVP는 읽기 전용으로 못 박는다.** lot status를 바꾸거나 발행 이력을 코어에 쓰지 않는다. 그래야 작고 안전하다.

### 애드온 ④ 설비 가동률 OEE 계산 (EquipmentOee)

| 항목 | 내용 |
|------|------|
| **목적** | 설비별 OEE(가동률×성능×품질) 근사 계산 위젯 |
| **입력 코어 엔티티** | `ProductionResult`(equipment_id, good/defect_quantity, started_at/ended_at), `Operation`(started_at/completed_at) — **읽기** |
| **읽기 경로** | 읽기 전용 Ecto 집계. equipment_id별 기간 집계. (EXT-1 `equipment_measurements`와는 **연동하지 않는다** — MVP는 코어 ProductionResult만으로 근사. EXT-1 연계는 후속) |
| **출력** | 설비별 OEE 표/위젯: 가동률(실적시간/계획시간 근사), 품질률(good/(good+defect)), 성능률(표준 cycle time 대비, Routing.standard_cycle_time 활용 시). MVP는 **품질률 + 단순 가동률**부터 |
| **화면 유무** | 있음. LiveView 1개 |
| **쓰기/AuditLog** | 없음(읽기 전용 집계) |
| **구현 규모** | 작음~중. OEE 정의가 분모(계획시간) 가정에 민감하므로 **MVP는 품질률+가동률 근사로 작게 시작**. Extension 모듈 + 계산 모듈(순수 함수, 테스트 용이) + LiveView 1. ~3 파일 |
| **새 테이블** | 0 |

> OEE 정식 계산(계획정지/비계획정지 구분, 이상적 cycle time)은 데이터 모델 확장이 필요하다 → MVP는 **가용 데이터로 근사**하고, 정밀 OEE는 EXT-4(생산관리 고도화)로 미룬다. 계산 로직은 **순수 함수**로 분리해 가정이 바뀌어도 테스트로 고정.

### 애드온 ⑤ 일일 생산 요약 (DailyProductionSummary)

| 항목 | 내용 |
|------|------|
| **목적** | 특정 날짜의 생산 현황 한 장 요약(품목별 양품/불량, 작업지시 진행) |
| **입력 코어 엔티티** | `WorkOrder`(status), `ProductionResult`(good/defect_quantity, ended_at), `Item` — **읽기** |
| **읽기 경로** | 읽기 전용 Ecto 집계(날짜 기준 ended_at 필터 + 품목별 sum). 일부는 `Production.list_work_orders/1` 재사용 |
| **출력** | 요약 카드: 오늘 작업지시 N건(상태별), 총 양품/불량 수량, 품목 상위. 화면 + (선택)JSON. AI 요약 API(mvp-scope §6)의 입력 데이터 소스로도 재사용 가능 |
| **화면 유무** | 있음. LiveView 1개(날짜 선택 → 요약). 홈 대시보드 성격 |
| **쓰기/AuditLog** | 없음(읽기 전용) |
| **구현 규모** | 작음. Extension 모듈 + 집계 모듈 + LiveView 1. ~3 파일 |
| **새 테이블** | 0 |

> **5개 모두 읽기 전용 + 새 테이블 0**(③도 MVP 읽기 전용). 코어 도메인 트랜잭션을 만들지 않으므로 AuditLog/LOT/Outbox 룰의 새 적용 대상이 없다 — qa-auditor는 애드온에서 "AuditLog 누락"을 결함으로 보지 말 것(§6 검증 포인트). 이것이 애드온을 작고 안전하게 만드는 핵심 결정이다.

### 2.3 애드온 공통 디렉토리 구조 (예: ② DefectStats)

```text
lib/open_mes_addons/
├── defect_stats/
│   ├── extension.ex        # OpenMes.Addons.DefectStats.Extension — behaviour 구현(메타데이터)
│   ├── stats.ex            # 집계 쿼리(읽기 전용) — 순수히 Repo 읽기
│   └── live/
│       └── dashboard_live.ex  # OpenMesWeb.Addons.DefectStatsLive (LiveView)
```

> LiveView 모듈은 웹 계층이므로 네임스페이스를 `OpenMesWeb.Addons.{Addon}Live`로 둔다(웹은 `OpenMesWeb`). 비즈니스/집계 로직(`Stats`)은 `OpenMes.Addons.{Addon}`(도메인 계층)에 둔다. CSV 다운로드처럼 컨트롤러가 필요하면 `OpenMesWeb.Addons.{Addon}Controller`.

---

## 3. 홈페이지 확장 카탈로그 (Phoenix LiveView)

### 3.1 라우트

```text
GET /                      → 확장 카탈로그(홈페이지). CatalogLive
GET /extensions            → 동일(별칭, 명시적 경로)
GET /extensions/:addon...  → 각 애드온/확장 자체 화면(home_path 가 가리키는 곳)
```

- 홈(`/`)을 카탈로그로 둔다(현재 코어는 `/api`만 있고 루트 화면 없음). `/extensions`도 같은 LiveView로 별칭.
- 각 확장 화면은 자기 `home_path/0`가 반환하는 경로에 산다(예: `/extensions/defect-stats`, `/ingest/health`).

### 3.2 LiveView 모듈 구조

```text
lib/open_mes_web/
├── live/
│   ├── catalog_live.ex          # OpenMesWeb.CatalogLive — 카탈로그 본체
│   └── catalog_live.html.heex   # 카드 목록 템플릿(또는 ~H sigil 인라인)
└── components/
    └── extension_card.ex        # (선택) 카드 컴포넌트. 카드가 단순하면 인라인(pi)
```

`CatalogLive` 동작:

```elixir
defmodule OpenMesWeb.CatalogLive do
  @moduledoc "확장 카탈로그 홈페이지. 등록된 확장을 카드로 렌더. 카테고리 필터 + enabled 배지."
  use OpenMesWeb, :live_view

  alias OpenMes.Extensions.Registry

  @impl true
  def mount(_params, _session, socket) do
    entries = Registry.all()                       # disabled 포함 — 카탈로그는 전부 보여줌
    categories = entries |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()

    {:ok,
     assign(socket,
       entries: entries,
       categories: categories,
       filter: :all,        # :all | 특정 category
       visible: entries
     )}
  end

  @impl true
  def handle_event("filter", %{"category" => "all"}, socket) do
    {:noreply, assign(socket, filter: :all, visible: socket.assigns.entries)}
  end

  def handle_event("filter", %{"category" => cat}, socket) do
    cat_atom = String.to_existing_atom(cat)
    visible = Enum.filter(socket.assigns.entries, &(&1.category == cat_atom))
    {:noreply, assign(socket, filter: cat_atom, visible: visible)}
  end
end
```

### 3.3 카드 렌더 요구사항 (요구된 항목 모두 충족)

각 카드:
- **이름**(한국어, `name`) — 제목
- **설명**(`description`) — 본문
- **카테고리**(`category`) — 작은 라벨(예: `설비수집` / `생산` / `품질` / `추적`)
- **enabled 상태 배지** — enabled면 초록 "활성", disabled면 회색 "비활성"
- **버전**(`version`) — 미세 텍스트
- **링크**: `home_path != nil`이고 `enabled == true`면 "열기" 링크(`home_path`로 이동). disabled거나 화면 없으면 링크 비활성/숨김

필터/구분:
- **카테고리 필터**: 상단에 카테고리 버튼(전체 + 각 카테고리). `phx-click="filter"`로 `visible` 갱신.
- **enabled/disabled 구분**: 배지로 시각 구분. (정렬은 §1.3 `all/0`이 category→name 순. 필요 시 enabled 먼저 정렬 옵션 추가 가능하나 MVP는 배지 구분으로 충분.)

> **카탈로그 노출 보장**: `Registry.all/0`은 config `:extensions` 리스트 전체(EXT-1, EXT-2, 애드온 5개)를 반환하므로 **7개 모두 카드로 노출**된다. enabled=false인 것도 disabled 배지로 보인다(설치 여부가 아니라 활성 여부를 보여주는 게 카탈로그의 일).

### 3.4 LiveView 인프라 전제

- 코어 WorkOrder 앱은 `mix phx.new --no-dashboard`(API 위주)로 시작했을 수 있다. **LiveView 사용을 위해 `phx.new` 시 LiveView 포함**(기본 포함)이거나, 누락 시 `phoenix_live_view` deps + `Endpoint`에 socket + `live_reload` 설정이 필요하다. §4 통합 전략에서 골격으로 다룬다.
- 카탈로그는 인증 없이 공개(MVP). 운영 시 관리자 권한 게이트는 후속.

---

## 4. Phoenix 앱 통합 전략

지금까지 `_workspace/02·06·07`은 **앱 트리 조각**(소스 파일 + 마이그레이션 + 패치)이지 실행 가능한 Phoenix 앱이 아니다. 이를 실제 앱으로 합친다.

### 4.1 `mix phx.new` 는 사용자가 로컬에서 실행 (이 환경엔 elixir/mix 없음)

> **전제**: 골격 생성 명령은 사용자가 로컬에서 실행한다. 우리는 골격 위에 얹을/교체할 파일을 작성한다.

권장 생성 명령(LiveView 포함 — 카탈로그가 LiveView이므로):

```bash
# 프로젝트 루트(/Users/hongsw/dev/open-mes-korea)에서:
mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer
# 주의: --no-dashboard 는 붙이지 않는다(LiveDashboard 무관하지만, LiveView 자체는 기본 포함).
#       01 설계는 --no-dashboard 였으나, 카탈로그가 LiveView 이므로 LiveView 스택을 살린다.
#       phx.new 는 기본으로 phoenix_live_view 를 포함한다.
# "."(현재 디렉토리)에 생성 시 기존 파일과 충돌하면 phx.new 가 물어본다 → §4.3 순서대로.
```

### 4.2 우리가 작성/교체하는 골격 파일 vs phx.new 보일러플레이트에 맡길 것

| 파일 | 누가 | 비고 |
|------|------|------|
| `mix.exs` (deps) | **우리가 수정** | phx.new 기본 deps + 확장 deps 병합: `broadway`(EXT-1), `ex_aws`/`ex_aws_s3`/`sweet_xml`/`hackney`/`file_system`(EXT-2), `eqrcode`(애드온③), (선택)`nimble_csv`(애드온①). §4.5 |
| `config/config.exs` | **우리가 수정** | `:extensions` 리스트(§1.2) 추가, 각 확장 기본 `enabled: false`, 애드온 config. phx.new Repo/Endpoint 설정은 유지 |
| `config/runtime.exs` | **우리가 수정** | EXT-1 `INGEST_*`, EXT-2 `MEDIA_*`/`MINIO_*`, 애드온 enabled 환경변수. phx.new DB URL 설정 유지 |
| `config/dev.exs` `test.exs` | **우리가 일부 수정** | test.exs 에 확장/애드온 `enabled: true`(테스트가 라우트 필요 시, EXT-1 router 패치 §주의 참조). 나머지 phx.new 유지 |
| `lib/open_mes/application.ex` | **우리가 수정(패치 적용)** | phx.new 가 생성한 application.ex 에 `++ ingest_children() ++ media_children() ++ addon_children()` 배선. §4.4 |
| `lib/open_mes_web/router.ex` | **우리가 수정(패치 적용)** | phx.new 라우터에 `/`(카탈로그) + 조건부 `/ingest`·`/media`·애드온 scope 추가. §4.4 |
| `lib/open_mes_web/endpoint.ex` | **phx.new 보일러플레이트** | LiveView socket 포함. 수정 불필요(LiveView 기본 포함 시) |
| `lib/open_mes/repo.ex` | **phx.new 보일러플레이트** | binary_id 옵션은 phx.new `--binary-id`가 처리 |
| `lib/open_mes_web.ex`(`use` 매크로) | **phx.new 보일러플레이트** | `:live_view`, `:controller` 등 정의 포함 |
| `lib/open_mes_web/components/*`, `core_components.ex`, layouts | **phx.new 보일러플레이트** | 카탈로그가 재사용. 새로 안 만듦(pi) |
| `assets/`, `tailwind`, `esbuild` | **phx.new 보일러플레이트** | LiveView UI용. 그대로 |
| 코어/확장 소스(`lib/open_mes/...`, `lib/open_mes_ingest/...`, `lib/open_mes_media/...`, `lib/open_mes_addons/...`) | **우리가 _workspace에서 복사** | §4.3 매핑 |
| 마이그레이션 | **우리가 _workspace에서 복사** | §4.3 순서 |
| `test/support/{data_case,conn_case}.ex` | **병합** | phx.new 가 생성하나, _workspace 버전과 충돌 시 phx.new 것 사용(표준) |

> **원칙**: phx.new가 잘 만드는 것(endpoint, web.ex, components, layouts, assets, repo)은 **건드리지 않는다**(pi — 보일러플레이트 재작성 금지). 우리는 (a) 도메인/확장 소스, (b) deps/config, (c) application.ex·router.ex 배선만 얹는다.

### 4.3 `_workspace` 기존 코드 → 실제 앱 트리 매핑 표

루트: `/Users/hongsw/dev/open-mes-korea/` (phx.new `.` 생성 후).

| 출처(_workspace) | 대상(앱 트리) | 비고 |
|------|------|------|
| `02_.../lib/open_mes/audit/*` | `lib/open_mes/audit/*` | 그대로 복사 |
| `02_.../lib/open_mes/outbox/*` | `lib/open_mes/outbox/*` | 그대로 복사 |
| `02_.../lib/open_mes/production/*` | `lib/open_mes/production/*` | 그대로 복사 |
| `02_.../lib/open_mes_web/controllers/*` | `lib/open_mes_web/controllers/*` | 그대로 복사 |
| `02_.../lib/open_mes_web/plugs/require_actor.ex` | `lib/open_mes_web/plugs/require_actor.ex` | 그대로 |
| `02_.../lib/open_mes_web/router.ex` | `lib/open_mes_web/router.ex` | **병합 기준 파일**. phx.new 라우터를 이걸로 교체 후 §4.4 배선 추가 |
| `02_.../priv/repo/migrations/2026061300000{1,2,3}_*` | `priv/repo/migrations/` | 먼저(audit→outbox→work_orders) |
| `06_.../lib/open_mes_ingest/*` | `lib/open_mes_ingest/*` | 그대로(EXT-1 전체) |
| `06_.../lib/open_mes_web/controllers/ingest_*` | `lib/open_mes_web/controllers/` | 그대로 |
| `06_.../lib/open_mes_web/plugs/require_device_token.ex` | `lib/open_mes_web/plugs/` | 그대로 |
| `06_.../priv/repo/migrations/202606131000*` | `priv/repo/migrations/` | work_orders 뒤 |
| `06_.../patches/application.ex.patch.md` | `lib/open_mes/application.ex` | **패치 적용**(§4.4), 파일 복사 아님 |
| `06_.../patches/router.ex.patch.md` | `lib/open_mes_web/router.ex` | **패치 적용**(§4.4) |
| `06_.../patches/config.snippets.md` | `config/{config,runtime,test}.exs` | 스니펫 병합 |
| `07_.../lib/open_mes_media/*` | `lib/open_mes_media/*` | 그대로(EXT-2 전체) |
| `07_.../priv/repo/migrations/20260613000010_create_media_assets.exs` | `priv/repo/migrations/` | §4.6 타임스탬프 주의(번호 정렬) |
| `07_.../CORE_PATCH.md` | `lib/open_mes/application.ex`, `router.ex`, config | **패치 적용**(media_children, /media scope) |
| (신규, 이 설계) `OpenMes.Extensions.*` | `lib/open_mes/extensions/{extension,definition,registry}.ex` | §1 |
| (신규) `OpenMesWeb.CatalogLive` | `lib/open_mes_web/live/catalog_live.ex` | §3 |
| (신규) `OpenMes.Ingest.Extension` | `lib/open_mes_ingest/extension.ex` | EXT-1 메타데이터 모듈(§4.4) |
| (신규) `OpenMes.Media.Extension` | `lib/open_mes_media/extension.ex` | EXT-2 메타데이터 모듈 |
| (신규) 애드온 5개 | `lib/open_mes_addons/{addon}/...` | §2 |

### 4.4 통합된 `application.ex` / `router.ex` 배선 (모든 확장 합산)

`application.ex` — EXT-1/EXT-2 패치를 합치고 애드온은 **child 불필요**(애드온은 LiveView/쿼리뿐, 백그라운드 프로세스 없음. ⑤ 일일요약을 캐시하는 GenServer를 둔다면 그때만 child 추가 — MVP는 불필요):

```elixir
def start(_type, _args) do
  children =
    [
      OpenMes.Repo,
      OpenMesWeb.Telemetry,        # phx.new 기본
      {Phoenix.PubSub, name: OpenMes.PubSub},  # phx.new 기본(LiveView 필요)
      OpenMesWeb.Endpoint
    ]
    ++ ingest_children()            # EXT-1 (06 패치)
    ++ media_children()             # EXT-2 (07 패치)
    # 애드온은 supervised child 없음(읽기 전용). 필요 시 addon_children() 추가.

  Supervisor.start_link(children, strategy: :one_for_one, name: OpenMes.Supervisor)
end

defp ingest_children, do: if(OpenMes.Ingest.enabled?(), do: [OpenMes.Ingest.Pipeline], else: [])
defp media_children do
  if OpenMes.Media.enabled?() do
    [OpenMes.Media.Transfer.TransferSupervisor, OpenMes.Media.Watch.Scanner, OpenMes.Media.Transfer.Dispatcher]
  else
    []
  end
end
```

`router.ex` — 코어 `/api` + 카탈로그 `/` + 조건부 확장 scope + 애드온 LiveView scope:

```elixir
# 브라우저 파이프라인(LiveView/HTML) — phx.new 기본 :browser 사용
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {OpenMesWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

# 카탈로그(홈)
scope "/", OpenMesWeb do
  pipe_through :browser
  live "/", CatalogLive, :index
  live "/extensions", CatalogLive, :index
end

# 애드온 LiveView 화면(각 애드온 enabled 시에만 등록 — 컴파일 타임 게이트, EXT-1 패턴 승계)
if OpenMes.Addons.DefectStats.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/defect-stats", DefectStatsLive, :index
  end
end
# … 애드온 ①③④⑤ 동일 패턴(각자 enabled? 게이트) …

# 코어 /api (02), 조건부 /ingest(06), 조건부 /media(07) scope 는 기존대로 …
```

> **EXT-1/EXT-2 메타데이터 모듈 추가(통합 시 신규)**: 카탈로그 노출을 위해 각 확장에 behaviour 구현 모듈을 1개씩 추가. 기존 파이프라인 코드 무변경.
>
> ```elixir
> defmodule OpenMes.Ingest.Extension do
>   use OpenMes.Extensions.Definition
>   @impl true; def id, do: :ext_ingest
>   @impl true; def name, do: "설비 데이터 수집"
>   @impl true; def description, do: "브로커리스 HTTP push → Broadway → TimescaleDB 적재(고빈도 텔레메트리)."
>   @impl true; def category, do: :ingest
>   @impl true; def version, do: "0.1.0"
>   @impl true; def enabled?, do: OpenMes.Ingest.enabled?()   # 기존 게이트 재사용
>   @impl true; def home_path, do: "/ingest/health"
> end
> ```

### 4.5 mix.exs deps 병합(확장 합산)

```elixir
defp deps do
  [
    # ── phx.new 기본(생략 표기) ──
    {:phoenix, "~> 1.7"},
    {:phoenix_ecto, "~> 4.4"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, ">= 0.0.0"},
    {:phoenix_live_view, "~> 0.20"},   # 카탈로그/애드온 화면
    {:jason, "~> 1.2"},
    {:bandit, "~> 1.0"},
    # … esbuild/tailwind/heroicons 등 phx.new 기본 …

    # ── EXT-1 (06) ──
    {:broadway, "~> 1.1"},
    # ── EXT-2 (07) ──
    {:ex_aws, "~> 2.5"}, {:ex_aws_s3, "~> 2.5"}, {:sweet_xml, "~> 0.7"},
    {:hackney, "~> 1.20"}, {:file_system, "~> 1.0"},
    # ── 애드온 ──
    {:eqrcode, "~> 0.2"}            # 애드온③ LOT QR (SVG QR 생성)
    # {:nimble_csv, "~> 1.2"}      # 애드온① (선택 — 수동 인코딩 시 불필요)
  ]
end
```

### 4.6 통합 순서 / 마이그레이션 의존성

```text
[0] 사용자: mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer  (로컬)
            → 충돌 파일은 보류, 골격만 받음

[1] 코어(02) 통합 — 다른 모든 것의 토대
    a. lib/open_mes/{audit,outbox,production}/* 복사
    b. lib/open_mes_web/{controllers,plugs}/* 복사, router.ex 02 버전으로 교체
    c. 마이그레이션 복사: 000001 audit_logs → 000002 outbox_events → 000003 work_orders
    d. mix ecto.create && mix ecto.migrate && mix test  (코어 단독 통과 확인)

[2] 레지스트리 + 카탈로그(신규, 이 설계 §1·§3) — 확장들의 노출 토대
    a. lib/open_mes/extensions/{extension,definition,registry}.ex
    b. lib/open_mes_web/live/catalog_live.ex
    c. config :open_mes, :extensions, [] (처음엔 빈 리스트로 시작 가능)
    d. router 에 / 카탈로그 scope. 빈 카탈로그라도 렌더 확인.

[3] EXT-1(06) 통합 (TimescaleDB 인프라 필요 — Docker 이미지)
    a. lib/open_mes_ingest/* 복사 + lib/open_mes_ingest/extension.ex(신규 메타데이터)
    b. application.ex/router.ex 패치(ingest_children, /ingest scope)
    c. 마이그레이션: 100001 enable_timescaledb → 100002 equipment_measurements → 100003 dead_letters
    d. :extensions 리스트에 OpenMes.Ingest.Extension 추가
    e. enabled:false 로 코어 테스트 회귀 통과 확인

[4] EXT-2(07) 통합 (MinIO 인프라 필요)
    a. lib/open_mes_media/* 복사 + lib/open_mes_media/extension.ex(신규)
    b. CORE_PATCH 적용(media_children, /media scope)
    c. 마이그레이션: create_media_assets (번호는 work_orders 뒤 보장)
    d. :extensions 리스트에 OpenMes.Media.Extension 추가

[5] 애드온 ①~⑤(신규) — 서로 독립, 병렬 가능
    a. 각 lib/open_mes_addons/{addon}/* + extension.ex + live/
    b. router 에 각 애드온 조건부 scope
    c. :extensions 리스트에 5개 추가
    d. 코어/EXT 무영향 확인(애드온은 읽기뿐)

[6] 전체 검증: mix test, 카탈로그 / 접속 → 7개 카드 확인(enabled 토글로 배지 변화).
```

> **마이그레이션 번호 정렬 주의(§4.6 핵심)**: Ecto는 마이그레이션을 **파일명 타임스탬프 오름차순**으로 실행한다. 현재 번호:
> - 코어: `20260613000001/2/3`(audit/outbox/work_orders)
> - EXT-2 media: `20260613000010`(work_orders 뒤 — OK)
> - EXT-1 ingest: `20260613100001/2/3`(가장 뒤 — OK)
>
> 순서 의존성: **work_orders·audit·outbox가 가장 먼저**(다른 게 참조하진 않지만 코어가 토대). EXT-1/EXT-2 테이블은 코어 테이블을 FK 참조하지 않으므로(설계상 의도) 상호 순서 자유. media(000010)가 ingest(100001)보다 앞서 실행되지만 무관(독립 테이블). **애드온은 마이그레이션 0개**라 의존성 추가 없음. → 현재 번호 그대로 두면 안전. domain-engineer는 새 마이그레이션 추가 시 코어(00000x) 뒤 번호를 쓴다.

---

## 5. config 정리 (확장/애드온 게이트 한눈에)

```elixir
# config/config.exs
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension, OpenMes.Media.Extension,
  OpenMes.Addons.WoCsvExport.Extension, OpenMes.Addons.DefectStats.Extension,
  OpenMes.Addons.LotQrLabel.Extension, OpenMes.Addons.EquipmentOee.Extension,
  OpenMes.Addons.DailyProductionSummary.Extension
]

# 코어는 항상 동작. 확장/애드온은 기본 off.
config :open_mes, OpenMes.Ingest, enabled: false          # EXT-1
config :open_mes, OpenMes.Media, enabled: false, object_store: OpenMes.Media.ObjectStore.S3ObjectStore, sink: OpenMes.Media.Sink.NoopSink  # EXT-2
config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true   # 애드온은 안전(읽기뿐)하므로 기본 on 가능 — 결정은 아래
config :open_mes, OpenMes.Addons.DefectStats, enabled: true
config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true
```

> **결정 — 애드온은 기본 `enabled: true`로 둔다(EXT-1/2는 기본 false 유지).** 근거: 애드온은 읽기 전용이고 인프라 의존(TimescaleDB/MinIO)이 없어 켜도 안전하다. 반면 EXT-1/2는 외부 인프라가 없으면 마이그레이션/부팅이 실패할 수 있어 기본 off. 카탈로그에서 애드온은 "활성", EXT-1/2는 "비활성(인프라 미설정)"으로 자연히 구분되어 보인다. (애드온도 보수적으로 off로 시작하고 싶으면 한 줄로 변경 가능 — 사용자 선택.)

---

## 6. qa-auditor 검증 포인트

### 정상(결함 아님 — 오탐 금지)

- ✅ **애드온 5개에 AuditLog 없음** — 5개 모두 **읽기 전용**(③도 MVP 읽기). 도메인 트랜잭션을 만들지 않으므로 "모든 쓰기에 AuditLog" 룰의 적용 대상이 아니다. AuditLog 부재는 정상.
- ✅ **레지스트리/카탈로그에 AuditLog·Outbox 없음** — 메타데이터 조회 + 화면 렌더뿐. 도메인 쓰기 0.
- ✅ **애드온이 새 DB 테이블 0개** — 읽기 위주 설계의 결과(작고 안전).
- ✅ **레지스트리에 DB/상태 없음** — config 명시 목록 + 콜백 호출. 영속 상태 불필요(설치 시스템 아님).

### 검증(위반 시 보고)

- ⛔ **코어 비침투**: 애드온/레지스트리/카탈로그가 코어 도메인 스키마를 **수정**하지 않는지. 코어 데이터는 **읽기만**(Repo 읽기/공개 조회 함수). 애드온이 `Repo.insert/update/delete`로 코어 테이블을 건드리면 위반.
- ⛔ **의존 방향**: 코어 도메인(`OpenMes.Production`/`WorkOrder`/`Audit`/`Outbox`)이 `OpenMes.Extensions.*`/`OpenMes.Addons.*`를 참조하지 않는지(grep). 레지스트리는 "확장이 의존하는 공통 계약"이지 코어가 의존하는 대상이 아니다.
- ⛔ **선택적 활성화**: 모든 확장/애드온을 `enabled: false`로 두고 코어 `mix test` 전체 통과. 카탈로그는 disabled 카드만 그려도 정상.
- ⛔ **애드온 ③ 읽기 전용 불변식**: LotQrLabel이 `MaterialLot` status/데이터를 **변경하지 않는지**(grep `Repo.update`/`Repo.insert` on MaterialLot). MVP는 라벨 생성만.
- ⛔ **EXT-1/EXT-2 무변경**: 메타데이터 모듈(`Extension`) 추가 외에 기존 파이프라인 코드가 변경되지 않았는지. application.ex/router.ex 배선은 기존 패치 범위 그대로.
- ⛔ **레지스트리 견고성**: 한 확장의 `enabled?/0`가 raise해도 카탈로그 전체가 죽지 않는지(§1.3 `safe_enabled?`).

> 즉 이 설계의 핵심 검증 축은 **"애드온은 코어를 읽기만 하고, AuditLog 룰은 새로 적용될 도메인 쓰기가 없다"**이다. 코어 도메인 트랜잭션(WorkOrder 등)의 AuditLog/LOT/상태머신 룰은 02 구현에서 이미 검증됐고, 이 설계는 거기에 새 도메인 쓰기를 추가하지 않는다.

---

## 7. domain-engineer 구현 지침 (병렬 분배)

> **(a) 기반 작업**과 **(b) 애드온 5개**를 분리한다. (a)는 한 명이 먼저(또는 동시 착수하되 카탈로그가 (a)에 의존). (b) 5개는 (a) §7.1의 `Extension` behaviour만 있으면 **서로 독립·병렬** 구현 가능.

### 7.a 기반 작업 — 레지스트리 + 카탈로그 + 앱 골격 (선행, 1인 권장)

**의존성**: 코어(02)가 앱 트리에 통합되어 있어야 함(§4.6 [1]).

구현 순서:
1. **`OpenMes.Extensions.Extension`** behaviour(§1.1) + **`OpenMes.Extensions.Definition`** use 매크로(선택 콜백 기본값).
2. **`OpenMes.Extensions.Registry`**(§1.3) — `all/0`, `enabled/0`, `by_category/0`, `modules/0`. 상태 없음. `safe_enabled?` 방어 포함.
3. **config**: `config :open_mes, :extensions, [...]`(§5). 처음엔 EXT/애드온 모듈이 아직 없으니 **빈 리스트로 시작**하고, 각 확장 통합 시 추가(컴파일 에러 회피).
4. **`OpenMesWeb.CatalogLive`**(§3.2) + 템플릿(§3.3): 카드 목록, 카테고리 필터, enabled 배지, home_path 링크. phx.new core_components/layout 재사용(새 디자인 시스템 만들지 말 것 — pi).
5. **router**: `/` `/extensions` → CatalogLive(§4.4 `:browser` 파이프라인).
6. **EXT-1/EXT-2 메타데이터 모듈**(§4.4): `OpenMes.Ingest.Extension`, `OpenMes.Media.Extension` 추가(기존 코드 무변경). `enabled?/0`는 각자 기존 게이트 위임. `:extensions` 리스트에 추가.
7. **앱 골격 배선**: 통합된 application.ex(§4.4) + mix.exs deps(§4.5) + config 병합(§5). (이 작업은 §4.6 통합 순서를 따른다.)

테스트:
- `Registry.all/0`이 등록 모듈 수만큼 엔트리 반환. `enabled/0`이 enabled만.
- 한 확장 `enabled?`가 raise해도 `all/0`이 죽지 않음(safe_enabled?).
- CatalogLive mount → 카드 N개 렌더, 카테고리 필터 phx-click → visible 변경(LiveView 테스트 `Phoenix.LiveViewTest`).
- enabled:false 회귀: 모든 확장 off에서 카탈로그가 disabled 카드만으로 정상 렌더 + 코어 테스트 통과.

### 7.b 애드온 5개 — 각각 독립 구현 명세 (병렬)

**공통 전제**: 7.a의 `Extension` behaviour + `Definition` 매크로 존재. 각 애드온은 `lib/open_mes_addons/{addon}/` 격리, config `enabled` 게이트, 코어 **읽기만**, 새 테이블 0(③도 MVP 0), AuditLog 무관(읽기). LiveView는 `OpenMesWeb.Addons.{Addon}Live`.

각 애드온 구현물(공통): `extension.ex`(behaviour 구현) + 로직 모듈(순수/읽기쿼리) + `live/` 1개 (+ ① 만 CSV 다운로드 컨트롤러 액션). config 한 줄 + router 조건부 scope 한 블록 + `:extensions` 리스트 한 줄.

#### (b-1) ① WoCsvExport — 작업지시 CSV 내보내기
- `OpenMes.Addons.WoCsvExport.Extension`: id `:addon_wo_csv_export`, name "작업지시 CSV 내보내기", category `:production`, home_path `"/extensions/wo-csv-export"`.
- 로직: `Csv.rows(filters)` — `OpenMes.Production.list_work_orders/1` 호출 후 CSV 라인 생성(수동 인코딩 권장, 따옴표/콤마 이스케이프). 순수 함수로 분리(테스트 용이).
- 화면: `WoCsvExportLive`(필터 폼) + 다운로드는 `OpenMesWeb.Addons.WoCsvExportController` `:download`(content-type csv, `send_download`/chunked). LiveView에서 다운로드 트리거는 링크(`~p"/extensions/wo-csv-export/download?status=..."`).
- 테스트: `Csv.rows` 가 주어진 WorkOrder 목록을 정확한 CSV로(이스케이프 포함). 빈 목록 → 헤더만.
- 규모: ~3~4 파일. **쓰기 0**.

#### (b-2) ② DefectStats — 불량 통계 위젯
- `Extension`: id `:addon_defect_stats`, name "불량 통계 위젯", category `:quality`, home_path `"/extensions/defect-stats"`.
- 로직: `Stats.by_defect_code(date_range)` — `DefectRecord` group_by defect_code sum(quantity). `Stats.defect_rate(date_range)` — `ProductionResult` sum(defect)/(sum(good)+sum(defect)). **읽기 전용 Ecto 쿼리**(스키마 alias 읽기 허용).
- 화면: `DefectStatsLive` — 기간 선택, 상위 불량코드 막대(CSS 바), 불량률 숫자.
- 테스트: 집계 쿼리 정확성(시드 데이터 → 기대 집계). 0건 기간 → 0/nil 안전.
- 규모: ~3 파일. **쓰기 0**.

#### (b-3) ③ LotQrLabel — LOT QR 라벨 생성
- `Extension`: id `:addon_lot_qr_label`, name "LOT QR 라벨 생성", category `:traceability`, home_path `"/extensions/lot-qr-label"`.
- 로직: `Labels.fetch(lot_no_or_id)` — `MaterialLot` **읽기 조회**. `Labels.qr_svg(lot_no)` — `eqrcode` 로 SVG 생성. **MaterialLot 변경 절대 금지(읽기 전용 불변식)**.
- 화면: `LotQrLabelLive` — lot 검색 → 라벨(품목/수량/상태 + QR SVG) 미리보기 → 브라우저 인쇄.
- 테스트: `qr_svg` 가 SVG 문자열 반환. `Labels.fetch` 미존재 lot → `{:error, :not_found}`. **MaterialLot 에 Repo.update/insert 호출 없음(코드 grep 검증).**
- 규모: ~3 파일 + `eqrcode` deps. **쓰기 0(MVP)**.

#### (b-4) ④ EquipmentOee — 설비 가동률 OEE
- `Extension`: id `:addon_equipment_oee`, name "설비 가동률(OEE)", category `:analytics`, home_path `"/extensions/equipment-oee"`.
- 로직: `Oee.by_equipment(date_range)` — `ProductionResult` equipment_id별 집계(good/defect, started_at~ended_at 가동시간). 계산은 **순수 함수** `Oee.compute(%{good, defect, run_seconds, planned_seconds, ...})` 로 분리(가정이 바뀌어도 테스트 고정). MVP: 품질률 + 단순 가동률 근사. EXT-1 measurements 미연동.
- 화면: `EquipmentOeeLive` — 기간 선택, 설비별 OEE 표.
- 테스트: `Oee.compute` 경계값(분모 0 → nil/0 방어, good=defect=0). 집계 쿼리 정확성.
- 규모: ~3 파일. **쓰기 0**. (OEE 분모 가정은 README에 명시 — 근사임을 표기.)

#### (b-5) ⑤ DailyProductionSummary — 일일 생산 요약
- `Extension`: id `:addon_daily_summary`, name "일일 생산 요약", category `:production`, home_path `"/extensions/daily-summary"`.
- 로직: `Summary.for_date(date)` — 그날 ended_at 기준 ProductionResult 품목별 good/defect 합, 상태별 WorkOrder 수(`Production.list_work_orders`). 읽기 전용.
- 화면: `DailyProductionSummaryLive` — 날짜 선택 → 요약 카드.
- (선택) `Summary.for_date/1`은 AI 요약 API(mvp-scope §6)의 입력으로 재사용 가능하게 map 반환.
- 테스트: 특정 날짜 시드 → 기대 요약. 데이터 없는 날 → 0 안전.
- 규모: ~3 파일. **쓰기 0**.

### 7.c 구현 세부 공통 규칙

- **코어 읽기만**: 애드온은 `OpenMes.Production`의 공개 조회 함수를 우선 사용. 없으면 코어 스키마(`WorkOrder`/`DefectRecord`/`ProductionResult`/`MaterialLot`/`Item`)를 alias해 **읽기 쿼리**만 작성. `Repo.insert/update/delete`로 코어 테이블 건드리면 위반.
- **새 테이블 금지(MVP)**: 5개 모두 마이그레이션 0. 부득이하면(③ 발행 이력 등) 이번 범위 밖(§8).
- **화면은 phx.new 컴포넌트 재사용**: 새 CSS 프레임워크/차트 라이브러리 도입 금지(pi). 막대는 CSS, 표는 기본 테이블.
- **config 게이트**: 각 애드온 `enabled?/0`는 `Application.get_env(:open_mes, __MODULE__의_addon_모듈, [])[:enabled]` 패턴. router scope는 컴파일 타임 `if ...Extension.enabled?()` 게이트(EXT-1 router 패턴 승계, test.exs에서 enabled:true 보장).
- **언어**: UI 텍스트/주석/에러 한국어, 식별자 영문.
- **레지스트리 등록**: 각 애드온 완료 시 `config :extensions` 리스트에 `Extension` 모듈 추가 → 카탈로그 자동 노출.

---

## 8. 미해결 / 후속 항목 (사용자 확인)

1. **phx.new 실행 + LiveView 스택**: 01 설계는 `--no-dashboard`였으나 카탈로그가 LiveView이므로 LiveView를 살린다(§4.1). 사용자가 로컬에서 `mix phx.new . --binary-id` 실행 필요. **승인/실행 필요**.
2. **애드온 기본 enabled 정책**: §5 결정은 애드온 기본 on(읽기 안전), EXT-1/2 기본 off(인프라 의존). 보수적으로 애드온도 off 시작을 원하면 변경 — **사용자 선택**.
3. **애드온 ③ 라벨 발행 이력**: MVP는 읽기 전용. "어떤 lot 라벨을 언제 누가 발행" 이력이 필요해지면 별도 테이블 + AuditLog로 후속 설계(그때는 도메인 쓰기 → 감사 룰 적용).
4. **OEE 정밀도**: MVP는 가용 데이터 근사(품질률+가동률). 계획정지/이상 cycle time 반영한 정식 OEE는 EXT-4(생산관리 고도화) + 데이터 모델 확장 필요.
5. **EXT-1 measurements ↔ ④ OEE 연계**: MVP 미연동(코어 ProductionResult만). 설비 실가동을 텔레메트리로 보강하려면 EXT-1 enabled 전제 + 합류 설계(후속).
6. **카탈로그 인증**: MVP 공개. 운영 시 관리자 권한 게이트(mvp-scope 관리자 기능)와 연계 — 인증 도입 시(01 §8) 함께.
7. **NimbleCSV 도입 여부**: 애드온① CSV. 수동 인코딩(의존성 0, pi) 권장하되 domain-engineer 판단.
