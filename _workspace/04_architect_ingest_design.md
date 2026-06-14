# 04. Architect 설계: Broadway 기반 고처리량 설비 데이터 수집 확장 모듈

- **작성자**: architect
- **작성일**: 2026-06-13
- **대상**: 설비 텔레메트리 수집 확장 (HTTP ingest → Broadway 검증·변환 → TimescaleDB 적재)
- **기술 스택 (확정)**: Phoenix (Elixir) + Ecto + PostgreSQL **+ Broadway + TimescaleDB(PostgreSQL 확장)**
- **메시지 소스 (확정)**: 브로커리스 — 외부 Kafka/MQTT 없이 HTTP push 수신 → 내부 Broadway producer
- **구현 깊이 (확정)**: 풀 파이프라인
- **참고 문서**: CLAUDE.md, docs/domain-model.md, docs/system-architecture.md, docs/ai-native-architecture.md, _workspace/01_architect_workorder_design.md
- **로드맵 위치**: 설비 데이터 수집 = Phase 6 (system-architecture / roadmap)
- **수신자**: domain-engineer (구현), qa-auditor (검토)

---

## 0. 설계 원칙 요약 (이 설계가 지켜야 하는 불변 규칙)

이 확장 모듈은 두 가지 상위 제약을 동시에 만족해야 한다.

### A. 확장 모듈의 코어 비침투 (pi 최소 코어)

1. **코어 무의존**: 코어(`lib/open_mes/`)는 이 확장에 일절 의존하지 않는다. Broadway/TimescaleDB가 없어도 코어는 완전히 동작한다. 확장은 별도 네임스페이스 `lib/open_mes_ingest/`로 격리한다.
2. **확장 포인트는 behaviour 계약**: 수집 파이프라인이 코어 도메인과 만나는 지점은 behaviour로 계약을 정의한다. 확장이 코어 내부 모듈/스키마를 직접 호출하지 않는다.
3. **선택적 활성화**: `application.ex`에서 config 플래그(`:ingest_enabled`)로 Broadway 파이프라인 child를 켜고 끈다. 꺼져도 코어는 정상 동작하고, 어떤 코어 테스트도 깨지지 않는다.

### B. 텔레메트리 vs 도메인 트랜잭션의 경계 (가장 중요)

4. **별도 hypertable**: 고빈도 설비 텔레메트리는 코어 13개 엔티티가 아닌 별도 TimescaleDB hypertable `equipment_measurements`에 적재한다.
5. **텔레메트리에는 건건 AuditLog를 달지 않는다** — 명시적 경계 선언.
   - 코어의 "모든 쓰기에 AuditLog" 원칙(CLAUDE.md L57-59)은 **도메인 트랜잭션 데이터에만 적용**된다(WorkOrder 생성/전이, Operation 실적, LOT 소비, 불량 기록).
   - 고빈도 텔레메트리(센서 측정값)는 **append-only hypertable 자체가 이력성을 보장**하므로 건건 AuditLog 대상이 아니다. 초당 수천 행에 AuditLog를 다는 것은 이력성 강화가 아니라 감사 로그 오염이며 시스템을 마비시킨다.
   - **qa-auditor 주의**: `equipment_measurements` 적재 경로에 AuditLog가 없는 것은 **정상**이다. 누락이 아니다. (§8.2에 검증 항목으로 명시)
6. **도메인 이벤트는 코어로 흘려보낸다**: 텔레메트리 그 자체는 코어에 닿지 않지만, 도메인적으로 의미 있는 사건(예: 설비 임계치 초과 → 점검 필요 신호)은 코어의 `outbox_events`로 흘려보낸다. 단 이 연계는 **behaviour 계약을 통해서만** 일어나고, MVP에서는 인터페이스만 정의하고 실제 발행은 최소(또는 후속)로 둔다(§6.3, §8.4).

### C. 기존 컨벤션 승계 (01번 설계 일관성)

7. PK 타입: 코어는 `binary_id`. 단 hypertable은 시계열 특성상 PK 전략이 다름 → §2 참조.
8. OTP 앱 이름 `open_mes`, 코어 컨텍스트 `OpenMes`, 웹 `OpenMesWeb`. 확장은 `OpenMes.Ingest`.
9. 한국어 우선(주석/에러메시지), 영문 식별자.
10. MVP 범위 준수, 과설계 금지. 지금 필요한 최소만 만들고 확장 경로는 남긴다.

---

## 1. 확장 모듈 디렉토리 구조 (코어와 격리)

### 1.1 의존성 추가 (mix.exs)

```elixir
# mix.exs deps에 추가
{:broadway, "~> 1.1"},
# TimescaleDB는 라이브러리가 아니라 PostgreSQL 확장. deps 추가 없음.
# 마이그레이션에서 CREATE EXTENSION + create_hypertable로 활성화.
```

> **결정**: 별도 Repo를 만들지 않는다. TimescaleDB는 PostgreSQL 확장이므로 기존 `OpenMes.Repo`로 동일 DB에 hypertable을 만든다. 별도 Repo/별도 DB는 MVP 과설계(YAGNI). 단 hypertable과 코어 테이블은 **테이블 레벨로만 분리**된다(트랜잭션 결합 안 함, §5 참조).

### 1.2 디렉토리 구조

```text
open_mes/
├── lib/
│   ├── open_mes/                         # ← 코어 (이 확장에 무의존, 변경 없음)
│   │   ├── application.ex                #   ← child_spec 조건부 추가만 (§7.2, 유일한 코어 접점)
│   │   ├── repo.ex
│   │   ├── production/ ...
│   │   ├── audit/ ...
│   │   └── outbox/ ...
│   │       └── outbox.ex                 #   기존 emit 헬퍼 — 확장이 behaviour 구현체에서 재사용
│   │
│   ├── open_mes_ingest/                  # ← 확장 네임스페이스 (격리)
│   │   ├── ingest.ex                     #   확장 퍼사드 (활성 여부, 공개 진입점)
│   │   ├── pipeline.ex                   #   Broadway 파이프라인 정의 (use Broadway)
│   │   ├── buffer_producer.ex            #   브로커리스 producer (GenStage, 내부 버퍼)
│   │   ├── message.ex                    #   수집 메시지 구조체 + 정규화
│   │   ├── validator.ex                  #   검증·변환 (순수 함수)
│   │   ├── measurement.ex                #   Ecto 스키마 (equipment_measurements, hypertable)
│   │   ├── loader.ex                     #   TimescaleDB 벌크 insert_all
│   │   ├── dead_letter.ex                #   검증 실패 격리 (ingest_dead_letters)
│   │   ├── dead_letter_record.ex         #   Ecto 스키마
│   │   │
│   │   └── sink/                         #   ← 코어 연계 behaviour 계약
│   │       ├── domain_sink.ex            #     behaviour 정의 (@callback)
│   │       ├── noop_sink.ex              #     기본 구현 (아무것도 안 함 — MVP 기본값)
│   │       └── outbox_sink.ex            #     코어 outbox로 도메인 이벤트 발행 (후속/옵션)
│   │
│   └── open_mes_web/
│       ├── router.ex                     # ← /ingest scope 추가 (조건부)
│       ├── controllers/
│       │   ├── ingest_controller.ex      #   POST /ingest/equipment
│       │   └── ingest_json.ex            #   202 응답 직렬화
│       └── plugs/
│           └── require_device_token.ex   #   설비/장비 토큰 인증 (코어 require_actor와 분리)
│
├── priv/
│   └── repo/
│       └── migrations/
│           ├── ..._enable_timescaledb.exs            # CREATE EXTENSION
│           ├── ..._create_equipment_measurements.exs # hypertable
│           └── ..._create_ingest_dead_letters.exs    # 격리 테이블
└── test/
    ├── open_mes_ingest/validator_test.exs
    ├── open_mes_ingest/pipeline_test.exs            # Broadway.test_message/3 사용
    └── open_mes_web/controllers/ingest_controller_test.exs
```

**모듈 경계와 책임**

| 모듈 | 책임 | 코어 의존 |
|------|------|----------|
| `OpenMes.Ingest` | 확장 퍼사드. `enabled?/0`, `push/1`(버퍼에 넣기). 컨트롤러의 유일한 진입점. | ❌ |
| `OpenMes.Ingest.Pipeline` | `use Broadway`. processors/batchers 토폴로지 정의, 콜백 구현. | ❌ |
| `OpenMes.Ingest.BufferProducer` | 브로커리스 GenStage producer. 내부 큐 + demand 기반 디스패치 + 백프레셔. | ❌ |
| `OpenMes.Ingest.Validator` | 수집 메시지 검증·정규화. **순수 함수**. DB 의존 없음. | ❌ |
| `OpenMes.Ingest.Measurement` | hypertable Ecto 스키마 + insert용 row map 변환. | ❌ |
| `OpenMes.Ingest.Loader` | `Repo.insert_all/3` 벌크 적재(batcher 콜백에서 호출). | Repo만 |
| `OpenMes.Ingest.DeadLetter` | 검증 실패 메시지를 `ingest_dead_letters`에 격리. | Repo만 |
| `OpenMes.Ingest.Sink.DomainSink` | **behaviour 계약**. 텔레메트리 → 코어 도메인 신호 변환 지점. | ❌(계약만) |
| `OpenMes.Ingest.Sink.NoopSink` | 기본 구현. 아무 동작 안 함. MVP 기본값. | ❌ |
| `OpenMes.Ingest.Sink.OutboxSink` | 코어 `OpenMes.Outbox`로 도메인 이벤트 발행(임계치 초과 등). | ✅(허용된 단방향 호출) |
| `IngestController` | 토큰 검증 후 `Ingest.push/1`. 즉시 202 반환(비동기). | ❌ |
| `RequireDeviceToken` plug | 설비 토큰 검증. 코어 `RequireActor`와 **별도**. | ❌ |

> **핵심 격리 규칙**:
> - 코어(`lib/open_mes/`)는 `OpenMes.Ingest.*`를 **import/alias/호출하지 않는다**. 의존 방향은 **확장 → 코어**의 단방향만 허용.
> - 확장이 코어에 닿는 유일한 정당 경로는 (a) `OpenMes.Repo`(같은 DB 인프라), (b) `Sink` behaviour 구현체에서 `OpenMes.Outbox.emit`(도메인 이벤트). 그 외 코어 내부 모듈(Production, WorkOrder 등) 직접 호출 금지.
> - `application.ex`의 child_spec 조건부 추가가 코어-확장의 **유일한 배선 접점**이며, config 플래그로 게이트된다.

---

## 2. `equipment_measurements` TimescaleDB Hypertable 스키마

### 2.1 설계 의도

- 고빈도 append-only 시계열. **수정/삭제 없음.** UPDATE/DELETE 함수 미작성(append-only가 이력성 보장).
- 코어 13개 엔티티와 **테이블 분리**. FK로 코어 테이블을 참조하지 **않는다**(텔레메트리는 도메인 트랜잭션과 결합하지 않음, 고빈도 적재 시 FK 검증 비용 회피).
- `equipment_id`는 코어 `ProductionResult.equipment_id`와 **의미적으로 동일한 식별자**지만 FK 제약은 걸지 않는다. 설비 마스터가 별도 테이블로 정식화되기 전이며(현 도메인 모델에 Equipment 엔티티 없음), 고빈도 경로에서 join 무결성보다 적재 처리량을 우선한다. → 의미 연결은 §6의 sink/집계에서 처리.

### 2.2 PK / 시간 컬럼 전략

> **결정 — hypertable은 `binary_id` 단일 PK를 쓰지 않는다.** 코어는 `binary_id` PK 컨벤션이지만, TimescaleDB hypertable은 **파티셔닝 컬럼(시간)이 반드시 인덱스/제약에 포함**되어야 한다. 시계열 표준 패턴을 따른다.

- 파티셔닝 차원: `measured_at`(설비가 측정한 시각, 디바이스 타임스탬프).
- 단일 UUID PK 대신, 식별이 필요하면 `(equipment_id, measured_at, metric_key)` 조합으로 충분. 별도 surrogate `id`는 두지 않는다(고빈도 row에 UUID 생성 비용·저장 비용 회피 — YAGNI).
- Ecto 스키마는 `@primary_key false`로 정의하고 복합 식별을 논리적으로만 사용.

### 2.3 컬럼 정의

| 필드 | 타입 | 제약 | 비고 |
|------|------|------|------|
| `equipment_id` | `string` | NOT NULL | 설비 식별자. 코어 `equipment_id`와 의미 동일(FK 없음). |
| `metric_key` | `string` | NOT NULL | 측정 항목 키 (예: `temperature`, `pressure`, `cycle_count`). |
| `value` | `float` (double precision) | NULL 허용 | 수치 측정값. |
| `string_value` | `string` | NULL 허용 | 상태/문자형 측정값(예: `running`). value와 상호배타적. |
| `unit` | `string` | NULL 허용 | 단위(예: `degC`, `bar`). |
| `quality` | `string` | NOT NULL, DEFAULT `'good'` | 측정 품질 플래그(`good`/`uncertain`/`bad`). 디바이스/검증 단계에서 부여. |
| `measured_at` | `utc_datetime_usec` | NOT NULL | **파티셔닝 차원**. 디바이스 측정 시각. |
| `ingested_at` | `utc_datetime_usec` | NOT NULL | 서버 수집 시각(지연 측정용). |
| `work_order_id` | `binary_id` | NULL 허용 | (옵션) 수집 시점 작업지시 컨텍스트. 디바이스가 보내면 보존. FK 없음. |
| `meta` | `map`(jsonb) | NULL 허용 | 디바이스 부가 정보(라인/슬롯 등). 스키마 유연성. |

> `value`와 `string_value`를 분리: 수치 시계열 분석과 상태 시계열을 한 테이블에서 다루기 위함. 둘 중 하나는 채워져야 한다(검증 단계에서 강제, §3.3).

### 2.4 마이그레이션 (hypertable 생성 포함)

세 개의 마이그레이션으로 분리하여 의존성을 명확히 한다.

**(1) TimescaleDB 확장 활성화** — `..._enable_timescaledb.exs`
```elixir
def up do
  execute "CREATE EXTENSION IF NOT EXISTS timescaledb;"
end
def down do
  # 확장 제거는 위험(다른 hypertable 영향). down은 no-op 또는 명시적 DROP 금지.
  :ok
end
```
> 운영 DB에 TimescaleDB가 설치되어 있어야 함(Docker 이미지: `timescale/timescaledb:latest-pg16` 등). → §8.1 인프라 전제.

**(2) equipment_measurements + hypertable** — `..._create_equipment_measurements.exs`
```elixir
def up do
  create table(:equipment_measurements, primary_key: false) do
    add :equipment_id, :string, null: false
    add :metric_key, :string, null: false
    add :value, :float
    add :string_value, :string
    add :unit, :string
    add :quality, :string, null: false, default: "good"
    add :measured_at, :utc_datetime_usec, null: false
    add :ingested_at, :utc_datetime_usec, null: false
    add :work_order_id, :binary_id
    add :meta, :map
  end

  # 시계열 조회의 핵심 인덱스: 설비+측정항목별 시간 역순 조회
  create index(:equipment_measurements, [:equipment_id, :metric_key, :measured_at])

  # hypertable 전환 (chunk 7일 간격은 시작값; 데이터량 보고 조정)
  execute """
  SELECT create_hypertable('equipment_measurements', 'measured_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE);
  """

  # value/string_value 중 하나는 NOT NULL (최후 방어선; 1차 검증은 앱)
  execute """
  ALTER TABLE equipment_measurements
    ADD CONSTRAINT equipment_measurements_value_present
    CHECK (value IS NOT NULL OR string_value IS NOT NULL);
  """
  execute """
  ALTER TABLE equipment_measurements
    ADD CONSTRAINT equipment_measurements_quality_check
    CHECK (quality IN ('good','uncertain','bad'));
  """
end

def down do
  drop table(:equipment_measurements)
end
```
> **MVP 범위 명시**: retention policy / continuous aggregate / compression 은 **이번 범위 밖**(과설계 금지). 데이터량이 쌓인 뒤 운영 데이터를 보고 후속 마이그레이션으로 추가한다(§8.3).

**(3) ingest_dead_letters** — §5 참조.

---

## 3. Broadway 파이프라인 구조

### 3.1 토폴로지 개요

```text
HTTP POST /ingest/equipment
      ↓ (Ingest.push/1 — 동기, 즉시 202)
[BufferProducer]  ← 브로커리스 내부 큐(GenStage). demand 기반 백프레셔.
      ↓
[processors]      ← 검증·변환 (Validator). 동시성 N. 실패 시 dead-letter.
      ↓
[batchers]
   └ :timescale   ← TimescaleDB 벌크 insert_all (Loader). 배치 단위 적재.
```

> **브로커리스 = producer가 외부 브로커 대신 in-memory 큐를 갖는 커스텀 GenStage producer.** Broadway의 producer 자리에 Kafka/SQS 대신 `BufferProducer`를 꽂는다. 인프라 의존 0.

### 3.2 Broadway 정의 (Pipeline)

```elixir
defmodule OpenMes.Ingest.Pipeline do
  use Broadway
  alias Broadway.Message
  alias OpenMes.Ingest.{Validator, Loader, DeadLetter}

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {OpenMes.Ingest.BufferProducer, []},
        concurrency: 1,
        # 한 번에 producer가 내보내는 최대 이벤트 수(과도한 메모리 점유 방지)
        rate_limiting: [allowed_messages: 5_000, interval: 1_000]
      ],
      processors: [
        default: [
          concurrency: System.schedulers_online() * 2,
          max_demand: 100   # 백프레셔: processor당 미처리 상한
        ]
      ],
      batchers: [
        timescale: [
          concurrency: 2,
          batch_size: 500,      # insert_all 한 번에 500행
          batch_timeout: 1_000  # 500행 안 차도 1초 후 flush (저빈도 대응)
        ]
      ]
    )
  end

  @impl true
  def handle_message(_processor, %Message{data: raw} = msg, _ctx) do
    case Validator.validate(raw) do
      {:ok, row} ->
        msg
        |> Message.update_data(fn _ -> row end)
        |> Message.put_batcher(:timescale)

      {:error, reason} ->
        # 검증 실패 → dead-letter로 보내고 메시지는 fail 처리(재시도 안 함)
        DeadLetter.capture(raw, reason)
        Message.failed(msg, reason)
    end
  end

  @impl true
  def handle_batch(:timescale, messages, _batch_info, _ctx) do
    rows = Enum.map(messages, & &1.data)
    Loader.bulk_insert(rows)   # Repo.insert_all, 부분 실패 시 §5.3
    messages
  end

  @impl true
  def handle_failed(messages, _ctx) do
    # handle_message에서 failed 처리된 메시지의 사후 훅(로깅 등). 이미 dead-letter 격리됨.
    messages
  end
end
```

### 3.3 검증·변환 (Validator, 순수 함수)

```elixir
defmodule OpenMes.Ingest.Validator do
  @moduledoc "수집 raw 맵 → equipment_measurements row 맵. DB 의존 없는 순수 함수."

  @max_skew_seconds 86_400  # 측정시각 미래/과거 허용 범위(±1일). 그 밖은 오염으로 간주.

  def validate(raw) when is_map(raw) do
    with {:ok, equipment_id} <- required_string(raw, "equipment_id"),
         {:ok, metric_key}   <- required_string(raw, "metric_key"),
         {:ok, measured_at}  <- parse_time(raw["measured_at"]),
         :ok                 <- value_present(raw),
         :ok                 <- within_skew(measured_at) do
      now = DateTime.utc_now()
      {:ok,
       %{
         equipment_id: equipment_id,
         metric_key: metric_key,
         value: cast_float(raw["value"]),
         string_value: raw["string_value"],
         unit: raw["unit"],
         quality: raw["quality"] || "good",
         measured_at: measured_at,
         ingested_at: now,
         work_order_id: raw["work_order_id"],
         meta: raw["meta"]
       }}
    end
  end

  def validate(_), do: {:error, :not_a_map}
  # required_string / parse_time / value_present / within_skew / cast_float 구현은 domain-engineer.
end
```

- 검증 항목: 필수 필드 존재, 측정값 1개 이상 존재(`value` 또는 `string_value`), 시각 파싱·skew 범위, 타입 캐스트.
- **변환**: device payload(자유 JSON) → DB row map 정규화. `ingested_at` 서버 부여.
- 순수 함수이므로 단위 테스트가 쉽고 빠르다(§7.4).

### 3.4 동시성/배치/백프레셔 설정 가이드

| 파라미터 | 권장 시작값 | 근거 / 튜닝 방향 |
|---------|-----------|----------------|
| producer `concurrency` | 1 | 단일 버퍼 큐. 순서·단순성. 병목 시 분할은 후속. |
| producer `rate_limiting` | 5,000 msg/s | 메모리 폭주 방지 상한. 부하 테스트로 조정. |
| processors `concurrency` | `schedulers_online * 2` | CPU 바운드 검증. 코어 수에 비례. |
| processors `max_demand` | 100 | **핵심 백프레셔 노브**. 낮추면 메모리↓·지연↑, 높이면 처리량↑·메모리↑. |
| batcher `batch_size` | 500 | insert_all 행 수. PostgreSQL 파라미터 한계(컬럼수×행수<65535) 내. 컬럼 10개 기준 안전. |
| batcher `batch_timeout` | 1,000ms | 저빈도에도 1초 내 flush 보장(데이터 가시성). |
| batcher `concurrency` | 2 | DB 커넥션 풀과 균형. 풀 사이즈 초과 금지. |

> **백프레셔 흐름**: BufferProducer는 demand가 있을 때만 큐에서 메시지를 내보낸다. processors가 포화(max_demand 도달)면 demand가 멈추고 producer 큐가 쌓인다. 큐가 상한(§4.3 `max_queue_len`)을 넘으면 **HTTP 수신 단계에서 429**로 거부 → 디바이스가 재전송. 이렇게 끝단(HTTP)까지 백프레셔를 전달해 메모리 무한 증가를 막는다.

> **DB 커넥션 주의**: batcher concurrency × (insert_all 동시성)이 `Repo` pool_size를 넘으면 안 된다. 기본 pool_size 10 기준 batcher 2는 안전. pool_size 조정 시 함께 검토.

---

## 4. HTTP Ingest 엔드포인트 + 인증/actor 처리

### 4.1 엔드포인트

| 메서드 | 경로 | 컨트롤러 액션 | 설명 | 응답 |
|--------|------|--------------|------|------|
| POST | `/ingest/equipment` | `:create` | 단건 또는 배열 측정값 수집 | 202 Accepted |
| GET | `/ingest/health` | `:health` | 파이프라인 활성/큐 깊이 확인 | 200 |

- **scope 분리**: 코어 `/api`와 별도로 `scope "/ingest", OpenMesWeb`. 라우터에서 ingest scope 전체를 config 게이트(§7.2)로 조건부 등록.
- **202 Accepted (비동기)**: 컨트롤러는 토큰 검증 → `Ingest.push/1`로 버퍼에 적재 → **즉시 202** 반환. 적재 결과(검증/DB)는 기다리지 않는다(고처리량 핵심). 디바이스는 "접수됨"만 확인.
- **배치 수신 지원**: body가 단건 객체 또는 객체 배열 모두 허용. 배열이면 각 원소를 개별 메시지로 push.

요청 예시:
```json
POST /ingest/equipment
Authorization: Bearer <device-token>
[
  {"equipment_id":"EQP-01","metric_key":"temperature","value":72.4,"unit":"degC","measured_at":"2026-06-13T08:00:01.123Z"},
  {"equipment_id":"EQP-01","metric_key":"state","string_value":"running","measured_at":"2026-06-13T08:00:01.123Z"}
]
```
응답:
```json
202 {"accepted": 2}
```
큐 포화 시:
```json
429 {"error": "ingest_busy", "retry_after_ms": 500}
```

### 4.2 인증 / actor 처리 (설비 토큰 — MVP 임시 방식)

> **결정 — 설비는 사람 actor가 아니다.** 코어의 `X-Actor-Id`(사람 행위자) 방식과 **분리**한다. 설비 수집은 디바이스/시스템 토큰으로 인증한다.

- **MVP 임시 방식**: `Authorization: Bearer <token>` 헤더. 토큰은 config의 정적 화이트리스트로 검증.
  ```elixir
  # config/runtime.exs
  config :open_mes, OpenMes.Ingest,
    enabled: System.get_env("INGEST_ENABLED", "false") == "true",
    device_tokens: System.get_env("INGEST_DEVICE_TOKENS", "") |> String.split(",", trim: true)
  ```
- `RequireDeviceToken` plug: Bearer 토큰을 화이트리스트와 대조. 불일치 시 401. 통과 시 `conn.assigns.device_actor`에 `"device:<token-label>"` 형태로 주입.
- **텔레메트리 actor 의미**: 적재되는 measurement row에는 사람 actor_id를 두지 않는다. `equipment_id` 자체가 출처다. AuditLog를 안 달므로(§0-B) actor_id 컬럼도 measurement에 없다. 단 **dead-letter 격리 레코드**에는 어느 디바이스 토큰에서 온 오염인지 추적용으로 `source` 필드를 남긴다(§5.2).
- **후속 확장 지점**: 실제 운영은 디바이스별 발급 토큰 + 회전(rotation) + 토큰별 rate limit. MVP는 정적 화이트리스트로 단순화하고 plug만 교체하면 되도록 격리. (mTLS/디바이스 인증서는 더 후속.)

---

## 5. 검증 실패 / 오염 데이터 처리 (재시도 + dead-letter)

### 5.1 처리 정책 결정

| 실패 유형 | 처리 | 재시도 |
|----------|------|--------|
| **검증 실패**(필수 필드 누락, skew 초과, 타입 오류 등 = 오염 데이터) | dead-letter 격리 후 `Message.failed`. | ❌ 재시도 무의미(데이터가 영구히 잘못됨) |
| **DB 일시 오류**(커넥션 끊김 등, batcher 단계) | Broadway 기본 재시도(배치 재처리). | ✅ Broadway가 배치를 다시 처리 |
| **DB 영구 오류**(CHECK 위반 = 검증 누락분) | 부분 실패 행만 dead-letter, 나머지 커밋(§5.3). | ❌ |

> **핵심 구분**: 오염 데이터(garbage in)는 재시도해도 영원히 실패하므로 **즉시 dead-letter**. 인프라 일시 오류만 재시도. 이 구분이 무한 재시도 루프를 막는다.

### 5.2 dead-letter 테이블 — `ingest_dead_letters`

| 필드 | 타입 | 제약 | 비고 |
|------|------|------|------|
| `id` | `binary_id` | PK | (저빈도이므로 UUID PK 무방) |
| `raw_payload` | `map`(jsonb) | NOT NULL | 원본 메시지 그대로(재처리/분석용) |
| `reason` | `string` | NOT NULL | 실패 사유(예: `missing:equipment_id`, `skew_exceeded`) |
| `source` | `string` | NULL | 디바이스 토큰 라벨(어느 출처 오염인지) |
| `inserted_at` | `utc_datetime_usec` | NOT NULL | 격리 시각 |

- 일반 PostgreSQL 테이블(hypertable 아님). 저빈도.
- 인덱스: `index(:ingest_dead_letters, [:reason])`, `index(:ingest_dead_letters, [:inserted_at])`.
- **append-only**: 운영자가 분석 후 수동 정리(또는 후속 retention). DELETE/UPDATE 함수 미작성.
- **이것은 AuditLog가 아니다.** 도메인 변경 이력이 아니라 수집 오류 격리소다. 코어 audit_logs와 무관.

### 5.3 batcher 부분 실패 처리

- `Repo.insert_all`은 전체가 한 트랜잭션. CHECK 위반 1건이 배치 전체를 롤백시킨다.
- **MVP 전략**: 검증(§3.3)에서 CHECK 위반 가능 데이터를 1차로 걸러 batcher에 오염이 거의 안 가게 한다. 그래도 batcher insert가 통째로 실패하면 → 해당 배치를 dead-letter로 일괄 격리하고 로그 경보. (행 단위 재분할 재시도는 후속 — 과설계 회피.)

---

## 6. config 기반 on/off + behaviour 계약

### 6.1 선택적 활성화

```elixir
# config/config.exs (기본 비활성 — 코어는 이게 false여도 완전 동작)
config :open_mes, OpenMes.Ingest, enabled: false

# config/runtime.exs 에서 환경변수로 켬 (§4.2 참조)
```

`application.ex` 변경(코어-확장 유일 배선 접점):
```elixir
def start(_type, _args) do
  children =
    [
      OpenMes.Repo,
      OpenMesWeb.Endpoint
      # ... 기존 코어 children
    ] ++ ingest_children()

  Supervisor.start_link(children, strategy: :one_for_one, name: OpenMes.Supervisor)
end

defp ingest_children do
  if OpenMes.Ingest.enabled?() do
    [OpenMes.Ingest.Pipeline]  # Broadway가 BufferProducer까지 supervise
  else
    []
  end
end
```

- `enabled? == false`면 Broadway child가 아예 안 뜬다. 라우터의 `/ingest` scope도 조건부 미등록. 코어 영향 0.
- **검증 포인트(qa-auditor)**: config를 끄고 `mix test` 전체가 통과해야 한다. 확장이 코어 동작에 필수가 아님을 증명.

### 6.2 behaviour 계약 — `DomainSink`

수집 파이프라인이 코어 도메인과 만나는 **유일한 추상 경계**.

```elixir
defmodule OpenMes.Ingest.Sink.DomainSink do
  @moduledoc """
  텔레메트리 → 코어 도메인 신호 변환 계약.
  확장이 코어 내부를 직접 건드리지 않고, 이 behaviour 구현체를 통해서만 도메인에 영향을 준다.
  적재된 measurement 배치를 받아, 도메인적으로 의미 있는 신호(임계치 초과 등)를 판단해
  코어로 흘려보낼 수 있다.
  """

  @doc "검증·적재된 measurement row 배치를 후처리. 도메인 이벤트 발행 등."
  @callback handle_measurements([map()]) :: :ok
end
```

- 어떤 sink를 쓸지는 config로 선택:
  ```elixir
  config :open_mes, OpenMes.Ingest, sink: OpenMes.Ingest.Sink.NoopSink
  ```
- Pipeline의 `handle_batch`가 `Loader.bulk_insert` 직후 `configured_sink().handle_measurements(rows)`를 호출.

### 6.3 sink 구현체

- **`NoopSink`** (MVP 기본값): `def handle_measurements(_), do: :ok`. 텔레메트리는 적재만 되고 코어로 아무것도 안 흘러간다. **이것이 기본**이며 §0-B의 "텔레메트리는 도메인과 분리" 경계를 코드로 보장.
- **`OutboxSink`** (옵션/후속): 임계치 초과 등 도메인 의미 사건을 코어 `OpenMes.Outbox.emit`으로 발행.
  - 예: `equipment.threshold_breached` 이벤트. 단 **이 이벤트 타입은 현재 문서(system-architecture.md L48-55)에 정의되어 있지 않다** → 임의 추가 금지(01번 설계 §6 결정 승계). 발행하려면 먼저 문서 이벤트 목록에 추가 후 활성화.
  - 따라서 MVP는 `OutboxSink`를 **스켈레톤만** 두고(또는 미구현), 기본은 `NoopSink`. 도메인 이벤트 연계는 §8.4 후속.

> **이 설계의 핵심**: 텔레메트리→도메인 연계 여부가 **config 한 줄(sink 교체)**로 결정된다. 코어는 sink behaviour의 존재조차 모른다(의존 방향 확장→코어 유지). 도메인 이벤트가 필요해지면 `OutboxSink`로 교체하되, 발행은 반드시 코어 `Outbox.emit`(동일 트랜잭션 패턴)을 경유한다.

---

## 7. domain-engineer 구현 지침

### 7.1 마이그레이션 의존성 / 구현 순서

```text
[전제] Docker DB 이미지를 timescaledb 포함 이미지로 교체 (§8.1) — 코드 전 인프라 확인
  1. 마이그레이션: enable_timescaledb  (CREATE EXTENSION)
  2. 마이그레이션: create_equipment_measurements (+ create_hypertable + CHECK)
  3. 마이그레이션: create_ingest_dead_letters
  4. OpenMes.Ingest.Measurement / DeadLetterRecord 스키마 (@primary_key false 주의 — measurement)
  5. OpenMes.Ingest.Validator (순수 함수) + 단위 테스트 먼저 (TDD 가능)
  6. OpenMes.Ingest.Loader (insert_all) / DeadLetter.capture
  7. OpenMes.Ingest.Sink.DomainSink behaviour + NoopSink (기본값)
  8. OpenMes.Ingest.BufferProducer (GenStage producer + 큐 + 백프레셔)
  9. OpenMes.Ingest.Pipeline (use Broadway) + Ingest 퍼사드(enabled?/push)
 10. application.ex 조건부 child + config (enabled:false 기본)
 11. RequireDeviceToken plug + IngestController + 라우터 조건부 scope
 12. 테스트: Validator 단위, Pipeline(Broadway.test_message), Controller(202/401/429)
```

### 7.2 구현 세부 규칙

- **코어 비침투 절대 규칙**: `lib/open_mes/` 하위 파일을 수정하지 않는다. **유일한 예외는 `application.ex`의 `ingest_children/0` 추가**와 `router.ex`의 조건부 `/ingest` scope. 이 두 곳 외 코어 변경 금지. (코어 Production/WorkOrder/Audit 스키마 일절 손대지 않음.)
- **의존 방향**: `OpenMes.Ingest.*`는 `OpenMes.Repo`와 (OutboxSink 한정)`OpenMes.Outbox`만 코어에서 참조. 그 외 코어 모듈 alias 금지.
- **Measurement 스키마**: `@primary_key false`, `@timestamps_opts` 미사용(measured_at/ingested_at 수동 관리). `insert_all`은 timestamps 자동 안 넣으므로 row map에 직접 포함.
- **insert_all 주의**: `Repo.insert_all(Measurement, rows)`에서 rows의 키는 DB 컬럼명(atom). 캐스트는 Validator에서 끝냄. `placeholders` 옵션은 MVP 불필요.
- **BufferProducer 구현**: GenStage `:producer`. 내부 상태에 `:queue`(Erlang `:queue` 모듈) + `pending_demand`. `handle_demand`로 큐에서 꺼내 디스패치. `Ingest.push/1`은 producer에 `GenStage.cast`/`Broadway.push_messages` 류로 적재. 큐 길이 상한(`max_queue_len`, 기본 50_000) 초과 시 `push/1`이 `{:error, :busy}` 반환 → 컨트롤러 429.
- **202 비동기**: 컨트롤러는 절대 적재/검증 결과를 기다리지 않는다. `push` 성공(큐 적재)만 확인.
- **언어**: 주석/에러 메시지 한국어, 식별자 영문.
- **append-only**: Measurement/DeadLetter 컨텍스트에 update/delete 함수 미작성.

### 7.3 qa-auditor 검증 대비 (이 확장의 특수 검증 항목)

**일반 코어 감사 원칙은 이 확장에 그대로 적용되지 않는다.** 아래를 명시적으로 안내한다.

- ✅ **(정상) `equipment_measurements` 적재에 AuditLog 없음** — §0-B 경계. 고빈도 텔레메트리는 append-only hypertable이 이력성을 보장. **이것은 누락이 아니라 설계 결정.** qa-auditor는 텔레메트리 경로에서 AuditLog 부재를 결함으로 보고하지 말 것.
- ✅ **(정상) measurement에 actor_id 컬럼 없음** — 설비 출처(`equipment_id`)가 곧 actor. 사람 actor 모델 적용 대상 아님.
- ✅ **(정상) measurement가 코어 테이블을 FK 참조하지 않음** — 고빈도 적재/도메인 분리 의도.
- ⛔ **(검증) 코어 비침투**: `lib/open_mes/` 변경이 `application.ex`/`router.ex` 두 곳뿐인지. 그 외 코어 변경 있으면 위반.
- ⛔ **(검증) 선택적 활성화**: `enabled: false`로 `mix test`(코어 테스트) 전체 통과. Broadway child 미기동 확인.
- ⛔ **(검증) 의존 방향 단방향**: 코어 모듈이 `OpenMes.Ingest.*`를 참조하지 않는지(grep). 확장→코어만 허용.
- ⛔ **(검증) 도메인 이벤트는 Outbox 경유**: 만약 `OutboxSink`를 활성화했다면, 도메인 이벤트가 코어 `OpenMes.Outbox.emit`(동일 트랜잭션 패턴)으로만 발행되는지. 직접 outbox_events insert 금지.
- ⛔ **(검증) 오염 데이터 격리**: 검증 실패 메시지가 dead-letter로 가고 무한 재시도하지 않는지.

> 즉 **이 확장에서 audit-verify 스킬의 "모든 쓰기에 AuditLog" 룰은 텔레메트리 경로에 적용 제외**다. AuditLog/LOT/상태머신 룰은 코어 도메인 트랜잭션에만 유효하다. 이 경계를 qa-auditor가 인지해야 오탐을 피한다.

### 7.4 테스트 필수 케이스

- `Validator`: 정상 → row map, 필수필드 누락 → `{:error, ...}`, value/string_value 둘 다 없음 → 오류, skew 초과 → 오류, 단건 단위 테스트.
- `Pipeline`: `Broadway.test_message(OpenMes.Ingest.Pipeline, raw)` 로 정상 메시지 → measurement 적재 확인. 오염 메시지 → dead-letter 1건 + failed.
- `IngestController`: 유효 토큰 단건 → 202/`accepted:1`, 배열 → `accepted:N`, 토큰 없음/오류 → 401, 큐 포화 모의 → 429.
- **코어 비침투 회귀 테스트**: `enabled:false` 환경에서 코어 WorkOrder 테스트 전체 통과(확장이 코어를 깨지 않음).

---

## 8. 미해결 / 후속 항목

### 8.1 인프라 전제 (도메인 엔지니어 착수 전 확인)

- **TimescaleDB 설치 필요**: 현 Docker Compose의 PostgreSQL 이미지를 `timescale/timescaledb:latest-pg16`(또는 동등) 으로 교체해야 `CREATE EXTENSION timescaledb`가 동작한다. → **사용자 확인 필요**: Docker 이미지 교체 승인. (교체 안 하면 ingest 모듈 마이그레이션 실패하나, 코어는 영향 없음 — enabled:false면 코어 정상.)

### 8.2 Kafka/MQTT producer 전환 경로

- 현재 `BufferProducer`(브로커리스)를 Broadway producer 자리에 꽂았다. Broadway는 producer가 교체 가능한 설계이므로, 외부 브로커 도입 시 **`Pipeline`의 `producer.module`만 `BroadwayKafka.Producer` 등으로 교체**하면 processors/batchers/Validator/Loader는 그대로 재사용된다. HTTP ingest 컨트롤러는 브로커로 직접 publish하는 게이트웨이로 바뀌거나 유지 가능. → 전환 시 acknowledger/offset 관리가 추가되는 정도.

### 8.3 TimescaleDB 운영 정책 (데이터 누적 후)

- retention policy(`add_retention_policy`), continuous aggregate(분/시간 단위 롤업), compression(`add_compression_policy`)은 데이터량·조회 패턴 확인 후 후속 마이그레이션. 지금 도입은 과설계.

### 8.4 도메인 이벤트 연계 (OutboxSink 활성화)

- 설비 임계치 초과 → 점검 필요 같은 도메인 신호를 코어로 흘리려면: (1) `system-architecture.md` 이벤트 목록에 `equipment.threshold_breached` 등 정식 추가, (2) `OutboxSink` 구현(임계치 규칙 + `Outbox.emit`), (3) config sink 교체. 임계치 규칙(어떤 metric이 몇이면 이벤트인지)은 **도메인/사용자 정의 필요** → 현재 미정.
- 설비-작업지시 의미 연결(measurement.work_order_id ↔ 코어 WorkOrder)도 이 단계에서 집계/조인 정책 확정.

### 8.5 ClickHouse 등 대규모 분석 연계

- TimescaleDB는 운영 시계열 + 단기 분석에 충분. 페타급 분석/장기 OLAP가 필요해지면 hypertable → ClickHouse 등으로 CDC/배치 export. 현 단계 불필요(YAGNI). 별도 sink(`AnalyticsSink`)로 확장 가능한 구조는 이미 §6.2 behaviour로 열려 있음.

### 8.6 사용자 확인 필요 요약

1. **Docker DB 이미지 TimescaleDB 교체 승인** (§8.1) — 착수 전 필수.
2. **디바이스 토큰 방식**: MVP 정적 화이트리스트로 진행. 디바이스별 발급/회전 필요 시 확정.
3. **도메인 이벤트 연계 범위**: MVP는 `NoopSink`(텔레메트리 적재만). 임계치 이벤트 등 필요 시 이벤트 정의부터 확정(§8.4).
4. **chunk/retention 정책**: 7일 chunk 시작값으로 진행, 운영 데이터 보고 조정.
