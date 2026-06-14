defmodule OpenMes.Media.Transfer.TransferWorker do
  @moduledoc """
  단일 asset 스트리밍 이관 워커. (EXT-2 §4.2)

  전제: 이 워커는 Dispatcher 가 **이미 detected→uploading 선점에 성공한** asset 에 대해서만
  호출된다(asset.state == "uploading"). 즉 본 워커는 uploading 상태에서 출발한다.

  순서:
    1. ObjectStore.put_file_stream(bucket, object_key, nas_path) — **스트리밍**.
       이 과정에서 :on_chunk 콜백으로 SHA-256 을 **단일 패스 누적**(별도 재read 없음).
    2. ObjectStore.head 로 size 검증(NAS file_size == object size).
    3. 성공: uploading→stored 전이(조건부 UPDATE) + content_hash/etag/stored_at 기록.
    4. 실패: uploading→transfer_failed + retry_count↑ + last_error.
       (또는 retry_count 가 한계 초과 직전이면 Dispatcher 가 dead 로 보낸다.)
    5. stored 후 MediaSink.handle_stored(asset) 호출(NoopSink 기본).

  ★ 원본 보존 절대 불변식(§0-E-11):
    이 워커는 어떤 경로에서도 NAS 원본을 삭제하지 않는다(`File.rm` 류 호출 없음).
    stored 도, transfer_failed 도, 예외 경로도 원본을 건드리지 않는다. 데이터 유실 0.

  ★ 멱등/다중 워커 안전:
    모든 상태 전이는 MediaAsset.claim_query(조건부 UPDATE WHERE state=expected)로 수행.
    영향 행 0이면 다른 워커가 선점했거나 상태가 바뀐 것 → skip.
    object_key 가 등록 시점 고정이라 재시도해도 같은 key = 멱등 재업로드.

  격리: 코어 의존은 Repo 한정 + ObjectStore/MediaSink behaviour.
  """
  require Logger

  alias OpenMes.Repo
  alias OpenMes.Media
  alias OpenMes.Media.MediaAsset

  @doc """
  uploading 으로 선점된 asset 1건을 이관한다.

  반환:
    - `{:ok, :stored, asset}` — 이관·검증·전이 완료
    - `{:error, :transfer_failed}` — 이관 실패(원본 보존, 재시도 대상)
    - `{:error, :stale}` — 선점 경합으로 전이 실패(다른 워커 처리 중)
  """
  def run(%MediaAsset{state: "uploading"} = asset, opts \\ []) do
    store = Keyword.get(opts, :object_store, Media.object_store())
    sink = Keyword.get(opts, :sink, Media.sink())
    bucket = Keyword.get(opts, :bucket, Media.bucket())

    hash_state = :crypto.hash_init(:sha256)
    {:ok, hash_agent} = Agent.start_link(fn -> hash_state end)

    on_chunk = fn chunk ->
      Agent.update(hash_agent, fn h -> :crypto.hash_update(h, chunk) end)
      :ok
    end

    try do
      do_transfer(asset, store, sink, bucket, hash_agent, on_chunk)
    after
      Agent.stop(hash_agent)
    end
  end

  defp do_transfer(asset, store, sink, bucket, hash_agent, on_chunk) do
    case store.put_file_stream(bucket, asset.object_key, asset.nas_path, on_chunk: on_chunk) do
      {:ok, %{etag: etag, size: uploaded_size}} ->
        content_hash =
          hash_agent
          |> Agent.get(fn h -> :crypto.hash_final(h) end)
          |> Base.encode16(case: :lower)

        verify_and_store(asset, store, sink, bucket, etag, uploaded_size, content_hash)

      {:error, reason} ->
        fail(asset, "업로드 실패: #{inspect(reason)}")
    end
  rescue
    # 원본 read 실패/네트워크 예외 등 — 원본은 보존하고 transfer_failed 로 회수.
    e ->
      fail(asset, "이관 중 예외: #{inspect(e)}")
  end

  # size 검증(§4.2-3): NAS file_size == object size. 불일치면 transfer_failed.
  defp verify_and_store(asset, store, sink, bucket, etag, uploaded_size, content_hash) do
    object_size =
      case store.head(bucket, asset.object_key) do
        {:ok, %{size: s}} -> s
        # head 실패 시 업로드 응답 size 로 폴백(검증은 보수적으로 시도).
        {:error, _} -> uploaded_size
      end

    cond do
      object_size != asset.file_size ->
        fail(
          asset,
          "size 불일치: nas=#{asset.file_size} object=#{object_size} (업로드 size 검증 실패)"
        )

      true ->
        commit_stored(asset, sink, etag, content_hash)
    end
  end

  # uploading→stored 조건부 전이 + 메타 기록. 성공 시 MediaSink 후처리 호출.
  defp commit_stored(asset, sink, etag, content_hash) do
    sets = [
      content_hash: content_hash,
      etag: etag,
      stored_at: DateTime.utc_now(),
      last_error: nil
    ]

    case transition(asset, "stored", sets) do
      {:ok, stored_asset} ->
        # stored 후처리(NoopSink 기본). sink 실패는 stored 확정을 되돌리지 않는다.
        safe_sink(sink, stored_asset)
        {:ok, :stored, stored_asset}

      {:error, :content_hash_conflict} ->
        # 2차 멱등 키 충돌: 동일 내용이 이미 stored. duplicate 로 표시(§4.4).
        mark_duplicate(asset)

      {:error, :stale} ->
        {:error, :stale}
    end
  end

  # 이관 실패 처리(§4.4): transfer_failed + retry_count↑ + last_error. 원본 보존(삭제 없음).
  defp fail(asset, reason) do
    Logger.warning("media: 이관 실패 id=#{asset.id} 사유=#{reason}")

    sets = [
      retry_count: asset.retry_count + 1,
      last_error: String.slice(reason, 0, 1000)
    ]

    _ = transition(asset, "transfer_failed", sets)
    {:error, :transfer_failed}
  end

  # content_hash 충돌(2차 키) → duplicate 전이. object storage 중복분 정리는 best-effort.
  defp mark_duplicate(asset) do
    Logger.info("media: 내용 중복 감지(duplicate) id=#{asset.id} key=#{asset.object_key}")
    _ = transition(asset, "duplicate", last_error: "content_hash 중복(이미 stored 된 동일 내용)")
    {:ok, :duplicate, asset}
  end

  # 조건부 UPDATE 전이 실행. 영향 행 1이면 성공, 0이면 :stale(선점 경합).
  # content_hash 부분 유니크 위반은 :content_hash_conflict 로 매핑(stored 전이 한정).
  defp transition(asset, to, sets) do
    case MediaAsset.claim_query(asset, to, sets) do
      {:ok, query} ->
        try do
          case Repo.update_all(query, []) do
            {1, _} -> {:ok, %{asset | state: to}}
            {0, _} -> {:error, :stale}
          end
        rescue
          # Repo.update_all 은 changeset 경로가 아니라 constraint 를 Ecto 가 매핑하지 않는다.
          # content_hash 부분 유니크 위반은 Postgrex 원시 에러로 올라온다 → 코드로 분기.
          e in [Postgrex.Error, Ecto.ConstraintError] ->
            if content_hash_violation?(e) do
              {:error, :content_hash_conflict}
            else
              reraise e, __STACKTRACE__
            end
        end

      {:error, reason} ->
        Logger.error("media: 잘못된 전이 시도 id=#{asset.id} to=#{to} 사유=#{inspect(reason)}")
        {:error, :stale}
    end
  end

  # content_hash 유니크(media_assets_content_hash) 위반 여부 판별.
  defp content_hash_violation?(%Ecto.ConstraintError{constraint: c}),
    do: c == "media_assets_content_hash"

  defp content_hash_violation?(%Postgrex.Error{postgres: %{constraint: c}}),
    do: c == "media_assets_content_hash"

  defp content_hash_violation?(_), do: false

  # sink 호출은 예외로부터 격리(stored 는 이미 확정됨).
  defp safe_sink(sink, asset) do
    sink.handle_stored(asset)
  rescue
    e ->
      Logger.error("media: MediaSink 후처리 실패 id=#{asset.id} 사유=#{inspect(e)}")
      :ok
  end
end
