# 06. domain-engineer 구현: 설비 데이터 수집 확장 (EXT-1, Broadway Ingest)

- **구현자**: domain-engineer
- **기반 설계**: `_workspace/04_architect_ingest_design.md` (§7 구현 지침)
- **기술 스택**: Phoenix (Elixir) + Ecto + PostgreSQL + **Broadway + TimescaleDB**
- **메시지 소스**: 브로커리스 — HTTP push → 내부 GenStage BufferProducer
- **수신자(검증)**: qa-auditor, ai-safety-guardian(해당 없음 — AI 연동 코드 없음)

> 디렉토리는 Phoenix 표준 구조를 그대로 반영한다. 코어 앱(`open_mes`)의 동일 경로에 배치하면 동작한다.
> **코어(`lib/open_mes/`)는 수정하지 않는다.** 코어 접점은 `application.ex` / `router.ex` 두 곳뿐이며,
> 이 디렉토리의 `patches/` 에 패치 형태로 명시했다(직접 코어 파일을 건드리지 않음).

---

## 1. 파일 목록 및 역할

### 마이그레이션 (`priv/repo/migrations/`)
- `20260613100001_enable_timescaledb.exs` — `CREATE EXTENSION timescaledb`. down 은 no-op(확장 제거 위험 회피).
- `20260613100002_create_equipment_measurements.exs` — **hypertable**. `create_hypertable(measured_at, 7일 chunk)` + value/quality CHECK. `@primary_key false`(surrogate id 없음). 코어 테이블 FK 없음.
- `20260613100003_create_ingest_dead_letters.exs` — 오염 데이터 격리 테이블(일반 PG, append-only).

### 확장 도메인 (`lib/open_mes_ingest/`) — 코어와 격리된 네임스페이스
- `ingest.ex` — **퍼사드**. `enabled?/0`, `push/1`, `push_many/1`, `configured_sink/0`, `queue_depth/0`. 컨트롤러의 유일한 진입점.
- `pipeline.ex` — `use Broadway`. producer → processors(검증) → batchers(:timescale 벌크 적재). 검증 실패 → dead-letter + `Message.failed`.
- `buffer_producer.ex` — **브로커리스 GenStage producer**. 내부 `:queue` + demand 기반 디스패치 + 큐 상한(`max_queue_len` 기본 50_000) 초과 시 `{:error, :busy}`(백프레셔). **producer 교체 포인트**(Kafka/MQTT 전환 시 이 모듈만 교체).
- `validator.ex` — 검증·변환 **순수 함수**. 필수필드/측정값존재/시각skew/타입캐스트. DB 무의존.
- `measurement.ex` — hypertable Ecto 스키마(`@primary_key false`, timestamps 수동).
- `loader.ex` — `Repo.insert_all` 벌크 적재. 코어 의존은 `OpenMes.Repo` 만.
- `dead_letter.ex` + `dead_letter_record.ex` — 검증 실패 격리(`capture/3`, `capture_batch/3`). append-only.
- `sink/domain_sink.ex` — **behaviour 계약**(`@callback handle_measurements/1`). 텔레메트리→코어 도메인의 유일한 추상 경계.
- `sink/noop_sink.ex` — **기본 구현(MVP 기본값)**. 코어로 아무것도 안 흘림.
- `sink/outbox_sink.ex` — 옵션/후속 **스켈레톤**. 활성화 시 반드시 코어 `OpenMes.Outbox` 경유(직접 outbox INSERT 금지). 이벤트 타입 문서 등재 전 발행 안 함.

### 웹 (`lib/open_mes_web/`)
- `plugs/require_device_token.ex` — 디바이스 토큰 인증(`Authorization: Bearer`, config 화이트리스트). 코어 `RequireActor`(사람 actor)와 **분리**. 통과 시 `conn.assigns.device_actor`.
- `controllers/ingest_controller.ex` — `POST /ingest/equipment`(단건/배열, 즉시 **202**, 큐 포화 시 **429**), `GET /ingest/health`. 얇은 컨트롤러.

### 코어 패치 (`patches/`) — 코어 직접 수정 대신 패치로 명시
- `application.ex.patch.md` — `ingest_children/0`(config 게이트 조건부 Broadway child) 추가.
- `router.ex.patch.md` — `require_device_token` 파이프라인 + 조건부 `/ingest` scope 추가.
- `config.snippets.md` — config.exs/runtime.exs/test.exs/mix.exs/docker-compose 추가 스니펫.

### 테스트 (`test/`)
- `open_mes_ingest/validator_test.exs` — 정상/누락/skew/타입오류 등 순수함수 단위(async).
- `open_mes_ingest/buffer_producer_test.exs` — 큐 적재/상한 busy/demand 배수(async).
- `open_mes_ingest/backpressure_test.exs` — 큐 포화→busy, 컨트롤러 429 분기 계약.
- `open_mes_ingest/pipeline_test.exs` — `Broadway.test_message` 정상 적재 / 오염 dead-letter(공유 샌드박스).
- `open_mes_ingest/dead_letter_test.exs` — 격리 단건/래핑/배치.
- `open_mes_ingest/noop_sink_test.exs` — behaviour 구현 + 무부작용.
- `open_mes_ingest/ingest_facade_test.exs` — config on/off, queue_depth, sink 기본값.
- `open_mes_web/controllers/ingest_controller_test.exs` — 202(단건/배열)/401(토큰)/health.
- `support/data_case.ex`, `support/conn_case.ex` — 코어 테스트 케이스 템플릿(SQL Sandbox) 재사용.

---

## 2. 데이터 흐름 (한눈에)

```text
POST /ingest/equipment (Bearer device-token)
  → RequireDeviceToken plug (401 if invalid)
  → IngestController.create → Ingest.push_many/1
      ├─ 큐 여유 → BufferProducer 적재 → 즉시 202 {accepted:N}
      └─ 큐 상한 초과 → {:error,:busy} → 429 {error:"ingest_busy", retry_after_ms}
  ─(비동기, Broadway)─────────────────────────────────────────
  BufferProducer(내부 큐, demand 백프레셔)
    → processors: Validator.validate
        ├─ {:ok,row} → batcher :timescale
        └─ {:error,reason} → DeadLetter.capture + Message.failed (재시도 안 함)
    → batchers :timescale: Loader.bulk_insert (insert_all 500행)
        → configured_sink().handle_measurements (기본 NoopSink — 코어 무연계)
        └─ insert 전체 실패 → DeadLetter.capture_batch + Message.failed
```

---

## 3. qa-auditor 검증 포인트 (설계 §7.3 명시 — 오탐 방지)

### 정상(결함 아님)인 설계 결정
1. ✅ **`equipment_measurements` 적재에 AuditLog 없음** — 고빈도 텔레메트리는 append-only hypertable 이 이력성을 보장(설계 §0-B). 코어의 "모든 쓰기에 AuditLog" 룰은 **도메인 트랜잭션에만** 적용. 텔레메트리 경로는 적용 제외. **누락이 아님.**
2. ✅ **measurement 에 actor_id 컬럼 없음** — 설비 출처(`equipment_id`)가 곧 actor. 사람 actor 모델 비대상.
3. ✅ **measurement 가 코어 테이블 FK 참조 없음** — 고빈도 적재/도메인 분리 의도.
4. ✅ **dead_letters 는 AuditLog 가 아님** — 수집 오류 격리소. 코어 audit_logs 와 무관.

### 검증해야 할 불변식
5. ⛔ **코어 비침투**: `lib/open_mes/` 변경은 `application.ex`/`router.ex` 두 곳뿐(이마저도 `patches/` 에 명시, 코어 파일 직접 수정 0). 확장 코드는 전부 `lib/open_mes_ingest/` + `lib/open_mes_web/`(신규 파일).
6. ⛔ **의존 방향 단방향**: 확장 → 코어만. 코어가 `OpenMes.Ingest.*` 를 참조하지 않음. 확장이 코어에서 참조하는 것은 `OpenMes.Repo`(인프라) + (OutboxSink 한정)`OpenMes.Outbox` 뿐.
   - grep 확인: `grep -rn "OpenMes.Ingest" lib/open_mes/` → (application.ex 의 `OpenMes.Ingest.enabled?` 게이트 외) 결과 없어야 함.
7. ⛔ **선택적 활성화**: `enabled: false` 빌드에서 코어 work_order 테스트 전체 통과 + Broadway child 미기동(`ingest_facade_test` + 코어 회귀).
8. ⛔ **오염 데이터 격리**: 검증 실패 → dead-letter + `Message.failed`(재시도 루프 없음). `pipeline_test` 가 검증.
9. ⛔ **백프레셔/429**: 큐 상한 초과 시 `{:error,:busy}` → 429, 끝단(HTTP)까지 전파. `buffer_producer_test` + `backpressure_test` 가 검증.
10. ⛔ **도메인 이벤트 Outbox 경유**: `OutboxSink` 활성화 시에만 해당. 현재 기본 `NoopSink` 이며 outbox 발행 없음. OutboxSink 는 스켈레톤(직접 outbox INSERT 금지 주석 명시).

---

## 4. pi(최소 구현) 준수 확인

- 외부 브로커(Kafka/MQTT) 코드 **없음**. `BufferProducer` 가 producer 교체 포인트만 남김(설계 §8.2).
- 별도 Repo/별도 DB 만들지 않음(TimescaleDB = PG 확장, 기존 Repo 재사용).
- retention/continuous aggregate/compression **미구현**(데이터 누적 후 후속, 설계 §8.3).
- `OutboxSink` 는 스켈레톤만(이벤트 타입 문서 등재 전 발행 금지, 설계 §6.3).
- 코어 주석/에러 메시지 한국어, 식별자 영문.

---

## 5. 인프라 전제 / 사용자 확인 필요 (설계 §8.6)

1. **Docker DB 이미지 TimescaleDB 교체 승인** — `timescale/timescaledb:latest-pg16` 등. 교체 안 하면 ingest 마이그레이션 실패(코어는 `enabled:false`로 정상). `patches/config.snippets.md` 참조.
2. **디바이스 토큰**: MVP 정적 화이트리스트. 디바이스별 발급/회전은 후속(plug만 교체).
3. **도메인 이벤트 연계**: MVP `NoopSink`(적재만). 임계치 이벤트는 이벤트 정의부터 확정 후 `OutboxSink`.
4. **chunk/retention**: 7일 chunk 시작값, 운영 데이터 보고 조정.

---

## 6. 컴파일/테스트 메모

- `mix.exs` 에 `{:broadway, "~> 1.1"}` 추가 필요(`patches/config.snippets.md`).
- 라우터 `/ingest` scope 는 컴파일 타임 `if OpenMes.Ingest.enabled?()` 게이트 → 컨트롤러 테스트는 `config/test.exs` 에 `enabled: true, device_tokens: ["test-token"]` 필요.
- Broadway/Controller 테스트는 별도 프로세스가 DB 를 쓰므로 공유 샌드박스(`mode {:shared, self()}`, `async: false`)를 사용.
- TimescaleDB hypertable 은 일반 INSERT 관점에서 보통 테이블과 동일 → `insert_all` 검증에 특별 처리 불필요(테스트 DB 에 마이그레이션 적용 전제).
