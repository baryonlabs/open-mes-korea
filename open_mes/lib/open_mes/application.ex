defmodule OpenMes.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        OpenMesWeb.Telemetry,
        OpenMes.Repo,
        {DNSCluster, query: Application.get_env(:open_mes, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: OpenMes.PubSub},
        # Start to serve requests, typically the last entry
        OpenMesWeb.Endpoint
      ] ++ ingest_children() ++ media_children() ++ dureclaw_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpenMesWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ── EXT-1(설비 수집) 조건부 child (06 application.ex.patch.md) ────────────
  # 비침투: enabled?==false(기본)면 빈 리스트 → 코어만 기동. 영향 0.
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

  # ── EXT-5(DureClaw 연동) 조건부 child ─────────────────────────────────────
  # SkillCache ETS 테이블 소유자만 기동(동결 룰이 요청 프로세스 수명과 무관하게 생존).
  # enabled?==false(기본)면 빈 리스트 → 코어 영향 0. 소유 전용 프로세스라 crash 면 0.
  defp dureclaw_children do
    if OpenMes.Connect.DureClaw.enabled?() do
      [OpenMes.Connect.DureClaw.SkillCache.Server]
    else
      []
    end
  end
end
