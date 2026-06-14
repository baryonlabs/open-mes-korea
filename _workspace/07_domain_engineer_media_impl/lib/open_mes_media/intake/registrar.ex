defmodule OpenMes.Media.Intake.Registrar do
  @moduledoc """
  안정화된 파일을 media_assets 에 멱등 등록(state=detected). (EXT-2 §2.4)

  멱등성 핵심(EXT-1 WorkOrder 멱등 전이 버그 교훈 — 암묵에 맡기지 않음):
    - `Repo.insert(on_conflict: :nothing, conflict_target: :media_assets_source_identity)`.
    - 같은 (nas_path, file_mtime, file_size) 가 이미 있으면 **조용히 skip**(에러 아님, 정상).
    - Scanner 가 같은 파일을 N 번 봐도 row 는 1 개. 재시작/중복 스캔에 안전.

  object_key 결정(§3.3):
    - asset_id(UUID)를 먼저 생성해 KeyBuilder 로 object_key 를 만든다.
    - key 가 등록 시점에 확정되므로 이관 워커가 그대로 사용(재시도해도 같은 key = 멱등 업로드).
    - 충돌로 INSERT 안 되면 이 UUID/키는 버려진다(이미 등록된 row 가 자기 키를 갖고 있음).

  반환:
    - `{:ok, :inserted, asset}` — 새로 등록됨
    - `{:ok, :skipped}` — 이미 존재(멱등 skip, 정상)
    - `{:error, changeset}` — 등록 데이터 자체가 부적합

  격리: 코어 의존은 `OpenMes.Repo` 한정.
  """
  require Logger

  alias OpenMes.Repo
  alias OpenMes.Media.MediaAsset
  alias OpenMes.Media.ObjectStore.KeyBuilder
  alias OpenMes.Media.Watch.PathPolicy

  @doc """
  안정화된 파일 1건을 멱등 등록한다.

    * `file` — `%{path, size, mtime}` (Scanner 가 stat 으로 채움)
    * `opts` — `:root`(PathPolicy 상대경로 추출용)
  """
  def register(%{path: path, size: size, mtime: mtime}, opts \\ []) do
    root = Keyword.get(opts, :root, "")
    derived = PathPolicy.derive(path, root)

    asset_id = Ecto.UUID.generate()
    # key 날짜 세그먼트는 captured_at 우선, 없으면 mtime 으로 폴백(결정적).
    key_at = derived.captured_at || mtime

    object_key =
      KeyBuilder.build(asset_id, derived.media_type, derived.equipment_id, path, key_at)

    attrs = %{
      id: asset_id,
      equipment_id: derived.equipment_id,
      media_type: derived.media_type,
      nas_path: path,
      file_mtime: mtime,
      file_size: size,
      object_key: object_key,
      captured_at: derived.captured_at,
      meta: derived.meta
    }

    changeset =
      attrs
      |> MediaAsset.detect_changeset()
      # detect_changeset 은 id 를 캐스트하지 않으므로 PK 를 명시 주입(키 일관성 보장).
      |> Ecto.Changeset.put_change(:id, asset_id)

    do_insert(changeset, path)
  end

  defp do_insert(changeset, path) do
    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:nas_path, :file_mtime, :file_size]
         ) do
      # on_conflict: :nothing 시 충돌이면 PG 가 row 를 반환하지 않아 id 가 nil 로 온다.
      # 이것은 "이미 존재 → skip" 의 정상 신호다(에러 아님).
      {:ok, %MediaAsset{id: nil}} ->
        {:ok, :skipped}

      {:ok, %MediaAsset{} = asset} ->
        Logger.debug("media: 신규 감지 등록 path=#{path} id=#{asset.id}")
        {:ok, :inserted, asset}

      {:error, changeset} ->
        Logger.warning("media: 등록 실패 path=#{path} 사유=#{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end
end
