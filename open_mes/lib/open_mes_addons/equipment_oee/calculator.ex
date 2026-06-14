defmodule OpenMes.Addons.EquipmentOee.Calculator do
  @moduledoc """
  애드온 ④ 설비 가동률 OEE — **순수 계산 모듈**.

  설계 `09_architect_registry_catalog_design.md` §2 애드온④, §7-b.

  ## 왜 순수 함수인가
  OEE 정의는 분모(계획시간)·이상 cycle time 같은 가정에 민감하다. 그래서 계산 로직을
  Repo/DB 와 완전히 분리된 **순수 함수**로 둔다. 입력은 평범한 숫자/구조체뿐이며
  부수효과(DB, 시간 조회)가 없다 → 가정이 바뀌어도 단위 테스트로 정확성을 고정한다.

  ## OEE = 가용성(Availability) × 성능(Performance) × 품질(Quality)

    - 가용성 = 실가동시간 / 계획시간
    - 성능   = (표준 cycle time × 총생산수량) / 실가동시간
    - 품질   = 양품수량 / (양품수량 + 불량수량)

  모든 비율은 0.0 ~ (이론상 1.0) 범위의 `float`. 단 데이터 근사 특성상 성능/가용성은
  1.0 을 넘을 수 있어(예: 실가동 < 이론 생산시간) 안전하게 **0.0~1.0 으로 클램프**한다.

  ## 엣지케이스(크래시 금지 — 설계 필수 준수)
    - 계획시간 0/음수 또는 결측 → 가용성 계산 불가 → `nil`
    - 실가동시간 0/음수 또는 결측 → 성능 계산 불가 → `nil`
    - 총생산수량(양품+불량) 0 → 품질 계산 불가 → `nil`
    - 표준 cycle time 결측 → 성능 계산 불가 → `nil`
    - 세 요소 중 하나라도 `nil` → 종합 OEE `nil`(곱 불가)

  `nil` 은 "계산 불가"를 **명확히** 나타낸다(0% 와 구분). 화면은 nil 을 "—" 로 표시한다.
  """

  @typedoc "OEE 계산 입력. 시간은 초 단위 float, 수량은 number."
  @type input :: %{
          # 계획시간(초). 설비가 가동되도록 계획된 총 시간.
          planned_time_s: number() | nil,
          # 실가동시간(초). ProductionResult started_at~ended_at 합.
          running_time_s: number() | nil,
          # 양품수량
          good_qty: number() | nil,
          # 불량수량
          defect_qty: number() | nil,
          # 표준 cycle time(초/개). Routing.standard_cycle_time.
          standard_cycle_time_s: number() | nil
        }

  @typedoc "OEE 계산 결과. 각 비율은 0.0~1.0 float 또는 nil(계산 불가)."
  @type result :: %{
          availability: float() | nil,
          performance: float() | nil,
          quality: float() | nil,
          oee: float() | nil
        }

  @doc """
  단일 설비/기간의 OEE 3요소 + 종합 OEE 를 계산한다.

  ## 예시(개념)

      입력: 계획 480s, 실가동 432s, 양품 96, 불량 4, cycle 4s
      → 가용성 0.9, 성능 0.9259..., 품질 0.96, 종합 OEE ≈ 0.80

  (정확한 부동소수 값은 `test/.../calculator_test.exs` 가 고정한다.)
  """
  @spec compute(input()) :: result()
  def compute(input) when is_map(input) do
    availability = availability(input[:running_time_s], input[:planned_time_s])
    performance = performance(input[:standard_cycle_time_s], total_qty(input), input[:running_time_s])
    quality = quality(input[:good_qty], input[:defect_qty])
    oee = overall(availability, performance, quality)

    %{availability: availability, performance: performance, quality: quality, oee: oee}
  end

  @doc """
  가용성 = 실가동시간 / 계획시간.

  계획시간이 결측/0/음수면 `nil`(0 나눗셈 방어). 결과는 0.0~1.0 으로 클램프.
  """
  @spec availability(number() | nil, number() | nil) :: float() | nil
  def availability(running_time_s, planned_time_s) do
    cond do
      not is_number(running_time_s) or not is_number(planned_time_s) -> nil
      planned_time_s <= 0 -> nil
      running_time_s < 0 -> nil
      true -> clamp(running_time_s / planned_time_s)
    end
  end

  @doc """
  성능 = (표준 cycle time × 총생산수량) / 실가동시간.

  표준 cycle time/실가동시간이 결측이거나 실가동시간 0/음수면 `nil`(0 나눗셈 방어).
  결과는 0.0~1.0 으로 클램프.
  """
  @spec performance(number() | nil, number() | nil, number() | nil) :: float() | nil
  def performance(standard_cycle_time_s, total_qty, running_time_s) do
    cond do
      not is_number(standard_cycle_time_s) or not is_number(running_time_s) -> nil
      not is_number(total_qty) -> nil
      standard_cycle_time_s < 0 or total_qty < 0 -> nil
      running_time_s <= 0 -> nil
      true -> clamp(standard_cycle_time_s * total_qty / running_time_s)
    end
  end

  @doc """
  품질 = 양품수량 / (양품수량 + 불량수량).

  총생산(양품+불량)이 0/음수면 `nil`(0 나눗셈 방어). 결과는 0.0~1.0 으로 클램프.
  """
  @spec quality(number() | nil, number() | nil) :: float() | nil
  def quality(good_qty, defect_qty) do
    good = if is_number(good_qty), do: good_qty, else: nil
    defect = if is_number(defect_qty), do: defect_qty, else: nil

    cond do
      is_nil(good) or is_nil(defect) -> nil
      good < 0 or defect < 0 -> nil
      good + defect <= 0 -> nil
      true -> clamp(good / (good + defect))
    end
  end

  @doc """
  종합 OEE = 가용성 × 성능 × 품질.

  세 요소 중 하나라도 `nil`(계산 불가)이면 종합도 `nil`.
  """
  @spec overall(float() | nil, float() | nil, float() | nil) :: float() | nil
  def overall(a, p, q) when is_number(a) and is_number(p) and is_number(q), do: a * p * q
  def overall(_, _, _), do: nil

  @doc "백분율 문자열 포맷(소수 1자리). nil 은 \"—\"(계산 불가)."
  @spec to_percent(float() | nil) :: String.t()
  def to_percent(nil), do: "—"

  def to_percent(ratio) when is_number(ratio) do
    :erlang.float_to_binary(ratio * 100, decimals: 1) <> "%"
  end

  # 총생산수량 = 양품 + 불량(둘 중 결측은 0 으로 보정해 합산. 둘 다 결측이면 nil).
  defp total_qty(%{good_qty: g, defect_qty: d}) do
    cond do
      is_number(g) and is_number(d) -> g + d
      is_number(g) -> g
      is_number(d) -> d
      true -> nil
    end
  end

  defp total_qty(_), do: nil

  # 비율을 0.0~1.0 으로 클램프. 근사 데이터로 1.0 초과/음수가 나와도 안전 범위로.
  defp clamp(ratio) when is_number(ratio) do
    ratio
    |> max(0.0)
    |> min(1.0)
    |> :erlang.float()
  end
end
