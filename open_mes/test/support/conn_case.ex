defmodule OpenMesWeb.ConnCase do
  @moduledoc """
  컨트롤러 통합 테스트용 케이스 템플릿.

  HTTP 커넥션을 구성하고 Ecto SQL Sandbox 로 테스트를 격리한다.
  ~p 검증 sigil 사용을 위해 OpenMesWeb 의 verified_routes 를 import 한다.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint OpenMesWeb.Endpoint

      use OpenMesWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import OpenMesWeb.ConnCase
    end
  end

  setup tags do
    OpenMes.DataCase.setup_sandbox(tags)

    # conn 에 sandbox 메타데이터를 심어, async 테스트에서 LiveView/요청 프로세스가
    # 테스트 소유자의 sandbox 커넥션(시드 데이터 포함)을 공유하도록 한다.
    # (endpoint 의 Phoenix.Ecto.SQL.Sandbox plug 가 user-agent 헤더를 읽어 allow.)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(OpenMes.Repo, self())

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header(
        "user-agent",
        Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)
      )

    {:ok, conn: conn}
  end
end
