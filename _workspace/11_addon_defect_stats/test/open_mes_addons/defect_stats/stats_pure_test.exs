defmodule OpenMes.Addons.DefectStats.StatsPureTest do
  @moduledoc """
  순수 계산 함수 테스트 — DB 없이 실행(async).

  불량률/비율 계산과 **0 나눗셈 방어**(설계 §0 EXT-1 멱등 교훈처럼 엣지케이스 명시 처리)를
  고정한다. 이 테스트는 Repo 를 건드리지 않으므로 매우 빠르고 결정적이다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.DefectStats.Stats

  describe "defect_rate/2 — 불량률 = defect / total" do
    test "정상 계산" do
      assert Stats.defect_rate(5, 100) == 0.05
      assert Stats.defect_rate(1, 4) == 0.25
      assert Stats.defect_rate(10, 10) == 1.0
    end

    test "0 나눗셈 방어: total 이 0 이면 0.0" do
      assert Stats.defect_rate(0, 0) == 0.0
      assert Stats.defect_rate(7, 0) == 0.0
    end

    test "비정상 분모 방어: 음수/비숫자 total → 0.0" do
      assert Stats.defect_rate(3, -5) == 0.0
      assert Stats.defect_rate(3, nil) == 0.0
    end

    test "결과는 항상 float" do
      assert is_float(Stats.defect_rate(1, 3))
      assert is_float(Stats.defect_rate(0, 0))
    end
  end

  describe "ratio/2 — 비율 = part / whole" do
    test "정상 계산" do
      assert Stats.ratio(3, 12) == 0.25
      assert Stats.ratio(6, 6) == 1.0
    end

    test "0 나눗셈 방어: whole 이 0 이하면 0.0" do
      assert Stats.ratio(1, 0) == 0.0
      assert Stats.ratio(0, 0) == 0.0
      assert Stats.ratio(2, -1) == 0.0
    end
  end
end
