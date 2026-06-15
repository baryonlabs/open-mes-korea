defmodule OpenMes.Addons.DefectStats.StatsTest do
  @moduledoc """
  집계 정확성(불량률 계산, 0 나눗셈 방어) + 기간 필터 테스트 — DB 사용.

  `OpenMes.DataCase`(Ecto SQL Sandbox)로 격리. 테스트 전용 테이블 헬퍼
  `OpenMes.Addons.DefectStats.TestTables` 가 `production_results`/`defect_records` 를 만든다.
  애드온은 **읽기 전용**이므로 픽스처는 raw INSERT(`Repo.insert_all`)로 직접 적재한다.

  > 비동기 불가(`async: false`): CREATE TABLE/공유 테이블을 다루므로 직렬 실행.
  """
  use OpenMes.DataCase, async: false

  alias OpenMes.Addons.DefectStats.Stats
  alias OpenMes.Addons.DefectStats.TestTables
  alias OpenMes.Repo

  setup do
    TestTables.ensure!()
    # 샌드박스 트랜잭션 안에서 매 테스트마다 비운다(공유 테이블 격리).
    Repo.delete_all("defect_records")
    Repo.delete_all("production_results")
    :ok
  end

  # ── 픽스처 헬퍼(읽기 전용 애드온이므로 raw insert) ──────────────────

  defp insert_result(good, defect, ended_at) do
    id = Ecto.UUID.generate()

    Repo.insert_all("production_results", [
      %{
        id: Ecto.UUID.dump!(id),
        good_quantity: Decimal.new(good),
        defect_quantity: Decimal.new(defect),
        ended_at: ended_at,
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])

    id
  end

  defp insert_defect(result_id, code, qty) do
    Repo.insert_all("defect_records", [
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        production_result_id: Ecto.UUID.dump!(result_id),
        defect_code: code,
        quantity: Decimal.new(qty),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    ])
  end

  defp dt(iso), do: DateTime.from_iso8601(iso) |> elem(1)

  # ── summary/1 : 불량률 집계 ────────────────────────────────────────

  describe "summary/1 — 기간 불량률" do
    test "양품/불량 합계와 불량률을 계산한다" do
      insert_result(90, 10, dt("2026-06-10T10:00:00Z"))
      insert_result(80, 20, dt("2026-06-11T10:00:00Z"))

      s = Stats.summary(%{})

      assert s.good_quantity == 170
      assert s.defect_quantity == 30
      assert s.total_quantity == 200
      assert s.defect_rate == 0.15
    end

    test "0 나눗셈 방어: 실적이 없으면 모든 수량 0, 불량률 0.0" do
      s = Stats.summary(%{})

      assert s.good_quantity == 0
      assert s.defect_quantity == 0
      assert s.total_quantity == 0
      assert s.defect_rate == 0.0
    end

    test "0 나눗셈 방어: 생산수량(good+defect)이 0 이면 불량률 0.0" do
      insert_result(0, 0, dt("2026-06-10T10:00:00Z"))

      s = Stats.summary(%{})

      assert s.total_quantity == 0
      assert s.defect_rate == 0.0
    end

    test "기간 필터: 범위 밖 실적은 제외된다" do
      insert_result(90, 10, dt("2026-06-10T10:00:00Z"))
      insert_result(50, 50, dt("2026-06-20T10:00:00Z"))

      s = Stats.summary(%{from: dt("2026-06-19T00:00:00Z"), to: dt("2026-06-21T00:00:00Z")})

      # 6/20 실적만 집계
      assert s.good_quantity == 50
      assert s.defect_quantity == 50
      assert s.defect_rate == 0.5
    end
  end

  # ── defects_by_code/2 : 불량 유형별 집계 ───────────────────────────

  describe "defects_by_code/2 — 불량 유형별 수량/비율" do
    test "유형별 수량 합계와 비율, 수량 내림차순 정렬" do
      r1 = insert_result(80, 20, dt("2026-06-10T10:00:00Z"))
      insert_defect(r1, "SCRATCH", 15)
      insert_defect(r1, "CRACK", 5)
      r2 = insert_result(70, 10, dt("2026-06-11T10:00:00Z"))
      insert_defect(r2, "SCRATCH", 5)

      rows = Stats.defects_by_code(%{})

      assert [%{defect_code: "SCRATCH", quantity: 20}, %{defect_code: "CRACK", quantity: 5}] =
               Enum.map(rows, &Map.take(&1, [:defect_code, :quantity]))

      # 비율: 전체 불량 25 대비
      scratch = Enum.find(rows, &(&1.defect_code == "SCRATCH"))
      crack = Enum.find(rows, &(&1.defect_code == "CRACK"))
      assert scratch.ratio == 0.8
      assert crack.ratio == 0.2
    end

    test "0 나눗셈 방어: 불량 기록이 없으면 빈 목록(비율 계산 진입 안 함)" do
      assert Stats.defects_by_code(%{}) == []
    end

    test "limit 으로 상위 N 만 반환" do
      r = insert_result(0, 60, dt("2026-06-10T10:00:00Z"))
      insert_defect(r, "A", 30)
      insert_defect(r, "B", 20)
      insert_defect(r, "C", 10)

      rows = Stats.defects_by_code(%{}, limit: 2)

      assert length(rows) == 2
      assert Enum.map(rows, & &1.defect_code) == ["A", "B"]
    end

    test "기간 필터: 조인된 실적의 ended_at 기준으로 거른다" do
      r_in = insert_result(0, 10, dt("2026-06-20T10:00:00Z"))
      insert_defect(r_in, "IN", 10)
      r_out = insert_result(0, 99, dt("2026-06-01T10:00:00Z"))
      insert_defect(r_out, "OUT", 99)

      rows = Stats.defects_by_code(%{from: dt("2026-06-19T00:00:00Z"), to: dt("2026-06-21T00:00:00Z")})

      assert Enum.map(rows, & &1.defect_code) == ["IN"]
    end
  end
end
