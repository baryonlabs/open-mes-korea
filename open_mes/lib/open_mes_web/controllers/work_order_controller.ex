defmodule OpenMesWeb.WorkOrderController do
  @moduledoc """
  작업지시 API 컨트롤러.

  책임은 얇게 유지한다: 파라미터 파싱, actor 추출(plug 가 주입한 conn.assigns.actor_id),
  컨텍스트 호출, 상태코드 매핑. 비즈니스 로직(상태 전이/AuditLog/Outbox)은 전부 Production 컨텍스트가 담당.

  상태 전이는 동사형 하위 리소스(POST .../release 등)로 분리되어 감사 action/이벤트명과 1:1 매핑된다.
  """
  use OpenMesWeb, :controller

  alias OpenMes.Production
  alias OpenMes.Production.WorkOrder

  action_fallback OpenMesWeb.FallbackController

  # ── 조회(읽기) ──────────────────────────────────────────────

  def index(conn, params) do
    work_orders = Production.list_work_orders(params)
    render(conn, :index, work_orders: work_orders)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %WorkOrder{} = wo} <- Production.fetch_work_order(id) do
      render(conn, :show, work_order: wo)
    end
  end

  # ── 생성/수정(쓰기) ─────────────────────────────────────────

  def create(conn, %{"work_order" => params}) do
    with {:ok, %WorkOrder{} = wo} <-
           Production.create_work_order(params, conn.assigns.actor_id) do
      conn
      |> put_status(:created)
      |> render(:show, work_order: wo)
    end
  end

  def update(conn, %{"id" => id, "work_order" => params}) do
    with {:ok, %WorkOrder{} = wo} <-
           Production.update_work_order(id, params, conn.assigns.actor_id) do
      render(conn, :show, work_order: wo)
    end
  end

  # ── 상태 전이(쓰기, 동사형 엔드포인트) ──────────────────────

  def release(conn, %{"id" => id}),
    do: transition(conn, Production.release_work_order(id, conn.assigns.actor_id))

  def start(conn, %{"id" => id}),
    do: transition(conn, Production.start_work_order(id, conn.assigns.actor_id))

  def complete(conn, %{"id" => id}),
    do: transition(conn, Production.complete_work_order(id, conn.assigns.actor_id))

  def cancel(conn, %{"id" => id}),
    do: transition(conn, Production.cancel_work_order(id, conn.assigns.actor_id))

  # 전이 결과 공통 처리(성공 200 / 실패는 fallback 위임)
  defp transition(conn, {:ok, %WorkOrder{} = wo}),
    do: render(conn, :show, work_order: wo)

  defp transition(conn, {:error, _} = error),
    do: OpenMesWeb.FallbackController.call(conn, error)
end
