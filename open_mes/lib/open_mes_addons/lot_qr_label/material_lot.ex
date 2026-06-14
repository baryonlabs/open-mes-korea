defmodule OpenMes.Addons.LotQrLabel.MaterialLot do
  @moduledoc """
  LOT QR 라벨 애드온 전용 **읽기 전용** MaterialLot 스키마.

  설계 §2 애드온③ — 코어에 아직 LOT 조회 컨텍스트가 없으므로(MVP 미구현)
  애드온이 `material_lots` 테이블을 **읽기 전용**으로 매핑한다.

  ## 읽기 전용 불변식(필수, 설계 §0-B-7 / §2.3)
    - 이 모듈은 **changeset 을 제공하지 않는다.** 즉 Repo.insert/update/delete 의
      입력이 될 수 없다(컴파일/사용 단계에서 쓰기 경로가 생기지 않는다).
    - LOT 상태(available → reserved → ...)를 **절대 변경하지 않는다.**
    - QR 라벨 생성은 LOT 데이터를 읽기만 한다 → 새 테이블 0, AuditLog 0, Outbox 0.

  코어 컨벤션 승계: PK `binary_id`, `timestamps(:utc_datetime_usec)`.
  도메인 모델(`docs/domain-model.md` §MaterialLot)의 필드를 그대로 매핑한다.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # 읽기 전용: changeset 이 없으므로 Repo 쓰기 경로의 입력이 될 수 없다.
  schema "material_lots" do
    field :lot_no, :string
    field :item_id, :binary_id
    field :lot_type, :string
    field :quantity, :decimal
    field :status, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  도메인 모델에 정의된 MaterialLot status 목록(읽기/표시용).

  쓰기 검증용이 아니라 UI 라벨/필터 표시에만 쓴다(이 애드온은 상태를 바꾸지 않는다).
  """
  @spec statuses() :: [String.t()]
  def statuses,
    do: ~w(available reserved consumed produced quarantined scrapped)

  @doc "status 코드 → 한국어 표시 라벨."
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("available"), do: "가용"
  def status_label("reserved"), do: "예약"
  def status_label("consumed"), do: "소비"
  def status_label("produced"), do: "생산"
  def status_label("quarantined"), do: "격리"
  def status_label("scrapped"), do: "폐기"
  def status_label(other) when is_binary(other), do: other
  def status_label(nil), do: "-"
end
