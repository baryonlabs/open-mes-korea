defmodule OpenMesExtDemoWeb.DemoLive do
  @moduledoc """
  외부 데모 확장의 LiveView 화면(설계 30 증명 항목).

  호스트 router 의 `mount_extension_routes/0` 매크로가 `/extensions/demo` 로 마운트한다.
  코어를 참조하지 않는 자기완결 화면 — 외부 확장이 코어 수정 0 으로 화면까지 붙음을 증명.
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "외부 데모 확장")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="padding:2rem;font-family:sans-serif">
      <h1>외부 데모 확장 (open_mes_ext_demo)</h1>
      <p>
        별도 repo 의 path-dep 확장입니다. 호스트(open_mes)의 mix.exs 에 deps 한 줄만 추가했고,
        코어 소스(router.ex / config / extension.ex / ext.verify)는 수정하지 않았습니다.
      </p>
      <p>이 화면이 보인다면 자동 발견 + RouterMount 매크로가 외부 확장을 코어 침투 없이 마운트한 것입니다.</p>
    </div>
    """
  end
end
