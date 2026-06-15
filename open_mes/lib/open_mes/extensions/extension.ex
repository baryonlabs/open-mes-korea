defmodule OpenMes.Extensions.Extension do
  @moduledoc """
  확장 모듈 공통 계약(behaviour).

  EXT-1(설비수집), EXT-2(멀티미디어), 도메인 애드온 5개가 모두 이 behaviour 를 구현한다.
  레지스트리(`OpenMes.Extensions.Registry`)는 이 콜백들을 통해 각 확장의 메타데이터를
  수집하고, 홈페이지 카탈로그(`OpenMesWeb.CatalogLive`)는 그 목록을 카드로 렌더한다.

  핵심 원칙(설계 §1.1):
    - 이 behaviour 는 **"메타데이터 노출"만** 계약한다. 확장의 실제 동작(파이프라인/연산/화면)은
      각 확장 내부의 책임이며, 레지스트리는 동작을 알 필요가 없다(설치 시스템이 아님 — pi).
    - 이 계약은 **안정적**이어야 한다. 애드온 구현자는 이 시그니처만 보고 자기 확장을 만든다.

  ## 애드온 구현자가 따를 계약(요약)

  필수 콜백 6개:
    - `id/0`          : 확장 고유 식별자(영문 atom, 안정적)
    - `name/0`        : 사람이 읽는 이름(한국어)
    - `description/0` : 한 줄 설명(한국어)
    - `category/0`    : 분류(`t:category/0`)
    - `version/0`     : 버전 문자열
    - `enabled?/0`    : 활성 여부(config 게이트)

  선택 콜백 2개(`OpenMes.Extensions.Definition` 가 기본값 nil 주입):
    - `home_path/0`   : 자체 화면 경로(없으면 nil)
    - `icon/0`        : 카탈로그 카드 아이콘(없으면 nil → 기본 아이콘)

  구현 보일러플레이트 최소화를 위해 `use OpenMes.Extensions.Definition` 를 권장한다.
  그러면 선택 콜백 기본값(nil)이 자동 주입되어 필수 6개만 구현하면 된다.
  """

  @typedoc """
  확장 분류. 카탈로그 카테고리 필터에 사용한다.

    - `:ingest`       — 설비 데이터 수집(EXT-1)
    - `:media`        — 멀티미디어 수집(EXT-2)
    - `:production`   — 생산
    - `:quality`      — 품질
    - `:traceability` — 추적
    - `:analytics`    — 분석
  """
  @type category :: :ingest | :media | :production | :quality | :traceability | :analytics

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
  """
  @callback enabled?() :: boolean()

  @doc ~S'''
  (선택) 확장이 자체 화면을 가지면 홈페이지 내 경로를 반환한다. 없으면 `nil`.

  예: `"/extensions/wo-csv-export"`, `"/ingest/health"`.
  카탈로그는 `home_path != nil` 이고 `enabled? == true` 일 때만 "열기" 링크를 노출한다.
  '''
  @callback home_path() :: String.t() | nil

  @doc ~S'(선택) 카탈로그 카드 아이콘(heroicon 이름 등). 없으면 `nil` → 기본 아이콘.'
  @callback icon() :: String.t() | nil

  # home_path / icon 은 선택 콜백 — Definition 매크로가 기본 구현(nil)을 제공한다.
  @optional_callbacks [home_path: 0, icon: 0]

  @doc """
  유효 카테고리 목록(검증·카탈로그 라벨·가이드 공용 단일 출처).

  `t:category/0` union 과 일치한다. `mix ext.verify` 의 C6(카테고리 유효성)은
  이 함수를 기준으로 판정하며, 새 분류(예: `:integration`)를 추가할 때는 여기 한 줄만 늘린다.
  검증/카탈로그/가이드가 이 함수를 단일 출처로 따라온다(pi).
  """
  @spec categories() :: [category()]
  def categories, do: [:ingest, :media, :production, :quality, :traceability, :analytics]
end
