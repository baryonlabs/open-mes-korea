defmodule OpenMesWeb.Router do
  @moduledoc """
  통합 router.ex (설계 §3.1, §4.4 — 10/skel/router.ex + 애드온 5개 scope 합산).

  배선 합산:
    - `:browser` 파이프라인(LiveView/HTML) — phx.new 기본
    - `:api` + `:require_actor` — 코어 02 WorkOrder API
    - `:require_device_token` — EXT-1
    - `/` `/extensions` → CatalogLive(카탈로그 홈)
    - 조건부 `/ingest`(EXT-1), `/media`(EXT-2 — MVP는 백그라운드라 라우트 없음)
    - 조건부 애드온 5개 LiveView scope (각자 enabled? 컴파일 타임 게이트)

  컴파일 타임 게이트(`if ...enabled?()`): off 면 라우트 테이블에 흔적조차 남지 않는다.
  테스트에서 라우트가 필요하면 config/test.exs 에서 해당 확장 enabled: true.

  비침투: 코어 `/api` scope 는 확장 enabled 여부와 무관하게 항상 등록된다.
  """
  use OpenMesWeb, :router

  # ── 파이프라인 ─────────────────────────────────────────────────────────
  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_actor do
    plug OpenMesWeb.Plugs.RequireActor
  end

  pipeline :require_device_token do
    plug OpenMesWeb.Plugs.RequireDeviceToken
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenMesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # ── 카탈로그(홈) ───────────────────────────────────────────────────────
  scope "/", OpenMesWeb do
    pipe_through :browser

    live "/", CatalogLive, :index
    live "/extensions", CatalogLive, :index
  end

  # ── 코어 작업지시 API (02) — 항상 등록 ─────────────────────────────────
  scope "/api", OpenMesWeb do
    pipe_through [:api, :require_actor]

    resources "/work_orders", WorkOrderController, only: [:index, :show, :create, :update]
    post "/work_orders/:id/release", WorkOrderController, :release
    post "/work_orders/:id/start", WorkOrderController, :start
    post "/work_orders/:id/complete", WorkOrderController, :complete
    post "/work_orders/:id/cancel", WorkOrderController, :cancel
  end

  # ── EXT-1 설비 수집 (06) — 활성 시에만 등록 ────────────────────────────
  if OpenMes.Ingest.enabled?() do
    scope "/ingest", OpenMesWeb do
      pipe_through [:api, :require_device_token]

      post "/equipment", IngestController, :create
      get "/health", IngestController, :health
    end
  end

  # ── EXT-2 멀티미디어 (07) — MVP 는 백그라운드 파이프라인 위주라 HTTP 라우트 없음.
  #    (자체 라우트가 추가되면 여기에 조건부 scope 로 등록)

  # ── 애드온 ① 작업지시 CSV 내보내기 ─────────────────────────────────────
  if OpenMes.Addons.WoCsvExport.Extension.enabled?() do
    scope "/extensions", OpenMesWeb.Addons do
      pipe_through :browser

      live "/wo-csv-export", WoCsvExportLive, :index
      get "/wo-csv-export/download", WoCsvExportController, :download
    end
  end

  # ── 애드온 ② 불량 통계 위젯 ────────────────────────────────────────────
  if OpenMes.Addons.DefectStats.Extension.enabled?() do
    scope "/extensions", OpenMesWeb.Addons do
      pipe_through :browser

      live "/defect-stats", DefectStatsLive, :index
    end
  end

  # ── 애드온 ③ LOT QR 라벨 생성 ──────────────────────────────────────────
  if OpenMes.Addons.LotQrLabel.Extension.enabled?() do
    scope "/extensions", OpenMesWeb.Addons do
      pipe_through :browser

      live "/lot-qr-label", LotQrLabelLive, :index
    end
  end

  # ── 애드온 ④ 설비 가동률 OEE ───────────────────────────────────────────
  if OpenMes.Addons.EquipmentOee.Extension.enabled?() do
    scope "/extensions", OpenMesWeb.Addons do
      pipe_through :browser

      live "/equipment-oee", EquipmentOeeLive, :index
    end
  end

  # ── 애드온 ⑤ 일일 생산 요약 ────────────────────────────────────────────
  #   주의: home_path 가 "/extensions/daily-production-summary" 이므로 경로를 정확히 일치시킨다.
  #   (10/skel/router.ex 주석은 "/daily-summary" 로 표기했으나 실제 애드온은 아래 경로다.)
  if OpenMes.Addons.DailyProductionSummary.Extension.enabled?() do
    scope "/extensions", OpenMesWeb.Addons do
      pipe_through :browser

      live "/daily-production-summary", DailyProductionSummaryLive, :index
    end
  end
end
