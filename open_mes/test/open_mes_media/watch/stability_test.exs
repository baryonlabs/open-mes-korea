defmodule OpenMes.Media.Watch.StabilityTest do
  use ExUnit.Case, async: true

  alias OpenMes.Media.Watch.Stability

  @now ~U[2026-06-13 12:00:00.000000Z]
  # 유예(10초) 충분히 경과한 mtime
  @quiet_mtime ~U[2026-06-13 11:59:00.000000Z]
  # 방금 수정됨(유예 미경과)
  @recent_mtime ~U[2026-06-13 11:59:55.000000Z]

  defp obs(path, size, mtime), do: %{path: path, size: size, mtime: mtime}

  describe "임시/숨김 파일 제외(:ignore)" do
    test "임시 접미사는 ignore" do
      for suffix <- [".tmp", ".part", ".partial", ".filepart", "~"] do
        curr = obs("/nas/EQP-01/video/2026-06-13/cam1.mp4#{suffix}", 100, @quiet_mtime)
        assert Stability.assess(nil, curr, @now) == :ignore
      end
    end

    test "숨김 파일(. 시작)은 ignore" do
      curr = obs("/nas/EQP-01/.DS_Store", 100, @quiet_mtime)
      assert Stability.assess(nil, curr, @now) == :ignore
    end

    test "정상 파일명은 ignore 가 아님" do
      curr = obs("/nas/EQP-01/video/2026-06-13/cam1.mp4", 100, @quiet_mtime)
      refute Stability.assess(nil, curr, @now) == :ignore
    end
  end

  describe "mtime 유예" do
    test "유예 미경과면 pending(:mtime_quiet)" do
      curr = obs("/nas/a.mp4", 100, @recent_mtime)
      assert Stability.assess(nil, curr, @now) == {:pending, :mtime_quiet}
    end
  end

  describe "first_seen / size 안정화 (2-스캔)" do
    test "최초 관측(prev=nil)은 즉시 등록하지 않고 pending(:first_seen)" do
      curr = obs("/nas/a.mp4", 100, @quiet_mtime)
      assert Stability.assess(nil, curr, @now) == {:pending, :first_seen}
    end

    test "직전 size 와 다르면 pending(:size_changing)" do
      prev = %{size: 80, mtime: @quiet_mtime}
      curr = obs("/nas/a.mp4", 100, @quiet_mtime)
      assert Stability.assess(prev, curr, @now) == {:pending, :size_changing}
    end

    test "유예 경과 + 2회 size 동일 → stable" do
      prev = %{size: 100, mtime: @quiet_mtime}
      curr = obs("/nas/a.mp4", 100, @quiet_mtime)
      assert Stability.assess(prev, curr, @now) == :stable
    end

    test "유예 우선순위: size 가 같아도 유예 미경과면 pending" do
      prev = %{size: 100, mtime: @recent_mtime}
      curr = obs("/nas/a.mp4", 100, @recent_mtime)
      assert Stability.assess(prev, curr, @now) == {:pending, :mtime_quiet}
    end
  end
end
