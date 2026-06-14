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
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
