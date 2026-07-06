defmodule OpenMes.Extension.Definition do
  @moduledoc """
  `OpenMes.Extension` 의 선택 콜백 기본 구현을 주입하는 `use` 매크로.

  각 확장 모듈은 다음과 같이 사용한다:

      defmodule MyMesOeePro.Extension do
        use OpenMes.Extension.Definition

        @impl true
        def id, do: :oee_pro
        @impl true
        def name, do: "OEE 고도화"
        @impl true
        def description, do: "설비 종합효율 상세 분석"
        @impl true
        def category, do: :analytics
        @impl true
        def version, do: "0.1.0"
        @impl true
        def enabled?, do: Application.compile_env(:my_mes_oee_pro, :enabled, true)

        # 화면이 있으면 home_path 와 route_spec 을 override.
        @impl true
        def home_path, do: "/extensions/oee-pro"
        @impl true
        def route_spec do
          %{
            scope: "/extensions",
            pipeline: :browser,
            routes: [{:live, "/oee-pro", MyMesOeeProWeb.OeeProLive, :index}]
          }
        end
      end

  이렇게 하면 선택 콜백(`home_path/0`, `icon/0`, `route_spec/0`)은 기본값(nil)이 주입되므로
  필수 6개만 구현하면 된다. 화면/라우트가 있는 확장만 해당 콜백을 override 한다.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour OpenMes.Extension

      @impl true
      def home_path, do: nil

      @impl true
      def icon, do: nil

      @impl true
      def route_spec, do: nil

      # 화면/아이콘/라우트가 있는 확장은 이 기본값을 override 한다.
      defoverridable home_path: 0, icon: 0, route_spec: 0
    end
  end
end
