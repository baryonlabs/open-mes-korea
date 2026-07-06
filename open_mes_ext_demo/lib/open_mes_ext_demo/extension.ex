defmodule OpenMesExtDemo.Extension do
  @moduledoc """
  외부 repo 확장 증명용 더미 Extension(설계 30 증명 항목).

  코어(`:open_mes`)를 전혀 참조하지 않고 계약 패키지(`OpenMes.Extension`)만 구현한다.
  호스트 `open_mes/mix.exs` 에 deps 한 줄(`{:open_mes_ext_demo, path: ...}`)만 추가하면
  `:auto` 발견이 이 모듈을 잡아 카탈로그 카드 + 라우트(`/extensions/demo`)에 자동 노출한다.

  - category 는 코어가 모르는 자유 atom(`:demo`) — known_categories 미포함이지만 정상(C6 정보성).
  - 기본 비활성(`enabled: false`) — 증명 후 남겨두되 코어 영향 0.
  """
  use OpenMes.Extension.Definition

  @impl true
  def id, do: :ext_demo

  @impl true
  def name, do: "외부 데모 확장"

  @impl true
  def description, do: "별도 repo path-dep 확장이 코어 수정 0 으로 자동 노출됨을 증명하는 더미."

  # 코어가 모르는 자유 카테고리(개방형 atom 증명 — 설계 30 §2.2). 폴백 라벨로 렌더된다.
  @impl true
  def category, do: :demo

  @impl true
  def version, do: "0.1.0"

  # 기본 비활성 — config 로 켠다(코어 비침투 기본 off).
  @impl true
  def enabled? do
    :open_mes_ext_demo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  @impl true
  def home_path, do: "/extensions/demo"

  # 라우트 데이터 선언(순수 데이터 — 외부 확장이 Router 모듈을 만들 필요 없음, 설계 30 §2.1).
  @impl true
  def route_spec do
    %{
      scope: "/extensions",
      pipeline: :browser,
      routes: [{:live, "/demo", OpenMesExtDemoWeb.DemoLive, :index}]
    }
  end
end
