defmodule OpenMes.Application do
  @moduledoc """
  통합 application.ex (설계 §4.4, 10/skel/application.ex 승계).

  phx.new 산출물을 기준으로 확장 배선만 추가한다:
    - children 리스트 끝에 `++ ingest_children() ++ media_children()`
    - private 게이트 함수 `ingest_children/0`, `media_children/0`

  애드온 5개는 supervised child 가 없다(읽기 전용 LiveView/쿼리뿐, 백그라운드 프로세스 0).
  레지스트리/카탈로그도 supervised child 가 없다(상태 없는 순수 조회 모듈 + LiveView).
  → 이 파일에는 애드온/레지스트리 배선을 추가하지 않는다.

  비침투: ingest/media 가 enabled?==false(기본)면 빈 리스트 → 코어만 기동. 영향 0.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        OpenMes.Repo,
        OpenMesWeb.Telemetry,
        {Phoenix.PubSub, name: OpenMes.PubSub},
        # phx.new 가 생성한 그 외 코어 child(예: {DNSCluster, ...}, Finch 등)가 있으면
        # 여기 그대로 둔다.
        OpenMesWeb.Endpoint
      ] ++ ingest_children() ++ media_children()

    opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    OpenMesWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ── EXT-1(설비 수집) 조건부 child (06 application.ex.patch.md) ────────────
  defp ingest_children do
    if OpenMes.Ingest.enabled?() do
      [OpenMes.Ingest.Pipeline]
    else
      []
    end
  end

  # ── EXT-2(멀티미디어) 조건부 child (07 CORE_PATCH.md) ─────────────────────
  # 기동 순서: TransferSupervisor 가 Scanner/Dispatcher 보다 먼저.
  defp media_children do
    if OpenMes.Media.enabled?() do
      [
        OpenMes.Media.Transfer.TransferSupervisor,
        OpenMes.Media.Watch.Scanner,
        OpenMes.Media.Transfer.Dispatcher
      ]
    else
      []
    end
  end
end
