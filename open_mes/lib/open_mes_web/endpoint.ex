defmodule OpenMesWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :open_mes

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_open_mes_key",
    signing_salt: "5ICzQCeF",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :open_mes,
    gzip: false,
    only: OpenMesWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :open_mes
  end

  # 테스트(async) 에서 LiveView/요청 프로세스가 소유자(테스트)의 SQL Sandbox
  # 커넥션을 공유하도록 허용한다. conn 메타데이터(beam.metadata)를 읽어 해당
  # 프로세스를 allow 한다 — 격리 sandbox 에서도 LiveView 가 실제 시드 데이터를 본다.
  if Application.compile_env(:open_mes, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug OpenMesWeb.Router
end
