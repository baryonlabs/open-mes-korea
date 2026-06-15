defmodule OpenMesWeb.WorkOrderJSON do
  @moduledoc """
  작업지시 응답 직렬화(JSON view).

  planned_quantity 는 decimal 정밀도 보존을 위해 문자열로 직렬화한다.
  """
  alias OpenMes.Production.WorkOrder

  @doc "목록 응답"
  def index(%{work_orders: work_orders}) do
    %{data: for(wo <- work_orders, do: data(wo))}
  end

  @doc "단건 응답"
  def show(%{work_order: work_order}) do
    %{data: data(work_order)}
  end

  defp data(%WorkOrder{} = wo) do
    %{
      id: wo.id,
      work_order_no: wo.work_order_no,
      item_id: wo.item_id,
      # 정밀도 보존을 위해 문자열로 직렬화
      planned_quantity: decimal_to_string(wo.planned_quantity),
      due_date: wo.due_date,
      status: wo.status,
      released_at: wo.released_at,
      started_at: wo.started_at,
      completed_at: wo.completed_at,
      cancelled_at: wo.cancelled_at,
      inserted_at: wo.inserted_at,
      updated_at: wo.updated_at
    }
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
end
