defmodule OpenMesWeb.Plugs.RequireDeviceToken do
  @moduledoc """
  설비 수집 요청에 디바이스 토큰 인증을 강제하는 plug. 설계 §4.2.

  설비는 사람 actor 가 아니다 — 코어의 X-Actor-Id(사람 행위자) 방식과 **분리**한다.
  `Authorization: Bearer <token>` 헤더를 config 정적 화이트리스트와 대조한다(MVP 임시 방식).

  - 토큰 누락/불일치 → 401.
  - 통과 시 `conn.assigns.device_actor` 에 `"device:<token>"` 형태로 주입.
    (텔레메트리 measurement 에는 사람 actor_id 를 두지 않는다. dead-letter 의 source 추적용.)

  후속 확장(설계 §4.2): 디바이스별 발급 토큰 + 회전 + 토큰별 rate limit. MVP 는
  정적 화이트리스트로 단순화하고 이 plug 만 교체하면 되도록 격리한다.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- extract_bearer(conn),
         true <- token in allowed_tokens() do
      assign(conn, :device_actor, "device:" <> token)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized", message: "유효한 디바이스 토큰이 필요합니다 (Authorization: Bearer)"})
        |> halt()
    end
  end

  # Authorization: Bearer <token> 에서 토큰을 추출한다.
  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] ->
        case String.trim(token) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  # config 화이트리스트(runtime.exs 에서 환경변수로 주입, 설계 §4.2).
  defp allowed_tokens do
    :open_mes
    |> Application.get_env(OpenMes.Ingest, [])
    |> Keyword.get(:device_tokens, [])
  end
end
