defmodule OpenMesExtensionApi.MixProject do
  use Mix.Project

  @moduledoc """
  open_mes_extension_api — Open MES Korea 확장 계약 패키지.

  외부 repo 확장이 코어(`:open_mes`)에 의존하지 않고 이 **얇은 계약 패키지에만** 의존해
  확장을 만들 수 있도록 분리한 것이다(설계 30 §3).

  포함: behaviour(`OpenMes.Extension`) + `use` 매크로(`OpenMes.Extension.Definition`) +
        레지스트리(`OpenMes.Extension.Registry`) + 발견(`OpenMes.Extension.Discovery`) +
        라우트 주입 매크로(`OpenMes.Extension.RouterMount`).

  **Phoenix 미의존**: RouterMount 는 quote AST 만 생성하고 실제 `live/get/post` 매크로는
  호스트 Router 의 `use ...Web, :router` 컨텍스트에서 펼쳐진다. 따라서 이 패키지는 순수
  Elixir + `Mix.Project` introspection 만 쓴다(설계 30 §3.1, §3.2 — 단방향 의존).
  """

  def project do
    [
      app: :open_mes_extension_api,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # 외부 의존 0 — 계약 패키지는 가벼워야 한다(설계 30 §3.1).
  defp deps, do: []
end
