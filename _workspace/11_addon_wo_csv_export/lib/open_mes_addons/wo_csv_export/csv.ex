defmodule OpenMes.Addons.WoCsvExport.Csv do
  @moduledoc """
  작업지시 → CSV 직렬화(읽기 전용, 순수 함수).

  의존성 정책(pi, 설계 §2 비고):
    외부 CSV 라이브러리를 쓰지 않고 **직접 인코딩**한다. CSV 이스케이프 규칙은 단순하므로
    deps 0 으로 정확히 구현한다. 단 따옴표/쉼표/개행 이스케이프는 RFC 4180 을 정확히 따른다.

  RFC 4180 이스케이프 규칙:
    - 필드에 `,`(쉼표) · `"`(따옴표) · `\\r` · `\\n` 중 하나라도 있으면 필드 전체를 `"` 로 감싼다.
    - 필드 내부의 `"` 는 `""` 로 이중화한다.
    - 그 외 필드는 그대로 둔다.
    - 행 구분자는 CRLF(`\\r\\n`) — 엑셀 호환성.

  컬럼(설계 §2 애드온 ①): 작업지시번호, 품목, 계획수량, 납기일, 상태, 생성일.

  비고 — "품목" 컬럼:
    현재 코어에는 `Item` 스키마/`items` 테이블이 아직 없다(WorkOrder.item_id 는 단순
    binary_id 컬럼, `work_order.ex` L26-27). 그래서 "품목" 컬럼은 `item_id` 값을 출력한다.
    추후 Item 조인이 생기면 `work_order_to_row/1` 의 품목 추출만 교체하면 된다(다른 코드 무변경).
  """

  alias OpenMes.Production.WorkOrder

  @headers ["작업지시번호", "품목", "계획수량", "납기일", "상태", "생성일"]

  # WorkOrder.status(영문) → 한국어 라벨. 미정의 상태는 원문 그대로.
  @status_labels %{
    "draft" => "초안",
    "released" => "확정",
    "in_progress" => "진행중",
    "completed" => "완료",
    "cancelled" => "취소"
  }

  @doc "CSV 헤더 컬럼(테스트/외부 노출용)."
  @spec headers() :: [String.t()]
  def headers, do: @headers

  @doc """
  작업지시 목록을 CSV iodata 로 인코딩한다(헤더 1행 + 데이터 N행).

  목록이 비어도 헤더 행은 항상 포함된다(빈 CSV 도 컬럼 구조를 가진다).
  """
  @spec encode_work_orders([WorkOrder.t()] | [struct()]) :: iodata()
  def encode_work_orders(work_orders) when is_list(work_orders) do
    rows = [@headers | Enum.map(work_orders, &work_order_to_row/1)]

    rows
    |> Enum.map(&encode_row/1)
    |> Enum.intersperse("\r\n")
    # 마지막 행 뒤에도 CRLF 를 붙여 엑셀/파서 호환성을 높인다.
    |> then(&[&1, "\r\n"])
  end

  @doc "단일 작업지시 → CSV 셀 문자열 리스트(컬럼 순서 = @headers)."
  @spec work_order_to_row(struct()) :: [String.t()]
  def work_order_to_row(%{} = wo) do
    [
      to_cell(Map.get(wo, :work_order_no)),
      to_cell(Map.get(wo, :item_id)),
      decimal_cell(Map.get(wo, :planned_quantity)),
      date_cell(Map.get(wo, :due_date)),
      status_cell(Map.get(wo, :status)),
      datetime_cell(Map.get(wo, :inserted_at))
    ]
  end

  # ── 한 행 인코딩(필드 이스케이프 + 쉼표 결합) ──────────────────────────
  defp encode_row(cells) do
    cells
    |> Enum.map(&escape_field/1)
    |> Enum.intersperse(",")
  end

  @doc """
  RFC 4180 필드 이스케이프.

  필드에 쉼표/따옴표/개행이 있으면 따옴표로 감싸고 내부 따옴표는 이중화한다.
  (테스트가 직접 호출하므로 공개한다.)
  """
  @spec escape_field(String.t()) :: String.t()
  def escape_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      escaped = String.replace(value, "\"", "\"\"")
      "\"" <> escaped <> "\""
    else
      value
    end
  end

  # ── 셀 값 변환(타입별) ───────────────────────────────────────────────

  defp to_cell(nil), do: ""
  defp to_cell(value) when is_binary(value), do: value
  defp to_cell(value), do: to_string(value)

  defp decimal_cell(nil), do: ""
  defp decimal_cell(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_cell(value), do: to_string(value)

  defp date_cell(nil), do: ""
  defp date_cell(%Date{} = d), do: Date.to_iso8601(d)
  defp date_cell(value), do: to_string(value)

  defp datetime_cell(nil), do: ""
  defp datetime_cell(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp datetime_cell(%NaiveDateTime{} = ndt),
    do: ndt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

  defp datetime_cell(value), do: to_string(value)

  # 상태는 한국어 라벨로 변환(미정의 상태는 원문 유지).
  defp status_cell(nil), do: ""
  defp status_cell(status) when is_binary(status), do: Map.get(@status_labels, status, status)
  defp status_cell(status), do: to_string(status)
end
