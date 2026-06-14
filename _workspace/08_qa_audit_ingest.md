# 08. QA 감사: EXT-1 Broadway 설비 데이터 수집 확장 모듈

- **감사자**: qa-auditor
- **감사일**: 2026-06-13
- **대상**: `_workspace/06_domain_engineer_ingest_impl/` 전체
- **설계 기준**: `_workspace/04_architect_ingest_design.md`
- **원칙**: `CLAUDE.md` (pi 최소, 데이터 확보 우선, 확장 모듈 격리)
- **감사 범위**: 코어 비침투 / config off 코어 정상 / 텔레메트리 경계 / 백프레셔·멱등성 / pi 최소 / 순수 함수
- **AI 안전 검증은 범위 밖**(ai-safety-guardian 담당). 이 모듈은 AI 연동 없음.

---

## 최종 판정: ✅ APPROVED

설계 §0~§8의 불변 규칙(코어 비침투·텔레메트리 경계·백프레셔·멱등성·pi 최소)을 코드가 실제로 실현한다.
구현을 차단하거나 수정을 강제할 결함은 없다. 아래는 후속 권고(비차단) 2건뿐이다.

---

## 항목별 결과

### 1. 코어 비침투 (가장 중요) — ✅

| 검증 | 결과 | 근거 |
|------|------|------|
| 확장 코드가 `open_mes_ingest/`로 격리됐는가 | ✅ | `find lib -type f` 결과 코어(`lib/open_mes/`) 파일 0개. 모든 확장 코드는 `lib/open_mes_ingest/`, 웹 접점은 `lib/open_mes_web/`(컨트롤러/plug)에만 존재. |
| 코어 직접 수정이 있는가 | ✅ 없음 | 코어 변경은 `patches/`(application.ex 1곳, router.ex 1곳)로만 명시. 실제 코어 파일을 deliverable에 포함하지 않음 — 침투 0. |
| 코어 접점이 application.ex/router.ex 조건부 추가 2곳뿐인가 | ✅ | `patches/application.ex.patch.md`: `++ ingest_children()` + `ingest_children/0` 추가만. `patches/router.ex.patch.md`: `:require_device_token` 파이프라인 + `if enabled?()` `/ingest` scope만. 둘 다 config 게이트. |
| 확장→코어 단방향(Repo, Outbox만)인가 | ✅ | grep `OpenMes.(Repo\|Outbox\|Production\|WorkOrder\|Audit\|...)` 결과: 활성 코드의 코어 참조는 **`OpenMes.Repo`만**(loader.ex:11, dead_letter.ex:11, 테스트 샌드박스). `OpenMes.Outbox`는 `sink/outbox_sink.ex`의 **주석 스켈레톤**에만 등장(미실행). Production/WorkOrder/Audit 등 코어 도메인 모듈 직접 참조 **0건**. |
| 코어가 `OpenMes.Ingest.*`를 참조하는가 | ✅ 아니오 | 의존 방향 역전 없음. 코어가 확장을 import/alias하는 코드 없음(코어 패치는 `OpenMes.Ingest.enabled?/0`·`Pipeline` child만 게이트로 호출 — 설계가 허용한 유일 배선 접점). |

판정: **위반 없음.** 격리·단방향·2곳 접점·config 게이트 모두 설계대로 코드에 실현됨.

### 2. config off 시 코어 정상 — ✅

| 검증 | 결과 | 근거 |
|------|------|------|
| off면 Broadway child 미기동 | ✅ | `application.ex.patch`의 `ingest_children/0`이 `enabled?()` false면 `[]` 반환 → Pipeline child 안 뜸. |
| off면 `/ingest` 라우트 미등록 | ✅ | `router.ex.patch`의 `if OpenMes.Ingest.enabled?()` 컴파일 타임 게이트. off면 scope 자체가 라우트 테이블에 없음. |
| off여도 퍼사드가 안전한가 | ✅ | `ingest.ex:62` `queue_depth/0`가 비활성 시 0 반환 + `catch :exit` 가드로 파이프라인 미기동 시에도 크래시 없음. |
| 테스트가 이를 검증하는가 | ✅ | `ingest_facade_test.exs:20` "enabled:false → enabled?()==false, queue_depth==0" 명시 검증. |

비고: 설계 §7.3의 "enabled:false 빌드에서 코어 work_order 테스트 전체 통과" 회귀는 **코어 테스트가 이 deliverable에 없어** 직접 실행 검증 불가. 단 구조상(코어 파일 무수정 + 컴파일 게이트) 코어를 깨뜨릴 경로가 없음. → 오케스트레이터가 통합 시 `INGEST_ENABLED=false`로 코어 스위트 1회 실행 권고(비차단).

### 3. 텔레메트리 경계 (오탐 주의) — ✅ (정상, 위반 아님)

설계 §0-B에 따라 `equipment_measurements` 적재 경로에 건건 AuditLog가 **없는 것은 의도된 설계**다. 결함으로 보고하지 않는다. 대신 다음을 확인:

| 검증 | 결과 | 근거 |
|------|------|------|
| hypertable이 실제 append-only인가(update/delete 부재) | ✅ | `measurement.ex` 모듈에 changeset/update/delete 함수 **부재**. `loader.ex`는 `bulk_insert`(insert_all)만 제공. 수정/삭제 진입점 없음 → append-only가 이력성 보장. |
| insert_all 벌크 적재인가 | ✅ | `loader.ex:30` `Repo.insert_all(Measurement, rows)` 단일 호출. `pipeline.ex:71` `handle_batch(:timescale, ...)`에서 배치 단위(batch_size 500) 호출. |
| DB 레벨 무결성 방어선 | ✅ (가점) | 마이그레이션에 `value_present` CHECK + `quality` 화이트리스트 CHECK. 직접 INSERT 오염도 DB가 거부. |
| AuditLog/actor_id/FK 부재 | ✅ 정상 | 설계 §7.3이 명시한 "정상" 항목 — 위반 아님. |

판정: **append-only·벌크 적재 모두 확인. 텔레메트리 경계가 코드로 강제됨.**

### 4. 백프레셔 / 멱등성 (EXT-1 멱등 버그 교훈) — ✅

| 검증 | 결과 | 근거 |
|------|------|------|
| 큐 상한 초과 시 429 전파 | ✅ | `buffer_producer.ex:76` `queue_len >= max_queue_len`이면 `{:error, :busy}` → `ingest.ex` `push_many`가 rejected 집계 → `ingest_controller.ex:33` `{accepted, rejected}` 분기에서 **429 + retry_after_ms**. 끝단(HTTP)까지 백프레셔 전달. |
| BufferProducer demand/큐 로직 결함 | ✅ 없음 | `handle_call({:push,...})`가 상한 검사 후 적재 + 즉시 `take_demand`로 대기 demand 충족. `take_demand`의 `count = min(pending_demand, queue_len)`로 큐 초과 dequeue 불가. `dequeue` 순서 보존(FIFO). `pending_demand`/`queue_len` 감산 일관. **누수·음수·순서꼬임 경로 없음.** |
| 검증 실패가 dead-letter로 가는가 | ✅ | `pipeline.ex:63-66` 검증 실패 시 `DeadLetter.capture(raw, reason)` 후 `Message.failed`. |
| Message.failed로 재시도 루프 차단 | ✅ (핵심) | 오염 데이터는 `Message.failed`로 ack되어 **재처리되지 않음**. `handle_failed/2`는 사후 훅(로깅)일 뿐 재큐잉 안 함. NoopAcknowledger라 offset 재요청 없음 → **무한 재시도 루프 원천 차단**. EXT-1 WorkOrder 멱등 버그(무한 재시도/누수)가 여기서 재현되지 않음. |
| DB 일시 vs 영구 오류 구분 | ✅ | `loader.ex`: 예외는 `{:error, error}`로 변환 → `pipeline.ex:80` `handle_batch`가 배치 일괄 dead-letter + `Message.failed`(영구 오류는 무한 재시도 안 함). 설계 §5.1/§5.3의 구분(garbage 즉시 격리 / 인프라만 재시도)을 코드가 따름. |
| 테스트 | ✅ | `buffer_producer_test.exs`(상한→busy, demand→배수), `backpressure_test.exs`(429 분류 계약), `pipeline_test.exs`(오염→dead-letter + failed ack `{:ack, ref, [], [_failed]}`), `dead_letter_test.exs`(격리·배치). |

판정: **백프레셔·멱등성 모두 견고. 재시도 루프 차단이 명시적으로 코드+테스트로 보장됨.**

### 5. pi 최소 원칙 (YAGNI) — ✅

| 검증 | 결과 | 근거 |
|------|------|------|
| 외부 브로커 코드 부재 | ✅ | Kafka/MQTT/SQS 구현 없음. `BufferProducer`(브로커리스 in-memory)만. 교체 포인트는 `pipeline.ex:30` `producer.module` 한 곳 — 주석으로 전환 경로만 명시(코드 선구현 없음). |
| 호출처 0 선제 추상화 | ✅ 없음 | `DomainSink` behaviour + `NoopSink`는 설계가 지정한 확장점이며 `pipeline.ex:77`에서 **실제 호출됨**(`configured_sink().handle_measurements`). 죽은 추상화 아님. |
| OutboxSink 스켈레톤 과한가 | ✅ 적정 | `outbox_sink.ex`는 `handle_measurements/1`이 `:ok` 반환만, 발행 로직은 전부 주석. 이벤트 타입 미등재(설계 §6.3/§8.4) 전 발행 금지 결정을 정확히 따름 — 임의 이벤트 추가 0. behaviour 계약상 유지 타당. |
| 운영 정책 선구현 | ✅ 없음 | retention/continuous aggregate/compression 미구현(설계 §8.3 후속). 마이그레이션에 주석으로만 범위 밖 명시. |

판정: **최소 구현 + 확장점만 유지. YAGNI 위반 없음.**

### 6. 순수 함수 검증 (Validator) — ✅

| 검증 | 결과 | 근거 |
|------|------|------|
| DB 무의존 순수 함수 | ✅ | `validator.ex` 어떤 Repo/IO 의존 없음. `DateTime.utc_now/0`만 사용(부수효과 아님, 시각 조회). 단위 테스트가 async로 도는 것이 방증(`validator_test.exs:5` `async: true`). |
| skew 로직 | ✅ | `within_skew`가 `abs(DateTime.diff(now, measured_at, :second)) <= 86_400`. 미래·과거 양방향 ±1일 정확. 테스트 "과거 +2일 → skew_exceeded" 검증. |
| 타입캐스트 로직 | ✅ | `cast_float`(float/int/숫자문자열/nil 허용, 그 외 error), `cast_uuid`(nil 허용·`Ecto.UUID.cast`), `cast_quality`(화이트리스트), `parse_time`(ISO8601 + epoch 초/밀리초 13자리 분기). 모든 경로 테스트로 커버(정상 7건 + 실패 10건). |
| 측정값 상호배타 강제 | ✅ | `value_present`가 value·string_value 둘 다 없으면 `value_missing`. DB CHECK와 이중 방어. |

**경미한 관찰(비차단):**
- `validator.ex:118-119` `value_present(value, _)` (`is_number` 가드) 및 catch-all은 사실상 도달 불가 분기다. `cast_float`가 선행하여 value는 항상 nil 또는 float이므로 `is_number` 절만 유효하고 catch-all은 죽은 코드. 동작상 무해(방어적). 정리 가능하나 강제 아님.
- `within_skew`가 `parse_time`과 별개로 `DateTime.utc_now/0`를 재호출 → 마이크로초 단위 비결정성. ±1일 경계라 실무 무영향.

---

## 후속 권고 (모두 비차단)

1. **(권고) 코어 회귀 실행**: 오케스트레이터가 통합 시점에 `INGEST_ENABLED=false`로 코어 work_order 스위트 1회 실행하여 설계 §7.3 "코어 비침투 회귀"를 실측 확인. (구조상 위험 경로 없으나 설계가 명시한 검증 항목.)
2. **(선택) Validator 죽은 분기 정리**: `value_present` catch-all 제거로 가독성 향상. 동작 영향 없음.

## 오탐 방지 메모 (다음 감사자/오케스트레이터용)

- `equipment_measurements`에 AuditLog/actor_id/FK 없음 = **정상**(설계 §0-B). 위반 아님.
- `OutboxSink`가 아무 이벤트도 발행하지 않음 = **정상**(이벤트 타입 미등재 전 발행 금지, §6.3). 미구현 결함 아님.
- 코어 도메인의 AuditLog/LOT Genealogy/상태 머신 룰은 이 텔레메트리 확장 경로에 **적용 제외**다.
