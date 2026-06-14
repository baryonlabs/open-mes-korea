defmodule OpenMes.Ingest.Extension do
  @moduledoc """
  EXT-1(설비 데이터 수집)의 카탈로그 메타데이터 모듈.

  설계 §4.4 — 통합 시 **신규 추가**되는 얇은 메타데이터 모듈이다.
  기존 EXT-1 파이프라인 코드(`OpenMes.Ingest.*`)는 **일절 변경하지 않는다.**
  `enabled?/0` 는 EXT-1 의 기존 게이트 `OpenMes.Ingest.enabled?/0` 에 그대로 위임한다.
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :ext_ingest

  @impl true
  def name, do: "설비 데이터 수집"

  @impl true
  def description,
    do: "브로커리스 HTTP push → Broadway → TimescaleDB 적재(고빈도 텔레메트리)."

  @impl true
  def category, do: :ingest

  @impl true
  def version, do: "0.1.0"

  # 기존 EXT-1 게이트 재사용(config :open_mes, OpenMes.Ingest, enabled: ...).
  @impl true
  def enabled?, do: OpenMes.Ingest.enabled?()

  @impl true
  def home_path, do: "/ingest/health"
end
