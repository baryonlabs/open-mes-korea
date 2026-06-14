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
    # 멱등 등록의 핵심 신호(insert vs skip)를 PK(id) 로 판별하면 안 된다.
    # id 는 앱이 put_change 로 직접 주입하는 client-PK 이므로, on_conflict 충돌로
    # 실제 INSERT 가 일어나지 않아도 Repo.insert 가 돌려주는 struct 의 id 는 항상
    # 우리가 넣은 값(절대 nil 아님)이다. 따라서 "id == nil → skip" 판별은 틀린다.
    #
    # PostgreSQL `ON CONFLICT DO NOTHING RETURNING` 은 **실제로 INSERT 된 행만**
    # RETURNING 으로 돌려준다(충돌 skip 시 0행). insert_all 의 affected-count(=쳐낸 행 수)로
    # insert/skip 을 확실히 구분한다.
    if changeset.valid? do
      entry = insert_entry(changeset)

      {count, _} =
        Repo.insert_all(MediaAsset, [entry],
          on_conflict: :nothing,
          conflict_target: [:nas_path, :file_mtime, :file_size]
        )

      case count do
        0 ->
          # 충돌(이미 존재) → 조용히 skip(정상). 새 행/AuditLog/object 0.
          {:ok, :skipped}

        1 ->
          asset = Repo.get!(MediaAsset, entry.id)
          Logger.debug("media: 신규 감지 등록 path=#{path} id=#{asset.id}")
          {:ok, :inserted, asset}
      end
    else
      changeset = %{changeset | action: :insert}
      Logger.warning("media: 등록 실패 path=#{path} 사유=#{inspect(changeset.errors)}")
      {:error, changeset}
    end
  end

  # changeset 의 변경값 + 자동 timestamps 를 insert_all 입력 맵으로 변환한다.
  defp insert_entry(changeset) do
    now = DateTime.utc_now()

    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.take([
      :id,
      :equipment_id,
      :media_type,
      :nas_path,
      :file_mtime,
      :file_size,
      :content_hash,
      :object_key,
      :etag,
      :state,
      :retry_count,
      :last_error,
      :captured_at,
      :stored_at,
      :meta
    ])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Map.put(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end
end
