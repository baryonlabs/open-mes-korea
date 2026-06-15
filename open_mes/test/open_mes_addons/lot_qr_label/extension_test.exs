defmodule OpenMes.Addons.LotQrLabel.ExtensionTest do
  @moduledoc """
  애드온③ Extension behaviour 준수 + config 게이트(enabled?) 테스트.

  DB 불필요(async). 메타데이터 계약과 enabled? 위임만 검증한다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.LotQrLabel
  alias OpenMes.Addons.LotQrLabel.Extension

  describe "필수 콜백 구현(Extension behaviour 계약)" do
    test "id 는 :addon_lot_qr_label" do
      assert Extension.id() == :addon_lot_qr_label
    end

    test "name/description 은 비어있지 않은 한국어 문자열" do
      assert is_binary(Extension.name()) and Extension.name() != ""
      assert is_binary(Extension.description()) and Extension.description() != ""
    end

    test "category 는 :traceability" do
      assert Extension.category() == :traceability
    end

    test "version 은 \"0.1.0\"" do
      assert Extension.version() == "0.1.0"
    end

    test "enabled? 는 boolean" do
      assert is_boolean(Extension.enabled?())
    end
  end

  describe "선택 콜백" do
    test "home_path 는 LiveView 경로 문자열" do
      assert Extension.home_path() == "/extensions/lot-qr-label"
    end

    test "icon 은 Definition 매크로 기본값 nil" do
      assert Extension.icon() == nil
    end
  end

  describe "behaviour 채택" do
    test "Extension behaviour 를 채택했다" do
      behaviours =
        Extension.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert OpenMes.Extensions.Extension in behaviours
    end
  end

  describe "config 게이트(enabled?) 위임" do
    setup do
      original = Application.get_env(:open_mes, LotQrLabel)
      on_exit(fn -> restore_env(LotQrLabel, original) end)
      :ok
    end

    test "config enabled: true → enabled?/0 true, Extension.enabled?/0 도 true" do
      Application.put_env(:open_mes, LotQrLabel, enabled: true)
      assert LotQrLabel.enabled?() == true
      assert Extension.enabled?() == true
    end

    test "config enabled: false → false" do
      Application.put_env(:open_mes, LotQrLabel, enabled: false)
      assert LotQrLabel.enabled?() == false
      assert Extension.enabled?() == false
    end

    test "config 미설정 → 기본 false(안전)" do
      Application.delete_env(:open_mes, LotQrLabel)
      assert LotQrLabel.enabled?() == false
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:open_mes, key)
  defp restore_env(key, val), do: Application.put_env(:open_mes, key, val)
end
