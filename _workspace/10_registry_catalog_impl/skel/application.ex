defmodule OpenMes.Application do
  @moduledoc """
  통합 application.ex (설계 §4.4).

  phx.new 가 생성한 application.ex 를 기준으로, 확장 배선만 추가한다:
    - children 리스트 끝에 `++ ingest_children() ++ media_children()`
    - private 게이트 함수 `ingest_children/0`, `media_children/0`

  애드온 5개는 **supervised child 가 없다**(읽기 전용 LiveView/쿼리뿐, 백그라운드 프로세스 0).
  따라서 이 파일에 애드온 배선은 추가하지 않는다. (⑤ 일일요약을 캐시하는 GenServer 를
  도입하는 경우에만 그때 addon_children/0 을 추가 — MVP 불필요.)

  레지스트리/카탈로그도 supervised child 가 없다(상태 없는 순수 조회 모듈 + LiveView).
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        OpenMes.Repo,
        OpenMesWeb.Telemetry,
        {Phoenix.PubSub, name: OpenMes.PubSub},
        OpenMesWeb.Endpoint
        # ── phx.new 가 생성한 그 외 코어 child 는 여기 그대로 둔다 ──
      ] ++ ingest_children() ++ media_children()

    opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    OpenMesWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ── EXT-1(설비 수집) 조건부 child (06 application.ex.patch.md) ──────────
  # enabled?==false(기본)면 빈 리스트 → Broadway 파이프라인이 안 뜬다. 코어 영향 0.
  defp ingest_children do
    if OpenMes.Ingest.enabled?() do
      [OpenMes.Ingest.Pipeline]
    else
      []
    end
  end

  # ── EXT-2(멀티미디어) 조건부 child (07 CORE_PATCH.md) ──────────────────
  # 기동 순서 주의: TransferSupervisor 가 Scanner/Dispatcher 보다 먼저.
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
