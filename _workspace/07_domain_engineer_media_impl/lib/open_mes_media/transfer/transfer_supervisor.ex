defmodule OpenMes.Media.Transfer.TransferSupervisor do
  @moduledoc """
  동시 이관 수 제한(백프레셔) — Task.Supervisor + 토큰 세마포어 GenServer. (EXT-2 §4.3)

  설계: 영상은 수백 MB~GB. 동시에 많이 이관하면 NAS/네트워크/MinIO 가 포화된다.
  동시 실행 수를 `max_concurrent_transfers`(기본 3)로 제한한다.

  백프레셔 흐름:
    상한이 차면 Dispatcher 의 `try_dispatch/2` 가 거절(`:full`)을 받는다 →
    Dispatcher 가 신규 픽업을 멈춘다 → detected asset 이 DB 에 backlog 로 쌓인다
    (메모리 아님, DB 라 안전) → 슬롯이 비면 다음 주기에 픽업. EXT-1 Broadway max_demand 의
    EXT-2 버전(단위가 "동시 대용량 전송"이라 세마포어가 적합).

  이 GenServer 는 Task.Supervisor 를 자식으로 들고, 실행 슬롯 카운터를 관리한다.
  Task 가 끝나면(:DOWN) 슬롯을 반납한다.

  격리: 코어 의존 없음(워커가 Repo/ObjectStore 를 쓴다).
  """
  use GenServer
  require Logger

  alias OpenMes.Media

  defstruct [:task_sup, :limit, running: %{}]

  # ── 공개 API ──

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  이관 작업을 슬롯이 있으면 시작한다.

    * `fun` — 0-인자 함수(워커 본문). 별도 Task 로 실행된다.

  반환: `{:ok, pid}` 시작됨 | `:full` 슬롯 없음(백프레셔 — Dispatcher 가 픽업 중단).
  """
  def try_run(server \\ __MODULE__, fun) when is_function(fun, 0) do
    GenServer.call(server, {:try_run, fun})
  end

  @doc "현재 실행 중인 이관 수."
  def running_count(server \\ __MODULE__), do: GenServer.call(server, :running_count)

  @doc "여유 슬롯 수."
  def free_slots(server \\ __MODULE__), do: GenServer.call(server, :free_slots)

  # ── GenServer 콜백 ──

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :limit) || Media.max_concurrent_transfers()
    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, %__MODULE__{task_sup: task_sup, limit: limit, running: %{}}}
  end

  @impl true
  def handle_call({:try_run, _fun}, _from, %{running: running, limit: limit} = state)
      when map_size(running) >= limit do
    # 상한 도달 — 백프레셔. Dispatcher 가 이 신호를 받고 픽업을 멈춘다.
    {:reply, :full, state}
  end

  @impl true
  def handle_call({:try_run, fun}, _from, state) do
    task = Task.Supervisor.async_nolink(state.task_sup, fun)
    running = Map.put(state.running, task.ref, task.pid)
    {:reply, {:ok, task.pid}, %{state | running: running}}
  end

  @impl true
  def handle_call(:running_count, _from, state) do
    {:reply, map_size(state.running), state}
  end

  @impl true
  def handle_call(:free_slots, _from, state) do
    {:reply, max(state.limit - map_size(state.running), 0), state}
  end

  # async_nolink 결과 메시지(정상 종료) — 슬롯 반납.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | running: Map.delete(state.running, ref)}}
  end

  # Task 비정상 종료(:DOWN) — 슬롯 반납. 워커 크래시가 슬롯을 영구 점유하지 않게 함.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if reason not in [:normal, :shutdown] do
      Logger.warning("media: 이관 워커 비정상 종료 사유=#{inspect(reason)}")
    end

    {:noreply, %{state | running: Map.delete(state.running, ref)}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
