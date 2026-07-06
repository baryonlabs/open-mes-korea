defmodule OpenMes.Addons.DailyProductionSummary.Extension do
  @moduledoc """
  애드온 ⑤(일일 생산 요약)의 카탈로그 메타데이터 모듈.

  `OpenMes.Extension` behaviour 를 구현한다(설계 §1.1 계약).
  필수 6개(id/name/description/category/version/enabled?) + 화면이 있으므로 `home_path/0` override.
  `enabled?/0` 는 애드온 퍼사드 게이트(`OpenMes.Addons.DailyProductionSummary.enabled?/0`)에 위임한다.

  이 모듈은 **메타데이터만** 노출한다. 집계 로직/화면은 알지 않는다(레지스트리는 동작을 모름 — pi).
  """
  use OpenMes.Extension.Definition

  @impl true
  def id, do: :addon_daily_production_summary

  @impl true
  def name, do: "일일 생산 요약"

  @impl true
  def description,
    do:
      "선택한 날짜의 작업지시 진행/완료 건수와 품목별 양품/불량 수량을 한 장으로 보여주는 읽기 전용 요약."

  @impl true
  def category, do: :production

  @impl true
  def version, do: "0.1.0"

  # 애드온 퍼사드 게이트 재사용(config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: ...).
  @impl true
  def enabled?, do: OpenMes.Addons.DailyProductionSummary.enabled?()

  @impl true
  def home_path, do: "/extensions/daily-production-summary"

  # 라우트 데이터 선언(설계 30 §2.1) — live 1.
  @impl true
  def route_spec do
    %{
      scope: "/extensions",
      pipeline: :browser,
      routes: [
        {:live, "/daily-production-summary", OpenMesWeb.Addons.DailyProductionSummaryLive, :index}
      ]
    }
  end
end
