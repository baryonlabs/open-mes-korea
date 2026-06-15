defmodule OpenMes.Media.Transfer.Dispatcher do
  @moduledoc """
  detected/transfer_failed asset 픽업·디스패치(GenServer poll). (EXT-2 §4.1)

  매 주기(dispatch_interval_ms)마다:
    1. stale uploading 회수(§8.4): 너무 오래 uploading 인 asset(노드 재시작 등으로
       이관 중단)을 transfer_failed 로 되돌려 재이관 가능하게 한다. object_key 동일 =
       멱등 재업로드.
    2. transfer_failed 중 retry_count > max_retries 인 것을 dead 로 보낸다(원본 보존).
    3. detected/transfer_failed(재시도 가능) asset 을 소량 조회 → 각 건을
       **조건부 UPDATE 로 detected/transfer_failed → uploading 선점**(WHERE state=expected).
       영향 행 1일 때만 TransferSupervisor 로 워커 제출. 0이면 다른 워커 선점 → skip.

  백프레셔(§4.3):
    TransferSupervisor.try_run 이 :full 이면 픽업을 즉시 멈춘다. 남은 detected 는 DB 에
    backlog 로 남아 다음 주기에 처리(메모리 아님). NAS/네트워크/MinIO 포화 방지.

  ★ 멱등/다중 워커 안전(EXT-1 멱등 버그 교훈):
    픽업의 핵심은 조건부 UPDATE 선점이다. 같은 asset 을 두 워커가 동시에 보더라도
    UPDATE WHERE state='detected' 는 정확히 하나만 성공한다.

  격리: 코어 의존은 Repo 한정.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias OpenMes.Repo
  alias OpenMes.Media
  alias OpenMes.Media.MediaAsset
  alias OpenMes.Media.Transfer.{TransferSupervisor, TransferWorker}

  @batch_limit 20

  # ── 공개 API ──

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "즉시 1회 디스패치(테스트/수동 트리거). 동기 호출. 제출된 워커 수 반환."
  def dispatch_now(server \\ __MODULE__), do: GenServer.call(server, :dispatch_now)

  # ── GenServer 콜백 ──

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :dispatch_interval_ms) || Media.dispatch_interval_ms()

    state = %{
      interval: interval,
      max_retries: Keyword.get(opts, :max_retries) || Media.max_retries(),
      stale_seconds: Keyword.get(opts, :stale_uploading_seconds) || Media.stale_uploading_seconds(),
      supervisor: Keyword.get(opts, :supervisor, TransferSupervisor),
      worker_opts: Keyword.get(opts, :worker_opts, [])
    }

    schedule(interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:dispatch, state) do
    _ = run_dispatch(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:dispatch_now, _from, state) do
    submitted = run_dispatch(state)
    {:reply, submitted, state}
  end

  # ── 내부 로직 ──

  defp schedule(interval), do: Process.send_after(self(), :dispatch, interval)

  defp run_dispatch(state) do
    recover_stale_uploading(state)
    bury_exhausted(state)
    pickup_and_dispatch(state)
  end

  # ① stale uploading 회수: now - updated_at > stale_seconds 인 uploading → transfer_failed.
  #    노드 재시작으로 이관이 중단된 asset 을 재이관 가능 상태로 되돌린다.
  defp recover_stale_uploading(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.stale_seconds, :second)

    {count, _} =
      from(a in MediaAsset,
        where: a.state == "uploading" and a.updated_at < ^cutoff
      )
      |> Repo.update_all(
        set: [state: "transfer_failed", last_error: "uploading 시간 초과 회수(stale)", updated_at: DateTime.utc_now()]
      )

    if count > 0, do: Logger.info("media: stale uploading #{count}건 회수 → transfer_failed")
    count
  end

  # ② 재시도 소진 매장: transfer_failed 이고 retry_count > max_retries → dead(원본 보존).
  defp bury_exhausted(state) do
    {count, _} =
      from(a in MediaAsset,
        where: a.state == "transfer_failed" and a.retry_count > ^state.max_retries
      )
      |> Repo.update_all(set: [state: "dead", updated_at: DateTime.utc_now()])

    if count > 0, do: Logger.warning("media: 재시도 소진 #{count}건 → dead(원본 보존, 수동 조치 대상)")
    count
  end

  # ③ 픽업 + 조건부 선점 + 워커 제출. 백프레셔(:full)면 즉시 중단.
  defp pickup_and_dispatch(state) do
    candidates = fetch_candidates(state.max_retries)

    Enum.reduce_while(candidates, 0, fn asset, submitted ->
      case claim(asset) do
        {:ok, claimed} ->
          case submit(claimed, state) do
            :ok -> {:cont, submitted + 1}
            # 슬롯 없음(백프레셔) — 선점은 했지만 실행 못 함. uploading 으로 남으면 다음 주기
            # stale 회수 또는 즉시 재시도가 곤란하므로, 다음 주기에 바로 픽업되도록
            # transfer_failed 로 되돌린다(retry_count 증가 없이).
            :full ->
              release_back(claimed)
              {:halt, submitted}
          end

        :skip ->
          # 다른 워커가 선점했거나 상태가 바뀜 — 건너뜀.
          {:cont, submitted}
      end
    end)
  end

  # 픽업 대상: detected + 재시도 가능한 transfer_failed(retry_count <= max_retries).
  # 오래된 것 우선. 소량(batch_limit)만.
  defp fetch_candidates(max_retries) do
    from(a in MediaAsset,
      where:
        a.state == "detected" or
          (a.state == "transfer_failed" and a.retry_count <= ^max_retries),
      order_by: [asc: a.inserted_at],
      limit: ^@batch_limit
    )
    |> Repo.all()
  end

  # 조건부 UPDATE 선점: state=현재상태 → uploading. 영향 행 1이면 내가 가져옴.
  defp claim(%MediaAsset{state: from} = asset) do
    {:ok, query} = MediaAsset.claim_query(asset, "uploading")

    case Repo.update_all(query, []) do
      {1, _} ->
        Logger.debug("media: 선점 #{from}→uploading id=#{asset.id}")
        {:ok, %{asset | state: "uploading"}}

      {0, _} ->
        :skip
    end
  end

  # 선점한 asset 을 TransferSupervisor 의 제한된 슬롯에서 실행 시도.
  defp submit(asset, state) do
    fun = fn -> TransferWorker.run(asset, state.worker_opts) end

    case TransferSupervisor.try_run(state.supervisor, fun) do
      {:ok, _pid} -> :ok
      :full -> :full
    end
  end

  # 백프레셔로 실행 못 한 선점 asset 을 다음 주기 즉시 재픽업되도록 transfer_failed 로 환원.
  # retry_count 는 증가시키지 않는다(이관 시도 자체가 없었으므로 실패가 아님).
  defp release_back(asset) do
    {:ok, query} = MediaAsset.claim_query(asset, "transfer_failed", last_error: nil)
    Repo.update_all(query, [])
    :ok
  end
end
