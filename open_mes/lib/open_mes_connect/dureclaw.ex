defmodule OpenMes.Connect.DureClaw do
  @moduledoc """
  EXT-5 연동 허브 — DureClaw 분산 에이전트 협력 버스 연동 (`category: :integration`).

  설계 `docs/extension-roadmap.md` (A) 연동 허브: 이종 외부 프로그램을 *받아들이는* 계층.
  DureClaw 는 여러 머신(엣지 Pi·GPU·Mac)을 하나의 협동 AI 팀으로 묶는 Phoenix WS 버스다.
  이 확장은 그 버스의 **presence·Work Key·health 를 읽기 전용으로 관측**한다.

  ## pi 준수 / 안전

    - **읽기 전용**: 버스 REST(`/api/...`)를 GET 으로 조회만 한다. 코어 도메인 쓰기 0,
      AuditLog 0, Outbox 0, 새 테이블 0 (애드온 컨벤션과 동일).
    - **코어 비침투**: `OpenMes.Production`/`WorkOrder`/`Audit` 등 코어를 참조하지 않는다.
    - **config 게이트**: `config :open_mes, OpenMes.Connect.DureClaw, enabled: ...`
      (미설정 시 기본 false). 버스 주소는 env `BUS_URL`/`OAH_SECRET`.

  실제 화면은 `OpenMesWeb.Connect.DureClawLive`, 메타데이터는 `.Extension` 이 담당한다.
  """

  @timeout_ms 1500

  @doc """
  확장 활성 여부. config 게이트.

      config :open_mes, OpenMes.Connect.DureClaw, enabled: true

  미설정 시 기본값 false (코어 비침투 — 명시적으로 켜야 라우트/카탈로그 노출).
  """
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  @doc """
  버스 라이브 스냅샷(읽기 전용): 연결여부 + health + 온라인 에이전트 + Work Key.
  BUS_URL 미설정/버스 다운이어도 connected:false 로 안전 반환한다.
  """
  def snapshot do
    case base() do
      {:ok, http, headers} ->
        %{
          connected: true,
          bus_url: http,
          health: get_json(http, "/api/health", headers) || %{},
          agents: (get_json(http, "/api/presence", headers) || %{})["agents"] || [],
          work_keys: (get_json(http, "/api/work-keys", headers) || %{})["work_keys"] || []
        }

      :disabled ->
        %{connected: false, bus_url: nil, health: %{}, agents: [], work_keys: []}
    end
  end

  defp base do
    case System.get_env("BUS_URL") do
      url when is_binary(url) and url != "" ->
        http = String.replace(url, ~r/^ws/, "http")
        secret = System.get_env("OAH_SECRET", "")
        {:ok, http, [{"authorization", "Bearer #{secret}"}]}

      _ ->
        :disabled
    end
  end

  defp get_json(http, path, headers) do
    case Req.get("#{http}#{path}", headers: headers, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> body
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
