defmodule OpenMes.Outbox do
  @moduledoc """
  아웃박스(Outbox) 컨텍스트 — 이벤트 적재 헬퍼.

  설계 원칙:
    - 이벤트는 상태 변경과 동일 `Ecto.Multi`(=동일 트랜잭션) 안에서 적재한다.
      따라서 본 모듈은 Multi 스텝을 만들어 주는 함수를 제공한다.
    - MVP 범위: 발행 워커 없음. 적재만 한다.
    - append-only: update/delete 함수를 제공하지 않는다.
  """
  alias Ecto.Multi
  alias OpenMes.Outbox.Event

  @doc """
  주어진 `Ecto.Multi` 에 아웃박스 이벤트 INSERT 스텝을 추가한다.

  `attrs_fun` 은 이전 스텝 결과(map)를 받아 이벤트 속성 map 을 반환하는 함수다.

  ## 예시

      multi
      |> OpenMes.Outbox.put_event(:event, fn %{transition: wo} ->
        %{
          event_type: "work_order.released",
          aggregate_type: "work_order",
          aggregate_id: wo.id,
          occurred_at: DateTime.utc_now(),
          payload: %{...}
        }
      end)
  """
  def put_event(%Multi{} = multi, step_name, attrs_fun) when is_function(attrs_fun, 1) do
    Multi.insert(multi, step_name, fn changes ->
      changes
      |> attrs_fun.()
      |> Event.changeset()
    end)
  end
end
