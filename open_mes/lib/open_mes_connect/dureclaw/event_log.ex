defmodule OpenMes.Connect.DureClaw.EventLog do
  @moduledoc """
  분산 fleet 통신·대화 디버그 로그 — ETS 링버퍼(가장 최근 N건).

  원격 노드는 BEAM 프로세스가 아니라 Observer 로 못 본다. 대신 **MES 오케스트레이터가
  주고받는 트래픽**(task.assign 송신 · task.result 수신)을 여기 기록해, 확장 화면에서
  Observer 의도(라이브 상태·메시지 흐름)를 *디버깅 수준*으로 관찰한다.

  테이블 소유는 `SkillCache.Server`(앱 수명) — 요청/Task 프로세스가 죽어도 로그 유지.
  순수 관측 로그(코어 미참조). 민감정보 미기록(지시 텍스트는 앞부분만 슬라이스).
  """

  @table :dureclaw_event_log
  @cap 80
  @topic "dureclaw:events"

  @doc false
  def table, do: @table

  @doc "LiveView 가 구독할 PubSub 토픽 — 이벤트 실시간 push(3초 폴링 아님)."
  def topic, do: @topic

  defp ensure do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])

      _ ->
        @table
    end
  rescue
    ArgumentError -> @table
  end

  @doc "이벤트 1건 기록. type: :assign | :result | :route | :freeze. attrs 는 맵."
  def put(type, attrs) when is_map(attrs) do
    ensure()
    seq = :ets.update_counter(@table, :__seq__, {2, 1}, {:__seq__, 0})

    ev =
      attrs
      |> Map.merge(%{type: type, seq: seq, at: now_hms()})

    :ets.insert(@table, {seq, ev})
    if rem(seq, 20) == 0, do: trim()
    # 실시간 push — 기록 즉시 구독 중인 LiveView 로 broadcast(3초 폴링 아님).
    Phoenix.PubSub.broadcast(OpenMes.PubSub, @topic, {:dureclaw_event, ev})
    ev
  rescue
    _ -> :error
  end

  @doc "최근 n건(최신 우선)."
  def recent(n \\ 40) do
    ensure()

    :ets.tab2list(@table)
    |> Enum.reject(fn {k, _} -> k == :__seq__ end)
    |> Enum.map(fn {_, e} -> e end)
    |> Enum.sort_by(& &1.seq, :desc)
    |> Enum.take(n)
  rescue
    _ -> []
  end

  def clear do
    ensure()
    :ets.delete_all_objects(@table)
  end

  defp trim do
    items = :ets.tab2list(@table) |> Enum.reject(fn {k, _} -> k == :__seq__ end)
    over = length(items) - @cap

    if over > 0 do
      items
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.take(over)
      |> Enum.each(fn {k, _} -> :ets.delete(@table, k) end)
    end
  end

  defp now_hms do
    DateTime.utc_now() |> Calendar.strftime("%H:%M:%S")
  end
end
