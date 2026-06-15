defmodule OpenMes.Media.StateMachineTest do
  use ExUnit.Case, async: true

  alias OpenMes.Media.StateMachine

  describe "허용 전이(화이트리스트)" do
    test "정상 흐름 전이는 통과한다" do
      assert StateMachine.can_transition?("detected", "uploading")
      assert StateMachine.can_transition?("uploading", "stored")
      assert StateMachine.can_transition?("uploading", "transfer_failed")
      assert StateMachine.can_transition?("transfer_failed", "uploading")
      assert StateMachine.can_transition?("transfer_failed", "dead")
      assert StateMachine.can_transition?("uploading", "duplicate")
      assert StateMachine.can_transition?("detected", "duplicate")
    end

    test "feature_extracted 는 stored 에서만 예약 전이로 허용(EXT-3 자리)" do
      assert StateMachine.can_transition?("stored", "feature_extracted")
    end
  end

  describe "비허용 전이 거부" do
    test "건너뛰는 전이는 거부한다" do
      refute StateMachine.can_transition?("detected", "stored")
      refute StateMachine.can_transition?("detected", "dead")
      refute StateMachine.can_transition?("stored", "uploading")
    end

    test "종료 상태에서의 전이는 모두 거부한다" do
      assert StateMachine.allowed_from("dead") == []
      assert StateMachine.allowed_from("duplicate") == []
      assert StateMachine.allowed_from("feature_extracted") == []
      refute StateMachine.can_transition?("dead", "uploading")
      refute StateMachine.can_transition?("stored", "detected")
    end

    test "동일 상태로의 전이(no-op)는 항상 거부한다" do
      for s <- StateMachine.states() do
        refute StateMachine.can_transition?(s, s), "#{s}→#{s} 가 허용되면 안 됨"
      end
    end

    test "정의되지 않은 상태는 거부한다" do
      refute StateMachine.can_transition?("garbage", "uploading")
      refute StateMachine.can_transition?("uploading", "garbage")
    end
  end
end
