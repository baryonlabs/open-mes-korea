defmodule OpenMes.Ingest.BufferProducer do
  @moduledoc """
  브로커리스 GenStage producer — 내부 in-memory 큐. 설계 §3, §7.2.

  외부 브로커(Kafka/MQTT) 없이, HTTP 로 들어온 수집 메시지를 내부 큐에 담고
  하류 demand 에 맞춰 디스패치한다(데이터 확보 우선 — 인프라 의존 0).

  백프레셔 흐름(설계 §3.4):
    - demand 가 있을 때만 큐에서 메시지를 내보낸다(handle_demand).
    - processors 가 포화면 demand 가 멈추고 큐가 쌓인다.
    - 큐 길이가 상한(@default_max_queue_len)을 넘으면 push/2 가 `{:error, :busy}` 를
      반환 → 컨트롤러가 HTTP 429 로 거부 → 디바이스 재전송. 끝단까지 백프레셔 전달.

  producer 교체 포인트(설계 §8.2): 외부 브로커 도입 시 Pipeline 의 producer.module 만
  BroadwayKafka.Producer 등으로 교체하면 된다. 본 모듈은 브로커리스 구현일 뿐이며,
  processors/batchers/Validator/Loader 는 그대로 재사용된다.

  Broadway producer 규약: Broadway.Message 로 감싸 디스패치한다. 본 producer 는
  ack 가 필요 없는 비영속 소스이므로 `Broadway.NoopAcknowledger` 를 사용한다.
  """
  use GenStage

  alias Broadway.Message

  # 큐 길이 상한(설계 §7.2 기본 50_000). 초과 시 push 가 {:error, :busy}.
  @default_max_queue_len 50_000

  defmodule State do
    @moduledoc false
    defstruct queue: :queue.new(), queue_len: 0, pending_demand: 0, max_queue_len: 0
  end

  # ── Broadway producer 콜백 ────────────────────────────────────

  # Broadway 가 producer.module 의 두 번째 튜플 원소(opts)를 init 으로 넘긴다.
  def init(opts) do
    max_queue_len = Keyword.get(opts, :max_queue_len, @default_max_queue_len)
    {:producer, %State{max_queue_len: max_queue_len}}
  end

  # ── 공개 API (Ingest 퍼사드가 호출) ───────────────────────────

  @doc """
  단건 메시지를 producer 큐에 적재한다.

  - 큐가 상한 미만이면 적재하고 `:ok`.
  - 상한 도달이면 적재하지 않고 `{:error, :busy}`(→ 컨트롤러 429).

  `server` 기본값은 본 producer 의 등록 이름이다(아래 process_name/1 참조).
  Broadway 가 producer 프로세스에 부여하는 이름 규칙을 사용한다.
  """
  @spec push(server :: GenServer.server(), term()) :: :ok | {:error, :busy}
  def push(server \\ default_name(), payload) do
    GenStage.call(server, {:push, payload})
  end

  @doc "현재 큐 깊이(헬스 체크/모니터링용)."
  @spec queue_len(server :: GenServer.server()) :: non_neg_integer()
  def queue_len(server \\ default_name()) do
    GenStage.call(server, :queue_len)
  end

  @doc """
  Broadway 가 producer 프로세스에 부여하는 등록 이름.
  Pipeline 이름이 `OpenMes.Ingest.Pipeline` 이고 producer concurrency 가 1 이므로
  producer 는 `OpenMes.Ingest.Pipeline.Broadway.Producer_0` 로 등록된다.
  """
  def default_name do
    Module.concat([OpenMes.Ingest.Pipeline, "Broadway.Producer_0"])
  end

  # ── GenStage 콜백 ─────────────────────────────────────────────

  # 동기 push: 큐 상한 검사 → 적재 또는 거부 → 대기 demand 즉시 충족.
  def handle_call({:push, payload}, _from, %State{} = state) do
    if state.queue_len >= state.max_queue_len do
      {:reply, {:error, :busy}, [], state}
    else
      new_queue = :queue.in(payload, state.queue)
      state = %{state | queue: new_queue, queue_len: state.queue_len + 1}
      {events, state} = take_demand(state)
      {:reply, :ok, events, state}
    end
  end

  def handle_call(:queue_len, _from, %State{} = state) do
    {:reply, state.queue_len, [], state}
  end

  # 하류 demand 수신: 누적 demand 에 더해 큐에서 가능한 만큼 디스패치.
  def handle_demand(incoming_demand, %State{} = state) do
    state = %{state | pending_demand: state.pending_demand + incoming_demand}
    {events, state} = take_demand(state)
    {:noreply, events, state}
  end

  # ── 내부: 큐와 demand 를 맞춰 Broadway.Message 리스트로 꺼낸다 ──

  defp take_demand(%State{pending_demand: 0} = state), do: {[], state}

  defp take_demand(%State{} = state) do
    count = min(state.pending_demand, state.queue_len)
    {payloads, new_queue} = dequeue(state.queue, count, [])

    messages = Enum.map(payloads, &wrap_message/1)

    state = %{
      state
      | queue: new_queue,
        queue_len: state.queue_len - count,
        pending_demand: state.pending_demand - count
    }

    {messages, state}
  end

  defp dequeue(queue, 0, acc), do: {Enum.reverse(acc), queue}

  defp dequeue(queue, n, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> dequeue(rest, n - 1, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end

  # raw payload 를 Broadway.Message 로 감싼다. 비영속 소스이므로 ack 는 noop.
  defp wrap_message(payload) do
    %Message{
      data: payload,
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end
end
