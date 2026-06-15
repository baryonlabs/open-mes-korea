defmodule OpenMes.Addons.DefectStats.Extension do
  @moduledoc """
  애드온 ②(불량 통계 위젯)의 카탈로그 메타데이터 모듈.

  `OpenMes.Extensions.Extension` behaviour 를 구현한다(설계 §1.1 계약).
  필수 6개(id/name/description/category/version/enabled?) + 화면이 있으므로 `home_path/0` override.
  `enabled?/0` 는 애드온 퍼사드 게이트(`OpenMes.Addons.DefectStats.enabled?/0`)에 위임한다.

  이 모듈은 **메타데이터만** 노출한다. 집계 로직/화면은 알지 않는다(레지스트리는 동작을 모름 — pi).
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :addon_defect_stats

  @impl true
  def name, do: "불량 통계 위젯"

  @impl true
  def description,
    do: "불량 유형별 수량/비율과 기간별 불량률을 집계해 보여주는 읽기 전용 위젯."

  @impl true
  def category, do: :quality

  @impl true
  def version, do: "0.1.0"

  # 애드온 퍼사드 게이트 재사용(config :open_mes, OpenMes.Addons.DefectStats, enabled: ...).
  @impl true
  def enabled?, do: OpenMes.Addons.DefectStats.enabled?()

  @impl true
  def home_path, do: "/extensions/defect-stats"
end
