defmodule OpenMesWeb.Plugs.RequireActor do
  @moduledoc """
  쓰기 요청에 actor 정보를 강제하는 plug.

  MVP 단계는 인증 미들웨어가 없으므로 `X-Actor-Id` HTTP 헤더로 행위자를 전달받는다.
  헤더가 없거나 공백뿐이면 422 로 거부한다(actor 없는 쓰기 금지, system-architecture.md L62).

  통과 시 `conn.assigns.actor_id` 에 trim 된 값을 주입한다.
  읽기(GET) 라우트에는 적용하지 않는다(라우터 파이프라인에서 분리).

  후속 확장: 실제 인증 도입 시 이 plug 만 교체하면 컨텍스트 시그니처는 유지된다.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @header "x-actor-id"

  def init(opts), do: opts

  def call(conn, _opts) do
    actor_id =
      conn
      |> get_req_header(@header)
      |> List.first()
      |> normalize()

    if actor_id do
      assign(conn, :actor_id, actor_id)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{actor: ["actor_id가 필요합니다 (X-Actor-Id 헤더)"]}})
      |> halt()
    end
  end

  # 빈 문자열/공백뿐인 값은 거부(nil 반환)
  defp normalize(nil), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
