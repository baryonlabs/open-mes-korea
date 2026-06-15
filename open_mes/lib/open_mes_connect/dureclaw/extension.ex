defmodule OpenMes.Connect.DureClaw.Extension do
  @moduledoc """
  EXT-5 연동 허브 — DureClaw 의 카탈로그 메타데이터 모듈.

  `OpenMes.Extensions.Extension` behaviour 를 구현한다(설계 §1.1 계약).
  필수 6개(id/name/description/category/version/enabled?) + 화면이 있으므로 `home_path/0` override.
  `enabled?/0` 는 퍼사드 게이트(`OpenMes.Connect.DureClaw.enabled?/0`)에 위임한다.

  이 모듈은 **메타데이터만** 노출한다. 버스 조회/화면은 알지 않는다(레지스트리는 동작을 모름 — pi).
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :connect_dureclaw

  @impl true
  def name, do: "DureClaw 분산 오케스트레이션"

  @impl true
  def description,
    do:
      "분산 에이전트 협력 버스(DureClaw) 연동 — 이기종 fleet(엣지 Pi·GPU·Mac)의 presence·Work Key 를 관측하는 읽기 전용 연동 허브."

  @impl true
  def category, do: :integration

  @impl true
  def version, do: "0.1.0"

  @impl true
  def enabled?, do: OpenMes.Connect.DureClaw.enabled?()

  @impl true
  def home_path, do: "/extensions/dureclaw"
end
