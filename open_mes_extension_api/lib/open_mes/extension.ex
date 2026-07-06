defmodule OpenMes.Extension do
  @moduledoc """
  확장 모듈 공통 계약(behaviour) — 계약 패키지 `open_mes_extension_api` 의 핵심.

  EXT-1(설비수집)·EXT-2(멀티미디어)·EXT-5(연동 허브)·도메인 애드온 5개, 그리고 **별도 repo
  외부 확장**이 모두 이 behaviour 를 구현한다. 레지스트리(`OpenMes.Extension.Registry`)는
  이 콜백들로 각 확장의 메타데이터를 수집하고, 홈페이지 카탈로그(`OpenMesWeb.CatalogLive`)는
  그 목록을 카드로 렌더한다. 라우트는 `route_spec/0`(선택 콜백) 데이터로 선언되어
  `OpenMes.Extension.RouterMount` 매크로가 컴파일 타임에 주입한다(설계 30 §2.1).

  핵심 원칙:
    - 이 behaviour 는 **"메타데이터 + 라우트 데이터 선언"만** 계약한다. 확장의 실제 동작
      (파이프라인/연산/화면)은 각 확장 내부의 책임이다(레지스트리는 동작을 모름 — pi).
    - 이 계약은 **외부 확장의 ABI** 다. 시그니처 변경은 외부 확장을 깨뜨린다(설계 30 §9.4).

  ## 구현자가 따를 계약(요약)

  필수 콜백 6개: `id/0` `name/0` `description/0` `category/0` `version/0` `enabled?/0`
  선택 콜백 3개(`OpenMes.Extension.Definition` 가 기본값 주입):
    - `home_path/0`   : 자체 화면 경로(없으면 nil)
    - `icon/0`        : 카탈로그 카드 아이콘(없으면 nil → 기본 아이콘)
    - `route_spec/0`  : 라우트 데이터 선언(없으면 nil → 라우트 0)

  보일러플레이트 최소화를 위해 `use OpenMes.Extension.Definition` 를 권장한다.
  그러면 선택 콜백 기본값이 자동 주입되어 필수 6개만 구현하면 된다.
  """

  @typedoc """
  확장 분류. 카탈로그 카테고리 필터에 사용한다.

  **개방형(`atom()`)** — 외부 repo 확장이 코어를 건드리지 않고 자유 카테고리를 쓸 수 있도록
  닫힌 union 을 열었다(설계 30 §2.2). 코어가 한국어 라벨/아이콘/필터 칩을 **제공하는**
  카테고리는 `known_categories/0` 에 모은다(검증 게이트가 아니라 "알려진 라벨"일 뿐).

  코어 제공 카테고리:
    - `:ingest` `:media` `:production` `:quality` `:traceability` `:analytics` `:integration`

  그 외 atom 도 정상이다(외부 확장의 자유). 카탈로그는 미지 카테고리를 폴백 라벨로 렌더한다.
  """
  @type category :: atom()

  @typedoc """
  라우트 데이터 선언(`route_spec/0` 반환). 외부 확장은 자기 Router 모듈을 만들 필요 없이
  순수 데이터(맵+튜플)로 라우트를 선언한다 — `RouterMount` 매크로가 컴파일 타임에 Phoenix
  매크로로 펼친다(설계 30 §2.1, pi: 추상화 최소).

    - `:scope`    — 라우트 scope 경로(예: `"/extensions"`)
    - `:pipeline` — 통과할 파이프라인(atom 또는 atom 리스트)
    - `:routes`   — 라우트 튜플 리스트. 각 튜플:
        - `{:live, path, live_module, action}`
        - `{:get,  path, controller, action}`
        - `{:post, path, controller, action}`
  """
  @type route_spec :: %{
          scope: String.t(),
          pipeline: atom() | [atom()],
          routes: [route_entry()]
        }

  @type route_entry ::
          {:live, String.t(), module(), atom()}
          | {:get, String.t(), module(), atom()}
          | {:post, String.t(), module(), atom()}

  @doc ~S'확장 고유 식별자(영문 atom, 안정적). 예: `:ext_ingest`, `:addon_wo_csv_export`.'
  @callback id() :: atom()

  @doc ~S'사람이 읽는 이름(한국어). 예: "설비 데이터 수집".'
  @callback name() :: String.t()

  @doc "한 줄 설명(한국어)."
  @callback description() :: String.t()

  @doc "분류. 카탈로그 필터에 사용."
  @callback category() :: category()

  @doc ~S'버전 문자열. 예: "0.1.0".'
  @callback version() :: String.t()

  @doc """
  활성화 여부. config 게이트.

  꺼져 있으면 카탈로그에 '비활성' 배지로 표시되고, 라우트/연산은 등록되지 않는다.
  관례상 각 확장의 퍼사드 게이트(`OpenMes.Ingest.enabled?/0` 등)에 위임한다.

  **라우트를 기여하는 확장**(`route_spec/0` 구현)의 `enabled?/0` 는 컴파일 타임 결정값
  (`Application.compile_env`)을 써야 한다 — 라우트는 컴파일 타임에 확정되므로(설계 30 §2.1).
  """
  @callback enabled?() :: boolean()

  @doc ~S'''
  (선택) 확장이 자체 화면을 가지면 홈페이지 내 경로를 반환한다. 없으면 `nil`.

  카탈로그는 `home_path != nil` 이고 `enabled? == true` 일 때만 "열기" 링크를 노출한다.
  '''
  @callback home_path() :: String.t() | nil

  @doc ~S'(선택) 카탈로그 카드 아이콘(heroicon 이름 등). 없으면 `nil` → 기본 아이콘.'
  @callback icon() :: String.t() | nil

  @doc """
  (선택) 라우트 데이터 선언. 라우트를 기여하지 않으면 `nil`(EXT-2 처럼 백그라운드 확장).

  순수 데이터(`t:route_spec/0`)를 반환한다 — 외부 확장이 Router 모듈을 만들 필요가 없다.
  `OpenMes.Extension.RouterMount.mount_extension_routes/0` 매크로가 컴파일 타임에 펼친다.
  """
  @callback route_spec() :: route_spec() | nil

  @optional_callbacks [home_path: 0, icon: 0, route_spec: 0]

  @doc """
  알려진(코어가 라벨/아이콘/필터 UI 를 제공하는) 카테고리 목록.

  **검증 게이트가 아니다.** category 타입은 `atom()` 으로 개방되어 있으므로(설계 30 §2.2),
  이 목록에 없는 카테고리도 정상이다(외부 확장의 자유). `mix ext.verify` C6 은 이 목록을
  기준으로 **정보성 경고**만 낸다(실패 아님). 카탈로그는 known 이면 한국어 라벨, 미지면 atom
  폴백 라벨로 렌더한다.
  """
  @spec known_categories() :: [atom()]
  def known_categories,
    do: [:ingest, :media, :production, :quality, :traceability, :analytics, :integration]
end
