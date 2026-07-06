defmodule OpenMes.Media.Extension do
  @moduledoc """
  EXT-2(멀티미디어 수집)의 카탈로그 메타데이터 모듈.

  설계 §4.4 — 통합 시 **신규 추가**되는 얇은 메타데이터 모듈이다.
  기존 EXT-2 코드(`OpenMes.Media.*`)는 **일절 변경하지 않는다.**
  `enabled?/0` 는 EXT-2 의 기존 게이트 `OpenMes.Media.enabled?/0` 에 그대로 위임한다.

  EXT-2 는 자체 HTML 화면이 없으므로(NAS 폴링 → object storage 이관 백그라운드 파이프라인)
  `home_path/0` 는 기본값 nil 을 유지한다 → 카탈로그에서 "열기" 링크 없이 카드만 노출된다.
  """
  use OpenMes.Extension.Definition

  @impl true
  def id, do: :ext_media

  @impl true
  def name, do: "멀티미디어 수집"

  @impl true
  def description,
    do: "NAS 폴링 감지 → object storage 이관 + 메타데이터 적재(소음/영상 등 대용량 바이너리)."

  @impl true
  def category, do: :media

  @impl true
  def version, do: "0.1.0"

  # 기존 EXT-2 게이트 재사용(config :open_mes, OpenMes.Media, enabled: ...).
  @impl true
  def enabled?, do: OpenMes.Media.enabled?()

  # home_path 는 기본값 nil — EXT-2 는 백그라운드 파이프라인이라 자체 화면이 없다.
end
