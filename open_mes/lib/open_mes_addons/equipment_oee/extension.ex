defmodule OpenMes.Addons.EquipmentOee.Extension do
  @moduledoc """
  애드온 ④(설비 가동률 OEE 계산)의 카탈로그 메타데이터 모듈.

  `OpenMes.Extensions.Extension` behaviour 를 구현한다(설계 §1.1 계약).
  필수 6개(id/name/description/category/version/enabled?) + 화면이 있으므로 `home_path/0` override.
  `enabled?/0` 는 애드온 퍼사드 게이트(`OpenMes.Addons.EquipmentOee.enabled?/0`)에 위임한다.

  이 모듈은 **메타데이터만** 노출한다. 계산 로직/화면은 알지 않는다(레지스트리는 동작을 모름 — pi).
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :addon_equipment_oee

  @impl true
  def name, do: "설비 가동률 OEE"

  @impl true
  def description,
    do: "설비별·기간별 OEE(가용성 × 성능 × 품질)를 코어 생산 실적에서 계산하는 읽기 전용 위젯."

  @impl true
  def category, do: :analytics

  @impl true
  def version, do: "0.1.0"

  # 애드온 퍼사드 게이트 재사용(config :open_mes, OpenMes.Addons.EquipmentOee, enabled: ...).
  @impl true
  def enabled?, do: OpenMes.Addons.EquipmentOee.enabled?()

  @impl true
  def home_path, do: "/extensions/equipment-oee"
end
