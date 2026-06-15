defmodule OpenMes.Addons.EquipmentOee.CalculatorTest do
  @moduledoc """
  애드온 ④ OEE 순수 계산 정확성 + 엣지케이스 방어 테스트.

  순수 함수이므로 DB 불필요(`async: true`). 0 나눗셈/결측 데이터에서 nil(계산 불가)을
  반환하고 절대 크래시하지 않음을 고정한다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.EquipmentOee.Calculator

  describe "compute/1 — 정상 OEE 계산" do
    test "가용성×성능×품질 = 종합 OEE 가 정확히 곱해진다" do
      result =
        Calculator.compute(%{
          planned_time_s: 480.0,
          running_time_s: 432.0,
          good_qty: 96,
          defect_qty: 4,
          standard_cycle_time_s: 4.0
        })

      # 가용성 = 432/480 = 0.9
      assert_in_delta result.availability, 0.9, 1.0e-9
      # 성능 = (4 × 100) / 432 = 0.9259...
      assert_in_delta result.performance, 400 / 432, 1.0e-9
      # 품질 = 96 / 100 = 0.96
      assert_in_delta result.quality, 0.96, 1.0e-9
      # 종합 = 0.9 × 0.9259... × 0.96
      assert_in_delta result.oee, 0.9 * (400 / 432) * 0.96, 1.0e-9
    end

    test "완벽한 설비는 OEE 1.0" do
      result =
        Calculator.compute(%{
          planned_time_s: 100.0,
          running_time_s: 100.0,
          good_qty: 50,
          defect_qty: 0,
          standard_cycle_time_s: 2.0
        })

      assert result.availability == 1.0
      assert result.performance == 1.0
      assert result.quality == 1.0
      assert result.oee == 1.0
    end
  end

  describe "availability/2 — 가용성 = 실가동 / 계획" do
    test "정상 비율" do
      assert_in_delta Calculator.availability(45.0, 60.0), 0.75, 1.0e-9
    end

    test "계획시간 0 → nil(0 나눗셈 방어)" do
      assert Calculator.availability(10.0, 0) == nil
    end

    test "계획시간 음수 → nil" do
      assert Calculator.availability(10.0, -5) == nil
    end

    test "결측(nil) → nil" do
      assert Calculator.availability(nil, 60.0) == nil
      assert Calculator.availability(45.0, nil) == nil
    end

    test "실가동 > 계획이면 1.0 으로 클램프" do
      assert Calculator.availability(120.0, 60.0) == 1.0
    end
  end

  describe "performance/3 — 성능 = (cycle × 총생산) / 실가동" do
    test "정상 비율" do
      assert_in_delta Calculator.performance(2.0, 30, 80.0), 0.75, 1.0e-9
    end

    test "실가동시간 0 → nil(0 나눗셈 방어)" do
      assert Calculator.performance(2.0, 30, 0) == nil
    end

    test "표준 cycle time 결측 → nil" do
      assert Calculator.performance(nil, 30, 80.0) == nil
    end

    test "총생산 결측 → nil" do
      assert Calculator.performance(2.0, nil, 80.0) == nil
    end

    test "이론 생산시간 > 실가동이면 1.0 으로 클램프" do
      assert Calculator.performance(10.0, 100, 50.0) == 1.0
    end
  end

  describe "quality/2 — 품질 = good / (good + defect)" do
    test "정상 비율" do
      assert_in_delta Calculator.quality(90, 10), 0.9, 1.0e-9
    end

    test "총생산 0(양품·불량 모두 0) → nil(0 나눗셈 방어)" do
      assert Calculator.quality(0, 0) == nil
    end

    test "결측 → nil" do
      assert Calculator.quality(nil, 10) == nil
      assert Calculator.quality(90, nil) == nil
    end

    test "음수 → nil" do
      assert Calculator.quality(-1, 10) == nil
    end

    test "불량 0, 양품 양수 → 1.0" do
      assert Calculator.quality(100, 0) == 1.0
    end
  end

  describe "overall/3 + compute — nil 전파" do
    test "한 요소라도 nil 이면 종합 OEE nil" do
      assert Calculator.overall(nil, 0.9, 0.9) == nil
      assert Calculator.overall(0.9, nil, 0.9) == nil
      assert Calculator.overall(0.9, 0.9, nil) == nil
    end

    test "compute: 계획시간 0 + 생산 0 → 모든 요소 nil, 크래시 없음" do
      result =
        Calculator.compute(%{
          planned_time_s: 0,
          running_time_s: 0,
          good_qty: 0,
          defect_qty: 0,
          standard_cycle_time_s: nil
        })

      assert result == %{availability: nil, performance: nil, quality: nil, oee: nil}
    end

    test "compute: 빈 맵도 크래시 없이 모두 nil" do
      assert Calculator.compute(%{}) == %{
               availability: nil,
               performance: nil,
               quality: nil,
               oee: nil
             }
    end
  end

  describe "to_percent/1" do
    test "비율을 백분율 문자열로" do
      assert Calculator.to_percent(0.9) == "90.0%"
      assert Calculator.to_percent(0.5) == "50.0%"
      assert Calculator.to_percent(1.0) == "100.0%"
      # 소수 1자리 포맷 + "%" 접미사
      assert Calculator.to_percent(0.123) =~ ~r/^\d+\.\d%$/
    end

    test "nil 은 — (계산 불가, 0% 와 구분)" do
      assert Calculator.to_percent(nil) == "—"
    end
  end
end
