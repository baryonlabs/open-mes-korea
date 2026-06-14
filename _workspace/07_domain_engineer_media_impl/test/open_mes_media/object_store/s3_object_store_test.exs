defmodule OpenMes.Media.ObjectStore.ContractTest do
  @moduledoc """
  ObjectStore behaviour 계약 검증.

  실제 MinIO/S3 통합은 인프라(§7.4)가 필요하므로 CI 단위 테스트에서는 제외하고,
  여기서는 behaviour 계약(put_file_stream/head/delete + :on_chunk 스트리밍)을
  FakeObjectStore 로 검증한다. S3ObjectStore 는 동일 계약을 ex_aws 로 구현하며,
  MinIO 연동은 통합 테스트(@tag :integration)로 분리한다.
  """
  use ExUnit.Case, async: false

  alias OpenMes.Media.Test.FakeObjectStore
  alias OpenMes.Media.ObjectStore.KeyBuilder

  @bucket "contract-bucket"

  setup do
    FakeObjectStore.setup()
    Process.delete(:fake_store_fail)

    tmp = Path.join(System.tmp_dir!(), "obj_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "put_file_stream 은 :on_chunk 로 모든 바이트를 순서대로 흘린다(스트리밍 계약)", %{tmp: tmp} do
    content = String.duplicate("X", 10_000)
    path = Path.join(tmp, "a.bin")
    File.write!(path, content)

    {:ok, agent} = Agent.start_link(fn -> <<>> end)
    on_chunk = fn c -> Agent.update(agent, fn acc -> acc <> c end) end

    assert {:ok, %{etag: _, size: 10_000}} =
             FakeObjectStore.put_file_stream(@bucket, "k", path, on_chunk: on_chunk)

    # 콜백으로 흘러간 바이트의 총합이 원본과 동일(누락/순서 보장)
    assert Agent.get(agent, & &1) == content
  end

  test "on_chunk 누적 해시가 알려진 SHA-256 과 일치한다(W-1 순서 정확성)", %{tmp: tmp} do
    # 알려진 내용 → 알려진 SHA-256. on_chunk 가 파일 바이트 순서대로(단일 패스)
    # 호출되어야만 :crypto.hash_update 누적 결과가 이 값과 일치한다.
    # 청크가 순서 없이/중복으로 도달하면 불일치한다(W-1 회귀 방지).
    content = "open-mes-korea-EXT2-known-content"
    known_sha256 = "d4be4f1feae83c62d9ff25b959e7d4085de0c1286aafe0aa2384557a54209861"

    path = Path.join(tmp, "known.bin")
    File.write!(path, content)

    # TransferWorker 와 동일한 순서 의존 누적 경로를 재현.
    {:ok, hash_agent} = Agent.start_link(fn -> :crypto.hash_init(:sha256) end)
    on_chunk = fn chunk -> Agent.update(hash_agent, &:crypto.hash_update(&1, chunk)) end

    assert {:ok, _} = FakeObjectStore.put_file_stream(@bucket, "known", path, on_chunk: on_chunk)

    computed =
      hash_agent
      |> Agent.get(&:crypto.hash_final(&1))
      |> Base.encode16(case: :lower)

    Agent.stop(hash_agent)
    assert computed == known_sha256
  end

  test "여러 청크(멀티파트 규모)에서도 누적 해시가 :crypto.hash/2 단일계산과 일치한다", %{tmp: tmp} do
    # 청크 경계가 여러 번 나뉘어도(스트리밍) 순차 누적 결과가
    # 전체를 한 번에 해시한 값과 동일해야 한다(순서·누락·중복 없음 보장).
    content = String.duplicate("NOISE", 50_000)
    expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    path = Path.join(tmp, "multi.bin")
    File.write!(path, content)

    {:ok, hash_agent} = Agent.start_link(fn -> :crypto.hash_init(:sha256) end)
    on_chunk = fn chunk -> Agent.update(hash_agent, &:crypto.hash_update(&1, chunk)) end

    assert {:ok, _} = FakeObjectStore.put_file_stream(@bucket, "multi", path, on_chunk: on_chunk)

    computed =
      hash_agent
      |> Agent.get(&:crypto.hash_final(&1))
      |> Base.encode16(case: :lower)

    Agent.stop(hash_agent)
    assert computed == expected
  end

  test "head 는 업로드된 객체의 size/etag 를 반환한다", %{tmp: tmp} do
    path = Path.join(tmp, "a.bin")
    File.write!(path, "hello")
    {:ok, _} = FakeObjectStore.put_file_stream(@bucket, "k2", path, [])

    assert {:ok, %{size: 5}} = FakeObjectStore.head(@bucket, "k2")
  end

  test "head 미존재 객체는 :not_found" do
    assert {:error, :not_found} = FakeObjectStore.head(@bucket, "없는키")
  end

  test "delete 는 object storage 객체만 제거(NAS 원본과 무관)", %{tmp: tmp} do
    path = Path.join(tmp, "a.bin")
    File.write!(path, "data")
    {:ok, _} = FakeObjectStore.put_file_stream(@bucket, "k3", path, [])

    assert :ok = FakeObjectStore.delete(@bucket, "k3")
    assert {:error, :not_found} = FakeObjectStore.head(@bucket, "k3")
    # NAS 원본(로컬 파일)은 delete 와 무관하게 보존
    assert File.exists?(path)
  end

  test "KeyBuilder 는 asset_id 를 포함해 충돌을 차단한다" do
    at = ~U[2026-06-13 08:00:00.000000Z]
    k1 = KeyBuilder.build("uuid-1", "video", "EQP-01", "/nas/EQP-01/video/2026-06-13/cam1.mp4", at)
    k2 = KeyBuilder.build("uuid-2", "video", "EQP-01", "/nas/EQP-01/video/2026-06-13/cam1.mp4", at)

    assert k1 == "video/EQP-01/2026/06/13/uuid-1_cam1.mp4"
    assert k1 != k2
  end
end
