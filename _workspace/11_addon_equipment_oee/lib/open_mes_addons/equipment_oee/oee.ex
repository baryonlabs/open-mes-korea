defmodule OpenMes.Addons.EquipmentOee.Oee do
  @moduledoc """
  애드온 ④ 설비 가동률 OEE — **읽기 전용 집계 모듈**.

  설계 §2 애드온④. Repo **읽기만** 한다(쓰기/AuditLog/Outbox/새 테이블 0).

  ## 책임
    - 설비(equipment_id)별·기간별로 코어 데이터를 읽어 OEE 입력을 모은다.
    - 실가동시간(running_time): ProductionResult `started_at`~`ended_at` 차(초) 합산.
    - 품질 수량: good_quantity / defect_quantity 합산.
    - 표준 cycle time: ProductionResult → Operation → Routing 조인으로 평균 cycle time.
    - 모은 입력을 **순수 함수** `Calculator.compute/1` 에 넘겨 비율을 얻는다.

  ## 가정(MVP 근사 — 설계 §2 "가용 데이터로 근사")
    - 계획시간(planned_time)은 코어에 별도 테이블이 없다. MVP 는 **조회 기간 전체 길이**를
      설비당 계획시간으로 근사한다(가용성 = 실가동 / 기간길이). 정밀 계획정지 모델은 후속.
    - cycle time 단위는 초(초/개)로 가정(ReadModels.Routing 주석 참조).

  ## 엣지케이스(크래시 금지)
    - 기간/데이터 결측, started_at·ended_at 결측, 수량 0 등은 `Calculator` 가 nil/0 로 방어.
    - 이 모듈은 결측 행을 **건너뛰지 않고**, 가능한 값만 합산해 Calculator 에 넘긴다
      (started_at·ended_at 둘 다 있는 행만 실가동시간에 기여).
  """

  import Ecto.Query

  alias OpenMes.Addons.EquipmentOee.Calculator
  alias OpenMes.Addons.EquipmentOee.ReadModels.{Operation, ProductionResult, Routing}

  # Repo 는 코어 앱의 Repo. 컴파일 시점 모듈 부재로 깨지지 않게 런타임 참조.
  @repo Application.compile_env(:open_mes, [__MODULE__, :repo], OpenMes.Repo)

  @typedoc "설비별 OEE 한 행."
  @type row :: %{
          equipment_id: binary() | nil,
          planned_time_s: float(),
          running_time_s: float(),
          good_qty: number(),
          defect_qty: number(),
          standard_cycle_time_s: float() | nil,
          result: Calculator.result()
        }

  @doc """
  기간 [from, to) 안에서 설비별 OEE 를 계산해 행 목록으로 반환한다.

  `ended_at` 이 기간 안에 드는 ProductionResult 를 대상으로 한다.
  `from`/`to` 는 `DateTime`. `to <= from` 이면 빈 목록(잘못된 기간 방어).

  Repo 미가용(테스트 등)일 때는 `opts[:repo]` 로 주입할 수 있다.
  """
  @spec by_equipment(DateTime.t(), DateTime.t(), keyword()) :: [row()]
  def by_equipment(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    repo = Keyword.get(opts, :repo, @repo)
    planned_time_s = planned_time_seconds(from, to)

    if DateTime.compare(to, from) != :gt do
      []
    else
      from
      |> aggregate_query(to)
      |> repo.all()
      |> Enum.map(&build_row(&1, planned_time_s))
    end
  end

  @doc """
  단일 설비의 OEE 를 계산한다. 데이터가 없으면 0 입력 기반 결과(품질/성능 nil).
  """
  @spec for_equipment(binary(), DateTime.t(), DateTime.t(), keyword()) :: row()
  def for_equipment(equipment_id, %DateTime{} = from, %DateTime{} = to, opts \\ []) do
    rows = by_equipment(from, to, opts)

    Enum.find(rows, &(&1.equipment_id == equipment_id)) ||
      build_row(
        %{equipment_id: equipment_id, running_time_s: 0.0, good: 0, defect: 0, cycle_time: nil},
        planned_time_seconds(from, to)
      )
  end

  @doc "기간 안에 실적이 있는 설비 id 목록(드롭다운용)."
  @spec list_equipment_ids(DateTime.t(), DateTime.t(), keyword()) :: [binary()]
  def list_equipment_ids(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    repo = Keyword.get(opts, :repo, @repo)

    query =
      from r in ProductionResult,
        where: not is_nil(r.equipment_id),
        where: not is_nil(r.ended_at) and r.ended_at >= ^from and r.ended_at < ^to,
        distinct: true,
        select: r.equipment_id

    repo.all(query)
  end

  # ── 내부 ────────────────────────────────────────────────────────────

  # 설비별 집계 쿼리: 실가동시간(초), good/defect 합, 평균 표준 cycle time.
  # started_at·ended_at 둘 다 있는 행만 실가동시간에 기여(결측 행은 0 기여).
  defp aggregate_query(from, to) do
    from r in ProductionResult,
      left_join: o in Operation,
      on: o.id == r.operation_id,
      left_join: rt in Routing,
      on: rt.process_id == o.process_id,
      where: not is_nil(r.equipment_id),
      where: not is_nil(r.ended_at) and r.ended_at >= ^from and r.ended_at < ^to,
      group_by: r.equipment_id,
      select: %{
        equipment_id: r.equipment_id,
        # 실가동시간 합(초): ended_at - started_at, 둘 다 있을 때만. EXTRACT(EPOCH ...).
        running_time_s:
          coalesce(
            sum(
              fragment(
                "CASE WHEN ? IS NOT NULL AND ? IS NOT NULL THEN EXTRACT(EPOCH FROM (? - ?)) ELSE 0 END",
                r.started_at,
                r.ended_at,
                r.ended_at,
                r.started_at
              )
            ),
            0
          ),
        good: coalesce(sum(r.good_quantity), 0),
        defect: coalesce(sum(r.defect_quantity), 0),
        cycle_time: avg(rt.standard_cycle_time)
      }
  end

  # 집계 행 → OEE 행(Calculator 호출).
  defp build_row(agg, planned_time_s) do
    running = to_float(agg[:running_time_s]) || 0.0
    good = to_number(agg[:good]) || 0
    defect = to_number(agg[:defect]) || 0
    cycle = to_float(agg[:cycle_time])

    input = %{
      planned_time_s: planned_time_s,
      running_time_s: running,
      good_qty: good,
      defect_qty: defect,
      standard_cycle_time_s: cycle
    }

    %{
      equipment_id: agg[:equipment_id],
      planned_time_s: planned_time_s,
      running_time_s: running,
      good_qty: good,
      defect_qty: defect,
      standard_cycle_time_s: cycle,
      result: Calculator.compute(input)
    }
  end

  # 기간 길이(초)를 설비 계획시간으로 근사. to <= from 이면 0.
  defp planned_time_seconds(from, to) do
    diff = DateTime.diff(to, from, :second)
    if diff > 0, do: diff * 1.0, else: 0.0
  end

  # Decimal/integer/float/nil → float | nil (안전).
  defp to_float(nil), do: nil
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  defp to_number(nil), do: nil
  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(n) when is_number(n), do: n
end
