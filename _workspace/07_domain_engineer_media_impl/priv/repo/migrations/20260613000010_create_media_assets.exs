defmodule OpenMes.Repo.Migrations.CreateMediaAssets do
  @moduledoc """
  멀티미디어 수집 메타데이터(media_assets) 테이블 생성. (EXT-2)

  설계 근거: `_workspace/05_architect_media_ingest_design.md` §5.3.

  성격(중요 — qa-auditor 오탐 방지):
    - `media_assets` 는 도메인 트랜잭션이 아니라 **수집 운영 인덱스**다(고빈도 텔레메트리에 준함).
    - 따라서 코어의 "모든 쓰기에 AuditLog" 원칙이 적용되지 않는다(§0-C 경계).
    - actor_id 컬럼 없음 — 출처는 `equipment_id` + `nas_path`(설비 출처가 곧 출처).
    - 코어 테이블 FK 참조 없음 — 수집/도메인 분리 의도(EXT-1과 동일).

  멱등성(중요 — EXT-1 WorkOrder 멱등 전이 버그 교훈):
    - 멱등성을 암묵에 맡기지 않고 DB 유니크 제약 2단계로 못 박는다(§2.4).
    - 1차 키: (nas_path, file_mtime, file_size) — stat 결과만으로 빠른 중복 차단.
    - 2차 키: content_hash(부분 유니크) — 이관 중 계산하는 내용 기반 최종 방어선.

  PK 는 코어 컨벤션대로 binary_id(UUID). hypertable 이 아닌 저~중빈도 운영 인덱스다.
  """
  use Ecto.Migration

  def change do
    create table(:media_assets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # 출처 설비. EXT-1 equipment_measurements.equipment_id 와 동일 식별자 규약(FK 없음, §2.5).
      add :equipment_id, :string, null: false
      # 미디어 종류. audio/video/image. CHECK 제약으로 방어.
      add :media_type, :string, null: false

      # 원본 NAS 절대경로. 멱등 1차 키 구성.
      add :nas_path, :string, null: false
      # 원본 수정시각. 멱등 1차 키 구성(같은 경로에 덮어쓰면 mtime 변동 → 새 asset).
      add :file_mtime, :utc_datetime_usec, null: false
      # 바이트 크기. GB 영상 대비 bigint. 멱등 1차 키 + 이관 size 검증.
      add :file_size, :bigint, null: false

      # SHA-256(이관 중 스트림에서 단일 패스 계산). 멱등 2차 키(부분 유니크).
      add :content_hash, :string
      # object storage key(등록 시 결정 → 이관 워커가 그대로 사용 = 멱등 재업로드).
      add :object_key, :string
      # object storage 가 반환한 etag(이관 확인용).
      add :etag, :string

      # 처리상태 머신 값(§5.2). 기본 detected. CHECK 제약으로 방어.
      add :state, :string, null: false, default: "detected"
      # 이관 재시도 횟수.
      add :retry_count, :integer, null: false, default: 0
      # 마지막 실패 사유(transfer_failed/dead 진단용).
      add :last_error, :string

      # (옵션) 미디어 촬영/녹음 시각. 경로/파일명에서 파싱되면 채움.
      add :captured_at, :utc_datetime_usec
      # object storage 이관 확정 시각.
      add :stored_at, :utc_datetime_usec
      # 원본 경로, 분류 부가정보 등(데이터를 버리지 않기 위한 보존 칸).
      add :meta, :map

      timestamps(type: :utc_datetime_usec)
    end

    # ── 멱등성(§2.4) — 명시적 DB 제약(암묵에 맡기지 않음) ──

    # 1차(빠른) 키: 같은 (경로, 수정시각, 크기)는 같은 파일. 동일 파일 N회 스캔 → row 1개.
    create unique_index(:media_assets, [:nas_path, :file_mtime, :file_size],
             name: :media_assets_source_identity
           )

    # 2차(확정) 키: 같은 내용(content_hash)은 중복. content_hash 가 채워진 행만 대상(부분 유니크).
    create unique_index(:media_assets, [:content_hash],
             where: "content_hash IS NOT NULL",
             name: :media_assets_content_hash
           )

    # 픽업 쿼리 인덱스(Dispatcher: state 별 조회 + 오래된 것 우선).
    create index(:media_assets, [:state, :inserted_at])
    # 설비/종류/촬영시각 조회용(운영/EXT-3 합류 조회).
    create index(:media_assets, [:equipment_id, :media_type, :captured_at])

    # ── 방어선 CHECK(changeset 우회 직접 SQL 대비) ──

    create constraint(:media_assets, :media_assets_media_type_check,
             check: "media_type IN ('audio','video','image')"
           )

    create constraint(:media_assets, :media_assets_state_check,
             check:
               "state IN ('detected','uploading','stored','transfer_failed','dead','duplicate','feature_extracted')"
           )

    # 재시도 횟수는 음수 불가.
    create constraint(:media_assets, :media_assets_retry_count_nonneg,
             check: "retry_count >= 0"
           )
  end
end
