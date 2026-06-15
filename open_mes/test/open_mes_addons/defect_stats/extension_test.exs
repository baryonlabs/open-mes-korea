defmodule OpenMes.Addons.DefectStats.ExtensionTest do
  @moduledoc """
  애드온 ② Extension behaviour 준수 + enabled?/0 게이트 테스트 (DB 불필요, async).

  설계 §1.1 계약(필수 6 + home_path)과 §2 메타데이터(id/name/category/version)를 고정한다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.DefectStats
  alias OpenMes.Addons.DefectStats.Extension

  describe "필수 콜백 6개 + 메타데이터" do
    test "id/name/description/category/version 값이 설계와 일치한다" do
      assert Extension.id() == :addon_defect_stats
      assert Extension.name() == "불량 통계 위젯"
      assert is_binary(Extension.description()) and Extension.description() != ""
      assert Extension.category() == :quality
      assert Extension.version() == "0.1.0"
    end

    test "enabled?/0 는 boolean" do
      assert is_boolean(Extension.enabled?())
    end

    test "home_path/0 는 애드온 화면 경로" do
      assert Extension.home_path() == "/extensions/defect-stats"
    end

    test "icon/0 기본값(Definition 매크로 주입)은 nil" do
      assert Extension.icon() == nil
    end
  end

  describe "behaviour 채택" do
    test "Extension behaviour 를 채택했다" do
      behaviours =
        Extension.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert OpenMes.Extension in behaviours
    end
  end

  describe "enabled?/0 ↔ 퍼사드 게이트 위임" do
    test "Extension.enabled?/0 는 DefectStats.enabled?/0 에 위임한다" do
      assert Extension.enabled?() == DefectStats.enabled?()
    end

    test "config 미설정 시 기본 false" do
      original = Application.get_env(:open_mes, DefectStats)
      Application.delete_env(:open_mes, DefectStats)

      try do
        refute DefectStats.enabled?()
      after
        if original, do: Application.put_env(:open_mes, DefectStats, original)
      end
    end

    test "config enabled: true 면 true" do
      original = Application.get_env(:open_mes, DefectStats)
      Application.put_env(:open_mes, DefectStats, enabled: true)

      try do
        assert DefectStats.enabled?()
        assert Extension.enabled?()
      after
        if original do
          Application.put_env(:open_mes, DefectStats, original)
        else
          Application.delete_env(:open_mes, DefectStats)
        end
      end
    end
  end
end
