defmodule OpenMes.Extensions.ExtensionTest do
  @moduledoc """
  Extension behaviour 준수 테스트 (설계 §7.a).

  실제 등록 확장(EXT-1/EXT-2 메타데이터 모듈)이 계약을 올바르게 구현했는지,
  Definition 매크로가 선택 콜백 기본값을 제대로 주입하는지 검증한다.
  애드온 5개가 통합되면 이 테스트의 모듈 목록에 추가하기만 하면 동일하게 검증된다.
  """
  use ExUnit.Case, async: true

  # 계약 검증 대상(이 기반 작업 시점의 등록 확장). 애드온 통합 시 여기에 추가.
  @extension_modules [
    OpenMes.Ingest.Extension,
    OpenMes.Media.Extension
  ]

  describe "필수 콜백 구현" do
    for mod <- @extension_modules do
      test "#{inspect(mod)} 가 필수 콜백을 모두 구현하고 타입이 올바르다" do
        mod = unquote(mod)

        assert is_atom(mod.id())
        assert is_binary(mod.name()) and mod.name() != ""
        assert is_binary(mod.description()) and mod.description() != ""

        assert mod.category() in [
                 :ingest,
                 :media,
                 :production,
                 :quality,
                 :traceability,
                 :analytics
               ]

        assert is_binary(mod.version()) and mod.version() != ""
        assert is_boolean(mod.enabled?())
      end
    end
  end

  describe "선택 콜백(Definition 매크로 기본값)" do
    test "home_path/0 는 String 또는 nil" do
      for mod <- @extension_modules do
        assert match?(nil, mod.home_path()) or is_binary(mod.home_path())
      end
    end

    test "icon/0 는 String 또는 nil" do
      for mod <- @extension_modules do
        assert match?(nil, mod.icon()) or is_binary(mod.icon())
      end
    end
  end

  describe "behaviour 채택" do
    test "각 모듈이 Extension behaviour 를 채택했다" do
      for mod <- @extension_modules do
        behaviours =
          mod.module_info(:attributes)
          |> Keyword.get_values(:behaviour)
          |> List.flatten()

        assert OpenMes.Extensions.Extension in behaviours,
               "#{inspect(mod)} 는 OpenMes.Extensions.Extension behaviour 를 채택해야 한다"
      end
    end
  end

  describe "id 고유성" do
    test "등록 확장 id 는 서로 겹치지 않는다" do
      ids = Enum.map(@extension_modules, & &1.id())
      assert ids == Enum.uniq(ids)
    end
  end

  describe "EXT-1/EXT-2 게이트 위임" do
    test "Ingest.Extension.enabled? 는 OpenMes.Ingest.enabled? 와 일치" do
      assert OpenMes.Ingest.Extension.enabled?() == OpenMes.Ingest.enabled?()
    end

    test "Media.Extension.enabled? 는 OpenMes.Media.enabled? 와 일치" do
      assert OpenMes.Media.Extension.enabled?() == OpenMes.Media.enabled?()
    end
  end
end
