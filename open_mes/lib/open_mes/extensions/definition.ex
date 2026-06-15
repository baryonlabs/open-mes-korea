defmodule OpenMes.Extensions.Definition do
  @moduledoc """
  `OpenMes.Extensions.Extension` 의 선택 콜백 기본 구현을 주입하는 `use` 매크로.

  각 확장 모듈은 다음과 같이 사용한다:

      defmodule OpenMes.Addons.WoCsvExport.Extension do
        use OpenMes.Extensions.Definition

        @impl true
        def id, do: :addon_wo_csv_export
        @impl true
        def name, do: "작업지시 CSV 내보내기"
        @impl true
        def description, do: "작업지시 목록을 CSV 로 내려받는다."
        @impl true
        def category, do: :production
        @impl true
        def version, do: "0.1.0"
        @impl true
        def enabled?, do: OpenMes.Addons.WoCsvExport.enabled?()

        # 화면이 있는 확장만 home_path 를 override.
        @impl true
        def home_path, do: "/extensions/wo-csv-export"
      end

  이렇게 하면 선택 콜백(`home_path/0`, `icon/0`)은 기본값 nil 이 주입되므로
  필수 6개(id/name/description/category/version/enabled?)만 구현하면 된다.
  화면 있는 확장만 `home_path/0` 를(아이콘 쓰면 `icon/0` 도) override 한다.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour OpenMes.Extensions.Extension

      @impl true
      def home_path, do: nil

      @impl true
      def icon, do: nil

      # 화면/아이콘이 있는 확장은 이 기본값을 override 한다.
      defoverridable home_path: 0, icon: 0
    end
  end
end
