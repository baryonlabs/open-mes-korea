defmodule OpenMes.Addons.WoCsvExport.Extension do
  @moduledoc """
  작업지시 CSV 내보내기 애드온의 `Extension` behaviour 구현(메타데이터).

  레지스트리(`OpenMes.Extensions.Registry`)가 이 모듈의 콜백으로 카탈로그 카드를 그린다.
  실제 CSV 로직은 `OpenMes.Addons.WoCsvExport`(퍼사드) / `.Csv`(직렬화) 가 담당하며,
  이 모듈은 메타데이터 + 활성 게이트만 노출한다(설계 §1.1 — behaviour 는 메타데이터만 계약).

  `use OpenMes.Extensions.Definition` 가 선택 콜백(`icon/0`)의 기본값(nil)을 주입하므로,
  필수 6개(id/name/description/category/version/enabled?) + 화면 경로(home_path/0)만 구현한다.
  """
  use OpenMes.Extensions.Definition

  @impl true
  def id, do: :addon_wo_csv_export

  @impl true
  def name, do: "작업지시 CSV 내보내기"

  @impl true
  def description, do: "작업지시 목록을 상태/기간 필터로 조회해 CSV 파일로 내려받는다(읽기 전용)."

  @impl true
  def category, do: :production

  @impl true
  def version, do: "0.1.0"

  @impl true
  def enabled?, do: OpenMes.Addons.WoCsvExport.enabled?()

  # 자체 화면(필터 선택 + 다운로드)을 가지므로 home_path 를 override 한다.
  @impl true
  def home_path, do: "/extensions/wo-csv-export"
end
