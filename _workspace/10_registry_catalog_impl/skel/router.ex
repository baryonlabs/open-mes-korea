defmodule OpenMesWeb.Router do
  @moduledoc """
  통합 router.ex (설계 §3.1, §4.4).

  배선 합산:
    - 코어 `/api`(02 WorkOrder) — 기존 그대로
    - `:browser` 파이프라인(LiveView/HTML) — phx.new 기본
    - `/` `/extensions` → CatalogLive(카탈로그 홈, 이 기반 작업 신규)
    - 조건부 `/ingest`(06), `/media`(07) — 각 확장 enabled? 컴파일 타임 게이트
    - 조건부 애드온 LiveView scope(애드온 통합 시 추가, 이 기반 작업 범위 밖)

  컴파일 타임 게이트(`if ...enabled?()`)는 EXT-1 router 패턴 승계 — off 면 라우트 테이블에
  흔적조차 남지 않는다. 테스트에서 해당 라우트가 필요하면 config/test.exs 에서 enabled: true.
  """
  use OpenMesWeb, :router

  # ── 코어 API 파이프라인(02 승계) ────────────────────────────────────
  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_actor do
    plug OpenMesWeb.Plugs.RequireActor
  end

  # ── EXT-1 디바이스 토큰 파이프라인(06 router 패치) ──────────────────
  pipeline :require_device_token do
    plug OpenMesWeb.Plugs.RequireDeviceToken
  end

  # ── 브라우저(LiveView/HTML) 파이프라인 — phx.new 기본 ───────────────
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenMesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # ── 카탈로그(홈) ───────────────────────────────────────────────────
  scope "/", OpenMesWeb do
    pipe_through :browser

    live "/", CatalogLive, :index
    live "/extensions", CatalogLive, :index
  end

  # ── 코어 작업지시 API(02) — 기존 그대로 ────────────────────────────
  scope "/api", OpenMesWeb do
    pipe_through [:api, :require_actor]

    resources "/work_orders", WorkOrderController, only: [:index, :show, :create, :update]
    post "/work_orders/:id/release", WorkOrderController, :release
    post "/work_orders/:id/start", WorkOrderController, :start
    post "/work_orders/:id/complete", WorkOrderController, :complete
    post "/work_orders/:id/cancel", WorkOrderController, :cancel
  end

  # ── EXT-1 설비 수집(06) — 확장 활성 시에만 등록 ────────────────────
  if OpenMes.Ingest.enabled?() do
    scope "/ingest", OpenMesWeb do
      pipe_through [:api, :require_device_token]

      post "/equipment", IngestController, :create
      get "/health", IngestController, :health
    end
  end

  # ── EXT-2 멀티미디어(07) — 자체 HTTP 라우트가 있으면 여기에(CORE_PATCH 참조).
  #    MVP EXT-2 는 백그라운드 파이프라인 위주라 라우트가 없을 수 있다.

  # ── 애드온 LiveView scope (애드온 통합 시 추가, 각자 enabled? 게이트) ──
  # 설계 §4.4 — 각 애드온은 아래 블록을 한 덩어리씩 추가한다(이 기반 작업 범위 밖).
  #
  # if OpenMes.Addons.WoCsvExport.Extension.enabled?() do
  #   scope "/extensions", OpenMesWeb.Addons do
  #     pipe_through :browser
  #     live "/wo-csv-export", WoCsvExportLive, :index
  #     get "/wo-csv-export/download", WoCsvExportController, :download
  #   end
  # end
  #
  # if OpenMes.Addons.DefectStats.Extension.enabled?() do
  #   scope "/extensions", OpenMesWeb.Addons do
  #     pipe_through :browser
  #     live "/defect-stats", DefectStatsLive, :index
  #   end
  # end
  #
  # if OpenMes.Addons.LotQrLabel.Extension.enabled?() do
  #   scope "/extensions", OpenMesWeb.Addons do
  #     pipe_through :browser
  #     live "/lot-qr-label", LotQrLabelLive, :index
  #   end
  # end
  #
  # if OpenMes.Addons.EquipmentOee.Extension.enabled?() do
  #   scope "/extensions", OpenMesWeb.Addons do
  #     pipe_through :browser
  #     live "/equipment-oee", EquipmentOeeLive, :index
  #   end
  # end
  #
  # if OpenMes.Addons.DailyProductionSummary.Extension.enabled?() do
  #   scope "/extensions", OpenMesWeb.Addons do
  #     pipe_through :browser
  #     live "/daily-summary", DailyProductionSummaryLive, :index
  #   end
  # end
end
