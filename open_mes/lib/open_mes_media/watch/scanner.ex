defmodule OpenMes.Media.Watch.Scanner do
  @moduledoc """
  주기적 폴링 NAS 스캐너(GenServer). (EXT-2 §2.2)

  설계 결정 — inotify/FileSystem 미채택, 폴링 채택:
    NFS/SMB 로 마운트된 NAS 에 **다른 호스트**가 쓴 변경은 watch 호스트 커널에
    inotify 이벤트로 오지 않는다(네트워크 파일시스템 근본 특성). 폴링(readdir+stat)은
    NAS 와 무관하게 동작한다. 데이터 확보 우선 — 실시간성보다 "안 놓치는 것"이 먼저.

  동작:
    매 주기(scan_interval_ms)마다 각 watch_root 를 재귀 순회하며 각 파일의 size/mtime 을
    stat 한다. 직전 관측치(prev)와 함께 Stability 게이트에 통과시키고, :stable 인 파일만
    Registrar 로 멱등 등록한다. 직전 관측치는 in-memory map(path → {size, mtime})에 보관한다.

  안정성 게이트가 2-스캔 비교를 요구하므로, 손상본(쓰기 중 파일)은 등록되지 않는다.
  멱등 등록(Registrar)이 중복을 막으므로, 같은 안정 파일을 여러 주기에서 봐도 row 는 1 개.

  격리: 코어 의존은 (Registrar 경유) Repo 한정.
  """
  use GenServer
  require Logger

  alias OpenMes.Media
  alias OpenMes.Media.Intake.Registrar
  alias OpenMes.Media.Watch.Stability

  # ── 공개 API ──

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "즉시 1회 스캔(테스트/운영 수동 트리거). 동기 호출."
  def scan_now(server \\ __MODULE__), do: GenServer.call(server, :scan_now)

  # ── GenServer 콜백 ──

  @impl true
  def init(opts) do
    roots = Keyword.get(opts, :watch_roots) || Media.watch_roots()
    interval = Keyword.get(opts, :scan_interval_ms) || Media.scan_interval_ms()
    min_quiet = Keyword.get(opts, :min_quiet_seconds) || Media.min_quiet_seconds()

    state = %{
      roots: roots,
      interval: interval,
      min_quiet: min_quiet,
      # path → %{size, mtime} 직전 관측치(안정화 size 비교용).
      seen: %{}
    }

    if roots == [] do
      Logger.info("media: Scanner 기동(watch_roots 비어 있음 — 등록 없음). 설정 확인 요망.")
    else
      Logger.info("media: Scanner 기동 roots=#{inspect(roots)} interval=#{interval}ms")
    end

    schedule(interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:scan, state) do
    new_seen = run_scan(state)
    schedule(state.interval)
    {:noreply, %{state | seen: new_seen}}
  end

  @impl true
  def handle_call(:scan_now, _from, state) do
    new_seen = run_scan(state)
    {:reply, :ok, %{state | seen: new_seen}}
  end

  # ── 내부 로직 ──

  defp schedule(interval), do: Process.send_after(self(), :scan, interval)

  # 모든 root 를 순회하며 안정 파일을 등록. 반환은 다음 주기용 새 seen map.
  defp run_scan(state) do
    now = DateTime.utc_now()

    Enum.reduce(state.roots, %{}, fn root, acc ->
      root
      |> list_files()
      |> Enum.reduce(acc, fn path, seen_acc ->
        process_file(path, root, state, now, seen_acc)
      end)
    end)
  end

  # 단일 파일: stat → Stability 판정 → :stable 이면 Registrar 등록. 항상 현재 관측치를 다음 seen 에 누적.
  defp process_file(path, root, state, now, seen_acc) do
    case stat_observation(path) do
      {:ok, curr} ->
        prev = Map.get(state.seen, path)
        opts = [min_quiet_seconds: state.min_quiet]

        case Stability.assess(prev, curr, now, opts) do
          :stable ->
            maybe_register(curr, root)

          {:pending, _reason} ->
            :ok

          :ignore ->
            :ok
        end

        # 다음 주기 비교를 위해 현재 관측치 보관(:ignore/pending 도 보관해야 안정화가 진행됨).
        Map.put(seen_acc, path, %{size: curr.size, mtime: curr.mtime})

      :error ->
        # 스캔 도중 사라졌거나 stat 실패 — seen 에서 자연 탈락(다음 스캔에 없으면 제거됨).
        seen_acc
    end
  end

  defp maybe_register(curr, root) do
    case Registrar.register(curr, root: root) do
      {:ok, :inserted, _asset} -> :ok
      {:ok, :skipped} -> :ok
      {:error, _changeset} -> :ok
    end
  rescue
    # 등록 중 예외가 나도 스캐너는 죽지 않는다(다음 파일/다음 주기 계속). 데이터 확보 우선.
    e ->
      Logger.error("media: 등록 중 예외 path=#{curr.path} 사유=#{inspect(e)}")
      :ok
  end

  # 파일 1건 stat → 관측치 map. 디렉토리/심볼릭/접근불가는 :error 로 스킵.
  defp stat_observation(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime_posix}} ->
        {:ok, %{path: path, size: size, mtime: DateTime.from_unix!(mtime_posix)}}

      _ ->
        :error
    end
  end

  # root 하위 모든 일반 파일 경로를 재귀 수집.
  # 주의: 디렉토리 진입 실패/권한 오류는 조용히 스킵(데이터 확보 우선, 한 디렉토리 실패가 전체를 막지 않음).
  defp list_files(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(root, entry)

          cond do
            File.dir?(full) -> list_files(full)
            File.regular?(full) -> [full]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end
end
