defmodule OpenMes.Ingest.Measurement do
  @moduledoc """
  equipment_measurements hypertable 의 Ecto 스키마. 설계 §2.

  특이사항:
    - `@primary_key false` — hypertable 은 단일 surrogate PK 를 두지 않는다(설계 §2.2).
      논리적 식별은 (equipment_id, measured_at, metric_key) 조합으로 본다.
    - timestamps 자동 관리 안 함 — measured_at(디바이스 시각)/ingested_at(서버 시각)을
      Validator 에서 직접 채운다. insert_all 은 timestamps 를 자동으로 넣지 않는다.
    - append-only: 이 스키마에 대한 update/delete 함수를 제공하지 않는다.

  실제 적재는 Loader 가 `Repo.insert_all/3` 로 row map 을 직접 벌크 INSERT 한다.
  본 스키마는 테이블 정의/컬럼 매핑/조회용으로 둔다(insert_all 의 첫 인자로도 사용).
  """
  use Ecto.Schema

  @primary_key false
  schema "equipment_measurements" do
    field :equipment_id, :string
    field :metric_key, :string
    field :value, :float
    field :string_value, :string
    field :unit, :string
    field :quality, :string, default: "good"
    field :measured_at, :utc_datetime_usec
    field :ingested_at, :utc_datetime_usec
    field :work_order_id, Ecto.UUID
    field :meta, :map
  end

  @doc """
  insert_all 에 사용할 컬럼 키 목록(순수 참조용).
  Validator 가 만드는 row map 의 키와 일치해야 한다.
  """
  def insert_columns do
    [
      :equipment_id,
      :metric_key,
      :value,
      :string_value,
      :unit,
      :quality,
      :measured_at,
      :ingested_at,
      :work_order_id,
      :meta
    ]
  end
end
