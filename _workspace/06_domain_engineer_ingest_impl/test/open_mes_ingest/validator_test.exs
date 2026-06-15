defmodule OpenMes.Ingest.ValidatorTest do
  @moduledoc """
  Validator 순수 함수 단위 테스트(설계 §7.4). DB 의존 없음 → async.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Ingest.Validator

  # 현재 시각 기준 유효한 ISO8601 문자열(skew 통과)
  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  describe "정상 케이스" do
    test "수치 측정값 → row map 으로 정규화된다" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "temperature",
        "value" => 72.4,
        "unit" => "degC",
        "measured_at" => now_iso()
      }

      assert {:ok, row} = Validator.validate(raw)
      assert row.equipment_id == "EQP-01"
      assert row.metric_key == "temperature"
      assert row.value == 72.4
      assert row.unit == "degC"
      # 기본 품질 + 서버 수집 시각 부여
      assert row.quality == "good"
      assert %DateTime{} = row.ingested_at
      assert %DateTime{} = row.measured_at
    end

    test "상태(문자) 측정값은 string_value 로 보존되고 value 는 nil" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "state",
        "string_value" => "running",
        "measured_at" => now_iso()
      }

      assert {:ok, row} = Validator.validate(raw)
      assert row.value == nil
      assert row.string_value == "running"
    end

    test "정수 value 는 float 로 캐스트된다" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "cycle_count",
        "value" => 10,
        "measured_at" => now_iso()
      }

      assert {:ok, %{value: 10.0}} = Validator.validate(raw)
    end

    test "숫자 문자열 value 도 float 로 캐스트된다" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "pressure",
        "value" => "1.5",
        "measured_at" => now_iso()
      }

      assert {:ok, %{value: 1.5}} = Validator.validate(raw)
    end

    test "epoch(밀리초) measured_at 을 파싱한다" do
      ms = System.system_time(:millisecond)

      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "temperature",
        "value" => 1.0,
        "measured_at" => ms
      }

      assert {:ok, %{measured_at: %DateTime{}}} = Validator.validate(raw)
    end

    test "유효한 work_order_id(UUID)는 보존된다" do
      uuid = Ecto.UUID.generate()

      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "temperature",
        "value" => 1.0,
        "measured_at" => now_iso(),
        "work_order_id" => uuid
      }

      assert {:ok, %{work_order_id: ^uuid}} = Validator.validate(raw)
    end

    test "지정된 quality 화이트리스트 값은 보존된다" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "temperature",
        "value" => 1.0,
        "quality" => "uncertain",
        "measured_at" => now_iso()
      }

      assert {:ok, %{quality: "uncertain"}} = Validator.validate(raw)
    end
  end

  describe "검증 실패 → {:error, reason}" do
    test "map 이 아니면 not_a_map" do
      assert {:error, "not_a_map"} = Validator.validate("nope")
    end

    test "equipment_id 누락" do
      raw = %{"metric_key" => "t", "value" => 1.0, "measured_at" => now_iso()}
      assert {:error, "missing:equipment_id"} = Validator.validate(raw)
    end

    test "metric_key 누락" do
      raw = %{"equipment_id" => "EQP-01", "value" => 1.0, "measured_at" => now_iso()}
      assert {:error, "missing:metric_key"} = Validator.validate(raw)
    end

    test "measured_at 누락" do
      raw = %{"equipment_id" => "EQP-01", "metric_key" => "t", "value" => 1.0}
      assert {:error, "missing:measured_at"} = Validator.validate(raw)
    end

    test "value 와 string_value 둘 다 없으면 value_missing" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "t",
        "measured_at" => now_iso()
      }

      assert {:error, "value_missing"} = Validator.validate(raw)
    end

    test "skew 초과(과거 +2일)는 skew_exceeded" do
      old = DateTime.utc_now() |> DateTime.add(-2 * 86_400, :second) |> DateTime.to_iso8601()

      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "t",
        "value" => 1.0,
        "measured_at" => old
      }

      assert {:error, "skew_exceeded"} = Validator.validate(raw)
    end

    test "잘못된 measured_at 형식" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "t",
        "value" => 1.0,
        "measured_at" => "not-a-date"
      }

      assert {:error, "invalid:measured_at"} = Validator.validate(raw)
    end

    test "숫자가 아닌 value" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "t",
        "value" => "abc",
        "measured_at" => now_iso()
      }

      assert {:error, "invalid:value"} = Validator.validate(raw)
    end

    test "잘못된 work_order_id" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "t",
        "value" => 1.0,
        "measured_at" => now_iso(),
        "work_order_id" => "not-a-uuid"
      }

      assert {:error, "invalid:work_order_id"} = Validator.validate(raw)
    end

    test "화이트리스트 밖 quality" do
      raw = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "t",
        "value" => 1.0,
        "quality" => "weird",
        "measured_at" => now_iso()
      }

      assert {:error, "invalid:quality"} = Validator.validate(raw)
    end
  end
end
