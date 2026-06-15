defmodule OpenMes.Ai.AiInteraction do
  @moduledoc """
  AI 상호작용(AiInteraction) Ecto 스키마 + changeset + 상태 전이 검증 — 설계 23번 §A.1/§A.2.

  모든 AI 상호작용의 감사 레코드이자 승인 흐름 상태머신의 보유자.

  상태머신(CLAUDE.md L61 — 임의 전이 추가 금지):

      proposed ──(열람)──> reviewed ──(승인)──> approved ──(적용 성공)──> executed
         │                     │                   │
         └──(거부)──> rejected ◄┘                   └──(적용 실패)──> failed

  - proposed : AI 제안 직후(부수효과 0).
  - reviewed : 승인자 열람(MVP 는 proposed→approved 직행도 허용).
  - approved : 승인 확정 — 이 시점부터 apply 가능.
  - rejected : 거부(터미널).
  - executed : 실제 step 변경 적용 완료(터미널).
  - failed   : 적용 중 오류 → 전체 롤백, 사유 기록(터미널).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # "answered" 는 25번(Level 1 읽기 조사)의 터미널 상태 — propose 상태머신을 거치지 않는
  # 평행 경로(intent="query"). proposed→... 전이 그래프(@transitions)에는 등장하지 않으며,
  # changeset 직접 생성으로만 진입한다(transition_changeset 미경유 → 23번 상태머신 무손상).
  @statuses ~w(proposed reviewed approved rejected executed failed answered)

  # 허용 전이 그래프(A.2). 이 맵에 없는 전이는 모두 차단된다.
  @transitions %{
    "proposed" => ~w(reviewed approved rejected),
    "reviewed" => ~w(approved rejected),
    "approved" => ~w(executed failed),
    # 터미널 상태 — 추가 전이 없음
    "rejected" => [],
    "executed" => [],
    "failed" => []
  }

  schema "ai_interactions" do
    field :actor_id, :string
    field :intent, :string
    field :prompt, :string
    field :response_summary, :string
    field :referenced_resources, :map
    field :proposed_action, :map
    field :approval_status, :string, default: "proposed"
    field :provider, :string
    field :reviewer_id, :string
    field :reviewed_at, :utc_datetime_usec
    field :execution_result, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required [:actor_id, :intent, :prompt, :approval_status]
  @optional [
    :response_summary,
    :referenced_resources,
    :proposed_action,
    :provider,
    :reviewer_id,
    :reviewed_at,
    :execution_result
  ]

  @doc "AI 상호작용 생성용 changeset(제안 단계)."
  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required, message: "필수 항목입니다")
    |> validate_inclusion(:approval_status, @statuses, message: "허용되지 않은 상태입니다")
    |> validate_change(:actor_id, fn :actor_id, value ->
      if is_binary(value) and String.trim(value) != "",
        do: [],
        else: [actor_id: "actor_id 는 비어 있을 수 없습니다"]
    end)
  end

  @doc """
  상태 전이용 changeset — `from` 현재 상태에서 `to` 로의 전이가 허용될 때만 통과.
  허용되지 않은 전이는 changeset 에 에러를 추가한다(상태머신 강제).
  """
  def transition_changeset(%__MODULE__{} = interaction, to_status, attrs \\ %{}) do
    interaction
    |> cast(attrs, @optional)
    |> put_change(:approval_status, to_status)
    |> validate_inclusion(:approval_status, @statuses, message: "허용되지 않은 상태입니다")
    |> validate_transition(interaction.approval_status, to_status)
  end

  @doc "from → to 전이가 상태머신에서 허용되는가."
  def allowed_transition?(from, to) do
    to in Map.get(@transitions, from, [])
  end

  @doc "상태 목록."
  def statuses, do: @statuses

  defp validate_transition(changeset, from, to) do
    if allowed_transition?(from, to) do
      changeset
    else
      add_error(changeset, :approval_status, "허용되지 않은 상태 전이입니다: #{from} → #{to}")
    end
  end
end
