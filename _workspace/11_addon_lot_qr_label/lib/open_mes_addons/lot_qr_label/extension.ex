defmodule OpenMes.Addons.LotQrLabel.Extension do
  @moduledoc """
  애드온③ LOT QR 라벨 생성의 카탈로그 메타데이터 모듈.

  `OpenMes.Extensions.Extension` behaviour 를 구현하여 홈페이지 확장 카탈로그
  (`OpenMesWeb.CatalogLive`)에 카드로 노출된다(설계 §1.1, §3).

  필수 콜백 6개(id/name/description/category/version/enabled?) + 화면 경로(home_path).
  `enabled?/0` 는 애드온 퍼사드 게이트 `OpenMes.Addons.LotQrLabel.enabled?/0` 에 위임한다.

  분류는 `:traceability`(추적) — LOT 식별/라벨링은 추적성 도메인이다.
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :addon_lot_qr_label

  @impl true
  def name, do: "LOT QR 라벨 생성"

  @impl true
  def description,
    do: "MaterialLot 의 lot_no 를 QR 코드 라벨(인쇄용)로 생성한다. 읽기 전용."

  @impl true
  def category, do: :traceability

  @impl true
  def version, do: "0.1.0"

  # 애드온 게이트 재사용(config :open_mes, OpenMes.Addons.LotQrLabel, enabled: ...).
  @impl true
  def enabled?, do: OpenMes.Addons.LotQrLabel.enabled?()

  @impl true
  def home_path, do: "/extensions/lot-qr-label"
end
