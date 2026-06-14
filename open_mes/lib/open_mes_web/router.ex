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
    - phx.new dev_routes(LiveDashboard) 보존

  컴파일 타임 게이트(`if ...enabled?()`): off 면 라우트 테이블에 흔적조차 남지 않는다.

  비침투: 코어 `/api` scope 는 확장 enabled 여부와 무관하게 항상 등록된다.
  """
  use OpenMesWeb, :router

  # ── 파이프라인 ─────────────────────────────────────────────────────────
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OpenMesWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_actor do
    plug OpenMesWeb.Plugs.RequireActor
  end

  pipeline :require_device_token do
    plug OpenMesWeb.Plugs.RequireDeviceToken
  end

  # ── 홈(/)·확장 카탈로그 ─────────────────────────────────────────────────
  # 루트는 생산현황 대시보드로 진입(MES 운영 시스템). 확장 카탈로그는 /extensions.
  scope "/", OpenMesWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/extensions", CatalogLive, :index
    # 확장 개발 가이드 — 앱 내 자기완결 페이지(외부 URL 의존 0).
    live "/extensions/guide", GuideLive, :index

    # 데모 역할(role) 전환 — LiveView 가 세션을 못 쓰므로 컨트롤러 경유(설계 §4.4).
    post "/session/role/:role", SessionController, :set_role
  end

  # ── 관리자 영역 (/admin) — MES 운영 프론트 (G1 기준정보) ──────────────
  # system-architecture.md "관리자 화면" 분리. 기존 `/`·`/extensions`(CatalogLive)와
  # 네임스페이스가 겹치지 않아 충돌 0. 세션 actor 는 on_mount 훅(AdminLive)이 주입한다.
  scope "/admin", OpenMesWeb.Admin.MasterData do
    pipe_through :browser

    # 기준정보 6종 — 각 Index/Form 통합(live_action :index/:new/:edit).
    live "/items", ItemLive, :index
    live "/items/new", ItemLive, :new
    live "/items/:id/edit", ItemLive, :edit

    live "/boms", BomLive, :index
    live "/boms/new", BomLive, :new
    live "/boms/:id/edit", BomLive, :edit

    live "/processes", ProcessLive, :index
    live "/processes/new", ProcessLive, :new
    live "/processes/:id/edit", ProcessLive, :edit

    live "/routings", RoutingLive, :index
    live "/routings/new", RoutingLive, :new
    live "/routings/:id/edit", RoutingLive, :edit

    live "/equipment", EquipmentLive, :index
    live "/equipment/new", EquipmentLive, :new
    live "/equipment/:id/edit", EquipmentLive, :edit

    live "/workers", WorkerLive, :index
    live "/workers/new", WorkerLive, :new
    live "/workers/:id/edit", WorkerLive, :edit
  end

  # ── 관리자 영역 (/admin) — 설정 (생산라인 구성) ───────────────────────
  # 라인 모니터의 정규식 하드코딩을 대체하는 설정 데이터 편집(설계 22번). 모든 쓰기는
  # ProductionLine 컨텍스트 경유(AuditLog). 세션 actor 는 AdminLive on_mount 주입.
  # 27번 신규 — 지식베이스(OKF) export/import 컨트롤러(파일 다운로드/업로드).
  # live "/settings/knowledge/:id" 보다 먼저 등록해 "export" 가 :id 로 캡처되지 않게 한다.
  scope "/admin", OpenMesWeb do
    pipe_through :browser

    get "/settings/knowledge/export", KnowledgeExportController, :export
    post "/settings/knowledge/import", KnowledgeImportController, :import
    get "/settings/knowledge/:id/export", KnowledgeExportController, :export_one
  end

  scope "/admin", OpenMesWeb.Admin.Settings do
    pipe_through :browser

    # 27번 신규 — 지식베이스(OKF 문서) CRUD LiveView.
    live "/settings/knowledge", KnowledgeLive, :index
    live "/settings/knowledge/new", KnowledgeLive, :new
    live "/settings/knowledge/:id", KnowledgeLive, :show
    live "/settings/knowledge/:id/edit", KnowledgeLive, :edit

    live "/settings/lines", ProductionLineLive, :index
    live "/settings/lines/new", ProductionLineLive, :new
    live "/settings/lines/:id/edit", ProductionLineLive, :edit
    live "/settings/lines/:id/steps", ProductionLineStepLive, :index
    live "/settings/lines/:id/steps/new", ProductionLineStepLive, :new
    live "/settings/lines/:id/steps/:step_id/edit", ProductionLineStepLive, :edit

    # 23번 신규 — AI 라인 구성(실동작) + skill/mcp/connector(스텁)
    live "/settings/ai-line", AiLineLive, :index
    live "/settings/skills", SkillSettingsLive, :index
    live "/settings/mcp", McpSettingsLive, :index
    live "/settings/connectors", ConnectorSettingsLive, :index
  end

  # ── 관리자 영역 (/admin) — AI 조사 (25번, Level 1 Read-only) ────────────
  # 시계열+미디어+생산 종합 조사. 모든 조사는 OpenMes.Ai.Investigation 경유
  # (AiInteraction(query) + AuditLog). 쓰기 0 — 읽기 전용. 세션 actor 는 AdminLive on_mount 주입.
  scope "/admin", OpenMesWeb.Admin.Ai do
    pipe_through :browser

    live "/ai/investigate", InvestigateLive, :index
  end

  # ── 관리자 영역 (/admin) — 생산관리 (G2) ──────────────────────────────
  # WorkOrder 목록/생성/상세/상태전이 + 공정 실적 입력. 모든 쓰기는 Production
  # 컨텍스트 경유(AuditLog/Outbox/상태머신). 세션 actor 는 AdminLive on_mount 주입.
  scope "/admin", OpenMesWeb.Admin.Production do
    pipe_through :browser

    live "/work-orders", WorkOrderLive, :index
    live "/work-orders/new", WorkOrderLive, :new
    live "/work-orders/:id", WorkOrderLive, :show
    live "/work-orders/:id/operations", OperationLive, :index
  end

  # ── 관리자 영역 (/admin) — LOT 추적 (G3) ──────────────────────────────
  # 자재 LOT 등록 / LOT 투입(consume_lot = LotConsumption) / 제품 LOT 생성(produce) /
  # LOT 계보(genealogy) 조회. 모든 쓰기는 Lots 컨텍스트 경유(AuditLog/Outbox/LotConsumption).
  scope "/admin", OpenMesWeb.Admin.Lots do
    pipe_through :browser

    live "/lots", LotLive, :index
    live "/lots/:id/genealogy", GenealogyLive, :show
  end

  # ── 관리자 영역 (/admin) — 조회/대시보드 (G5) ─────────────────────────
  # 전부 읽기 전용(도메인 쓰기 0, AuditLog 무관). 집계는 컨텍스트 읽기 함수/Reports 모듈 경유.
  # 생산현황/공정별실적/불량현황/재고흐름/LOT 이력. 외부 차트 없이 표+CSS 막대.
  scope "/admin", OpenMesWeb.Admin.Reports do
    pipe_through :browser

    live "/dashboard", DashboardLive, :index
    live "/reports/production", ProductionReportLive, :index
    live "/reports/defects", DefectsReportLive, :index
    live "/reports/inventory", InventoryReportLive, :index
    live "/reports/lots", LotHistoryLive, :index
  end

  # ── 관리자 영역 (/admin) — 관리자(시스템) (G6) ────────────────────────
  # 감사 로그 조회(읽기 전용 — AuditLog 목록/필터) + 사용자/권한(MVP 간이 — Worker 표시).
  scope "/admin", OpenMesWeb.Admin.System do
    pipe_through :browser

    live "/audit-logs", AuditLogLive, :index
    live "/users", UserLive, :index
  end

  # ── 현장 영역 (/shopfloor) — 현장 화면 (G4) ────────────────────────────
  # 별도 현장 레이아웃(대형 버튼·큰 글씨·태블릿 터치 UX). admin 사이드바와 분리.
  # 작업 시작/종료(Operation 상태전이), 실적 입력(ProductionResult/DefectRecord),
  # LOT 스캔 투입(consume_lot). 모든 쓰기는 Production/Lots 컨텍스트 경유.
  scope "/shopfloor", OpenMesWeb.Shopfloor do
    pipe_through :browser

    live "/", TodayLive, :index
    live "/operations/:id", OperationLive, :show
    live "/operations/:id/result", ResultLive, :show
    live "/scan", ScanLive, :index
  end

  # ── 코어 작업지시 API (02) — 항상 등록 ─────────────────────────────────
  # 조회(index/show)는 actor 헤더가 필요 없다(읽기 경로). 쓰기(create/update/전이)만
  # `:require_actor` 를 통과해 AuditLog actor 를 강제한다.
  scope "/api", OpenMesWeb do
    pipe_through :api

    resources "/work_orders", WorkOrderController, only: [:index, :show]
  end

  scope "/api", OpenMesWeb do
    pipe_through [:api, :require_actor]

    resources "/work_orders", WorkOrderController, only: [:create, :update]
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
  if OpenMes.Addons.DailyProductionSummary.Extension.enabled?() do
    scope "/extensions", OpenMesWeb.Addons do
      pipe_through :browser

      live "/daily-production-summary", DailyProductionSummaryLive, :index
    end
  end

  # ── phx.new dev_routes (LiveDashboard) — 개발 환경 보존 ─────────────────
  if Application.compile_env(:open_mes, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OpenMesWeb.Telemetry
    end
  end
end
