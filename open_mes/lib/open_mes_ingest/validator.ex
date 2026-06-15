defmodule OpenMes.Ingest.Validator do
  @moduledoc """
  수집 raw 맵 → equipment_measurements row 맵 검증·변환. 설계 §3.3.

  DB 의존이 없는 **순수 함수**다(단위 테스트가 쉽고 빠르다).
  검증 항목:
    - 필수 필드(equipment_id, metric_key) 존재
    - 측정값 1개 이상 존재(value 또는 string_value)
    - measured_at 파싱 가능 + skew 범위(±1일) 내
    - 타입 캐스트(value → float, work_order_id → UUID)
  변환:
    - device payload(자유 JSON) → DB row map(컬럼명 atom 키)
    - ingested_at 서버 부여, quality 기본값 "good"

  검증 실패 시 `{:error, reason}` 을 반환하며, 이 reason 이 dead-letter 의 사유가 된다.
  """

  # 측정시각 미래/과거 허용 범위(±1일). 그 밖은 오염으로 간주.
  @max_skew_seconds 86_400

  @type raw :: map()
  @type row :: map()

  @doc """
  raw 맵을 검증·정규화한다.

  성공: `{:ok, row_map}` (insert_all 용, 키는 컬럼 atom)
  실패: `{:error, reason}` (reason 은 dead-letter 사유 문자열)
  """
  @spec validate(raw) :: {:ok, row} | {:error, String.t()}
  def validate(raw) when is_map(raw) do
    with {:ok, equipment_id} <- required_string(raw, "equipment_id"),
         {:ok, metric_key} <- required_string(raw, "metric_key"),
         {:ok, measured_at} <- parse_time(raw["measured_at"]),
         {:ok, value} <- cast_float(raw["value"]),
         :ok <- value_present(value, raw["string_value"]),
         :ok <- within_skew(measured_at),
         {:ok, work_order_id} <- cast_uuid(raw["work_order_id"]),
         {:ok, quality} <- cast_quality(raw["quality"]) do
      {:ok,
       %{
         equipment_id: equipment_id,
         metric_key: metric_key,
         value: value,
         string_value: cast_string(raw["string_value"]),
         unit: cast_string(raw["unit"]),
         quality: quality,
         measured_at: measured_at,
         ingested_at: DateTime.utc_now(),
         work_order_id: work_order_id,
         meta: cast_meta(raw["meta"])
       }}
    end
  end

  def validate(_), do: {:error, "not_a_map"}

  # ── 내부 검증/캐스트 헬퍼 ─────────────────────────────────────

  # 필수 문자열: 존재하고 공백이 아니어야 한다.
  defp required_string(raw, key) do
    case raw[key] do
      v when is_binary(v) ->
        case String.trim(v) do
          "" -> {:error, "missing:#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, "missing:#{key}"}
    end
  end

  # measured_at 파싱: ISO8601 문자열 또는 epoch(정수, 초/밀리초 추정)를 허용.
  defp parse_time(nil), do: {:error, "missing:measured_at"}

  defp parse_time(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "invalid:measured_at"}
    end
  end

  defp parse_time(v) when is_integer(v) do
    # 13자리(밀리초)면 ms, 그보다 작으면 초로 본다.
    {unit, value} = if v > 9_999_999_999, do: {:millisecond, v}, else: {:second, v}

    case DateTime.from_unix(value, unit) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, "invalid:measured_at"}
    end
  end

  defp parse_time(_), do: {:error, "invalid:measured_at"}

  # value 캐스트: nil 허용(string_value 만 있는 상태형 측정). 숫자/숫자문자열 → float.
  defp cast_float(nil), do: {:ok, nil}
  defp cast_float(v) when is_float(v), do: {:ok, v}
  defp cast_float(v) when is_integer(v), do: {:ok, v * 1.0}

  defp cast_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, ""} -> {:ok, f}
      _ -> {:error, "invalid:value"}
    end
  end

  defp cast_float(_), do: {:error, "invalid:value"}

  # value / string_value 중 하나는 반드시 채워져야 한다.
  defp value_present(nil, nil), do: {:error, "value_missing"}
  defp value_present(nil, ""), do: {:error, "value_missing"}

  defp value_present(nil, sv) when is_binary(sv) do
    if String.trim(sv) == "", do: {:error, "value_missing"}, else: :ok
  end

  defp value_present(value, _sv) when is_number(value), do: :ok
  defp value_present(_, _), do: {:error, "value_missing"}

  # 측정시각 skew 검사: 서버 현재 시각 기준 ±@max_skew_seconds 이내여야 한다.
  defp within_skew(%DateTime{} = measured_at) do
    diff = abs(DateTime.diff(DateTime.utc_now(), measured_at, :second))
    if diff <= @max_skew_seconds, do: :ok, else: {:error, "skew_exceeded"}
  end

  # work_order_id: 없으면 nil 허용. 있으면 UUID 형식이어야 한다.
  defp cast_uuid(nil), do: {:ok, nil}

  defp cast_uuid(v) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "invalid:work_order_id"}
    end
  end

  defp cast_uuid(_), do: {:error, "invalid:work_order_id"}

  # quality: 미지정 시 "good". 지정 시 화이트리스트 검증.
  defp cast_quality(nil), do: {:ok, "good"}

  defp cast_quality(v) when v in ["good", "uncertain", "bad"], do: {:ok, v}
  defp cast_quality(_), do: {:error, "invalid:quality"}

  # 선택 문자열: 빈 문자열은 nil 로 정규화.
  defp cast_string(nil), do: nil

  defp cast_string(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      _ -> v
    end
  end

  defp cast_string(_), do: nil

  # meta: map 만 보존. 그 외(문자열 등)는 무시(nil).
  defp cast_meta(v) when is_map(v), do: v
  defp cast_meta(_), do: nil
end
