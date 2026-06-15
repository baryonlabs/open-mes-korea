defmodule OpenMes.Addons.EquipmentOee.OeeTest do
  @moduledoc """
  애드온 ④ 읽기 집계(`Oee`) 테스트.

  실제 DB 없이 **스텁 Repo**(`opts[:repo]` 주입)로 집계 결과 → Calculator 연결과
  엣지케이스(잘못된 기간, 빈 데이터, Decimal/결측 처리)를 검증한다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.EquipmentOee.Oee

  # 집계 쿼리 결과를 흉내내는 스텁 Repo. `all/1` 에 미리 정한 행을 돌려준다.
  defmodule StubRepo do
    def new(rows), do: {__MODULE__, rows}
  end

  # opts[:repo] 로 주입할, all/1 을 구현한 익명 모듈 대용 — 프로세스 사전 사용.
  defmodule FakeRepo do
    def put(rows), do: Process.put(:fake_rows, rows)
    def all(_query), do: Process.get(:fake_rows, [])
  end

  describe "by_equipment/3 — 집계 → OEE" do
    test "스텁 집계 행이 Calculator 로 정확히 연결된다" do
      FakeRepo.put([
        %{
          equipment_id: "eq-1",
          running_time_s: 432.0,
          good: Decimal.new("96"),
          defect: Decimal.new("4"),
          cycle_time: Decimal.new("4.0")
        }
      ])

      {:ok, from} = DateTime.new(~D[2026-06-01], ~T[00:00:00], "Etc/UTC")
      # 계획시간 = 기간 길이 = 480 초가 되도록 8분 기간.
      {:ok, to} = DateTime.new(~D[2026-06-01], ~T[00:08:00], "Etc/UTC")

      [row] = Oee.by_equipment(from, to, repo: FakeRepo)

      assert row.equipment_id == "eq-1"
      assert row.planned_time_s == 480.0
      assert_in_delta row.result.availability, 432 / 480, 1.0e-9
      assert_in_delta row.result.quality, 0.96, 1.0e-9
      assert_in_delta row.result.performance, 400 / 432, 1.0e-9
      refute is_nil(row.result.oee)
    end

    test "잘못된 기간(to <= from) → 빈 목록(쿼리 미실행)" do
      FakeRepo.put([%{equipment_id: "x", running_time_s: 1.0, good: 1, defect: 0, cycle_time: 1.0}])
      {:ok, from} = DateTime.new(~D[2026-06-02], ~T[00:00:00], "Etc/UTC")
      {:ok, to} = DateTime.new(~D[2026-06-01], ~T[00:00:00], "Etc/UTC")

      assert Oee.by_equipment(from, to, repo: FakeRepo) == []
    end

    test "결측 cycle_time → 성능 nil(크래시 없음)" do
      FakeRepo.put([
        %{equipment_id: "eq-2", running_time_s: 100.0, good: 10, defect: 0, cycle_time: nil}
      ])

      {:ok, from} = DateTime.new(~D[2026-06-01], ~T[00:00:00], "Etc/UTC")
      {:ok, to} = DateTime.new(~D[2026-06-01], ~T[00:10:00], "Etc/UTC")

      [row] = Oee.by_equipment(from, to, repo: FakeRepo)
      assert row.result.performance == nil
      assert row.result.oee == nil
      assert row.result.quality == 1.0
    end

    test "빈 데이터 → 빈 목록" do
      FakeRepo.put([])
      {:ok, from} = DateTime.new(~D[2026-06-01], ~T[00:00:00], "Etc/UTC")
      {:ok, to} = DateTime.new(~D[2026-06-02], ~T[00:00:00], "Etc/UTC")
      assert Oee.by_equipment(from, to, repo: FakeRepo) == []
    end
  end

  describe "for_equipment/4" do
    test "데이터 없는 설비 → 0 입력 기반 결과(품질/성능 nil, 크래시 없음)" do
      FakeRepo.put([])
      {:ok, from} = DateTime.new(~D[2026-06-01], ~T[00:00:00], "Etc/UTC")
      {:ok, to} = DateTime.new(~D[2026-06-02], ~T[00:00:00], "Etc/UTC")

      row = Oee.for_equipment("missing", from, to, repo: FakeRepo)
      assert row.equipment_id == "missing"
      assert row.result.quality == nil
      assert row.result.oee == nil
    end
  end
end
