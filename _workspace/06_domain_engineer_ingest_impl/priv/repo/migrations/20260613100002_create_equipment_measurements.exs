defmodule OpenMes.Repo.Migrations.CreateEquipmentMeasurements do
  @moduledoc """
  설비 텔레메트리 hypertable(equipment_measurements) 생성. 설계 §2.

  성격: 고빈도 append-only 시계열. 수정/삭제 없음(append-only 자체가 이력성 보장).
  따라서 코어의 "모든 쓰기에 AuditLog" 원칙 적용 대상이 아니다(설계 §0-B, §7.3).

  격리 규칙:
    - 코어 13개 엔티티와 테이블 레벨로 분리. 코어 테이블을 FK 참조하지 않는다
      (고빈도 적재 시 FK 검증 비용 회피, 도메인 트랜잭션과 결합 안 함).
    - equipment_id 는 코어 ProductionResult.equipment_id 와 의미상 동일하나 FK 없음.

  PK 전략: 단일 binary_id PK 를 쓰지 않는다(설계 §2.2).
    hypertable 은 파티셔닝 컬럼(measured_at)이 인덱스/제약에 포함되어야 하고,
    고빈도 row 에 UUID 생성/저장 비용을 회피하기 위해 surrogate id 를 두지 않는다.
    논리적 식별은 (equipment_id, measured_at, metric_key) 조합으로 충분.
  """
  use Ecto.Migration

  def up do
    create table(:equipment_measurements, primary_key: false) do
      # 설비 식별자. 코어 equipment_id 와 의미 동일(FK 없음).
      add :equipment_id, :string, null: false
      # 측정 항목 키. 예: temperature / pressure / cycle_count / state
      add :metric_key, :string, null: false
      # 수치 측정값(double precision). string_value 와 상호배타적.
      add :value, :float
      # 상태/문자형 측정값. 예: running. value 와 상호배타적.
      add :string_value, :string
      # 단위. 예: degC / bar
      add :unit, :string
      # 측정 품질 플래그. good / uncertain / bad
      add :quality, :string, null: false, default: "good"
      # 파티셔닝 차원 — 디바이스가 측정한 시각
      add :measured_at, :utc_datetime_usec, null: false
      # 서버 수집 시각(수집 지연 측정용)
      add :ingested_at, :utc_datetime_usec, null: false
      # (옵션) 수집 시점 작업지시 컨텍스트. 디바이스가 보내면 보존. FK 없음.
      add :work_order_id, :binary_id
      # 디바이스 부가 정보(라인/슬롯 등). 스키마 유연성 확보.
      add :meta, :map
    end

    # 시계열 조회의 핵심 인덱스: 설비+측정항목별 시간 조회
    create index(:equipment_measurements, [:equipment_id, :metric_key, :measured_at])

    # hypertable 전환. chunk 7일 간격은 시작값(데이터량 보고 후속 조정).
    execute """
    SELECT create_hypertable('equipment_measurements', 'measured_at',
      chunk_time_interval => INTERVAL '7 days',
      if_not_exists => TRUE);
    """

    # value / string_value 중 하나는 반드시 존재(최후 방어선; 1차 검증은 앱 Validator).
    execute """
    ALTER TABLE equipment_measurements
      ADD CONSTRAINT equipment_measurements_value_present
      CHECK (value IS NOT NULL OR string_value IS NOT NULL);
    """

    # 품질 플래그 화이트리스트(잘못된 직접 INSERT 방어).
    execute """
    ALTER TABLE equipment_measurements
      ADD CONSTRAINT equipment_measurements_quality_check
      CHECK (quality IN ('good','uncertain','bad'));
    """
  end

  def down do
    # hypertable 도 일반 테이블처럼 drop 으로 제거된다(chunk 까지 함께 제거).
    drop table(:equipment_measurements)
  end

  # MVP 범위 명시: retention policy / continuous aggregate / compression 은 이번 범위 밖.
  # 데이터 누적 후 운영 데이터를 보고 후속 마이그레이션으로 추가한다(설계 §8.3).
end
