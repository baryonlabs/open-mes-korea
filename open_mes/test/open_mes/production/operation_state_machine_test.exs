defmodule OpenMes.Production.OperationStateMachineTest do
  @moduledoc "Operation 상태머신 순수 함수 검증(허용/불허 전이)."
  use ExUnit.Case, async: true

  alias OpenMes.Production.OperationStateMachine, as: SM

  test "허용 전이" do
    assert SM.can_transition?("pending", "ready")
    assert SM.can_transition?("pending", "skipped")
    assert SM.can_transition?("ready", "running")
    assert SM.can_transition?("running", "paused")
    assert SM.can_transition?("running", "completed")
    assert SM.can_transition?("paused", "running")
    assert SM.can_transition?("paused", "completed")
  end

  test "불허 전이 및 종료 상태" do
    refute SM.can_transition?("pending", "running")
    refute SM.can_transition?("pending", "completed")
    refute SM.can_transition?("completed", "running")
    refute SM.can_transition?("skipped", "ready")
    # 동일 상태(no-op)도 전이표에 없음
    refute SM.can_transition?("running", "running")
  end

  test "statuses/0 는 6종" do
    assert Enum.sort(SM.statuses()) ==
             Enum.sort(~w(pending ready running paused completed skipped))
  end

  test "allowed_from/1" do
    assert SM.allowed_from("completed") == []
    assert Enum.sort(SM.allowed_from("running")) == Enum.sort(~w(paused completed))
  end
end
