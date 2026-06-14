defmodule OpenMes.Media.PipelineTest do
  @moduledoc """
  감지→이관→인덱싱 통합 흐름 + 멱등 중복 스캔 + 원본 보존 검증(§7.5, §9).

  Scanner 의 시간 기반 안정화는 단위 테스트(StabilityTest)에서 다루므로, 여기서는
  Registrar(detected) → Dispatcher(선점·디스패치) → TransferWorker(stored) 파이프라인을
  실제 GenServer(Supervisor/Dispatcher)로 엮어 검증한다.
  """
  use OpenMes.DataCase, async: false

  alias OpenMes.Media.MediaAsset
  alias OpenMes.Media.Intake.Registrar
  alias OpenMes.Media.Transfer.{Dispatcher, TransferSupervisor}
  alias OpenMes.Media.Test.FakeObjectStore

  @bucket "test-bucket"
  @mtime ~U[2026-06-13 08:00:00.000000Z]

  setup do
    FakeObjectStore.setup()

    tmp = Path.join(System.tmp_dir!(), "media_pipe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, sup} = TransferSupervisor.start_link(name: nil, limit: 2)
    # Sandbox 를 GenServer 들이 공유하도록 allow.
    Ecto.Adapters.SQL.Sandbox.allow(OpenMes.Repo, self(), sup)

    worker_opts = [object_store: FakeObjectStore, sink: OpenMes.Media.Sink.NoopSink, bucket: @bucket]

    {:ok, disp} =
      Dispatcher.start_link(
        name: nil,
        supervisor: sup,
        worker_opts: worker_opts,
        max_retries: 5
      )

    Ecto.Adapters.SQL.Sandbox.allow(OpenMes.Repo, self(), disp)

    {:ok, tmp: tmp, sup: sup, disp: disp}
  end

  defp drop_file(tmp, name, content) do
    path = Path.join(tmp, name)
    File.write!(path, content)
    %{path: path, size: byte_size(content), mtime: @mtime}
  end

  defp wait_until(fun, tries \\ 50)
  defp wait_until(_fun, 0), do: flunk("조건이 시간 내에 충족되지 않음")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, tries - 1)
    end
  end

  test "감지 → 디스패치 → 이관 → stored (인덱싱 메타 채워짐, 원본 보존)", ctx do
    f = drop_file(ctx.tmp, "cam1.mp4", "영상바이너리")
    assert {:ok, :inserted, asset} = Registrar.register(f, root: ctx.tmp)
    assert asset.state == "detected"

    # 디스패처 1회 실행 → detected 선점·이관 제출
    assert Dispatcher.dispatch_now(ctx.disp) == 1

    wait_until(fn ->
      Repo.get!(MediaAsset, asset.id).state == "stored"
    end)

    stored = Repo.get!(MediaAsset, asset.id)
    assert stored.state == "stored"
    assert stored.content_hash
    assert stored.object_key
    assert stored.stored_at
    # ★ 원본 보존: object storage 적재 후에도 NAS 원본 보존
    assert File.exists?(f.path)
    # object storage 에 1건 적재됨
    assert FakeObjectStore.put_object_count() == 1
  end

  test "같은 파일 중복 스캔(N회 등록) 후 파이프라인 → asset 1개, object 1건 (멱등)", ctx do
    f = drop_file(ctx.tmp, "cam1.mp4", "영상")

    assert {:ok, :inserted, _} = Registrar.register(f, root: ctx.tmp)
    assert {:ok, :skipped} = Registrar.register(f, root: ctx.tmp)
    assert {:ok, :skipped} = Registrar.register(f, root: ctx.tmp)

    Dispatcher.dispatch_now(ctx.disp)
    wait_until(fn -> Repo.aggregate(from(a in MediaAsset, where: a.state == "stored"), :count) == 1 end)

    assert Repo.aggregate(MediaAsset, :count) == 1
    assert FakeObjectStore.put_object_count() == 1
  end

  test "재시도 소진(retry_count > max_retries) → Dispatcher 가 dead 로 매장, 원본 끝까지 보존", ctx do
    f = drop_file(ctx.tmp, "cam1.mp4", "영상")
    {:ok, :inserted, asset} = Registrar.register(f, root: ctx.tmp)

    # 이관이 반복 실패해 retry_count 가 한계(max_retries=5)를 초과한 상황을 직접 구성.
    # (워커의 transfer_failed 전이 자체는 TransferWorkerTest 에서 검증; 여기선 dead 매장 경로.)
    Repo.update_all(
      from(a in MediaAsset, where: a.id == ^asset.id),
      set: [state: "transfer_failed", retry_count: 6]
    )

    Dispatcher.dispatch_now(ctx.disp)

    reloaded = Repo.get!(MediaAsset, asset.id)
    assert reloaded.state == "dead"
    # ★ dead 여도 원본 보존(절대 삭제 금지 — 데이터 유실 0)
    assert File.exists?(f.path)
  end
end
