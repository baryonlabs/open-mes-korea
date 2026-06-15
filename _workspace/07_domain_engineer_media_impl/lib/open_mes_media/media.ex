defmodule OpenMes.Media do
  @moduledoc """
  멀티미디어 수집 확장(EXT-2) 퍼사드.

  설계 근거: `_workspace/05_architect_media_ingest_design.md` §1.3, §6.1.

  공개 진입점:
    - `enabled?/0` — config 플래그. application.ex 가 watch/transfer child 기동 여부 결정.
    - config 접근 헬퍼(object_store/sink/bucket/watch_roots 등).
    - 상태 조회(`list_by_state/2`, `get_asset/1`).

  격리: 코어(`OpenMes.*`)에 대한 의존은 `OpenMes.Repo` 한정.
  (Sink 구현체만 후속에서 `OpenMes.Outbox` 를 참조할 수 있다 — MVP NoopSink 는 무의존.)
  """
  import Ecto.Query, only: [from: 2]

  alias OpenMes.Repo
  alias OpenMes.Media.MediaAsset

  @config_key {:open_mes, __MODULE__}

  @doc """
  확장 활성화 여부. 기본 false(코어는 false 여도 완전 동작).

  application.ex 의 `media_children/0` 와 라우터 `/media` scope 가 이 값으로 게이트된다.
  """
  def enabled? do
    config(:enabled, false) == true
  end

  @doc "선택된 ObjectStore 구현 모듈."
  def object_store, do: config(:object_store, OpenMes.Media.ObjectStore.S3ObjectStore)

  @doc "선택된 MediaSink 구현 모듈(기본 NoopSink)."
  def sink, do: config(:sink, OpenMes.Media.Sink.NoopSink)

  @doc "object storage 버킷명."
  def bucket, do: config(:bucket, "open-mes-media")

  @doc "watch 대상 루트 디렉토리 목록."
  def watch_roots, do: config(:watch_roots, [])

  @doc "스캔 주기(ms)."
  def scan_interval_ms, do: config(:scan_interval_ms, 5_000)

  @doc "안정화 mtime 유예(초)."
  def min_quiet_seconds, do: config(:min_quiet_seconds, 10)

  @doc "이관 디스패치 주기(ms)."
  def dispatch_interval_ms, do: config(:dispatch_interval_ms, 2_000)

  @doc "동시 이관 상한(백프레셔)."
  def max_concurrent_transfers, do: config(:max_concurrent_transfers, 3)

  @doc "이관 최대 재시도 횟수(초과 시 dead)."
  def max_retries, do: config(:max_retries, 5)

  @doc "uploading 회수 임계(초). 이 시간 넘게 uploading 인 asset 은 stale 로 보고 회수."
  def stale_uploading_seconds, do: config(:stale_uploading_seconds, 1_800)

  @doc "특정 상태의 asset 목록을 오래된 순으로 조회."
  def list_by_state(state, limit \\ 100) when is_binary(state) do
    Repo.all(
      from a in MediaAsset,
        where: a.state == ^state,
        order_by: [asc: a.inserted_at],
        limit: ^limit
    )
  end

  @doc "asset 단건 조회(nil 가능)."
  def get_asset(id), do: Repo.get(MediaAsset, id)

  # config 접근 헬퍼. 키워드 리스트에서 키를 읽는다.
  defp config(key, default) do
    {app, mod} = @config_key
    app |> Application.get_env(mod, []) |> Keyword.get(key, default)
  end
end
