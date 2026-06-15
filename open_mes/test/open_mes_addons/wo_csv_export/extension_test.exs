defmodule OpenMes.Addons.WoCsvExport.ExtensionTest do
  @moduledoc """
  Extension behaviour 준수 + enabled? 게이트 테스트.

  검증 포인트:
    - 필수 6개 콜백(id/name/description/category/version/enabled?) 메타데이터 정확성.
    - home_path/0(자체 화면) override 됨, icon/0 기본 nil.
    - Extension behaviour 를 구현했고 모든 콜백이 export 된다.
    - enabled?/0 가 config 게이트(OpenMes.Addons.WoCsvExport) 에 위임한다.
  """
  use ExUnit.Case, async: false

  alias OpenMes.Addons.WoCsvExport
  alias OpenMes.Addons.WoCsvExport.Extension

  # 테스트 동안 config 를 바꾸고 끝나면 복원한다.
  setup do
    original = Application.get_env(:open_mes, WoCsvExport)
    on_exit(fn -> restore(:open_mes, WoCsvExport, original) end)
    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  describe "필수 메타데이터 콜백" do
    test "id 는 :addon_wo_csv_export" do
      assert Extension.id() == :addon_wo_csv_export
    end

    test "name 은 한국어 이름" do
      assert Extension.name() == "작업지시 CSV 내보내기"
    end

    test "description 은 비어있지 않은 문자열" do
      assert is_binary(Extension.description())
      assert Extension.description() != ""
    end

    test "category 는 :production" do
      assert Extension.category() == :production
    end

    test "version 은 \"0.1.0\"" do
      assert Extension.version() == "0.1.0"
    end
  end

  describe "선택 콜백" do
    test "home_path 는 자체 화면 경로로 override 됨" do
      assert Extension.home_path() == "/extensions/wo-csv-export"
    end

    test "icon 은 기본값 nil(Definition 매크로 주입)" do
      assert Extension.icon() == nil
    end
  end

  describe "behaviour 준수" do
    test "Extension behaviour 를 구현한다" do
      behaviours =
        Extension.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert OpenMes.Extension in behaviours
    end

    test "모든 필수/선택 콜백이 export 된다" do
      # 전체 병렬 실행 시 모듈 로드 전 function_exported?가 false를 반환하는 것 방지
      Code.ensure_loaded!(Extension)

      for {fun, arity} <- [
            id: 0,
            name: 0,
            description: 0,
            category: 0,
            version: 0,
            enabled?: 0,
            home_path: 0,
            icon: 0
          ] do
        assert function_exported?(Extension, fun, arity),
               "#{fun}/#{arity} 가 export 되지 않았습니다"
      end
    end
  end

  describe "enabled?/0 — config 게이트 위임" do
    test "config enabled: true 면 활성" do
      Application.put_env(:open_mes, WoCsvExport, enabled: true)
      assert Extension.enabled?() == true
      assert WoCsvExport.enabled?() == true
    end

    test "config enabled: false 면 비활성" do
      Application.put_env(:open_mes, WoCsvExport, enabled: false)
      assert Extension.enabled?() == false
      assert WoCsvExport.enabled?() == false
    end

    test "config 미설정이면 기본 비활성(false)" do
      Application.delete_env(:open_mes, WoCsvExport)
      assert Extension.enabled?() == false
    end

    test "enabled 값이 truthy 아닌 값이면 false 로 정규화" do
      Application.put_env(:open_mes, WoCsvExport, enabled: "yes")
      assert WoCsvExport.enabled?() == false
    end
  end
end
