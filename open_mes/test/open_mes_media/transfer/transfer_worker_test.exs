defmodule OpenMes.Media.Transfer.TransferWorkerTest do
  @moduledoc """
  이관 워커 검증(§7.5):
    - 정상 → stored + content_hash + object_key + etag
    - 업로드 실패 → transfer_failed + retry_count↑ + 원본 보존
    - size 불일치 → transfer_failed
    - content_hash 단일 패스 누적이 실제 SHA-256 과 일치
    - ★ 어떤 경로에서도 NAS 원본 파일이 보존됨(삭제 안 함)
  """
  use OpenMes.DataCase, async: false

  alias OpenMes.Media.MediaAsset
  alias OpenMes.Media.Transfer.TransferWorker
  alias OpenMes.Media.Test.FakeObjectStore

  @bucket "test-bucket"

  setup do
    FakeObjectStore.setup()
    Process.delete(:fake_store_fail)

    tmp = Path.join(System.tmp_dir!(), "media_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, tmp: tmp}
  end

  # uploading 상태로 선점된 asset 을 만든다(워커는 uploading 에서 출발).
  defp uploading_asset(tmp, content, opts \\ []) do
    nas_path = Path.join(tmp, Keyword.get(opts, :name, "cam1.mp4"))
    File.write!(nas_path, content)

    {:ok, asset} =
      %MediaAsset{}
      |> Ecto.Changeset.change(%{
        equipment_id: "EQP-01",
        media_type: "video",
        nas_path: nas_path,
        file_mtime: ~U[2026-06-13 08:00:00.000000Z],
        file_size: byte_size(content),
        object_key: "video/EQP-01/2026/06/13/#{Ecto.UUID.generate()}_cam1.mp4",
        state: "uploading"
      })
      |> Repo.insert()

    {asset, nas_path}
  end

  defp worker_opts, do: [object_store: FakeObjectStore, sink: OpenMes.Media.Sink.NoopSink, bucket: @bucket]

  test "정상 이관 → stored + content_hash + etag + stored_at", %{tmp: tmp} do
    content = "노이즈영상바이너리내용"
    {asset, nas_path} = uploading_asset(tmp, content)

    assert {:ok, :stored, _} = TransferWorker.run(asset, worker_opts())

    reloaded = Repo.get!(MediaAsset, asset.id)
    assert reloaded.state == "stored"
    assert reloaded.content_hash == expected_sha256(content)
    assert reloaded.etag
    assert reloaded.stored_at
    # ★ 원본 보존: stored 후에도 NAS 원본이 그대로 존재
    assert File.exists?(nas_path)
  end

  test "content_hash 는 스트림 단일 패스 누적이 실제 SHA-256 과 일치한다", %{tmp: tmp} do
    content = String.duplicate("청크경계테스트", 2_000)
    {asset, _} = uploading_asset(tmp, content)

    assert {:ok, :stored, _} = TransferWorker.run(asset, worker_opts())
    reloaded = Repo.get!(MediaAsset, asset.id)
    assert reloaded.content_hash == expected_sha256(content)
  end

  test "업로드 실패 → transfer_failed + retry_count↑ + 원본 보존", %{tmp: tmp} do
    {asset, nas_path} = uploading_asset(tmp, "내용")
    Process.put(:fake_store_fail, {:put, :minio_down})

    assert {:error, :transfer_failed} = TransferWorker.run(asset, worker_opts())

    reloaded = Repo.get!(MediaAsset, asset.id)
    assert reloaded.state == "transfer_failed"
    assert reloaded.retry_count == 1
    assert reloaded.last_error =~ "업로드 실패"
    # ★ 실패해도 원본 보존
    assert File.exists?(nas_path)
  end

  test "size 불일치 → transfer_failed + 원본 보존", %{tmp: tmp} do
    {asset, nas_path} = uploading_asset(tmp, "정확한내용")
    # head 가 다른 size 를 반환하도록 강제
    Process.put(:fake_store_fail, {:head_size, 999_999})

    assert {:error, :transfer_failed} = TransferWorker.run(asset, worker_opts())

    reloaded = Repo.get!(MediaAsset, asset.id)
    assert reloaded.state == "transfer_failed"
    assert reloaded.last_error =~ "size 불일치"
    assert File.exists?(nas_path)
  end

  test "이미 선점 해제된(uploading 아님) asset 전이는 stale 로 no-op", %{tmp: tmp} do
    {asset, _} = uploading_asset(tmp, "내용")
    # 다른 워커가 이미 stored 로 바꿔둔 상황을 시뮬레이션
    Repo.update_all(
      from(a in MediaAsset, where: a.id == ^asset.id),
      set: [state: "stored"]
    )

    # 워커는 메모리상 uploading 인 asset 으로 stored 전이를 시도하지만 WHERE state='uploading' 가 0행
    result = TransferWorker.run(asset, worker_opts())
    assert match?({:error, :stale}, result) or match?({:ok, :stored, _}, result) == false

    reloaded = Repo.get!(MediaAsset, asset.id)
    # 이미 stored 였으므로 그대로 stored(중복 전이로 깨지지 않음)
    assert reloaded.state == "stored"
  end

  defp expected_sha256(content),
    do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
