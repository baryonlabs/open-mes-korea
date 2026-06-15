defmodule OpenMes.Media.ObjectStore.S3ObjectStore do
  @moduledoc """
  ObjectStore 의 MinIO/S3 기본 구현(ex_aws 멀티파트 스트리밍). (EXT-2 §3.2)

  MinIO 는 S3 API 호환이므로 endpoint/credential 만 MinIO 로 설정한다.
  endpoint/credential 은 config(:ex_aws, ...) 에서 읽는다(§3.2 runtime config).

  **스트리밍 절대 규칙(GB 영상 OOM 방지)**:
    `ExAws.S3.Upload.stream_file/1` 로 파일을 청크 스트림으로 흘려 멀티파트 업로드한다.
    `File.read/1` 로 전체를 메모리에 올리지 않는다.

  **순차 단일 패스 해시(content_hash)** (W-1 수정):
    `:on_chunk` 콜백은 **업로드 스트림이 아니라**, 본 구현이 직접 여는
    `File.stream!/3` 의 청크를 `Enum.reduce` 로 **순차(단일 스레드, 파일 바이트 순서)**
    하게 흘려 호출자(TransferWorker)가 SHA-256 을 누적하게 한다.

    왜 업로드 스트림에서 분리하는가:
      `ExAws.S3.upload` 의 멀티파트는 파트를 **동시(parallel)** 처리할 수 있어,
      청크가 파일 바이트 순서대로 `:on_chunk` 에 도달한다는 보장이 없다.
      해시 누적은 순서 의존적(`:crypto.hash_update`)이므로, 순서가 어긋나면
      content_hash(2차 멱등 키)가 원본 SHA-256 과 불일치할 수 있다(W-1).
      따라서 해시는 **순서가 보장된 별도 순차 read** 위에서 계산하고,
      업로드는 동시성을 그대로 허용해 대용량 스트리밍 성능을 해치지 않는다.

    `File.stream!`(청크 스트림)이므로 GB 영상도 메모리에 통째로 올리지 않는다
    (`File.read` 금지 원칙 준수 — 청크 단위 순차 read 일 뿐 전체 적재 아님).

  격리: 코어(`OpenMes.*`)에 의존하지 않는다.
  """
  @behaviour OpenMes.Media.ObjectStore

  require Logger

  # ex_aws upload 청크 크기(영상 대비. §8.4 — 기본 5MB 보다 크게 잡아 파트 수 절감).
  @chunk_bytes 16 * 1024 * 1024

  # 해시 누적용 순차 read 청크 크기(업로드 파트와 무관. 작게 잡아 메모리 상한 통제).
  @hash_chunk_bytes 1024 * 1024

  @impl true
  def put_file_stream(bucket, key, source_path, opts \\ []) do
    on_chunk = Keyword.get(opts, :on_chunk, fn _ -> :ok end)

    with {:ok, %File.Stat{size: size}} <- File.stat(source_path) do
      # (W-1) 해시는 순서가 보장된 순차 단일 패스로 먼저 누적한다.
      #   업로드의 (동시성 가능) 멀티파트 스트림과 분리해 content_hash 정확성을 보장.
      #   File.stream! 은 청크 스트림이므로 전체 메모리 적재가 아니다(`File.read/1` 금지 준수).
      stream_hash_sequentially(source_path, on_chunk)

      # 업로드는 동시성을 그대로 허용해 대용량 스트리밍 성능을 유지한다.
      result =
        source_path
        |> ExAws.S3.Upload.stream_file(chunk_size: @chunk_bytes)
        |> ExAws.S3.upload(bucket, key, content_type: content_type(key))
        |> ExAws.request(ex_aws_overrides())

      case result do
        {:ok, %{headers: headers}} ->
          {:ok, %{etag: etag_from_headers(headers), size: size}}

        {:ok, _other} ->
          # 멀티파트 완료 응답 형태가 환경에 따라 다를 수 있어 head 로 보강(검증은 워커가 한다).
          {:ok, %{etag: nil, size: size}}

        {:error, reason} ->
          Logger.warning("media: object storage 업로드 실패 key=#{key} 사유=#{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def head(bucket, key) do
    case ExAws.S3.head_object(bucket, key) |> ExAws.request(ex_aws_overrides()) do
      {:ok, %{headers: headers}} ->
        size =
          headers
          |> header_value("content-length")
          |> parse_int()

        {:ok, %{size: size, etag: etag_from_headers(headers)}}

      {:error, {:http_error, 404, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(bucket, key) do
    case ExAws.S3.delete_object(bucket, key) |> ExAws.request(ex_aws_overrides()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── 내부 헬퍼 ──

  # (W-1) 파일을 순차 단일 패스(파일 바이트 순서, 단일 스레드)로 흘려 :on_chunk 을 호출한다.
  #   - Enum.reduce 로 청크를 순서대로 소비하므로 on_chunk 호출 순서 = 파일 바이트 순서.
  #   - SHA-256 누적(:crypto.hash_update)의 순서 의존성을 안전하게 만족한다.
  #   - File.stream!(@hash_chunk_bytes) 청크 단위 read — 전체를 메모리에 올리지 않는다.
  defp stream_hash_sequentially(source_path, on_chunk) do
    source_path
    |> File.stream!([], @hash_chunk_bytes)
    |> Enum.reduce(:ok, fn chunk, :ok ->
      on_chunk.(IO.iodata_to_binary(chunk))
      :ok
    end)

    :ok
  end

  # config 의 ex_aws 설정을 그대로 쓰되, 호출 단위 override 여지를 남긴다(테스트/멀티엔드포인트).
  defp ex_aws_overrides, do: []

  defp etag_from_headers(headers) do
    headers
    |> header_value("etag")
    |> case do
      nil -> nil
      v -> String.trim(v, "\"")
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  defp parse_int(nil), do: 0

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp content_type(key) do
    case key |> Path.extname() |> String.downcase() do
      ".mp4" -> "video/mp4"
      ".mov" -> "video/quicktime"
      ".avi" -> "video/x-msvideo"
      ".mkv" -> "video/x-matroska"
      ".wav" -> "audio/wav"
      ".flac" -> "audio/flac"
      ".mp3" -> "audio/mpeg"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      _ -> "application/octet-stream"
    end
  end
end
