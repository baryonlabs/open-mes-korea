# 22. Architect — 생산라인 구성 설정화 (정규식 하드코딩 → 데이터/설정)

대상 전환: `LineMonitor.line_steps/0` 의 **`~r/^P\d{2}$/` 정규식 공정 식별 + `"EQ-"<>process_code` 장비 규약** → **ProductionLine/ProductionLineStep 설정 데이터**.
신규 설정 페이지: `/admin/settings/lines` (생산라인 구성 CRUD + 단계 편집).
원칙: pi(신규 엔티티 2개·최소 필드, 과추상화 금지), 도메인 불변식(AuditLog·binary_id·컨텍스트 경유), **기존 라인 모니터 결과 보존**(전환 후 동일 화면), 한국어 UI/영문 식별자.
선행 문서: `_workspace/21_architect_factory_line_monitor.md`(라인 모니터 설계 — 정규식 하드코딩 출처).

---

## 0. 핵심 설계 결정 (요약 5)

1. **신규 컨텍스트 `OpenMes.ProductionLine` 를 둔다(MasterData 에 욱여넣지 않음).** 라인은 "공정·설비를 조합한 구성(configuration)"으로 기준정보 6종과 성격이 다르고(단계 컬렉션을 가진 집합체), 향후 MCP/AI propose 경로의 자연스러운 소유자다. 단 **AuditLog 패턴은 MasterData 의 제네릭 `create/2`·`update/2`(Multi+Audit.put_log) 를 그대로 복제**해 일관성을 유지한다(새 감사 메커니즘 발명 금지). resource_type = `"production_line"`, `"production_line_step"`.

2. **ProductionLineStep 은 Routing 을 대체하지 않고 "모니터 표시 구성"만 담는다.** Routing(품목×공정×순서×C/T)은 생산 실행용으로 그대로 둔다(무손상). ProductionLineStep 은 **라인 모니터가 "어떤 라인의 어떤 공정을 몇 번째로 어떤 설비로 그릴지"** 만 정의한다. 즉 라우팅 ≠ 라인구성. 둘은 별개 관심사이고, 라인구성은 품목과 무관(라인 단위). 과한 통합(Routing 흡수) 금지 — pi.

3. **`process_id`/`equipment_id` 는 FK(binary_id 참조)로 둔다 — 정규식·코드 규약 제거.** Step 은 `line_id → process_id`(필수, 모니터 노드 공정), `equipment_id`(선택 — 없으면 fallback), `sequence`(필수, 라인 내 순서). `"EQ-"<>code` 문자열 규약을 **명시적 FK 로 승격**. equipment_id 가 nil 인 단계는 모니터에서 "설비 미지정(unknown)"으로 안전 표시(§2.3). FK constraint 로 존재하지 않는 공정/설비 참조 차단.

4. **LineMonitor 전환은 `line_steps/0` 의 입력 조립부만 교체, 순수 판정부(`process_steps/4` 이하)는 불변.** 21번에서 이미 "조회 1곳(line_steps) + 순수 판정 다수" 경계를 세웠다. `line_steps/0` 가 정규식 대신 **`ProductionLine.steps_for_monitor(line_id)`** 를 읽어 동일 형태(`steps_input`, `equip_by_process`)로 `process_steps/4` 에 넘긴다. 순수 함수·컴포넌트·LiveView 시그니처 0 변경. `line_steps/0` 는 하위호환 위해 **`line_steps(line_id \\ :default)`** 로 확장(기본 라인 자동 선택). seed 라인 1개면 기존과 동일 결과.

5. **seed 전환은 "기존 P01~P10 마스터 유지 + 라인 구성으로 묶기"** — 기존 공정/설비/라우팅 seed 블록(§F)은 **그대로 두고**, 그 뒤에 ProductionLine "사출 성형 라인" 1건 + ProductionLineStep 10건(기존 inj_process_recs/inj_equipment_recs 참조)을 **append**. 멱등(라인 code 가드). 정규식을 제거해도 LineMonitor 가 이 라인을 기본으로 표시 → 21번 데모 신호등(P03 품질·P07 장비·P09 데이터미수신) 동일 재현.

---

## 1. 도메인 모델 (신규 엔티티 2개)

### 1.1 `ProductionLine` (생산라인)

라인 = 모니터링 대상 단위(예 "사출 성형 라인"). binary_id + AuditLog(기준정보처럼 변경 시).

| 필드 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | binary_id | PK | |
| `line_code` | string | required, **unique** | 라인 코드(영문, 예 `LINE-INJ`) |
| `name` | string | required | 라인명(한국어, 예 "사출 성형 라인") |
| `description` | string | nullable | 설명 |
| `active` | boolean | default true | 활성(비활성은 삭제 대신) |
| `inserted_at`/`updated_at` | utc_datetime_usec | | |

테이블: `production_lines`. 인덱스: `unique_index(:line_code)`.
삭제 없음(이력 보존) — active=false 로 비활성. MasterData 의 Item/Process 컨벤션 동일.

### 1.2 `ProductionLineStep` (라인 공정 단계)

라인-공정-순서-장비 매핑. "이 라인의 N번째 공정은 P, 설비는 EQ".

| 필드 | 타입 | 제약 | 설명 |
|------|------|------|------|
| `id` | binary_id | PK | |
| `line_id` | binary_id | required, **FK → production_lines** | 소속 라인 |
| `process_id` | binary_id | required, **FK → processes** | 공정(모니터 노드) |
| `equipment_id` | binary_id | nullable, **FK → equipment** | 대표 설비(없으면 모니터 unknown) |
| `sequence` | integer | required, > 0 | 라인 내 표시 순서 |
| `inserted_at`/`updated_at` | utc_datetime_usec | | |

테이블: `production_line_steps`. 제약:
- `unique_index([:line_id, :sequence])` — 라인 내 순서 유일.
- `index(:line_id)` — 라인별 조회.
- `foreign_key_constraint(:line_id / :process_id / :equipment_id)`.
- on_delete: 라인 삭제는 없으므로(이력 보존) `restrict` 또는 미지정. **단계 자체는 삭제 허용**(구성 편집 — 기준정보와 달리 step 은 "구성 요소"라 hard delete 가능, 단 라인 update AuditLog 로 변경 흔적 남김 §3.4).

> pi: 라인당 공정 1회 등장 가정이 자연스럽지만, `unique([line_id, process_id])` 강제는 하지 않는다(되돌림 공정 등 — YAGNI). 순서 유일성만 강제.

### 1.3 관계

```
ProductionLine 1 ──< ProductionLineStep >── 1 Process   (process_id FK)
                                         >── 0..1 Equipment (equipment_id FK, nullable)

Process / Equipment  : 기존 MasterData 엔티티(무변경) — Step 이 참조만.
Routing              : 무관(생산 실행용 — 손대지 않음, 결정 #2).
```

다중 라인 지원: ProductionLine N건 + 라인별 Step 컬렉션. 모니터는 라인 1개 선택(§2.2).

---

## 2. LineMonitor 연동 (정규식 제거)

### 2.1 컨텍스트 신규 읽기 함수 `ProductionLine.steps_for_monitor/1`

라인 모니터가 소비할 형태로 단계를 조립(공정·설비 라벨 preload 포함). **순수 조회**(쓰기 0).

```elixir
@doc """
라인 id(또는 :default) → 모니터 입력용 단계 리스트(sequence 오름차순).
반환: [%{process_id, process_code, name, sequence, equipment_id, equipment_active, equipment_name}]
공정/설비 라벨은 조인으로 해석. 빈 라인이면 []. :default 는 기본 라인(§2.2) 선택.
"""
def steps_for_monitor(line_id_or_default)
```

- 내부: `production_line_steps` ⋈ `processes`(process_code/name) ⋈ `equipment`(name/active, LEFT JOIN — equipment_id nullable) `where line_id = ^id` `order_by sequence`.
- `equipment_id == nil` 인 단계 → equipment_* 전부 nil(모니터에서 `:unknown` 처리, 기존 규약 fallback 과 동일 안전).

### 2.2 기본 라인 선택 규칙

- `steps_for_monitor(:default)` = **활성 라인 중 line_code 오름차순 첫 라인**(또는 가장 오래된 라인). seed 라인 1개면 그 라인.
- 모니터 URL param 지원: `/admin/reports/production?line=LINE-INJ` (선택). param 없으면 :default.
- 라인 0개(빈 설정) → `[]` → 모니터 empty_state(공정 노드 0). 안전.

### 2.3 `LineMonitor.line_steps/1` 전환 (정규식 제거)

기존(정규식):
```elixir
def line_steps do
  processes = MasterData.list_processes() |> Enum.filter(&Regex.match?(~r/^P\d{2}$/, &1.process_code)) |> Enum.sort_by(&...)
  equipment_map = ... "EQ-"<>process_code 규약 ...
  process_steps(steps_input, by_process_map, equip_by_process, op_status_map)
end
```

전환 후(설정 기반):
```elixir
def line_steps(line \\ :default) do
  monitor_steps = ProductionLine.steps_for_monitor(line)   # ← 정규식·규약 제거, 설정 읽기
  process_ids   = Enum.map(monitor_steps, & &1.process_id)

  by_process_map = Reports.production_by_process() |> Map.new(&{&1.process_id, &1})
  op_status_map  = Production.latest_operation_status_by_process(process_ids)

  steps_input =
    Enum.map(monitor_steps, fn s ->
      %{process_id: s.process_id, process_code: s.process_code, name: s.name, sequence: s.sequence}
    end)

  equip_by_process =
    Map.new(monitor_steps, fn s ->
      {s.process_code,
        s.equipment_id && %{active: s.equipment_active, name: s.equipment_name, equipment_code: nil}}
    end)

  process_steps(steps_input, by_process_map, equip_by_process, op_status_map)
end
```

- **순수 판정부(`process_steps/4`, `data_status`, `equipment_status`, `quality_status`, `overall`, `line_summary`) 0 변경** — 입력 형태 동일.
- `equipment_status/3` 는 이미 `nil → :unknown`, `%{active: false} → :bad` 처리(line_monitor.ex 133~143) — equipment_id 미지정 단계 자동 안전.
- 모듈 상수 `@process_code_pattern` 삭제. `MasterData.list_processes` 직접 필터 삭제(라인이 공정 선별).
- `ProductionReportLive` 의 `LineMonitor.line_steps()` 호출은 그대로 동작(기본 인자) — LiveView 무손상. URL param 연동만 선택 추가(§3.5).

### 2.4 설비 매핑 fallback (규약 보존, 선택)

equipment_id 가 nil 이고 **호환을 원하면**, `steps_for_monitor` 가 `"EQ-"<>process_code` 설비를 보조 조회해 채울 수 있다(pi: 기본은 nil→unknown 으로 충분, fallback 은 domain-engineer 판단). 권장: **fallback 없이 명시 FK 만**(결정 #3 — 규약 제거가 목적). seed 가 equipment_id 를 채우므로 데모 동일.

---

## 3. 설정 페이지 (라인 구성 편집)

### 3.1 IA — 사이드바 신규 그룹 "설정"

`AdminComponents.@menu` 에 신규 그룹 추가(메뉴 트리 = 가시성·인가·배지 단일 원천):

```elixir
%{
  group: "설정",
  items: [
    %{label: "생산라인 구성", path: "/admin/settings/lines", enabled: true,
      roles: ["production_manager"]}     # system_admin 은 항상 포함(Authorization)
  ]
}
```

- 위치: "관리자" 그룹 위(설정은 운영 구성, 시스템 관리와 구분). 또는 "기준정보" 다음. → **"관리자" 직전**에 둔다.
- role: `system_admin`(항상) + `production_manager`. (라인 구성은 생산관리자 업무.)
- 메뉴 한 줄 추가만으로 `Authorization.roles_for_path("/admin/settings/lines")` = `[system_admin, production_manager]` 자동 결정(별도 매핑 코드 0).

### 3.2 화면 구성 (기존 admin CRUD LiveView 패턴 — ItemLive 컨벤션)

**2개 LiveView**(목록/라인 + 단계 편집), 또는 **1개 LiveView 2 live_action**. pi: 라인 목록과 단계 편집은 화면이 다르므로 **2 LiveView** 권장.

#### (A) `ProductionLineLive` — 라인 목록/생성/수정 (`/admin/settings/lines`)

ItemLive 패턴 그대로: `:index`(목록) / `:new`(생성 모달) / `:edit`(수정 모달).
- 목록 표: 라인코드 | 라인명 | 단계 수 | 상태(active_badge) | [구성 편집] [수정] [활성토글].
- "구성 편집" → `/admin/settings/lines/:id/steps` 이동.
- 생성/수정 모달: line_code, name, description, active(checkbox).
- 쓰기는 `ProductionLine` 컨텍스트 경유(AuditLog 내장). LiveView 는 Repo 직접 호출 0.

#### (B) `ProductionLineStepLive` — 단계 편집 (`/admin/settings/lines/:id/steps`)

라인 1개의 공정 단계 컬렉션 편집(핵심 화면):
- 상단: 라인명 + 모니터 미리보기 링크(`/admin/reports/production?line={code}`).
- 단계 표(sequence 순): 순서 | 공정(드롭다운 라벨) | 설비(라벨/미지정) | [위/아래 이동] [수정] [삭제].
- "단계 추가" 버튼 → 모달: **공정 드롭다운**(`MasterData.list_processes` 활성), **설비 드롭다운**(`list_equipment` 활성 + "미지정" 옵션), sequence(자동=마지막+1 또는 입력).
- **순서 재정렬**: 위/아래 이동 버튼(`reorder` 이벤트 → 인접 step 의 sequence swap, 컨텍스트 트랜잭션 1회 + AuditLog). pi: 드래그앤드롭 금지(외부 JS 0), 버튼 swap 으로 충분.
- 단계 삭제: 확인 후 `delete_step`(라인 update AuditLog 동반).

빈 라인(단계 0): empty_state "공정 단계가 없습니다. '단계 추가' 로 구성하세요."

### 3.3 라우트 (router.ex 신규 scope)

```elixir
# ── 관리자 영역 (/admin) — 설정 (생산라인 구성) ──────────────────────
scope "/admin", OpenMesWeb.Admin.Settings do
  pipe_through :browser

  live "/settings/lines", ProductionLineLive, :index
  live "/settings/lines/new", ProductionLineLive, :new
  live "/settings/lines/:id/edit", ProductionLineLive, :edit
  live "/settings/lines/:id/steps", ProductionLineStepLive, :index
  live "/settings/lines/:id/steps/new", ProductionLineStepLive, :new
  live "/settings/lines/:id/steps/:step_id/edit", ProductionLineStepLive, :edit
end
```

`use OpenMesWeb.Admin.AdminLive`(on_mount 인가 자동). 메뉴 트리 prefix `/admin/settings/lines` 가 모든 하위 경로 인가 커버(Authorization prefix 매칭).

### 3.4 AuditLog 트리거 지점 (모든 쓰기)

| 동작 | action | resource_type | before/after |
|------|--------|---------------|--------------|
| 라인 생성 | `production_line.create` | production_line | nil / 스냅샷 |
| 라인 수정(활성토글 포함) | `production_line.update` | production_line | 스냅샷/스냅샷 |
| 단계 추가 | `production_line_step.create` | production_line_step | nil / 스냅샷 |
| 단계 수정(공정/설비 변경) | `production_line_step.update` | production_line_step | 스냅샷/스냅샷 |
| 단계 순서변경(swap) | `production_line_step.update` ×2(또는 reorder 1건) | production_line_step | 스냅샷/스냅샷 |
| 단계 삭제 | `production_line_step.delete` | production_line_step | 스냅샷 / nil |

→ **MasterData 제네릭 `create/2`·`update/2` 동일 패턴**(`Ecto.Multi` + `Audit.put_log`). 삭제는 `delete/2`(신규 — Multi.delete + Audit, action `*.delete`, before=스냅샷 after=nil). reorder 는 2 step swap 을 1 트랜잭션 + AuditLog(각 step update 또는 라인 단위 1건 — domain-engineer 판단, pi: 각 step update 2건 단순).

### 3.5 라인 모니터 연동 (라인 선택)

- `ProductionReportLive`: URL param `?line={line_code}` 읽어 `LineMonitor.line_steps(line_code)` 호출. 없으면 `:default`.
- (선택) 모니터 상단에 라인 선택 드롭다운(`ProductionLine.list_lines/0` 활성 라인) → `push_patch(?line=...)`. pi: 라인 1개면 생략 가능, 다중 라인 시 노출.

---

## 4. seed 전환

### 4.1 기존 블록 유지 + 라인 구성 append

`priv/repo/seeds.exs` §F(사출 라인 P01~P10 공정/설비/라우팅/WO) **전부 유지**(생산 흐름·실적 데모 필요). 그 뒤 `inj_process_recs`/`inj_equipment_recs`(이미 메모리에 있음) 참조해 라인 구성 추가:

```elixir
# ── G. 생산라인 구성(설정화) — 모니터가 정규식 대신 이 라인을 읽는다(설계 22번) ──
inj_line =
  get_or_create.(ProductionLine, :line_code, "LINE-INJ", fn ->
    ProductionLine.create_line(
      %{line_code: "LINE-INJ", name: "사출 성형 라인", description: "사출 성형 10공정 데모 라인"},
      actor
    )
  end)

# 단계 10건: P01~P10, sequence 1~10, equipment_id = EQ-Pnn(규약 → 명시 FK 로 고정).
inj_line_steps = [
  {"P01", 1}, {"P02", 2}, {"P03", 3}, {"P04", 4}, {"P05", 5},
  {"P06", 6}, {"P07", 7}, {"P08", 8}, {"P09", 9}, {"P10", 10}
]

Enum.each(inj_line_steps, fn {code, seq} ->
  # 멱등: (line_id, sequence) 가드 — get_or_create 변형 또는 Repo.get_by.
  ensure_line_step.(inj_line, inj_process_recs[code].id, inj_equipment_recs["EQ-#{code}"].id, seq)
end)
```

- `ensure_line_step` 헬퍼: `Repo.get_by(ProductionLineStep, line_id: ..., sequence: ...)` 없으면 `ProductionLine.create_step(...)`. 멱등.
- equipment_id 를 **명시적으로 EQ-Pnn FK 로 채움**(기존 `"EQ-"<>code` 문자열 규약을 데이터로 고정 — 결정 #3·#5).
- 2회 실행 멱등(라인 code + step sequence 가드).

### 4.2 동작 보존 검증

- 정규식 제거 후 `LineMonitor.line_steps()` = `LineMonitor.line_steps(:default)` → `steps_for_monitor` 가 LINE-INJ 의 10단계(P01~P10, EQ-Pnn) 반환 → `process_steps/4` 동일 입력 → **21번 데모 신호등 동일**(P03 품질이상·P07 장비이상·P09 데이터미수신·P10 진행중).
- 안내 출력 한 줄 추가: "생산라인 구성 LINE-INJ(10단계) 시드 완료 — /admin/settings/lines 에서 편집".

---

## 5. 향후 MCP/AI 확장 포인트 (이번 구현 X — 슬롯만)

CLAUDE.md AI 안전(제안→승인→적용, 직접 쓰기 금지, AiInteraction 기록)을 따른다. **실제 AI 연동 코드는 만들지 않음.** 확장 슬롯만 명시:

1. **`ProductionLine.propose_line_config/2`(예약 — 미구현)**: AI 가 자연어 지시("사출 라인에 검사 공정 추가")를 받아 라인 구성 **제안(proposed)** 을 생성하는 경로. 반환은 `AiInteraction`(status: proposed) + 제안 diff(추가/삭제/순서 step 목록). **직접 ProductionLineStep 을 쓰지 않음** — 제안만.
2. **승인 흐름 재사용**: 제안 → 검토 → 승인 시 비로소 `ProductionLine.create_step/update_step`(actor=승인자) 실행. AI 안전 상태머신(proposed→reviewed→approved→executed) 그대로.
3. **경계 명시**: ProductionLine 컨텍스트 모듈 docstring 에 "AI 는 propose_* 경로로만 진입, 쓰기 함수(create/update/delete_step)는 actor 인간 승인자 경유" 주석으로 슬롯 예약. 함수 stub 도 생성하지 않음(YAGNI) — 설계 문서에 경로만 기록.

> pi: 이번 구현 범위는 "설정 페이지에서 사람이 편집"까지. AI propose 는 컨텍스트가 그 소유자가 되도록 위치만 확보(MasterData 가 아닌 ProductionLine 에 둔 이유 — 결정 #1).

---

## 6. 디렉토리 / 모듈 경계

```
lib/open_mes/
  production_line/                          ← [신규] 컨텍스트
    production_line.ex                       ← [신규] 컨텍스트(list/get/create/update/delete_line·step + steps_for_monitor + 제네릭 create/update/delete with AuditLog)
    line.ex                                  ← [신규] ProductionLine 스키마+changeset
    line_step.ex                             ← [신규] ProductionLineStep 스키마+changeset
  production/
    line_monitor.ex                          ← [수정] line_steps/0→line_steps/1, 정규식·EQ규약 제거, ProductionLine.steps_for_monitor 읽기. 순수 판정부 불변.
lib/open_mes_web/
  admin/settings/
    production_line_live.ex                  ← [신규] 라인 목록/생성/수정 (ItemLive 패턴)
    production_line_step_live.ex             ← [신규] 단계 편집(추가/순서/삭제, 드롭다운)
  components/admin_components.ex             ← [수정] @menu 에 "설정" 그룹 1줄 추가
  router.ex                                  ← [수정] /admin/settings/lines scope 추가
  admin/reports/production_report_live.ex    ← [수정·선택] URL ?line= param 연동(없으면 :default — 무변경도 동작)
priv/repo/
  migrations/XXXXXX_create_production_lines.exs       ← [신규] production_lines + production_line_steps 테이블
  seeds.exs                                  ← [수정] §G 라인 구성 append(기존 §F 불변)
test/open_mes/
  production_line_test.exs                   ← [신규] CRUD+AuditLog+steps_for_monitor+멱등
  production/line_monitor_test.exs           ← [수정] line_steps 입력을 설정 기반으로(기존 순수 판정 케이스 무손상)
```

경계:
- `ProductionLine` = 라인/단계 CRUD(AuditLog) + `steps_for_monitor/1`(읽기 조립). MasterData 제네릭 패턴 복제.
- `LineMonitor` = 순수 판정 불변, `line_steps/1` 만 입력 소스 교체(정규식 → 컨텍스트).
- LiveView 2종 = 컨텍스트 경유만(Repo 직접 0). 기존 admin CRUD 패턴.

---

## 7. domain-engineer 구현 지침 (순서)

1. **마이그레이션** — `production_lines`(line_code unique, name, description, active) + `production_line_steps`(line_id FK, process_id FK, equipment_id FK nullable, sequence; unique([line_id, sequence]), index(line_id)). binary_id PK, utc_datetime_usec timestamps. on_delete restrict.
2. **스키마 2개** — `ProductionLine.Line`/`ProductionLine.LineStep`. changeset: required·unique·FK constraint(MasterData Process/Routing changeset 컨벤션 동일, 한국어 메시지). sequence > 0 검증.
3. **`OpenMes.ProductionLine` 컨텍스트** — MasterData 의 `@resources`/`create/2`/`update/2`/`snapshot`/`Audit.put_log` 패턴 **복제**:
   - `list_lines/1`, `get_line/1`, `fetch_line/1`, `create_line/2`, `update_line/2`(활성토글 포함).
   - `list_steps/1`(line_id), `get_step/1`, `create_step/2`, `update_step/2`, `delete_step/2`(신규 delete: Multi.delete + AuditLog action `*.delete`, before=스냅샷/after=nil).
   - `reorder_step/3`(step_id, :up/:down → 인접 step sequence swap, 1 트랜잭션 + AuditLog 2건 또는 1건).
   - `steps_for_monitor/1`(:default | line_id | line_code → 모니터 입력 형태, LEFT JOIN equipment). §2.1.
   - `change_line/2`·`change_step/2`(폼 changeset 빌더).
   - 모듈 docstring 에 AI propose 슬롯 주석(§5) — stub 함수는 만들지 않음.
4. **`LineMonitor.line_steps/1` 전환** — §2.3. 정규식·`@process_code_pattern`·`"EQ-"<>` 규약 제거. `ProductionLine.steps_for_monitor(line)` 읽어 동일 입력 조립. 순수 판정부 절대 불변. 기본 인자 `:default` 로 기존 호출 무손상.
5. **LiveView 2종** — `ProductionLineLive`(ItemLive 패턴: index/new/edit, 활성토글, 단계수 표시) + `ProductionLineStepLive`(index 단계 표 + new/edit 모달 공정·설비 드롭다운 + reorder 위/아래 + delete). admin_shell/page_header/table/modal/empty_state 재사용. 쓰기 전부 컨텍스트 경유.
6. **router.ex** — §3.3 scope `OpenMesWeb.Admin.Settings`.
7. **admin_components.ex** — §3.1 "설정" 그룹 1줄(`/admin/settings/lines`, roles: ["production_manager"]).
8. **seed §G** — §4. 기존 §F 뒤 append, `ensure_line_step` 멱등 헬퍼, equipment_id 명시 FK. 안내 출력 한 줄.
9. **(선택) `ProductionReportLive`** — `?line=` param → `line_steps(line)`. 다중 라인 드롭다운(라인 1개면 생략 가능).
10. **검증** — `mix compile` 무경고 / `mix test`(기존 무손상 + 신규 production_line_test: CRUD·AuditLog 6 action·steps_for_monitor·멱등·delete) / `mix run priv/repo/seeds.exs` 2회 멱등 / 실서버: `/admin/settings/lines` 에서 라인·단계 편집·순서변경·삭제 후 `/admin/reports/production` 신호등 **21번과 동일**(정규식 제거 후 동작 보존) 확인.

### 제약 (재강조)
- 신규 엔티티 2개·최소 필드. Routing 흡수·과추상화 금지(pi). FK 로 정규식·문자열 규약 제거.
- 모든 쓰기(라인/단계 생성·수정·순서·삭제) AuditLog 필수 — MasterData 제네릭 패턴 복제(새 감사 메커니즘 발명 금지).
- 컨텍스트 경유(LiveView Repo 직접 0). binary_id. 한국어 UI/영문 식별자.
- 기존 무손상: Routing·LineMonitor 순수 판정부·ProductionReportLive 호출·기존 seed §F·다른 라우트/메뉴 시그니처 불변. 빈 라인 안전(empty_state).
- AI propose 는 슬롯(주석)만 — 코드 0(YAGNI).

---

## 부록 A. 전환 전/후 LineMonitor 입력 비교

| 항목 | 전(21번, 정규식) | 후(22번, 설정) |
|------|------------------|----------------|
| 공정 선별 | `list_processes` + `~r/^P\d{2}$/` 필터 | `ProductionLine.steps_for_monitor(line)` |
| 순서 | `Enum.with_index(1)`(코드 정렬) | `ProductionLineStep.sequence`(편집 가능) |
| 장비 매핑 | `"EQ-"<>process_code` 문자열 규약 | `ProductionLineStep.equipment_id` FK |
| 장비 미지정 | (항상 규약 매핑 시도) | equipment_id=nil → `:unknown` 안전 |
| 라인 다중 | 불가(단일 정규식) | 라인 N개, 선택(:default/param) |
| 순수 판정부 | `process_steps/4` 등 | **불변(0 변경)** |

## 부록 B. AuditLog action 목록(신규)

`production_line.create` / `production_line.update` / `production_line_step.create` / `production_line_step.update` / `production_line_step.delete`
(reorder 는 step.update 재사용). 전부 MasterData 제네릭 패턴, actor_id 필수.
