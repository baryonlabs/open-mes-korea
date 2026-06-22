defmodule OpenMes.Addons.CadBom.Extension do
  @moduledoc """
  CAD 견적 BOM 애드온의 `Extension` behaviour 구현(메타데이터).

  레지스트리(`OpenMes.Extensions.Registry`)가 이 콜백으로 카탈로그 카드를 그린다.
  실제 로직은 `OpenMes.Addons.CadBom`(퍼사드) / `.Parser` / `.Classifier` / `.Csv` 가 담당하고,
  이 모듈은 메타데이터 + 활성 게이트만 노출한다(설계 §1.1).
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :addon_cad_bom

  @impl true
  def name, do: "CAD 견적 BOM"

  @impl true
  def description,
    do: "CAD 도면 인덱스(도번·도면명·분류)로 통합 BOM 을 만들고, 부품을 발주 공정별로 분류해 업체 견적용 BOM 을 내려받는다."

  @impl true
  def category, do: :production

  @impl true
  def version, do: "0.1.0"

  @impl true
  def enabled?, do: OpenMes.Addons.CadBom.enabled?()

  @impl true
  def home_path, do: "/extensions/cad-bom"
end
