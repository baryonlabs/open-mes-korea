# 25. Architect — AI 종합 조사 환경(시계열 EXT-1 + 미디어 EXT-2 + 생산) Level 1 Read-only

대상: **Claude(AI)가 시계열 설비 측정값(EXT-1) + 영상/미디어 메타(EXT-2) + 생산 데이터를 하나의 권한 필터 컨텍스트로 종합 조사**하는 환경. 사용자가 자연어로 질의하면("P03 설비 최근 진동 추세와 영상 이상 징후 조사해줘") AI가 시계열·미디어·생산을 묶어 보고 분석 요약을 반환한다. ai-native-architecture.md **Level 1: Read-only Assistant** — 쓰기 0, 승인 흐름 불필요(읽기는 즉시), 모든 조사는 `AiInteraction(intent="query")` 감사.

핵심 정체성(사용자 명시): "**시계열·영상 미디어 데이터를 Claude가 종합적으로 조사해서 볼 수 있는 환경을 구축했다**". EXT-1(TimescaleDB `equipment_measurements`)·EXT-2(MinIO `media_assets`)로 데이터는 이미 확보됨. 23번이 AI 쓰기 경로(propose→승인→apply)를 구축했다면, 25번은 그 반대편 — **AI 읽기 경로의 종합화**다.

선행: 23번(`OpenMes.Ai` 컨텍스트 + `Provider` behaviour + `AiInteraction` 엔티티 + `SkillRegistry` + 설정 메뉴 그룹). EXT-1(`OpenMes.Ingest` + `equipment_measurements`), EXT-2(`OpenMes.Media` + `media_assets`). 이 문서는 23번 인프라를 **읽기 전용 조사로 확장**한다 — 23번 무손상, 새 쓰기 메커니즘 0.

원칙: **CLAUDE.md·ai-native-architecture.md AI 안전 엄수**(Context API 경유, AI DB 직접 접근 0, 쓰기 0, AiInteraction 감사, 근거 표시, 권한 role 필터). pi(집계+샘플, raw 전량 금지, chart_components/Provider/AiInteraction 재활용, 과설계 금지). RAG 문서는 범위 밖(외부 커넥터). 기존 화면/라우트/23번 AI 연동 무손상. 한국어 UI/영문 식별자.

---

## 0. 핵심 설계 결정 (요약 5)

1. **AI는 시계열/미디어/생산 DB를 절대 직접 보지 않는다 — `OpenMes.Ai.Investigation.build_context/3`가 만든 단일 plain map(`ai_investigation_context`)만 본다.** 23번의 `ProductionLine.ai_context/2` 패턴을 그대로 종합 데이터로 확장: 설비/공정 하나를 중심으로 (a) 시계열 통계요약+샘플, (b) 미디어 메타+링크, (c) 생산 실적/불량을 **권한 role 필터** 후 하나의 map으로 묶는다. Provider 구현체는 이 map과 query 문자열만 받으므로 Repo/Ecto에 구조적으로 접근 불가(23번과 동일한 구조적 안전 경계). 이것이 "AI가 종합 조사하되 안전하다"의 코드 경계다.

2. **대량 시계열은 raw 전량이 아니라 "집계+샘플"로 컨텍스트에 넣는다(pi + 토큰 안전).** `equipment_measurements`는 고빈도 hypertable(설비당 초·분 단위 수만 row)이므로 AI에 전부 넘기면 토큰 폭발·환각·성능 붕괴. 컨텍스트는 metric_key별로 **통계 요약**(count/avg/min/max/최근값/단순 추세/이상치 개수)과 **다운샘플 시리즈**(예: 시간 버킷 평균 ≤ 60포인트)만 담는다. raw 시리즈 조회 함수는 차트 렌더 전용으로 분리하고 AI 컨텍스트에는 다운샘플만 — **"데이터 확보는 EXT-1/2가, AI 조사는 요약이"** 라는 역할 분리.

3. **Level 1이므로 승인 흐름·apply가 없다 — 조사는 propose보다 더 안전하다(쓰기 0, 즉시 응답).** 23번은 propose→approved→executed 상태머신을 거쳤지만, 25번 조사는 **읽고 요약만** 하므로 `AiInteraction(intent="query", approval_status="answered")` 단일 터미널 상태로 기록한다. 23번 상태머신(`proposed→...→executed`)에 손대지 않고, query 흐름은 그 상태머신을 **거치지 않는**(별 intent) 평행 경로다 — 상태머신 임의 전이 추가 0. 쓰기가 없으므로 reviewer/apply/Outbox `ai_action.*`도 없다(읽기엔 불필요).

4. **시계열·미디어의 `equipment_id`(문자열, 디바이스 키)와 코어의 `equipment_id`(binary_id FK)는 다른 키다 — 컨텍스트 빌더가 명시적으로 브리지한다.** EXT-1 `equipment_measurements.equipment_id`·EXT-2 `media_assets.equipment_id`는 디바이스가 보낸 **문자열**(예 `"EQ-P03"` 또는 `"P03"`)이고, 코어 `ProductionResult.equipment_id`는 `MasterData.Equipment.id`(binary_id)다. 조사는 **설비 1대(MasterData.Equipment, equipment_code 보유)를 기준점**으로: equipment_code(`"EQ-P03"`)로 EXT-1/2 문자열 키를 조회하고, equipment.id(binary_id)로 코어 생산 실적을 조회한다. 이 키 브리지를 빌더 한 곳에 격리(설계 §1.5) — AI는 브리지를 보지 않고 종합된 결과만 본다.

5. **시계열 추세 시각화를 위해 chart_components에 `line_chart`(SVG 꺾은선/면적) 1종만 신규 추가하고, 미디어는 메타+링크만(바이너리 0).** 현재 chart_components에는 막대/도넛/게이지/flow는 있으나 **시간축 꺾은선이 없다** — 시계열 추세 표시에 필요하므로 Geometry 순수 함수 기반 `line_chart` 1개만 추가(외부 라이브러리 0, 기존 패턴 답습). 미디어는 `media_assets`의 메타(촬영시각/타입/object_key/state)와 object storage **참조 링크(presigned 또는 경로)**만 표시 — 바이너리·썸네일 디코딩은 범위 밖(MVP는 타입 아이콘+메타, 링크 클릭은 후속). **새 차트 1개·새 미디어 위젯은 메타 표시뿐** — 과설계 금지.

---

## 1. AI Context 확장 — 시계열 + 미디어 + 생산 종합 (읽기 전용)

### 1.1 신규 컨텍스트 모듈 `OpenMes.Ai.Investigation`

23번 `OpenMes.Ai`(쓰기 경로)와 분리된 **읽기 조사 컨텍스트**. 위치 `lib/open_mes/ai/investigation.ex`(같은 ai/ 네임스페이스, 책임 분리). EXT-1/EXT-2는 **확장 네임스페이스**(`OpenMes.Ingest`/`OpenMes.Media`)이므로, 이 모듈이 코어↔확장 경계의 **조사용 읽기 퍼사드**가 된다(확장이 코어에 침투하지 않음 — 읽기 함수만 호출).

```
lib/open_mes/ai/
  investigation.ex          ← [신규] 종합 컨텍스트 빌더 + 조사 진입점(build_context, investigate)
  ai.ex                     ← [23번 그대로] 쓰기 경로(propose/approve/apply)
  ai_interaction.ex         ← [23번 + 확장] intent="query" / approval_status="answered" 허용
  provider.ex               ← [23번 + 확장] @callback investigate/2 추가
  provider/
    mock_provider.ex        ← [23번 + 확장] investigate/2 구현(통계 요약 템플릿)
    claude_provider.ex      ← [23번 + 확장] investigate/2 구현(실분석, 키 있을 때)
```

### 1.2 `ai_investigation_context` 구조 (AI가 보는 유일한 입력)

`build_context(equipment_code, opts, actor)` 반환. **권한 필터됨, 읽기 전용, plain map.** AI는 이 map만 본다.

```elixir
%{
  # ── 기준점: 설비 1대(또는 공정) ──
  subject: %{
    equipment_code: "EQ-P03",        # MasterData.Equipment.equipment_code (기준 키)
    equipment_name: "사출기 3호",
    equipment_id: "<binary_id>",     # 코어 생산 조회용(AI에 노출되나 식별자일 뿐)
    process_code: "P03",             # 연결 공정(있으면)
    process_name: "사출"
  },
  period: %{from: ~U[...], to: ~U[...], label: "최근 24시간"},

  # ── (A) 시계열 context: 집계 요약 + 다운샘플 시리즈 (raw 전량 금지) ──
  timeseries: %{
    metrics: [
      %{
        metric_key: "vibration", unit: "mm/s",
        count: 14_320, avg: 2.31, min: 0.4, max: 9.8, last: 3.1,
        trend: "rising",            # rising | falling | flat (단순 선형 기울기 판정)
        anomaly_count: 7,           # 3σ 또는 임계 초과 개수(요약)
        sample: [%{t: ~U[...], v: 2.1}, ...]   # 다운샘플 ≤ 60포인트(시간 버킷 평균)
      },
      %{metric_key: "temperature", ...}
    ],
    metric_count: 4,
    total_points: 58_240            # 원본 규모(요약했음을 명시 — 근거)
  },

  # ── (B) 미디어 context: 메타 + object storage 링크 (바이너리 0) ──
  media: %{
    assets: [
      %{id: "...", media_type: "video", captured_at: ~U[...],
        object_key: "media/EQ-P03/2026/...", state: "stored",
        file_size: 10_485_760, reference: "<presigned_or_path>",
        meta: %{...}}              # 추출 특징(있으면) — meta jsonb 그대로
    ],
    counts_by_type: %{"video" => 12, "image" => 40, "audio" => 0},
    total: 52
  },

  # ── (C) 생산 context: 작업지시·실적·불량 (기존 코어) ──
  production: %{
    process_summary: %{good: 1820, defect: 47, total: 1867, defect_rate: 0.0252},
    recent_defects: [%{recorded_at: ~U[...], defect_type: "...", quantity: 3}, ...],  # ≤ N건
    active_work_orders: [%{wo_no: "...", item: "...", status: "in_progress"}, ...],   # ≤ N건
    line_status: %{overall: :amber, data: :ok, equipment: :ok, quality: :warn}        # LineMonitor 재사용(있으면)
  },

  # ── 메타(근거 표시용) ──
  referenced: %{
    sources: ["equipment_measurements", "media_assets", "production_results", "defect_records"],
    timeseries_points_sampled: 58_240,
    media_assets_count: 52,
    role: "quality_manager",       # 어떤 권한으로 봤나
    generated_at: ~U[...]
  }
}
```

> **pi 경계**: `timeseries.metrics[].sample`은 다운샘플 ≤ 60포인트, `media.assets`·`production.recent_defects`·`active_work_orders`는 상한 N(예 20)건. raw 측정값 전량/미디어 바이너리는 컨텍스트에 절대 안 넣는다.

### 1.3 (A) 시계열 컨텍스트 — `build_timeseries/3`

EXT-1 `equipment_measurements`를 읽어 **metric_key별 통계 요약 + 다운샘플**. 새 read 함수가 EXT-1에 필요(현재 EXT-1은 적재 전용, 조회 함수 없음 — 설계 §3.1).

- **입력**: `equipment_id_string`(= equipment_code, 디바이스 키), period(from/to).
- **집계**(DB 측 권장 — 토큰/성능): `SELECT metric_key, count, avg, min, max, last(value, measured_at)` GROUP BY metric_key. TimescaleDB면 `time_bucket`로 다운샘플 시리즈를 같은 쿼리군에서.
- **추세 판정**(순수 함수, 테스트 대상): 다운샘플 시리즈의 선형 기울기 부호 → `rising|falling|flat`.
- **이상치 판정**(순수, 단순): avg±3σ 또는 metric 임계(설정 가능 시) 초과 개수. **완벽 통계 아님 — 요약 신호**(pi, 데이터 확보 우선과 동형).
- **다운샘플**: 버킷 수 ≤ 60(예: 24시간이면 24분 버킷). 시각화 차트와 AI 컨텍스트가 같은 다운샘플 공유(중복 쿼리 회피).

### 1.4 (B) 미디어 컨텍스트 — `build_media/3`

EXT-2 `media_assets`를 읽어 **설비/기간별 메타 + 타입별 개수 + object storage 링크**. 새 read 함수가 EXT-2에 필요(현재 `list_by_state/2`만 있음 — 설계 §3.2).

- **입력**: equipment_id_string(= equipment_code), period.
- **조회**: `WHERE equipment_id = ? AND captured_at BETWEEN ? AND ? ORDER BY captured_at DESC LIMIT N`(N≤20). `state="stored"` 우선(object storage에 올라간 것).
- **반환 필드**: id, media_type, captured_at, object_key, state, file_size, meta(추출 특징 jsonb 그대로 — 있으면 AI가 봄), reference(링크).
- **링크**: `OpenMes.Media.object_store`/`bucket`으로 경로 구성. presigned URL은 후속(MVP는 object_key + bucket 표시, 클릭 링크는 스텁 가능 — pi). **바이너리·썸네일 디코딩 0.**
- **타입별 개수**: `GROUP BY media_type` → `%{"video" => n, "image" => n, "audio" => n}`.

### 1.5 (C) 생산 컨텍스트 + 키 브리지 — `build_production/3`

코어(작업지시/실적/불량)를 **설비/공정 기준**으로 요약. 키 브리지가 여기서 일어난다(설계 결정 #4).

- **키 브리지**(빌더 한 곳에 격리):
  - 기준 `equipment_code`(예 `"EQ-P03"`)로 `MasterData.get_equipment_by_code/1` → `equipment.id`(binary_id) 확보.
  - equipment.id로 `Production` 실적/불량 조회(ProductionResult.equipment_id = binary_id FK).
  - equipment_code 문자열로 EXT-1/2 조회(§1.3/§1.4).
  - 공정 연결: 라인 구성(`ProductionLine`)에서 equipment↔process 매핑이 있으면 process_summary에 LineMonitor 결과 재사용.
- **반환**: process_summary(good/defect/total/rate), recent_defects(≤N), active_work_orders(≤N), line_status(LineMonitor `line_steps` 중 해당 공정 노드 — 있으면).
- **기존 컨텍스트 재사용**: `Production.*`, `Reports.production_by_process`, `LineMonitor.line_steps` 읽기 함수 재활용(새 쿼리 최소).

### 1.6 권한 role 필터 (AI Context API 원칙 — 이중 방어)

`build_context/3`는 actor의 role을 받아 인가:
- **허용 role**: `system_admin`, `production_manager`, `quality_manager`(품질이 시계열/미디어 조사 핵심 사용자). 그 외 `{:error, :unauthorized}`.
- 23번 `ProductionLine.ai_roles`(system_admin/production_manager)보다 **quality_manager 포함**(조사는 품질 분석 성격) — 단, 조사 전용 role 목록을 `Investigation`에 별도 정의(`@investigation_roles`)하여 23번 쓰기 권한과 혼동 0.
- role은 컨텍스트의 `referenced.role`에 기록(누가 어떤 권한으로 봤나 — 감사).
- **이중 방어**: LiveView on_mount 인가 + `build_context/3` 함수 인가(화면 우회 직접 호출도 차단).

---

## 2. AI 조사 흐름 (Level 1 Read-only — 쓰기 0, 즉시 응답)

```
[1] 사용자: 설비/공정 + 기간 선택 + 자연어 질의
    (LiveView /admin/ai/investigate, actor=current_actor, role 인가)
    예: "P03 설비 최근 진동 추세와 영상에서 이상 징후 조사해줘"
        │
        ▼
[2] Investigation.build_context(equipment_code, [period: ...], actor)   ← 권한 필터 종합 컨텍스트(쓰기 0)
        │   반환: ai_investigation_context (§1.2) — 시계열요약+미디어메타+생산. raw/바이너리 0.
        ▼
[3] Investigation.investigate(equipment_code, query, actor)             ← 조사 진입점
        │   ├─ build_context (인가 내장)
        │   ├─ Provider.active().investigate(context, query)            ← behaviour(mock|claude). Repo 접근 불가.
        │   │     반환: %{analysis: "한국어 분석/요약", findings: [...], referenced: context.referenced}
        │   └─ AiInteraction 생성(intent: "query", approval_status: "answered",
        │        prompt: query, response_summary: analysis,
        │        referenced_resources: context.referenced,   ← 어떤 시계열/미디어/생산 봤는지(근거)
        │        proposed_action: nil,                       ← 쓰기 없음(읽기 전용)
        │        provider: "mock"|"claude")
        │      + AuditLog(ai_interaction.query)              ← 모든 AI 조사 감사
        ▼   반환: {:ok, %{interaction, context, result}}    (← 부수효과: 쓰기 0. AiInteraction 1건 + AuditLog만)
[4] UI: 종합 결과 렌더(§4)
        - AI 분석 요약(result.analysis)
        - 시계열 SVG 차트(context.timeseries — line_chart 추세/이상치)
        - 미디어 목록(context.media — 타입/촬영시각/링크)
        - 근거(context.referenced — 본 데이터 소스/규모) 표시
        - provider 배지("Mock 요약" / "Claude")
```

**불변식 코드 경계**(23번 동형):
- Provider 구현체는 `context`(plain map) + `query`(string)만 받음 → Repo/Ecto 인자 없음 → **구조적으로 쓰기·DB 접근 불가**.
- 조사 경로엔 `propose_action`·`apply`·step 쓰기 호출이 **존재하지 않음**(grep 검증: investigate 경로에서 Repo write 0).
- `AiInteraction(intent="query")`는 23번 상태머신을 거치지 않음 — `answered` 단일 상태(터미널). 23번 `proposed→...` 전이 함수와 충돌 0.

### 2.1 왜 승인 흐름이 없는가 (Level 1 vs Level 3)

| | 23번 (Level 3, 쓰기) | 25번 (Level 1, 읽기) |
|---|---|---|
| AI 산출물 | diff(라인 구성 변경안) | 분석 텍스트 + 근거 |
| 부수효과 | 승인 후 step 쓰기 | **0** |
| 상태머신 | proposed→approved→executed | answered(단일) |
| 승인 필요 | 예(인간 reviewer) | **아니오**(읽기는 즉시) |
| Outbox | ai_action.proposed/approved | **없음**(읽기 이벤트 불요) |
| 감사 | AiInteraction + AuditLog | AiInteraction + AuditLog(동일) |

읽기는 "권한 없는 데이터를 못 본다"(role 필터)로 안전이 충분하고, 변경이 없으므로 승인이 불필요하다(ai-native-architecture.md L113-117: 쓰기·중요 변경에만 승인). **감사(AiInteraction)는 읽기도 예외 없이 기록** — "모든 AI 상호작용 감사"(CLAUDE.md L89).

---

## 3. EXT-1 / EXT-2 읽기 함수 신규 (확장 측 추가 — 코어 무침투)

조사 컨텍스트가 호출할 읽기 함수. **확장 네임스페이스에 추가**(EXT-1/2가 코어에 침투하지 않음 — 읽기 함수 노출만). append-only/텔레메트리 경계 유지(AuditLog 불필요 — 읽기 + 텔레메트리 데이터).

### 3.1 EXT-1: `OpenMes.Ingest` 조사 읽기 함수

현재 EXT-1은 적재 전용(`push`/`push_many`)이고 조회 함수가 없다. 조사용 읽기 함수 추가:

```elixir
# lib/open_mes_ingest/ingest.ex (또는 lib/open_mes_ingest/query.ex 분리 — 호출처 1곳이면 인라인, pi)

@doc "설비/기간별 metric_key 통계 요약(집계 — raw 전량 금지)."
def summarize_metrics(equipment_id, from, to)
# 반환: [%{metric_key, unit, count, avg, min, max, last, ...}]  — DB 집계(GROUP BY metric_key)

@doc "설비/metric/기간 다운샘플 시리즈(버킷 평균 ≤ buckets 포인트)."
def downsample(equipment_id, metric_key, from, to, buckets \\ 60)
# 반환: [%{t: utc, v: float}]  — TimescaleDB time_bucket 또는 일반 PG date_trunc/width_bucket
```

- equipment_id는 **문자열**(디바이스 키 = equipment_code). measured_at으로 기간 필터.
- TimescaleDB 함수(`time_bucket`, `last`) 사용 가능 시 활용, 아니면 일반 PG(`date_trunc`)로 폴백(pi — 환경 의존 최소).
- **AuditLog 불필요**: 시계열 hypertable은 텔레메트리(CLAUDE.md L35 "TimescaleDB hypertable(AuditLog 불필요)").

### 3.2 EXT-2: `OpenMes.Media` 조사 읽기 함수

`list_by_state/2`만 있음. 설비/기간 조회 추가:

```elixir
# lib/open_mes_media/media.ex

@doc "설비/기간별 미디어 자산 메타(촬영시각 내림차순, 상한 limit)."
def list_assets_by_equipment(equipment_id, from, to, limit \\ 20)
# 반환: [%MediaAsset{}]  — equipment_id(문자열) + captured_at 범위, state="stored" 우선

@doc "설비/기간 미디어 타입별 개수."
def count_by_type(equipment_id, from, to)
# 반환: %{"video" => n, "image" => n, "audio" => n}

@doc "asset 의 object storage 참조 링크(presigned 또는 경로). MVP: object_key+bucket 문자열."
def reference_for(%MediaAsset{} = asset)
# presigned URL 은 후속 — MVP 는 "bucket/object_key" 또는 nil(스텁). 바이너리 0.
```

- equipment_id는 **문자열**(디바이스 키). captured_at으로 기간 필터.
- **AuditLog 불필요**: media_assets는 수집 운영 인덱스(MediaAsset moduledoc 명시 — actor_id/AuditLog 없음이 의도된 경계).

### 3.3 키 브리지 헬퍼 (코어 측)

```elixir
# lib/open_mes/master_data/master_data.ex
@doc "설비 코드로 단건 조회(조사 키 브리지용)."
def get_equipment_by_code(equipment_code)  # 반환: %Equipment{} | nil
```

equipment_code(문자열) ↔ equipment.id(binary_id) 브리지를 코어에 1함수로. `Investigation.build_production`이 이걸로 생산 실적을 binary_id로 조회.

---

## 4. 조사 화면 — 시계열 SVG + 미디어 + AI 요약 (`/admin/ai/investigate`)

LiveView `OpenMesWeb.Admin.Ai.InvestigateLive`(`use OpenMesWeb.Admin.AdminLive` — on_mount 인가). 컨텍스트 경유만(Repo 직접 0).

### 4.1 화면 구성 (단일 LiveView)

- **상단 선택 영역**:
  - 설비 선택 드롭다운(`MasterData.list_equipment(active: true)`) — 조사 기준 설비.
  - 기간 선택(최근 1시간/24시간/7일 프리셋 — pi, 커스텀 범위는 후속).
  - 자연어 질의 textarea + "조사하기" 버튼. placeholder: "P03 설비 최근 진동 추세와 영상 이상 징후를 조사해줘".
- **조사 결과 패널**(investigate 후):
  - **(1) AI 분석 요약**: `result.analysis`(한국어 분석 텍스트) + provider 배지("Mock 요약"/"Claude"). 상단 강조.
  - **(2) 시계열 차트**: metric_key별 `line_chart`(§5) — 다운샘플 추세선 + 이상치 마커. 통계 요약(avg/min/max/추세/이상치 개수) 칩 병기.
  - **(3) 미디어 목록**: `context.media.assets`를 카드/행으로 — 타입 아이콘(video/image/audio) + 촬영시각 + 파일크기 + object 링크(또는 경로). 타입별 개수 배지.
  - **(4) 생산 요약**: process_summary(양품/불량/불량률 gauge 재사용) + recent_defects + line_status 신호등.
  - **(5) 근거(referenced)**: "참조: 측정값 58,240건 요약(다운샘플 60포인트), 미디어 52건, 생산 실적·불량. 권한: 품질관리자." — **AI 분석과 함께 항상 노출**(CLAUDE.md L88).
- **조사 이력**: 이 설비의 최근 `AiInteraction(intent="query")` 목록(질의 + 시각 + actor + provider). 감사 가시성.

### 4.2 메뉴 위치 + role

- **메뉴**: 사이드바에 "**AI**" 그룹 신설(또는 23번 "설정" 그룹 하위) — "AI 조사"(`/admin/ai/investigate`). 23번이 "설정"에 AI 라인 구성을 뒀으므로, 조사는 성격이 달라(분석/조회) **별도 "AI" 그룹**이 깔끔(pi: 그룹 1개 추가). 23번 메뉴 무손상.
- **role**: `system_admin`, `production_manager`, `quality_manager`(§1.6 `@investigation_roles`). 메뉴 `roles` + 라우트 prefix 인가 + `build_context` 함수 인가(삼중 방어).

### 4.3 안전 UI 규칙

- AI 분석은 항상 **근거(referenced) + 데이터 시각화(차트·미디어)와 함께** 노출 — AI가 본 데이터를 사용자가 직접 검증 가능(CLAUDE.md L88).
- AI 텍스트는 "**분석/조사 결과**"로 표기(단정 아닌 보조). "AI 요약" 배지로 사람 판단과 구분.
- 미디어 링크는 권한 내에서만(object storage 접근도 role 게이트 — MVP는 경로 표시, presigned는 후속).

---

## 5. chart_components 확장 — `line_chart` 1종 신규 (시계열 추세)

현재 chart_components: donut/bar/gauge/progress/flow/sparkline/line_monitor. **시간축 꺾은선이 없다** → 시계열 추세 표시용 `line_chart` 1개 추가(외부 라이브러리 0, Geometry 순수 함수 기반, 기존 패턴 답습).

```elixir
# lib/open_mes_web/components/chart_components.ex 에 추가
attr :points, :list, required: true, doc: "[%{t, v}] 다운샘플 시리즈(시간 오름차순)"
attr :anomalies, :list, default: [], doc: "[%{t, v}] 이상치 마커(선택)"
attr :unit, :string, default: ""
attr :label, :string, default: "추세"
attr :width, :integer, default: 640
attr :height, :integer, default: 180
def line_chart(assigns)  # 꺾은선(또는 면적) + 이상치 빨강 점 + y축 nice_ticks + x축 시각

# Geometry 에 순수 헬퍼 추가(필요 시):
# def line_path(points, plot_w, plot_h, x_range, y_range) :: %{path, area_path, point_coords}
```

- **재사용**: `Geometry.nice_ticks`(y축), 색 매핑(`chart_color`), normalize 헬퍼. 신규 색 0.
- **접근성**: `role="img"` + 한국어 aria-label(기존 규약). 이상치는 색+마커+개수 텍스트 병기(색만 의존 금지).
- **pi**: 꺾은선 1종이면 충분(다중 metric은 차트 여러 개 반복). 줌/팬/인터랙션은 범위 밖.

---

## 6. 이 환경의 의미 (문서화 — §5 사용자 요청)

### 6.1 왜 "시계열+미디어 AI 종합 조사"가 이 MES의 정체성인가

일반 MES는 생산 실적(작업지시·LOT·불량)만 다룬다. Open MES Korea는 **데이터 확보 우선 원칙**(CLAUDE.md L29-35)에 따라 EXT-1(고빈도 설비 시계열)·EXT-2(영상/소음 미디어)를 이미 확보했다. 그러나 데이터가 분산 저장(PostgreSQL 도메인 / TimescaleDB 시계열 / object storage 미디어)되어 있어 **사람이 셋을 교차 조사하기 어렵다**. 25번의 가치는:

> **흩어진 시계열·미디어·생산 데이터를 AI가 하나의 권한 필터 컨텍스트로 묶어, 자연어 질의 한 번으로 종합 조사·요약하게 한다.**

"P03 설비 진동이 튀는데 그 시각 영상에 이상이 있었나, 불량과 상관있나"를 사람이 3개 저장소를 뒤지는 대신 AI가 종합한다. 이것이 "AI native MES"(CLAUDE.md L7)의 구체적 실현이다.

### 6.2 데이터 흐름 (확보 → Context API → AI 조사)

```
[수집/확보]                    [저장 분리]                 [종합]                  [조사]
설비 디바이스 ──HTTP push──▶ TimescaleDB                 ┐
(EXT-1 Broadway)            equipment_measurements        │
                                                          ├─▶ Investigation       ──▶ Provider.investigate
NAS/카메라 ──watch/transfer▶ object storage + media_assets│   .build_context        (Mock/Claude)
(EXT-2)                     (MinIO)                        │   (권한 필터,              │
                                                          │    집계+샘플,             ▼
현장 실적/불량 ──────────────▶ PostgreSQL                  │    키 브리지)         AI 분석 요약 + 차트
(코어)                      production_results 등          ┘   = ai_investigation     + 미디어 + 근거
                                                              _context (plain map)   (/admin/ai/investigate)
```

- **확보(EXT-1/2)**: 이미 완료 — 데이터를 잃지 않는 게 1순위였다(CLAUDE.md L33).
- **Context API(Investigation)**: AI 안전 경계 — DB 직접 접근 0, 권한 필터, 집계+샘플.
- **조사(Provider)**: Level 1 읽기 — 쓰기 0, 감사 필수.

---

## 7. AI 안전 체크포인트 (ai-safety-guardian 검증 대상)

| # | 안전 원칙 (출처) | 이 설계의 충족 지점 |
|:--:|------------------|---------------------|
| 1 | AI Context API 경유, DB 직접 접근 금지 (CLAUDE.md L85,91) | Provider.investigate 는 plain map context + query 만 받음 — Repo/Ecto 인자 없음(구조적 차단). 시계열/미디어/생산 모두 `build_context`가 조회 후 map 으로만 전달 |
| 2 | AI 권한 없는 데이터 열람 금지 (L85) | `build_context/3` role 인가(`@investigation_roles`: admin/생산/품질), 그 외 :unauthorized. referenced.role 에 기록 |
| 3 | AI 기본 쓰기 권한 없음 (L86) | Level 1 읽기 — investigate 경로에 쓰기 호출 0. AiInteraction(intent="query", proposed_action=nil). grep 검증: 조사 경로 Repo write 0 |
| 4 | ProductionResult/LotConsumption/DefectRecord AI 직접 삭제 불가 (L87) | 조사는 읽기만 — 삭제·수정 경로 자체가 없음 |
| 5 | AI 제안/분석에 근거 데이터 동반 표시 (L88) | context.referenced(소스/규모/role) + 시계열 차트 + 미디어 목록을 AI 분석과 **항상 함께** UI 노출 |
| 6 | 모든 AI 상호작용 AiInteraction 기록 (L89) | 모든 조사 = AiInteraction(intent="query", answered) + AuditLog(ai_interaction.query). 읽기도 예외 없음 |
| 7 | 대량 데이터 안전(토큰/환각) | 시계열 raw 전량 금지 — 집계+다운샘플(≤60). 미디어 메타+링크만(바이너리 0). 상한 N건 |
| 8 | 상태머신 임의 전이 추가 금지 (CLAUDE.md L53) | query 는 23번 상태머신을 거치지 않는 평행 경로(answered 단일). proposed→... 전이 무손상 |
| 9 | 키 브리지 격리(권한 일관) | equipment_code↔binary_id 브리지를 build_production 한 곳에 격리. AI 는 브리지 미열람 |
| 10 | RAG 문서 분리 (ai-native L98) | RAG/문서는 범위 밖(외부 커넥터) — 본 조사는 시계열/미디어/생산만 |

---

## 8. 디렉토리 / 모듈 경계

```
lib/open_mes/ai/
  investigation.ex          ← [신규] build_context/3(종합), build_timeseries/build_media/build_production,
                                investigate/3(진입점), @investigation_roles 인가. 읽기 전용.
  ai.ex                     ← [23번 그대로] 쓰기 경로 무손상
  ai_interaction.ex         ← [수정] intent "query" + approval_status "answered" 허용(changeset/전이 검증 확장)
  provider.ex               ← [수정] @callback investigate/2 추가. label/active 재사용
  provider/mock_provider.ex ← [수정] investigate/2(통계 요약 + 미디어 개수 + 이상치 템플릿, 키 없이 동작)
  provider/claude_provider.ex ← [수정] investigate/2(실분석, 키 있을 때). system 프롬프트로 근거만 분석 강제
lib/open_mes/master_data/
  master_data.ex            ← [수정] get_equipment_by_code/1(키 브리지)
lib/open_mes_ingest/
  ingest.ex (or query.ex)   ← [수정/신규] summarize_metrics/3, downsample/5 (조사 읽기, 집계+샘플)
lib/open_mes_media/
  media.ex                  ← [수정] list_assets_by_equipment/4, count_by_type/3, reference_for/1
lib/open_mes_web/
  admin/ai/investigate_live.ex  ← [신규] 조사 LiveView(선택→질의→종합 결과)
  components/chart_components.ex ← [수정] line_chart/1 추가(시계열 추세)
  components/admin_components.ex ← [수정] @menu "AI" 그룹(AI 조사) 추가
  router.ex                 ← [수정] /admin/ai/investigate 라우트
lib/open_mes/charts/
  geometry.ex               ← [수정 가능] line_path/_(꺾은선 좌표) — 필요 시. nice_ticks 재사용
config/
  config.exs                ← [확인] OpenMes.Ai.Provider 기본 mock 그대로(23번)
test/
  ai_investigation_test.exs ← [신규] build_context 권한 필터/집계+샘플/키 브리지/investigate(mock)→AiInteraction+AuditLog
  ingest_query_test.exs     ← [신규] summarize_metrics/downsample 집계 정확성
```

경계:
- `Investigation` = 조사 컨텍스트 소유(읽기 only). EXT-1/2 읽기 함수 + 코어 생산 읽기를 종합. **쓰기 0.**
- Provider 구현체 = context map + query만 → Repo 불가(23번과 동일 구조적 안전).
- LiveView = 컨텍스트(Investigation) 경유만(Repo 직접 0).
- EXT-1/2 = 읽기 함수만 노출(코어가 확장에 의존하지 않도록, `Investigation`이 확장→코어 경계 퍼사드 역할).

---

## 9. domain-engineer 구현 지침 (순서)

1. **`AiInteraction` 확장** — changeset이 `intent="query"` + `approval_status="answered"` 허용. `answered`는 터미널(전이 없음). 23번 상태머신(`allowed_transition?`)은 propose 경로 전용으로 유지하고, query는 그 검증을 거치지 않는 별도 생성 경로(`OpenMes.Ai.Investigation`이 직접 insert + AuditLog). 23번 테스트 무손상.
2. **키 브리지** — `MasterData.get_equipment_by_code/1`.
3. **EXT-1 조사 읽기** — `Ingest.summarize_metrics/3`(GROUP BY metric_key 집계), `Ingest.downsample/5`(time_bucket 또는 date_trunc 다운샘플 ≤60). 추세·이상치 판정은 **순수 함수**(테스트 대상)로 분리. raw 전량 조회 함수 만들지 말 것.
4. **EXT-2 조사 읽기** — `Media.list_assets_by_equipment/4`(captured_at 범위 + limit), `Media.count_by_type/3`, `Media.reference_for/1`(MVP: bucket/object_key 문자열). 바이너리 0.
5. **`OpenMes.Ai.Investigation`**:
   - `@investigation_roles ~w(system_admin production_manager quality_manager)`.
   - `build_context(equipment_code, opts, actor)` — role 인가(미인가 :unauthorized) → 키 브리지 → build_timeseries/build_media/build_production 조립 → §1.2 map + referenced. **집계+샘플만, 상한 N.**
   - `investigate(equipment_code, query, actor)` — build_context → `Provider.active().investigate(context, query)` → AiInteraction(intent="query", answered, proposed_action: nil, referenced_resources: context.referenced, provider) insert + **AuditLog(ai_interaction.query)** (단일 Multi). **쓰기·Outbox 없음.**
   - `list_query_interactions(equipment_code)` — 조사 이력.
6. **`Provider` 확장** — `@callback investigate(context, query) :: {:ok, %{analysis, findings, referenced}} | {:error, term}`. `MockProvider.investigate/2`: context의 시계열 통계(추세/이상치 개수)·미디어 개수·생산 불량률을 **규칙 기반 한국어 템플릿**으로 요약(키 없이 동작 — 데모 핵심). `ClaudeProvider.investigate/2`: system 프롬프트로 "주어진 context 범위만 근거로 분석, 데이터에 없는 사실 발명 금지" 강제 + 한국어 분석 반환(키 있을 때).
7. **`line_chart`** — chart_components에 추가(Geometry 순수 함수 기반, 꺾은선+이상치 마커+y축 nice_ticks, role/aria 한국어). 필요 시 `Geometry.line_path`.
8. **`InvestigateLive`** — 설비/기간 선택 + 질의 → investigate → 종합 결과(AI 요약/시계열 차트/미디어 목록/생산 요약/근거/이력). admin_shell/page_header/status_badge/gauge 재사용. 안전 UI 규칙(§4.3).
9. **메뉴 + 라우트** — admin_components "AI" 그룹(AI 조사, roles: investigation_roles). router `/admin/ai/investigate`.
10. **검증** — `mix compile` 무경고 / `mix test`(ai_investigation: 권한 필터 거부, 집계+샘플 상한, 키 브리지, investigate(mock)→AiInteraction(query,answered)+AuditLog, 쓰기 0; ingest_query: 집계/다운샘플 정확) / `ANTHROPIC_API_KEY` 없이 `/admin/ai/investigate`에서 설비 선택+질의 → Mock 종합 요약+차트+미디어+근거 표시(전 흐름 mock 데모) / 기존 라우트·메뉴·23번 무손상.

### 제약 (재강조)
- **AI DB 직접 접근 0**: Provider는 context map+query만(Repo 불가). 시계열/미디어/생산 모두 build_context가 조회.
- **쓰기 0**: Level 1 읽기. investigate 경로에 Repo write/step 쓰기/삭제 0(grep 검증).
- **모든 조사 AiInteraction(query) + AuditLog**: 읽기도 예외 없음. proposed_action=nil.
- **대량 시계열 집계+샘플**: raw 전량 금지(다운샘플 ≤60, 상한 N). 미디어 메타+링크만(바이너리 0).
- **근거 표시 필수**: referenced + 차트 + 미디어를 AI 분석과 함께 UI.
- **권한 role 필터**: build_context 인가 + LiveView 인가 + 메뉴 roles(삼중).
- **23번/EXT-1/2/기존 화면 무손상**: 상태머신 평행 경로(answered), 확장 읽기 함수만 추가. RAG 범위 밖.
- 컨텍스트 경유(LiveView Repo 직접 0). binary_id. 한국어 UI/영문 식별자. pi(line_chart 1종, 집계+샘플, 과설계 금지).

---

## 부록. Provider.investigate 결과 + AiInteraction 매핑

```elixir
# Provider.investigate/2 반환
%{
  analysis: "P03 설비 진동(vibration)이 최근 24시간 상승 추세입니다(평균 2.31 mm/s, 최대 9.8, 이상치 7건). " <>
            "같은 기간 영상 12건·이미지 40건이 수집되었고, 공정 불량률은 2.52%로 주의 수준입니다. " <>
            "진동 상승과 불량 증가의 상관 가능성을 점검 권장합니다.",
  findings: [
    %{kind: "timeseries", metric: "vibration", note: "상승 추세 + 이상치 7건"},
    %{kind: "production", note: "불량률 2.52%(주의)"},
    %{kind: "media", note: "영상 12건 — 이상 시각대 검토 대상"}
  ],
  referenced: context.referenced   # 그대로 통과(근거 일관)
}

# AiInteraction 저장 매핑(intent="query")
%AiInteraction{
  actor_id: actor_id,
  intent: "query",
  prompt: "P03 설비 최근 진동 추세와 영상 이상 징후 조사해줘",
  response_summary: result.analysis,
  referenced_resources: context.referenced,   # 본 시계열/미디어/생산 소스·규모·role
  proposed_action: nil,                        # 쓰기 없음(읽기 전용)
  approval_status: "answered",                 # 터미널(승인 불요)
  provider: "mock" | "claude",
  reviewer_id: nil, reviewed_at: nil, execution_result: nil
}
```
- `intent="query"`로 23번 `propose_line_config`와 구분(감사·필터). `answered`로 23번 상태머신과 분리.
- referenced_resources = 근거(어떤 데이터를 봤나) — UI 표시 + 감사 동시 충족.
