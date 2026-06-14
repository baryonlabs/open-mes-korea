defmodule OpenMes.Extensions.Registry do
  @moduledoc """
  확장 레지스트리 — config 명시 목록(`:extensions`)을 읽어 각 확장의 메타데이터를 제공한다.

  ## 설계(§1.2, §1.3, §1.4)

    - **발견 방식**: 동적 발견/모듈 스캔이 아니라 `config :open_mes, :extensions, [...]` 의
      **명시 목록**을 읽는다. "이 시스템에 어떤 확장이 있는가?"를 config 한 곳에서 답한다(pi).
    - **상태 없음**: GenServer/ETS/DB 를 사용하지 않는다. config 조회 + 각 모듈 콜백 호출뿐인
      순수 조회 모듈이다(설치 시스템이 아니므로 영속 상태 불필요).
    - **얇은 코어 유틸**: 이 모듈은 확장들이 의존하는 공통 계약 선반이다. **코어 도메인
      (`OpenMes.Production`/`WorkOrder`/`Audit`/`Outbox`)은 이 모듈을 참조하지 않는다.**
      의존 방향: 확장/카탈로그 → Registry ← 확장(단방향).

  카탈로그(LiveView)와 라우터가 유일한 소비자다.

    - "등록되고 활성인 확장 목록" → `enabled/0`
    - "등록된 전체(비활성 포함)"   → `all/0` (카탈로그는 비활성 카드도 보여줌)
    - "카테고리별 그룹"            → `by_category/0`
  """

  alias OpenMes.Extensions.Extension

  @typedoc "한 확장의 메타데이터 엔트리. 카탈로그가 카드로 렌더하는 단위."
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

  @doc "config 에 등록된 모든 확장 모듈 목록."
  @spec modules() :: [module()]
  def modules, do: Application.get_env(:open_mes, :extensions, [])

  @doc """
  등록된 모든 확장의 메타데이터 엔트리.

  enabled 여부와 무관하게 전체를 반환한다(카탈로그가 비활성 카드도 표시해야 하므로).
  정렬: 카테고리 → 이름 순.
  """
  @spec all() :: [entry()]
  def all do
    modules()
    |> Enum.map(&to_entry/1)
    |> Enum.sort_by(&{&1.category, &1.name})
  end

  @doc "`enabled? == true` 인 확장만."
  @spec enabled() :: [entry()]
  def enabled, do: Enum.filter(all(), & &1.enabled)

  @doc "카테고리별 그룹(`%{category => [entry()]}`)."
  @spec by_category() :: %{Extension.category() => [entry()]}
  def by_category, do: Enum.group_by(all(), & &1.category)

  # ── 내부 ────────────────────────────────────────────────────────────

  @spec to_entry(module()) :: entry()
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

  # 한 확장의 enabled?/0 가 config 미설정 등으로 raise 해도 카탈로그 전체가 깨지지
  # 않도록 방어한다(설계 §1.3, §6 견고성 검증). 예외 시 비활성으로 간주.
  @spec safe_enabled?(module()) :: boolean()
  defp safe_enabled?(mod) do
    mod.enabled?()
  rescue
    _ -> false
  end

  # 선택 콜백 호출. 미구현(또는 nil) 이면 nil 을 반환한다.
  @spec maybe(module(), atom()) :: term()
  defp maybe(mod, fun) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: nil
  end
end
