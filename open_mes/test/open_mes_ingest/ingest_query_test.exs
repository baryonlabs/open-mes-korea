defmodule OpenMes.Ingest.IngestQueryTest do
  @moduledoc """
  EXT-1 조사용 읽기 함수 테스트(설계 25번 §3.1) — summarize_metrics/downsample.

  집계 정확성(count/avg/min/max/last) + 다운샘플(time_bucket, ≤ buckets) 검증.
  읽기 전용 — 쓰기 없음.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Ingest
  alias OpenMes.Repo

  @eq "EQ-IQ"

  defp seed(metric, values, base_offset_s \\ 60) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    n = length(values)

    rows =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        %{
          equipment_id: @eq,
          metric_key: metric,
          value: v * 1.0,
          unit: "u",
          quality: "good",
          measured_at: DateTime.add(now, -(n - i) * base_offset_s, :second),
          ingested_at: now,
          meta: %{}
        }
      end)

    Repo.insert_all("equipment_measurements", rows)
    now
  end

  describe "summarize_metrics/3" do
    test "metric_key 별 count/avg/min/max/last 집계" do
      now = seed("vibration", [1.0, 2.0, 3.0, 4.0])
      from = DateTime.add(now, -86_400, :second)

      [s] = Ingest.summarize_metrics(@eq, from, now)

      assert s.metric_key == "vibration"
      assert s.count == 4
      assert s.avg == 2.5
      assert s.min == 1.0
      assert s.max == 4.0
      # last = 가장 최근 measured_at 의 값(마지막 시딩 = 4.0).
      assert s.last == 4.0
      assert s.unit == "u"
    end

    test "데이터 없으면 빈 리스트" do
      now = DateTime.utc_now()
      assert Ingest.summarize_metrics("EQ-NONE", DateTime.add(now, -3600, :second), now) == []
    end

    test "기간 밖 측정값은 제외된다" do
      now = seed("temp", [10.0, 20.0])
      # 미래 기간 → 0건.
      future_from = DateTime.add(now, 3600, :second)
      future_to = DateTime.add(now, 7200, :second)
      assert Ingest.summarize_metrics(@eq, future_from, future_to) == []
    end
  end

  describe "downsample/5" do
    test "버킷 평균 시리즈를 시각 오름차순으로 반환(≤ buckets)" do
      now = seed("flow", Enum.map(1..120, & &1), 60)
      from = DateTime.add(now, -86_400, :second)

      series = Ingest.downsample(@eq, "flow", from, now, 60)

      assert length(series) <= 60
      assert Enum.all?(series, &is_float(&1.v))
      # 시각 오름차순.
      ts = Enum.map(series, & &1.t)
      assert ts == Enum.sort(ts, DateTime)
    end

    test "데이터 없으면 빈 리스트" do
      now = DateTime.utc_now()
      assert Ingest.downsample("EQ-NONE", "x", DateTime.add(now, -3600, :second), now) == []
    end
  end
end
