defmodule OpenMes.Extension.DiscoveryTest do
  @moduledoc """
  발견(Discovery) + 라우트 스펙 컴파일 타임 게이트 테스트(설계 30 §2.4).

    - all/0: 발견 + override(extra) + 제외(exclude) escape hatch
    - route_specs/0: enabled? + route_spec/0 가진 확장만, off 는 제외(라우트 흔적 0)
  """
  use ExUnit.Case, async: false

  alias OpenMes.Extension.Discovery

  # 라우트 기여 확장(enabled).
  defmodule RoutedOn do
    use OpenMes.Extension.Definition
    def id, do: :fixture_routed_on
    def name, do: "라우트 ON"
    def description, do: "켜진 라우트 기여 확장."
    def category, do: :analytics
    def version, do: "0.1.0"
    def enabled?, do: true

    def route_spec,
      do: %{scope: "/x", pipeline: :browser, routes: [{:live, "/on", SomeLive, :index}]}
  end

  # 라우트 기여하지만 비활성 → route_specs 에서 제외돼야 한다(off=흔적 0).
  defmodule RoutedOff do
    use OpenMes.Extension.Definition
    def id, do: :fixture_routed_off
    def name, do: "라우트 OFF"
    def description, do: "꺼진 라우트 기여 확장."
    def category, do: :analytics
    def version, do: "0.1.0"
    def enabled?, do: false

    def route_spec,
      do: %{scope: "/x", pipeline: :browser, routes: [{:live, "/off", SomeLive, :index}]}
  end

  # route_spec 없는(nil) 확장 → route_specs 에서 제외(라우트 미기여).
  defmodule NoRoute do
    use OpenMes.Extension.Definition
    def id, do: :fixture_no_route
    def name, do: "라우트 없음"
    def description, do: "백그라운드 확장."
    def category, do: :media
    def version, do: "0.1.0"
    def enabled?, do: true
  end

  setup do
    original = Application.get_env(:open_mes, :extensions)
    mode = Application.get_env(:open_mes, :extension_discovery)

    on_exit(fn ->
      if original,
        do: Application.put_env(:open_mes, :extensions, original),
        else: Application.delete_env(:open_mes, :extensions)

      if mode,
        do: Application.put_env(:open_mes, :extension_discovery, mode),
        else: Application.delete_env(:open_mes, :extension_discovery)

      Application.delete_env(:open_mes, :extra_extensions)
      Application.delete_env(:open_mes, :exclude_extensions)
    end)

    :ok
  end

  describe "route_specs/0 (컴파일 타임 라우트 게이트)" do
    setup do
      # :manual 모드 + 명시 목록으로 결정적으로 통제.
      Application.put_env(:open_mes, :extension_discovery, :manual)
      Application.put_env(:open_mes, :extensions, [RoutedOn, RoutedOff, NoRoute])
      :ok
    end

    test "enabled? 이고 route_spec 있는 확장만 반환(off·nil 제외)" do
      specs = Discovery.route_specs()

      paths =
        for %{routes: routes} <- specs, {_verb, path, _m, _a} <- routes, do: path

      assert "/on" in paths
      refute "/off" in paths,
             "비활성 확장 라우트가 노출되면 안 됨(off=라우트 흔적 0, 설계 30 §2.1)"

      # NoRoute(route_spec nil)는 라우트 스펙에 등장하지 않는다.
      assert length(specs) == 1
    end
  end

  describe "all/0 escape hatch (:auto 모드)" do
    setup do
      Application.put_env(:open_mes, :extension_discovery, :auto)
      :ok
    end

    test "extra_extensions 로 강제 등록, exclude_extensions 로 제외" do
      Application.put_env(:open_mes, :extra_extensions, [RoutedOn])
      assert RoutedOn in Discovery.all()

      Application.put_env(:open_mes, :exclude_extensions, [RoutedOn])
      refute RoutedOn in Discovery.all()
    end

    test "발견은 실제 등록된 코어 확장 8개를 포함한다" do
      ids = Discovery.all() |> Enum.map(& &1.id())
      assert :addon_wo_csv_export in ids
      assert :ext_ingest in ids
      assert :connect_dureclaw in ids
    end
  end
end
