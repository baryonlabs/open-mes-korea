defmodule OpenMes.Extensions.RegistryTest do
  @moduledoc """
  레지스트리 단위 테스트 (설계 §7.a 테스트 항목).

    - all/0 이 등록 모듈 수만큼 엔트리 반환
    - enabled/0 이 enabled 만 필터
    - by_category/0 그룹핑
    - 한 확장 enabled? 가 raise 해도 all/0 이 죽지 않음(safe_enabled?)
    - 빈 리스트 게이트(확장 0개)에서도 정상
  """
  use ExUnit.Case, async: false

  alias OpenMes.Extension.Registry
  alias OpenMes.Test.ExtensionFixtures
  alias OpenMes.Test.ExtensionFixtures.{EnabledWithScreen, Raising}

  setup do
    original = Application.get_env(:open_mes, :extensions)
    Application.put_env(:open_mes, :extensions, ExtensionFixtures.all_fixtures())

    on_exit(fn ->
      if original do
        Application.put_env(:open_mes, :extensions, original)
      else
        Application.delete_env(:open_mes, :extensions)
      end
    end)

    :ok
  end

  describe "modules/0" do
    test "config :extensions 리스트를 그대로 반환" do
      assert Registry.modules() == ExtensionFixtures.all_fixtures()
    end
  end

  describe "all/0" do
    test "등록 모듈 수만큼 엔트리 반환" do
      entries = Registry.all()
      assert length(entries) == length(ExtensionFixtures.all_fixtures())
    end

    test "엔트리는 메타데이터 전 항목을 담는다" do
      entry = Enum.find(Registry.all(), &(&1.id == :fixture_enabled_screen))

      assert entry.name == "활성 화면 확장"
      assert entry.description == "활성이며 자체 화면을 가진 더미 확장."
      assert entry.category == :production
      assert entry.version == "1.0.0"
      assert entry.enabled == true
      assert entry.home_path == "/extensions/fixture-enabled-screen"
      assert entry.icon == nil
      assert entry.module == EnabledWithScreen
    end

    test "category → name 순으로 정렬" do
      cats = Registry.all() |> Enum.map(& &1.category)
      assert cats == Enum.sort(cats)
    end

    test "raise 하는 확장도 entry 로 포함되며 enabled=false (safe_enabled?)" do
      entry = Enum.find(Registry.all(), &(&1.id == :fixture_raising))
      assert entry.module == Raising
      assert entry.enabled == false
    end

    test "한 확장 enabled? 가 raise 해도 all/0 전체가 죽지 않는다" do
      # Raising 이 포함되어 있어도 예외 없이 전체 엔트리를 반환해야 한다.
      assert length(Registry.all()) == 4
    end
  end

  describe "enabled/0" do
    test "enabled? == true 인 확장만 반환" do
      ids = Registry.enabled() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == [:fixture_enabled_noscreen, :fixture_enabled_screen]
    end

    test "비활성/예외 확장은 제외" do
      ids = Registry.enabled() |> Enum.map(& &1.id)
      refute :fixture_disabled_screen in ids
      refute :fixture_raising in ids
    end
  end

  describe "by_category/0" do
    test "카테고리별로 그룹핑" do
      groups = Registry.by_category()

      assert groups[:production] |> Enum.map(& &1.id) == [:fixture_enabled_screen]
      assert groups[:ingest] |> Enum.map(& &1.id) == [:fixture_enabled_noscreen]
      assert groups[:quality] |> Enum.map(& &1.id) == [:fixture_disabled_screen]
      assert groups[:analytics] |> Enum.map(& &1.id) == [:fixture_raising]
    end
  end

  describe "빈 게이트(확장 0개)" do
    test "all/enabled/by_category 모두 안전" do
      Application.put_env(:open_mes, :extensions, [])

      assert Registry.all() == []
      assert Registry.enabled() == []
      assert Registry.by_category() == %{}
    end
  end
end
