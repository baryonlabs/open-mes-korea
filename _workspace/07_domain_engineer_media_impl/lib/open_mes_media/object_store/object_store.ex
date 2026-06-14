defmodule OpenMes.Media.ObjectStore do
  @moduledoc """
  object storage 접근 계약(behaviour). (EXT-2 §3.1)

  MinIO/S3/NCP 등 S3 호환 백엔드를 교체 가능하게 추상화한다.
  대용량 바이너리(GB 영상)를 메모리에 통째로 올리지 않도록 **스트리밍 업로드를
  계약에 명시**한다. 구현체는 config 로 선택한다:

      config :open_mes, OpenMes.Media, object_store: OpenMes.Media.ObjectStore.S3ObjectStore

  테스트는 in-memory fake store 로 교체한다(behaviour 덕분에 MinIO 없이 단위 테스트 가능).

  격리 규칙: 이 모듈은 코어(`OpenMes.*`)에 의존하지 않는다. 순수 계약이다.
  """

  @type bucket :: String.t()
  @type key :: String.t()

  @doc """
  로컬/NAS 파일 경로를 스트리밍으로 업로드한다.

  **계약**: 구현체는 파일 전체를 메모리에 적재하지 않는다(멀티파트 스트리밍).
  `opts` 로 진행 중 청크를 관찰할 콜백을 전달할 수 있다:

    * `:on_chunk` — `(binary -> :ok)` 각 업로드 청크를 받는 함수
      (TransferWorker 가 SHA-256 을 단일 패스로 누적하기 위해 사용).

  반환: `{:ok, %{etag, size}}` | `{:error, term}`
  """
  @callback put_file_stream(bucket, key, source_path :: String.t(), opts :: keyword()) ::
              {:ok, %{etag: String.t(), size: non_neg_integer()}} | {:error, term()}

  @doc "객체 존재/메타 확인(이관 size 검증용)."
  @callback head(bucket, key) ::
              {:ok, %{size: non_neg_integer(), etag: String.t()}}
              | {:error, :not_found | term()}

  @doc "객체 삭제(실패 정리/duplicate 정리용). NAS 원본이 아니라 object storage 객체만 대상."
  @callback delete(bucket, key) :: :ok | {:error, term()}
end
