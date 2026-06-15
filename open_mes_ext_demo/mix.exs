defmodule OpenMesExtDemo.MixProject do
  use Mix.Project

  @moduledoc """
  open_mes_ext_demo — **외부 repo 확장 증명용** 더미 확장(설계 30 증명 항목).

  이 패키지는 코어(`:open_mes`)에 의존하지 **않는다.** 확장 계약 패키지
  (`open_mes_extension_api`)와 자기 화면을 위한 phoenix_live_view 에만 의존한다. 호스트
  (`open_mes/mix.exs`)에 deps 한 줄만 추가하면 카탈로그·라우트에 자동 노출됨을 증명한다.

  기본 비활성(enabled: false) — 증명 후 남겨두되 코어 동작에 영향 0.
  """
  def project do
    [
      app: :open_mes_ext_demo,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # 계약 패키지에만 의존(코어 :open_mes 무의존 — 단방향). 형제 path dep.
      {:open_mes_extension_api, path: "../open_mes_extension_api"},
      # 자기 LiveView 화면을 위한 의존(호스트 web 컨텍스트에서 펼쳐짐).
      {:phoenix_live_view, "~> 1.0.0-rc.1"}
    ]
  end
end
