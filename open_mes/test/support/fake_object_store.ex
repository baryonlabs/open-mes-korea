defmodule OpenMes.Media.Test.FakeObjectStore do
  @moduledoc """
  테스트용 in-memory ObjectStore 구현(behaviour 충족). MinIO 없이 단위 테스트 가능.

  - put_file_stream: 소스 파일을 실제 청크로 읽어 :on_chunk 콜백에 흘린다
    (TransferWorker 의 SHA-256 단일 패스 누적 경로를 그대로 검증하기 위함).
    실제 바이트를 ETS 에 저장하고 etag(md5)/size 를 반환.
  - head: 저장된 객체의 size/etag 반환.
  - delete: 객체 제거.

  주입형 실패 모드(테스트 시나리오):
    - process dictionary `:fake_store_fail` = {:put, reason} | {:head_size, n} 으로
      업로드 실패 / head size 조작을 시뮬레이션.
  """
  @behaviour OpenMes.Media.ObjectStore

  @table :fake_object_store

  def setup do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@table)
    :ok
  end

  def put_object_count, do: :ets.info(@table, :size)

  @impl true
  def put_file_stream(bucket, key, source_path, opts) do
    on_chunk = Keyword.get(opts, :on_chunk, fn _ -> :ok end)

    case Process.get(:fake_store_fail) do
      {:put, reason} ->
        {:error, reason}

      _ ->
        # 실제 파일을 청크로 읽어 콜백에 흘림(스트리밍 + 해시 경로 검증).
        bytes =
          source_path
          |> File.stream!([], 4096)
          |> Enum.reduce(<<>>, fn chunk, acc ->
            on_chunk.(chunk)
            acc <> chunk
          end)

        etag = bytes |> :erlang.md5() |> Base.encode16(case: :lower)
        :ets.insert(@table, {{bucket, key}, bytes, etag})
        {:ok, %{etag: etag, size: byte_size(bytes)}}
    end
  end

  @impl true
  def head(bucket, key) do
    forced = Process.get(:fake_store_fail)

    case :ets.lookup(@table, {bucket, key}) do
      [{_, bytes, etag}] ->
        size =
          case forced do
            {:head_size, n} -> n
            _ -> byte_size(bytes)
          end

        {:ok, %{size: size, etag: etag}}

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def delete(bucket, key) do
    :ets.delete(@table, {bucket, key})
    :ok
  end
end
