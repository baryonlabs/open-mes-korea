defmodule OpenMesWeb.Admin.Settings.ConnectorSettingsLive do
  @moduledoc """
  설정 — Connector 설정(EXT-5 연동 허브 진입점, 설계 23번 §B.4, 2순위 스텁).

  외부 시스템(ERP/디지털트윈/CSV/시뮬레이션/위키/RAG/DB) 연동 카탈로그 진입점. 실제 연결은 후속.
  데이터 소스(위키·DB) → RAG 문서 검색 → AI 인용(ai-native-architecture RAG 문서 영역) 흐름으로 AI 연동과 연결된다.
  """
  use OpenMesWeb.Admin.AdminLive

  @categories [
    %{name: "파일 (CSV/Excel)", desc: "정적 파일 업로드/내보내기 연동", badge: "MVP-1"},
    %{name: "REST / Webhook", desc: "외부 시스템 HTTP API 연동", badge: "MVP-2"},
    %{name: "산업 프로토콜 (OPC-UA/Modbus)", desc: "설비 직접 수집 — EXT-1 합류", badge: "후순위"},
    %{name: "디지털트윈", desc: "라인 시뮬레이션/가상화 연동", badge: "후순위"},
    %{name: "시뮬레이션", desc: "What-if 생산 시나리오 연동", badge: "후순위"},
    %{name: "문서 위키 (Wiki)", desc: "Confluence/Notion/MediaWiki — 표준작업서·설비 매뉴얼 문서 소스", badge: "문서"},
    %{name: "RAG 문서 검색", desc: "위키·표준문서를 AI가 검색·인용 (RAG 문서 영역, 생산 데이터와 분리)", badge: "AI"},
    %{name: "데이터베이스", desc: "외부 DB(PostgreSQL/MySQL/Oracle) — ERP·레거시 데이터 연동", badge: "데이터"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Connector 설정", categories: @categories)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header
        title="Connector 설정"
        subtitle="외부 시스템 연동 허브(EXT-5) 진입점. 인바운드 데이터는 EXT-1 수집 경로로 합류합니다."
      />

      <div class="mb-4 rounded-md border border-zinc-200 bg-zinc-50 p-3 text-sm text-zinc-600">
        외부 시스템(ERP/디지털트윈/CSV) 연동은 EXT-5 연동 허브에서 관리됩니다.
        <.link navigate="/extensions" class="font-medium text-indigo-600 hover:underline">확장 카탈로그 →</.link>
      </div>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <div :for={c <- @categories} class="rounded-lg border border-zinc-200 bg-white p-4">
          <div class="mb-1 flex items-center justify-between">
            <h3 class="text-sm font-semibold text-zinc-900">{c.name}</h3>
            <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[11px] font-medium text-zinc-600">
              {c.badge}
            </span>
          </div>
          <p class="text-xs text-zinc-500">{c.desc}</p>
        </div>
      </div>
    </.admin_shell>
    """
  end
end
