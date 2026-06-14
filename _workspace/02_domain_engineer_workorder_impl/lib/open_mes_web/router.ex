defmodule OpenMesWeb.Router do
  @moduledoc """
  라우터.

  파이프라인 분리:
    - :api          — 공통(JSON accept). 읽기 라우트에 적용.
    - :require_actor — 쓰기 라우트에 추가 적용. X-Actor-Id 헤더를 강제(RequireActor plug).

  상태 전이는 동사형 하위 리소스(POST .../release 등)로 노출하여
  감사 action 명/이벤트명과 URL 이 1:1 로 매핑되도록 한다.
  """
  use OpenMesWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # 쓰기 전용 파이프라인: actor 강제
  pipeline :require_actor do
    plug OpenMesWeb.Plugs.RequireActor
  end

  # ── 읽기(GET): actor 불필요 ─────────────────────────────────
  scope "/api", OpenMesWeb do
    pipe_through :api

    get "/work_orders", WorkOrderController, :index
    get "/work_orders/:id", WorkOrderController, :show
  end

  # ── 쓰기(POST/PATCH): actor 필수 ────────────────────────────
  scope "/api", OpenMesWeb do
    pipe_through [:api, :require_actor]

    post "/work_orders", WorkOrderController, :create
    patch "/work_orders/:id", WorkOrderController, :update

    # 상태 전이(동사형 엔드포인트)
    post "/work_orders/:id/release", WorkOrderController, :release
    post "/work_orders/:id/start", WorkOrderController, :start
    post "/work_orders/:id/complete", WorkOrderController, :complete
    post "/work_orders/:id/cancel", WorkOrderController, :cancel
  end
end
