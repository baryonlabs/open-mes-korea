defmodule OpenMes.Addons.EquipmentOee.ExtensionTest do
  @moduledoc """
  애드온 ④ Extension behaviour 준수 + 게이트 위임 + enabled?/0 토글 테스트.
  """
  use ExUnit.Case, async: false

  alias OpenMes.Addons.EquipmentOee
  alias OpenMes.Addons.EquipmentOee.Extension

  describe "Extension behaviour 필수 콜백" do
    test "필수 6개 메타데이터를 모두 구현한다" do
      assert Extension.id() == :addon_equipment_oee
      assert Extension.name() == "설비 가동률 OEE"
      assert is_binary(Extension.description()) and Extension.description() != ""
      assert Extension.category() == :analytics
      assert Extension.version() == "0.1.0"
      assert is_boolean(Extension.enabled?())
    end

    test "home_path/0 는 자체 화면 경로를 반환한다" do
      assert Extension.home_path() == "/extensions/equipment-oee"
    end

    test "icon/0 선택 콜백 기본값은 nil (Definition 주입)" do
      assert Extension.icon() == nil
    end

    test "Extension behaviour 를 실제로 구현 선언했다" do
      behaviours =
        Extension.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert OpenMes.Extension in behaviours
    end
  end

  describe "enabled?/0 — config 게이트 위임" do
    setup do
      original = Application.get_env(:open_mes, EquipmentOee)
      on_exit(fn -> restore(:open_mes, EquipmentOee, original) end)
      :ok
    end

    test "미설정 시 기본 false" do
      Application.delete_env(:open_mes, EquipmentOee)
      assert EquipmentOee.enabled?() == false
      assert Extension.enabled?() == false
    end

    test "config 로 켜면 true, Extension 이 퍼사드 게이트에 위임한다" do
      Application.put_env(:open_mes, EquipmentOee, enabled: true)
      assert EquipmentOee.enabled?() == true
      assert Extension.enabled?() == true
    end

    test "config 로 끄면 false" do
      Application.put_env(:open_mes, EquipmentOee, enabled: false)
      assert Extension.enabled?() == false
    end
  end

  defp restore(_app, _key, nil), do: :ok
  defp restore(app, key, val), do: Application.put_env(app, key, val)
end
