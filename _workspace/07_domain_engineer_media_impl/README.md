# 07. domain-engineer 구현: 멀티미디어(소음/영상) NAS Watch 수집 확장 (EXT-2)

- **구현자**: domain-engineer
- **기반 설계**: `_workspace/05_architect_media_ingest_design.md` (§7 구현 지침)
- **기술 스택**: Phoenix (Elixir) + Ecto + PostgreSQL + ExAws(S3/MinIO)
- **수신자(검증)**: qa-auditor

> Phoenix 표준 구조. 실제 `open_mes` 앱의 동일 경로에 그대로 배치하면 동작한다.
> **코어 접점은 `CORE_PATCH.md` 1개 문서로 격리**(application.ex 1곳 + config + 옵션 router).

---

## 파일 목록 및 핵심 역할

### 마이그레이션 (priv/repo/migrations/)
- `20260613000010_create_media_assets.exs`
  — media_assets 테이블. **멱등 유니크 2단계**: `(nas_path,file_mtime,file_size)` 1차 +
    `content_hash` 부분 유니크 2차. media_type/state CHECK. binary_id PK.
    **AuditLog/actor_id/코어 FK 없음**(§0-C 의도된 텔레메트리 경계).

### 도메인 (lib/open_mes_media/)
- `media.ex` — 확장 퍼사드. `enabled?/0`, config 접근, 상태 조회(`list_by_state/2`).
- `state_machine.ex` — 처리상태 전이 **화이트리스트**(순수 함수). detected→uploading→stored,
  transfer_failed↔uploading→dead, duplicate, **stored→feature_extracted 예약(EXT-3)**.
- `media_asset.ex` — Ecto 스키마 + `detect_changeset`(state=detected 강제) +
  **`claim_query/3`**(조건부 UPDATE `WHERE state=expected` 선점 = 다중 워커/멱등 안전).
- `watch/stability.ex` — 쓰기 완료(안정화) 판정(순수). temp 제외 + mtime 유예 +
  **2-스캔 size 안정화**(first_seen 즉시 등록 금지).
- `watch/path_policy.ex` — NAS 경로 → equipment_id/media_type/captured_at(순수).
  비규약 경로도 버리지 않고 unknown + meta 보존. EXT-1 식별자 규약 일치.
- `watch/scanner.ex` — **폴링 스캐너 GenServer**(inotify 미채택 — NAS 원격 쓰기 미감지 회피).
  직전 관측치 캐시 + Stability 결합 → :stable 만 Registrar 로.
- `intake/registrar.ex` — **멱등 INSERT**(`on_conflict: :nothing`). 중복은 정상 skip.
  object_key 를 등록 시점 확정(asset_id 포함 → 재시도 멱등 업로드).
- `object_store/object_store.ex` — **ObjectStore behaviour**(put_file_stream/head/delete).
  스트리밍 업로드를 계약에 명시(:on_chunk 로 해시 단일 패스).
- `object_store/s3_object_store.ex` — MinIO/S3 구현(ex_aws **스트리밍 멀티파트** +
  :on_chunk tap). `File.read` 전체 적재 없음.
- `object_store/key_builder.ex` — object key 규칙(asset_id 포함 충돌 차단, 순수).
- `transfer/transfer_supervisor.ex` — **동시 이관 상한 세마포어**(Task.Supervisor + 카운터).
  `try_run` 이 :full 이면 백프레셔.
- `transfer/transfer_worker.ex` — 단일 asset **스트리밍 이관 + SHA-256 단일 패스 누적 +
  size 검증 → stored**. 실패 → transfer_failed(+retry↑). **어떤 경로에서도 NAS 원본 삭제 없음**.
  stored 후 MediaSink 호출.
- `transfer/dispatcher.ex` — 픽업 GenServer. **조건부 UPDATE 선점**(detected/transfer_failed→
  uploading) + 백프레셔 연동 + **stale uploading 회수** + **재시도 소진 dead 매장**(원본 보존).
- `sink/media_sink.ex` — **MediaSink behaviour**(stored 후처리. EXT-3 확장점).
- `sink/noop_sink.ex` — 기본 구현. 아무 동작 안 함(§0-C 경계를 코드로 보장).

### 코어 접점 (별도 문서)
- `CORE_PATCH.md` — application.ex 조건부 child 1곳 + mix.exs deps + config + 옵션 router +
  docker-compose MinIO. **이것이 코어의 유일한 변경**. enabled:false 면 코어 영향 0.

### 테스트 (test/)
- `state_machine_test.exs` — 허용/비허용 전이, 종료 상태, **동일 상태 no-op 거부**.
- `watch/stability_test.exs` — temp 제외, mtime 유예, first_seen, size 변동, stable.
- `watch/path_policy_test.exs` — 규약 도출, 비규약 unknown 보존, type mismatch.
- `intake/registrar_test.exs` — **멱등: 같은 파일 N회 → row 1개**. mtime 다르면 새 row.
- `transfer/transfer_worker_test.exs` — 정상 stored + 해시 일치, 업로드 실패→transfer_failed,
  size 불일치, **원본 보존(모든 경로)**, stale no-op.
- `transfer/pipeline_test.exs` — 감지→디스패치→이관→stored 통합, **중복 스캔 멱등**,
  재시도 소진 dead, **원본 끝까지 보존**.
- `object_store/s3_object_store_test.exs` — behaviour 계약(:on_chunk 스트리밍, head/delete),
  KeyBuilder 충돌 차단.
- `invariants_test.exs` — **정적 검증**: lib 에 File.rm 없음(원본 보존), 이관 경로 File.read 없음
  (스트리밍), EXT-1 미참조, config off 기본.
- `support/data_case.ex` — Ecto Sandbox 케이스.
- `support/fake_object_store.ex` — in-memory ObjectStore(MinIO 없이 단위 테스트).

---

## qa-auditor 검증 포인트 대응표

| 검증 항목 | 대응 |
|----------|------|
| **코어 비침투** | 코어 변경은 `CORE_PATCH.md`(application.ex 1곳 + config + 옵션 router)에만. lib/open_mes_media 격리. |
| **선택적 활성화** | `OpenMes.Media.enabled?` 기본 false. media_children 조건부. `invariants_test` 가 off 확인. |
| **의존 방향 단방향** | EXT-2 는 `OpenMes.Repo` 만 참조(NoopSink 는 무의존). EXT-1(`OpenMes.Ingest.*`) 미참조 — `invariants_test`. |
| **멱등성(명시)** | DB 유니크 2단계 + Registrar `on_conflict:nothing`. `registrar_test`/`pipeline_test` 가 N회→1개 검증. |
| **상태 머신 화이트리스트** | `StateMachine` 순수 함수. 모든 전이가 `claim_query` 조건부 UPDATE 선점. |
| **원본 보존** | 코드에 `File.rm` 없음(`invariants_test` 정적 검증). transfer_failed/dead 도 원본 보존(테스트). |
| **스트리밍 이관** | `ExAws.S3.Upload.stream_file` + :on_chunk. 이관 경로 `File.read` 없음(`invariants_test`). |
| **텔레메트리 경계(정상)** | media_assets 에 AuditLog/actor_id/FK 없음 — §0-C 의도된 설계(누락 아님). |
| **도메인 이벤트 Outbox** | MVP 는 NoopSink(해당 없음). 후속 sink 가 발행 시 `OpenMes.Outbox.emit` 경유 계약. |

---

## pi 최소 준수
- 특징추출/소음분석 코드 **없음**. `stored→feature_extracted` state 만 예약,
  `MediaSink` 확장점만 남김. EXT-3 도입 시 `NoopSink`→`FeatureExtractSink` 교체.
- 별도 Repo/DB 없음(코어 Repo 공유, 테이블 분리). 별도 dead-letter 테이블 없음(`state=dead`).
- file_system(inotify) 미사용(NAS 원격 쓰기 미감지) — 폴링 채택.

## 후속(이번 범위 밖, 설계 §8)
- 원본 NAS 파일 보존 정책(MVP=삭제 안 함), object storage lifecycle, 대규모 디렉토리 스캔 최적화,
  presigned URL 조회 API, EXT-3 특징추출/도메인신호 연계.
