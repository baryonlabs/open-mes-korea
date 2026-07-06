defmodule OpenMes.Addons.DailyProductionSummary.ExtensionTest do
  @moduledoc """
  애드온 ⑤ 의 config 게이트 + Extension behaviour 준수 테스트.

  검증:
    - `DailyProductionSummary.enabled?/0` : config on/off 게이트(기본 false).
    - `Extension` behaviour 필수 6개 콜백 + home_path 의 계약 준수.
    - `Extension.enabled?/0` 가 퍼사드 게이트에 위임.
  """
  use ExUnit.Case, async: false

  alias OpenMes.Addons.DailyProductionSummary
  alias OpenMes.Addons.DailyProductionSummary.Extension

  setup do
    original = Application.get_env(:open_mes, DailyProductionSummary)

    on_exit(fn ->
      if original do
        Application.put_env(:open_mes, DailyProductionSummary, original)
      else
        Application.delete_env(:open_mes, DailyProductionSummary)
      end
    end)

    :ok
  end

  describe "enabled?/0 (config 게이트)" do
    test "config 미설정 시 기본 false" do
      Application.delete_env(:open_mes, DailyProductionSummary)
      refute DailyProductionSummary.enabled?()
    end

    test "enabled: true 로 켜진다" do
      Application.put_env(:open_mes, DailyProductionSummary, enabled: true)
      assert DailyProductionSummary.enabled?()
    end

    test "enabled: false 로 꺼진다" do
      Application.put_env(:open_mes, DailyProductionSummary, enabled: false)
      refute DailyProductionSummary.enabled?()
    end

    test "잘못된 값(true 아님)은 false 로 본다" do
      Application.put_env(:open_mes, DailyProductionSummary, enabled: "yes")
      refute DailyProductionSummary.enabled?()
    end
  end

  describe "Extension behaviour 준수" do
    test "필수 6개 콜백이 계약 타입을 만족" do
      assert Extension.id() == :addon_daily_production_summary
      assert is_atom(Extension.id())
      assert Extension.name() == "일일 생산 요약"
      assert is_binary(Extension.name())
      assert is_binary(Extension.description())
      assert Extension.category() == :production
      assert Extension.version() == "0.1.0"
      assert is_boolean(Extension.enabled?())
    end

    test "home_path 는 자체 화면 경로를 반환" do
      assert Extension.home_path() == "/extensions/daily-production-summary"
    end

    test "icon 기본값은 nil(Definition 매크로 주입)" do
      assert Extension.icon() == nil
    end

    test "Extension behaviour 를 명시적으로 구현한다" do
      behaviours =
        Extension.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert OpenMes.Extension in behaviours
    end

    test "Extension.enabled?/0 는 퍼사드 게이트에 위임한다" do
      Application.put_env(:open_mes, DailyProductionSummary, enabled: true)
      assert Extension.enabled?() == DailyProductionSummary.enabled?()

      Application.put_env(:open_mes, DailyProductionSummary, enabled: false)
      assert Extension.enabled?() == DailyProductionSummary.enabled?()
    end
  end
end
