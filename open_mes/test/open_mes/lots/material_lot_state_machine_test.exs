defmodule OpenMes.Lots.MaterialLotStateMachineTest do
  @moduledoc "MaterialLot 상태머신 순수 함수 검증."
  use ExUnit.Case, async: true

  alias OpenMes.Lots.MaterialLotStateMachine, as: SM

  test "허용 전이" do
    assert SM.can_transition?("available", "reserved")
    assert SM.can_transition?("available", "quarantined")
    assert SM.can_transition?("available", "scrapped")
    assert SM.can_transition?("reserved", "consumed")
    assert SM.can_transition?("reserved", "available")
    assert SM.can_transition?("quarantined", "available")
    assert SM.can_transition?("produced", "available")
    assert SM.can_transition?("produced", "reserved")
  end

  test "불허 전이 및 종료 상태" do
    refute SM.can_transition?("available", "consumed")
    refute SM.can_transition?("consumed", "available")
    refute SM.can_transition?("scrapped", "available")
    refute SM.can_transition?("available", "available")
  end

  test "statuses/0 는 6종" do
    assert Enum.sort(SM.statuses()) ==
             Enum.sort(~w(available reserved consumed produced quarantined scrapped))
  end
end
