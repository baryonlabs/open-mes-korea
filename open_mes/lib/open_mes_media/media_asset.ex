defmodule OpenMes.Media.MediaAsset do
  @moduledoc """
  멀티미디어 자산(media_assets) Ecto 스키마 + changeset + 전이 쿼리 헬퍼.

  설계 근거: `_workspace/05_architect_media_ingest_design.md` §5.

  책임:
    - DB 매핑(필드/타입)과 등록 시 필드 검증.
    - 상태 전이 유효성은 `OpenMes.Media.StateMachine` 에 위임한다.
    - 다중 워커 안전을 위한 조건부 선점 쿼리(`claim_query/2`)를 제공한다.

  텔레메트리 경계(§0-C):
    media_assets 는 도메인 트랜잭션이 아니라 수집 운영 인덱스이므로
    AuditLog/actor_id/코어 FK 가 없다. 이는 누락이 아니라 의도된 설계 경계다.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias OpenMes.Media.StateMachine

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @media_types ~w(audio video image)
  @states StateMachine.states()

  @type t :: %__MODULE__{}

  schema "media_assets" do
    field :equipment_id, :string
    field :media_type, :string

    field :nas_path, :string
    field :file_mtime, :utc_datetime_usec
    field :file_size, :integer

    field :content_hash, :string
    field :object_key, :string
    field :etag, :string

    field :state, :string, default: "detected"
    field :retry_count, :integer, default: 0
    field :last_error, :string

    field :captured_at, :utc_datetime_usec
    field :stored_at, :utc_datetime_usec
    field :meta, :map

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  감지 등록용 changeset(state=detected 강제).

  Registrar 가 안정화된 파일을 멱등 INSERT 할 때 사용한다.
  state 는 캐스트 대상에서 제외하고 항상 "detected" 로 강제한다(등록 경로로 다른 상태 진입 금지).
  """
  def detect_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :equipment_id,
      :media_type,
      :nas_path,
      :file_mtime,
      :file_size,
      :object_key,
      :captured_at,
      :meta
    ])
    |> validate_required([:equipment_id, :media_type, :nas_path, :file_mtime, :file_size],
      message: "필수 항목입니다"
    )
    |> validate_inclusion(:media_type, @media_types, message: "허용되지 않은 미디어 종류입니다")
    |> validate_number(:file_size, greater_than_or_equal_to: 0, message: "파일 크기는 음수일 수 없습니다")
    # 등록 시 상태는 항상 detected 로 강제(클라이언트/호출자가 state 를 보내도 무시).
    |> put_change(:state, "detected")
    |> put_change(:retry_count, 0)
  end

  @doc """
  주어진 asset 의 상태를 `from` → `to` 로 선점 전이시키는 조건부 UPDATE 쿼리를 만든다.

  핵심(다중 워커 안전 + 멱등 — EXT-1 멱등 버그 교훈):
    - `WHERE id = ^id AND state = ^from` 조건이 핵심이다.
    - 이 쿼리를 `Repo.update_all/2` 로 실행해 영향 행이 1이면 내가 선점한 것,
      0이면 다른 워커가 이미 가져갔거나 상태가 바뀐 것(no-op skip).
    - 같은 전이를 두 번 시도해도 두 번째는 영향 행 0이라 안전하다.

  허용되지 않은 전이(StateMachine 화이트리스트 밖)는 쿼리를 만들지 않고 {:error, reason} 반환.

  `extra_sets` 로 전이 시 함께 갱신할 컬럼을 넘긴다(예: stored 전이 시 object_key/etag/content_hash).
  updated_at 은 자동 갱신한다.
  """
  def claim_query(%__MODULE__{id: id, state: from}, to, extra_sets \\ []) do
    cond do
      not (to in @states) ->
        {:error, {:unknown_state, to}}

      not StateMachine.can_transition?(from, to) ->
        {:error, {:invalid_transition, from, to}}

      true ->
        sets =
          extra_sets
          |> Keyword.put(:state, to)
          |> Keyword.put(:updated_at, DateTime.utc_now())

        query =
          from a in __MODULE__,
            where: a.id == ^id and a.state == ^from,
            update: [set: ^sets]

        {:ok, query}
    end
  end
end
