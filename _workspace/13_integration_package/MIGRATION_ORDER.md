# 마이그레이션 순서표 (통합 최종)

Ecto 는 `priv/repo/migrations/` 의 파일을 **파일명 타임스탬프 오름차순**으로 실행한다.
아래 번호 그대로 두면 의존성 순서가 보장된다(번호를 바꾸지 말 것).

| 순서 | 타임스탬프 | 파일 / 모듈 | 출처 | 만드는 것 | 의존성 |
|----|-----------|------------|------|----------|-------|
| 1 | `20260613000001` | `create_audit_logs` (`OpenMes.Repo.Migrations.CreateAuditLogs`) | 코어 02 | `audit_logs` 테이블 | 없음(토대) |
| 2 | `20260613000002` | `create_outbox_events` (`...CreateOutboxEvents`) | 코어 02 | `outbox_events` 테이블 | 없음 |
| 3 | `20260613000003` | `create_work_orders` (`...CreateWorkOrders`) | 코어 02 | `work_orders` 테이블 | audit/outbox 와 독립(FK 없음) |
| 4 | `20260613000010` | `create_media_assets` (`...CreateMediaAssets`) | EXT-2 07 | `media_assets` 테이블 | 코어 FK 참조 없음(독립) |
| 5 | `20260613100001` | `enable_timescaledb` (`...EnableTimescaledb`) | EXT-1 06 | `CREATE EXTENSION timescaledb` | **TimescaleDB 이미지 필수** |
| 6 | `20260613100002` | `create_equipment_measurements` (`...CreateEquipmentMeasurements`) | EXT-1 06 | `equipment_measurements` **hypertable** | 5번(timescaledb 확장) 필수 |
| 7 | `20260613100003` | `create_ingest_dead_letters` (`...CreateIngestDeadLetters`) | EXT-1 06 | `ingest_dead_letters` 테이블(일반, hypertable 아님) | 없음 |

## 핵심 규칙

- **코어(1~3)가 가장 먼저.** 다른 모든 것의 토대.
- **EXT-2(4)** 는 코어를 FK 참조하지 않으므로 EXT-1 과 순서 자유. 번호상 코어 뒤에 온다.
- **EXT-1(5~7)** 은 내부 순서가 중요: `enable_timescaledb`(5) → `equipment_measurements` hypertable(6).
  5번 없이 6번을 돌리면 `create_hypertable` 호출이 실패한다.
- **애드온 5개는 운영 마이그레이션 0개.** 새 테이블을 만들지 않고 코어/EXT 테이블을 **읽기만** 한다.
  - 애드온 테스트용 임시 테이블 스크립트는 `test/support/` 로 복사되며 **운영 마이그레이션이 아니다**:
    - `11_addon_daily_summary/test/support/migrations/20260613200001_create_daily_summary_read_tables.exs`
    - `11_addon_defect_stats/test/support/defect_stats_tables.exs`
  - 이 파일들은 `priv/repo/migrations/` 에 넣지 말 것(integrate.sh 가 `test/support/` 로만 복사).
- **레지스트리/카탈로그/EXT 메타데이터 모듈(10)** 도 마이그레이션 0개(새 테이블 없음).

## 인프라 의존 요약

| 마이그레이션 | 필요한 인프라 | 없을 때 |
|------------|-------------|--------|
| 1~4 | 일반 PostgreSQL | — |
| 5~6 | **TimescaleDB 확장** (timescale/timescaledb 이미지) | `CREATE EXTENSION` 실패 → EXT-1 끄고(`INGEST_ENABLED=false`) 마이그레이션 제외 |
| 7 | 일반 PostgreSQL | — |

> EXT-1 을 쓰지 않을 거면 5/6/7 마이그레이션 파일을 복사하지 않으면 된다(코어/EXT-2 는 일반 PG 로 동작).
> docker-compose.yml 의 `timescale/timescaledb` 이미지는 일반 PostgreSQL 기능도 모두 제공하므로
> 코어/EXT-2 만 쓸 때도 그대로 사용 가능하다.
