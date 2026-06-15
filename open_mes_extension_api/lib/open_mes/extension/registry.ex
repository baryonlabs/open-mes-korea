defmodule OpenMes.Extension.Registry do
  @moduledoc """
  확장 레지스트리 — 등록된 확장의 메타데이터를 제공한다(계약 패키지 `open_mes_extension_api`).

  ## 설계(설계 30 §2.4)

    - **발견 방식**: `modules/0` 이 단일 진입점이다. 발견 모드(`:manual`/`:auto`)에 따라
      `Application.get_env(:extensions)`(명시 목록) 또는 `OpenMes.Extension.Discovery.all/0`
      (자동 발견)을 호출한다. 카탈로그·ext.verify 는 `Registry` 만 보므로 하류 변경 없음.
    - **상태 없음**: GenServer/ETS/DB 를 쓰지 않는다. config 조회 + 콜백 호출뿐인 순수 조회.
    - **얇은 코어 유틸**: 확장/카탈로그/Router 가 의존하는 공통 계약 선반이다.
      **코어 도메인(Production/WorkOrder/Audit/Outbox)은 이 모듈을 참조하지 않는다**(단방향).

  카탈로그(LiveView)와 라우터·ext.verify 가 유일한 소비자다.
  """

  alias OpenMes.Extension

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

  @doc """
  등록된 모든 확장 모듈 목록.

  발견 모드(`config :open_mes, :extension_discovery`)에 따라 분기한다:
    - `:manual` — `config :open_mes, :extensions` 명시 목록(현행 동작, 되돌리기 포인트).
    - `:auto`   — `OpenMes.Extension.Discovery.all/0` 자동 발견(deps 한 줄로 끝).

  기본값은 config 에서 `:auto`(설계 30 §5/§7-S5). 미설정 시 `:manual`(보수적 폴백 —
  발견 인프라 부재 환경에서도 안전). escape hatch 로 언제든 `:manual` 로 되돌릴 수 있다.
  """
  @spec modules() :: [module()]
  def modules do
    case Application.get_env(:open_mes, :extension_discovery, :manual) do
      :auto -> OpenMes.Extension.Discovery.all()
      _ -> Application.get_env(:open_mes, :extensions, [])
    end
  end

  @doc """
  등록된 모든 확장의 메타데이터 엔트리(enabled 무관 — 카탈로그가 비활성 카드도 표시).

  정렬: 카테고리 → 이름 순.
  """
  @spec all() :: [entry()]
  def all do
    modules()
    |> Enum.map(&to_entry/1)
    |> Enum.sort_by(&{to_string(&1.category), &1.name})
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

  # enabled?/0 가 config 미설정 등으로 raise 해도 카탈로그 전체가 깨지지 않도록 방어.
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
