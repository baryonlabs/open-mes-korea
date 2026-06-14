defmodule OpenMes.Addons.WoCsvExportTest do
  @moduledoc """
  퍼사드(`OpenMes.Addons.WoCsvExport`) 테스트 중 DB 불필요한 부분.

  - filename/1: 시각 기반 파일명 포맷.
  - enabled?/0: config 게이트(Extension 테스트와 별개로 퍼사드 직접 검증).

  to_csv/1(코어 조회 → CSV)와 컨트롤러/LiveView 는 코어 Repo(work_orders 테이블)가 필요하므로
  앱 통합 후 `OpenMes.DataCase`/`ConnCase` 기반 통합 테스트로 검증한다(아래 README 참조).
  """
  use ExUnit.Case, async: false

  alias OpenMes.Addons.WoCsvExport

  describe "filename/1" do
    test "work_orders_YYYYMMDD_HHMMSS.csv 형식" do
      name = WoCsvExport.filename(~U[2026-06-13 14:25:30Z])
      assert name == "work_orders_20260613_142530.csv"
    end

    test "확장자는 .csv" do
      assert String.ends_with?(WoCsvExport.filename(), ".csv")
    end
  end

  describe "enabled?/0" do
    setup do
      original = Application.get_env(:open_mes, WoCsvExport)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:open_mes, WoCsvExport)
          value -> Application.put_env(:open_mes, WoCsvExport, value)
        end
      end)

      :ok
    end

    test "enabled: true → true" do
      Application.put_env(:open_mes, WoCsvExport, enabled: true)
      assert WoCsvExport.enabled?()
    end

    test "미설정 → false(기본 비활성)" do
      Application.delete_env(:open_mes, WoCsvExport)
      refute WoCsvExport.enabled?()
    end
  end
end
