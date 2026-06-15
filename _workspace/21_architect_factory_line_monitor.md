# 21. Architect — 공장 생산라인 모니터 재설계 (`/admin/reports/production`)

대상: `/admin/reports/production` (= `OpenMesWeb.Admin.Reports.ProductionReportLive`)
교체: 기존 "표 + CSS 막대" 공정별 실적 → **사출 성형 공장 1라인(10공정) SVG 생산라인 모니터**
원칙: pi(외부 차트/JS 라이브러리 0, 순수 SVG + 서버 순수 함수), **읽기 전용**(도메인 쓰기 0, AuditLog 무관)
재활용: `Charts.Geometry`(`flow_nodes` 확장), `ChartComponents`(신규 라인 모니터 컴포넌트 추가), 20번 대시보드 패턴(30초 폴링)

선행 문서: `_workspace/20_architect_visual_dashboard_design.md`(SVG 위젯/Geometry/30초 폴링 패턴 확립)

---

## 0. 핵심 설계 결정 (요약 5)

1. **공정→장비 매핑은 "자연키 규약"으로 선언한다(신규 FK 0).** 도메인에 Process↔Equipment FK가 없고(설비는 `ProductionResult.equipment_id`로만 연결), MVP에 스키마 변경은 과하다(pi). seed에서 `P01↔EQ-P01`, `P02↔EQ-P02` … 처럼 **코드 끝 2자리를 맞춰** 생성하고, 모니터는 `equipment_code` 규약(`"EQ-" <> process_code`)으로 공정의 대표 설비를 해석한다. 장비 정상 여부는 `equipment.active`(가동/비가동) + 최근 실적 유무로 추정한다. 스키마 무변경 → 기존 화면/마이그레이션 무손상.
2. **공정 상태 판정은 신규 순수 함수 1곳(`Production.LineMonitor`)에 모은다.** "데이터 처리/장비/품질" 3축을 각각 판정하고 종합 신호등(green/amber/red)을 산출하는 규칙을 Ecto 집계와 분리한 **순수 함수**로 둔다. 입력은 이미 조회된 공정/실적/설비/Operation 맵(컨텍스트가 모아서 전달), 출력은 라인 노드 리스트. 임계치(불량률 5%/10%)는 모듈 상수. 컴포넌트/LiveView는 판정 로직을 갖지 않는다.
3. **10공정 가로 1행이 길어 `Geometry.flow_nodes`를 "지그재그(serpentine)"로 확장한다.** 기존 `flow_nodes/5`는 단일 행이라 10노드가 좁다. **신규 `Geometry.line_nodes(count, w, h, node_w, node_h, opts)`** 를 추가해 `rows`(기본 2)로 2행 뱀형 배치 + 행 끝 꺾임 엣지를 산출한다. 기존 `flow_nodes`는 **불변**(20번 대시보드 미니맵이 사용 중 — 무손상). pi: 한 함수 추가, 일반화 금지(rows만 옵션).
4. **신호등은 SVG 원 3개(점등/소등)로 그린다 — 색만이 아니라 라벨·아이콘 병기.** 각 공정 노드 안에 미니 신호등(초/노/빨 원, 해당 상태만 점등)과 "데이터/장비/품질" 3개 상태 칩(텍스트). 색맹 대응으로 종합 상태는 노드 좌상단 상태 텍스트("정상/주의/이상")로도 표기. 연결 화살표는 흐름 정상이면 실선 회색, 데이터 미수신/이상 하류면 **빨강 점선**.
5. **빈 데이터·부분 데이터에서도 라인이 그려진다 — 라우트/리다이렉트/다른 화면 무손상.** seed 0건이어도 10공정 노드가 "데이터 없음(회색)"으로 렌더된다(공정 마스터만 있으면 라인 표시). `production_report_live.ex` **render/mount만 교체**, router·다른 LiveView·기존 `Reports`/`Geometry`/`ChartComponents` 시그니처 불변. 기존 `production_by_process/0`는 그대로 두고 신규 함수만 추가.

---

## 1. 10공정 라인 정의 (사출 성형 공장)

순서대로(sequence 1~10). 공정코드 `P01`~`P10`, 설비코드 `EQ-P01`~`EQ-P10`(규약: `"EQ-" <> process_code`).

| seq | process_code | 공정명(한국어) | 설비명 | 표준 C/T(초) | 의도된 상태(데모) |
|-----|-------------|---------------|--------|-------------|------------------|
| 1 | P01 | 자재투입 | 자재투입기 | 20 | 정상(양품多·불량少) |
| 2 | P02 | 건조 | 건조기 | 40 | 정상 |
| 3 | P03 | 사출 | 사출기 | 35 | **품질 이상**(불량률 높음, red) |
| 4 | P04 | 냉각 | 냉각기 | 30 | 정상 |
| 5 | P05 | 취출 | 취출로봇 | 15 | 주의(불량률 5~10%, amber) |
| 6 | P06 | 1차검사 | 비전검사기 | 25 | 정상 |
| 7 | P07 | 후가공 | 트리밍기 | 30 | **장비 이상**(equipment.active=false, red) |
| 8 | P08 | 조립 | 조립로봇 | 50 | 정상 |
| 9 | P09 | 2차검사 | 측정기 | 25 | **데이터 미수신**(실적 0건 = 처리 이상, red) |
| 10 | P10 | 포장출하 | 포장기 | 20 | 정상(running, 진행 중) |

> 공정명/설비명은 조정 가능. 핵심은 **정상·품질이상·장비이상·데이터미수신·주의가 모두 1개 이상** 섞여 신호등 3색이 화면에 동시 노출되는 것.

라우팅: 품목 `FP-INJ`(완제품 사출품, 신규) 1개에 위 10공정을 sequence 1~10으로 등록.

---

## 2. 공정 상태 판정 규칙 (`OpenMes.Production.LineMonitor`, 신규 순수 모듈)

### 2.1 입력(컨텍스트가 모아서 전달 — LineMonitor는 쿼리 안 함)

```
process_steps(routing_or_processes, by_process_map, equipment_map, op_status_map)
  routing_or_processes : [%{process_id, process_code, name, sequence}]  (sequence 오름차순)
  by_process_map       : %{process_id => %{good_quantity, defect_quantity, total, defect_rate, result_count}}
                         (= Reports.production_by_process 결과를 Map.new(& {&1.process_id, &1}))
  equipment_map        : %{process_code => %{active: bool, name, equipment_code}}  (규약 매핑 해석 결과)
  op_status_map        : %{process_id => latest_operation_status}  ("running"|"completed"|"paused"|"ready"|"pending"|nil)
```

### 2.2 3축 판정(각 축 → :ok | :warn | :bad | :unknown)

**A. 데이터 처리 (`data_status`)** — "공정에서 실적이 나오거나 처리되는가"
- `result_count > 0` 또는 op_status ∈ {running, completed, paused} → `:ok`
- op_status ∈ {ready, pending} 이고 실적 0 → `:warn` (대기 — 아직 미처리)
- op_status == nil 이고 실적 0 → `:bad` (**데이터 미수신** = 처리 이상)

**B. 장비 (`equipment_status`)** — "설비가 정상 가동인가"
- equipment_map에 매핑 없음 → `:unknown` (설비 미지정)
- `active == false` → `:bad` (**장비 비가동/이상**)
- `active == true` 이고 (실적 있음 또는 op 진행) → `:ok`
- `active == true` 이고 실적·진행 모두 없음 → `:warn` (가동 등록됐으나 산출 없음)

**C. 품질 (`quality_status`)** — "불량률이 임계 이하인가"
- 실적 0(total==0) → `:unknown` (판정 불가)
- `defect_rate < 0.05` → `:ok`
- `0.05 <= defect_rate < 0.10` → `:warn`
- `defect_rate >= 0.10` → `:bad`

임계: `@warn_rate 0.05`, `@danger_rate 0.10` (모듈 상수, 20번 게이지 thresholds와 동일 의미축).

### 2.3 종합 신호등(`overall`) — 3색

worst-of 규칙(가장 나쁜 축이 종합을 지배):
- 어느 축이라도 `:bad` → `:red` (이상)
- bad 없고 어느 축이라도 `:warn` → `:amber` (주의)
- 모두 `:ok`/`:unknown` 중 `:ok` 1개 이상 → `:green` (정상)
- 모두 `:unknown`(완전 무데이터) → `:gray` (데이터 없음 — 빈 상태)

각 노드 출력 맵:
```
%{
  process_id, process_code, name, sequence,
  good, defect, total, defect_rate,         # 숫자(표시용; Decimal→그대로, 컴포넌트에서 정규화)
  result_count, op_status, equipment_name, equipment_active,
  data_status, equipment_status, quality_status,   # :ok|:warn|:bad|:unknown
  overall                                            # :green|:amber|:red|:gray
}
```

### 2.4 라인 요약(`line_summary(steps)` 순수 함수)

```
%{
  total_processes,                 # 10
  green, amber, red, gray,         # 종합 상태별 공정 수
  line_good, line_defect,          # 라인 전체 양품/불량 합(Decimal)
  line_defect_rate,                # 0..1 (0나눗셈 방어)
  operating_rate,                  # 가동률 = (data_status==:ok 공정 수) / total (0..1)
  bottleneck_process_code          # 불량률 최댓값 공정(병목) 또는 nil
}
```

---

## 3. 공장 SVG 시각화 구성

### 3.1 화면 레이아웃 (admin_shell 안)

```
page_header "공장 생산라인 모니터"  [roles: production_manager, quality_manager]  우측: 마지막 갱신 시각 + 새로고침 버튼
├─ [라인 요약 바]   가동률 게이지(gauge 재활용) | 정상 N / 주의 N / 이상 N 칩 | 병목 공정 배지 | 라인 불량률
├─ [생산라인 흐름도]  ← 핵심: line_monitor 컴포넌트 (10노드 지그재그 + 신호등 + 연결 화살표)
├─ [범례]            신호등 의미(초=정상/노=주의/빨=이상/회=데이터없음) + 화살표(실선=정상흐름, 빨강점선=이상)
└─ [공정 상세 표]    각 공정: 양품/불량/불량률 미니 막대(sparkline 재활용) + 3축 상태 칩 (접근성 보조·표 fallback)
```

### 3.2 신규 컴포넌트 `line_monitor` (`ChartComponents`에 추가)

```elixir
attr :steps, :list, required: true     # LineMonitor.process_steps/4 결과(§2.3)
attr :width, :integer, default: 980
attr :height, :integer, default: 320
attr :rows, :integer, default: 2       # 지그재그 행 수
```

렌더 구조(SVG 1장):
- **노드 좌표**: `Geometry.line_nodes(length(steps), width, height, node_w=150, node_h=104, rows: @rows)` → `%{nodes, edges}`.
- **각 공정 노드(`<g>`)**:
  - `<rect>` 박스, 테두리색 = 종합 상태색(green/amber/red/gray), 좌상단 `<text>` 상태 라벨("정상/주의/이상/데이터없음").
  - 공정명 + `Pnn` + sequence.
  - **신호등(미니, SVG 원 3개)**: 세로 또는 가로 3원. 종합 상태에 해당하는 원만 채움(점등), 나머지 소등(회색 stroke). → 내부 헬퍼 `traffic_light/2` 또는 인라인.
  - **3축 상태 칩**: "데이터 ●", "장비 ●", "품질 ●" 각 축 색 점 + 한 글자 라벨(정상/주의/이상/—). 색맹 대응 텍스트 병기.
  - 처리량: "양품 N · 불량 M (x.x%)".
- **연결 화살표(`<line>`+marker)**: edge별. **하류 노드의 data_status가 :bad이면(데이터 미수신) 그 진입 엣지는 빨강 점선**(`stroke-dasharray`), 아니면 회색 실선. 행 끝→다음 행 시작 꺾임 엣지는 line_nodes가 좌표 제공.
- `role="img"` + `aria-label`("생산라인 10공정: 정상 N, 주의 N, 이상 N").

### 3.3 신호등 색 매핑 (기존 `chart_color/1` 재사용 + 보강)

종합 상태 → 색:
- `:green` → `chart_color("gauge_good")` (#22c55e)
- `:amber` → `chart_color("gauge_warn")` (#f59e0b)
- `:red` → `chart_color("gauge_danger")` (#ef4444)
- `:gray` → `chart_color("muted")` (#a1a1aa)

3축(:ok/:warn/:bad/:unknown)도 동일 매핑(`:ok→green, :warn→amber, :bad→red, :unknown→muted`). 신규 색 코드 도입 0 — 기존 `@colors` 재사용. 매핑 함수만 `ChartComponents`에 1개 추가(`status_color(atom)`), 또는 `LineMonitor`가 색 key 문자열까지 반환(권장: LineMonitor는 상태 atom만, 색 변환은 컴포넌트). 

### 3.4 라인 요약 바

- **가동률**: 기존 `gauge`(20번) 재활용 — `value = operating_rate`, `label="가동률"`. (게이지는 "불량률"용이지만 0..1 비율 일반이라 재사용 가능. thresholds는 가동률 의미상 반대이므로 `label`만 바꾸고 색 임계는 그대로 두거나, 단순 텍스트 KPI로 대체해도 됨 — domain-engineer 판단, pi.)
- **상태 칩**: 정상/주의/이상/데이터없음 건수 — 색 점 + 숫자(텍스트).
- **병목 공정**: `bottleneck_process_code` 배지(불량률 최댓값).
- **라인 불량률**: 텍스트 % 1자리.

### 3.5 공정 상세 표 (fallback·접근성)

`steps`를 표로: 공정 | 양품 | 불량 | 불량률(미니 막대 `sparkline` 또는 CSS 막대) | 데이터 | 장비 | 품질 | 종합. 색 칩 + 텍스트 라벨. 빈 데이터도 행 10개 표시.

---

## 4. Geometry 확장 — `line_nodes/6` (신규, 테스트 대상)

```elixir
@doc """
지그재그(serpentine) 라인 노드/엣지 좌표.
count 노드를 rows 행에 뱀형으로 배치(1행: 좌→우, 2행: 우→좌 …).
인접 노드 엣지 + 행 끝 꺾임(아래로 내려가는) 엣지를 함께 산출한다.
count<=0 → nodes:[], edges:[]. rows<1 → rows:1. 단일 행이면 flow_nodes와 동형.

반환: %{
  nodes: [%{x, y, w, h, cx, cy, row, col, index}],
  edges: [%{x1,y1,x2,y2, kind: :horizontal | :turn, from_index, to_index}]
}
"""
def line_nodes(count, w, h, node_w, node_h, opts \\ [])
```

설계:
- `rows = max(Keyword.get(opts, :rows, 2), 1)`, `per_row = ceil(count / rows)`.
- 각 행 y = 상하 등간격(행 높이 = h/rows, 노드를 행 내 수직 중앙).
- 행 내 x = 가로 등간격(flow_nodes의 gap 로직 재사용 가능). 짝수행은 좌→우, 홀수행은 우→좌(serpentine)로 col 방향 반전.
- 엣지: 연속 index i→i+1. 같은 행이면 `kind: :horizontal`(끝점은 진행 방향 면), 행이 바뀌면 `kind: :turn`(아래 노드 top↔위 노드 bottom를 잇는 세로/꺾임 — MVP는 두 노드 중심을 잇는 단순선 + marker로 충분, pi).
- **방어**: count 0/1, rows 1, per_row 0 나눗셈, 마지막 행 노드 수 부족(빈 칸 없이 실제 노드만 배치).
- `flow_nodes/5`는 **건드리지 않음**(20번 대시보드 미니맵 사용 중).

`test/open_mes/charts/geometry_test.exs`에 추가: count=10/rows=2 → 노드 10개·행 분배(6+4 또는 5+5)·serpentine x 방향 반전·turn 엣지 1개·count 0 빈 결과·rows 1 단일행.

---

## 5. seed 확장 (`priv/repo/seeds.exs` 끝에 추가 — 기존 블록 무손상)

**멱등·컨텍스트 함수·actor "seed" 준수**(기존 헬퍼 `get_or_create` 재사용). 기존 P-CUT/WO-1 등은 그대로 두고 **사출 라인 전용 블록을 append**.

### 5.1 마스터(공정 10 / 설비 10 / 품목 1 / 라우팅 10)

```
inj_processes = [{"P01","자재투입"}, ... {"P10","포장출하"}]   # §1 표
  → get_or_create(Process, :process_code, code, create_process(...))

inj_equipment = [{"EQ-P01","자재투입기", true}, ... {"EQ-P07","트리밍기", FALSE}, ... ]
  → P07만 active:false (장비 이상 데모). create_equipment 는 active 캐스트 지원.
  ※ create_equipment(%{equipment_code, name, active: false}, actor)

item FP-INJ "사출 완제품" (product, EA)  → get_or_create(Item,:item_code,...)

routing: FP-INJ × P01..P10, sequence 1..10, standard_cycle_time = §1표 (ensure_routing 재사용; 단 기존 ensure_routing은 (item,sequence) 자연키라 FP-INJ에 1~10 안전)
```

### 5.2 작업지시 + Operation 10개 + 실적(상태 섞기)

```
WO-INJ-1 (item FP-INJ, planned 200) : create → release → start
Operation 10개: create_operation(work_order_id, process_id=Pnn, sequence n)  # 항상 pending 생성

상태/실적 시나리오(공정별):
  P01 정상      : ready→start→ (result good 190 / defect 5) → complete
  P02 정상      : ready→start→ (result good 188 / defect 4) → complete
  P03 품질이상  : ready→start→ (result good 150 / defect 40)  [불량률~21%] → complete
  P04 정상      : ready→start→ (result good 185 / defect 3) → complete
  P05 주의      : ready→start→ (result good 180 / defect 12) [불량률~6%] → complete
  P06 정상      : ready→start→ (result good 182 / defect 2) → complete
  P07 장비이상  : ready→start→ (result good 60 / defect 5) → complete    # 실적 일부 있되 EQ-P07.active=false
  P08 정상      : ready→start→ (result good 178 / defect 4) → complete
  P09 데이터미수신: pending 유지(전이 없음) + 실적 0건                    # op_status=pending, total=0
  P10 진행중    : ready→start (실적 일부 good 90/defect 2, 미완료 = running)

  ※ Operation 상태머신: pending→ready→running→completed (직접 running 금지). seed는 ready_operation→start_operation→(result)→complete_operation 순서 준수.
  ※ create_production_result 는 worker_id/equipment_id 함께 — equipment_id = 해당 EQ-Pnn.id.
  ※ 불량 record_defect 는 선택(P03에 D-INJ-BURR 등 1~2건 추가하면 불량현황 화면도 풍부 — pi 최소: 생략 가능).
```

자연키 멱등: `Repo.get_by(WorkOrder, work_order_no: "WO-INJ-1")` 가드로 전체 블록 감싸기(기존 WO-1 패턴 동일).

### 5.3 안내 출력에 "사출 라인 10공정 시드 완료" 한 줄 추가.

---

## 6. LiveView 재작성 (`ProductionReportLive`)

20번 대시보드의 30초 폴링 패턴 채용(읽기 전용).

```elixir
@refresh_ms 30_000

def mount(_p, _s, socket) do
  if connected?(socket), do: schedule_refresh()
  {:ok, socket |> assign(page_title: "공장 생산라인 모니터") |> load_line()}
end

def handle_info(:refresh, socket), do: {:noreply, socket |> load_line() |> tap(fn _ -> schedule_refresh() end)}
def handle_event("refresh", _p, socket), do: {:noreply, load_line(socket)}
defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

defp load_line(socket) do
  steps = OpenMes.Production.LineMonitor.line_steps()   # ← 컨텍스트가 조회+판정 조립(아래)
  summary = OpenMes.Production.LineMonitor.line_summary(steps)
  socket
  |> assign(steps: steps, summary: summary, refreshed_at: DateTime.utc_now())
end
```

### 6.1 조립 함수 `LineMonitor.line_steps/0` (이 함수만 Ecto 접촉 — 나머지 판정은 순수)

`LineMonitor`는 "순수 판정"과 "조립(조회)"을 한 모듈에 두되 경계를 분리:
- `line_steps/0` : 라인 마스터·실적·설비·op상태를 조회해 `process_steps/4`(순수)에 넘기는 **유일한 쿼리 지점**.
  - 사출 라인 공정 식별: `MasterData.list_processes/1`에서 `process_code` `~r/^P\d{2}$/` (또는 routing of FP-INJ 기준) 필터 → sequence(=routing.sequence) 정렬.
  - `Reports.production_by_process/0` → `Map.new(&{&1.process_id, &1})`.
  - `MasterData.list_equipment/1` → `equipment_code` 규약(`"EQ-"<>process_code`)으로 `%{process_code => %{active,name,...}}`.
  - op_status: 각 process_id의 최신 Operation status — **신규 읽기 함수** `Production.latest_operation_status_by_process(process_ids)`(또는 `Reports`에 추가). 1쿼리(process_id별 최신 1건).
- `process_steps/4`, `line_summary/1`, `*_status/*`, `overall/*` : **순수**(Ecto 의존 0, 테스트 대상).

> pi 경계: "조회 1곳(line_steps) + 순수 판정 다수". LiveView·컴포넌트는 판정/쿼리 0.

### 6.2 신규 읽기 함수 (domain-engineer)

```elixir
# Production (또는 Reports)에 추가 — 읽기 전용
@doc "공정 id 목록 → 각 공정의 최신 Operation status 맵(%{process_id => status}). 없으면 빈 맵."
def latest_operation_status_by_process(process_ids)
  # operations 를 process_id 로 묶어 최신(inserted_at desc) 1건 status. distinct on/서브쿼리.
```

---

## 7. 디렉토리 / 모듈 경계

```
lib/open_mes/
  charts/geometry.ex                  ← [확장] line_nodes/6 추가 (flow_nodes 불변)
  production/
    reports.ex                        ← [확장] (선택) latest_operation_status_by_process 또는 production.ex에
    production.ex                     ← [확장] latest_operation_status_by_process/1
    line_monitor.ex                   ← [신규] 상태 판정 순수 함수 + line_steps/0 조립(쿼리 1곳)
lib/open_mes_web/
  components/chart_components.ex       ← [확장] line_monitor 컴포넌트 + status_color/1 (기존 5종 불변)
  admin/reports/production_report_live.ex  ← [교체] 라인 모니터 LiveView
priv/repo/seeds.exs                   ← [확장] 사출 라인 10공정 블록 append (기존 블록 불변)
test/open_mes/charts/geometry_test.exs ← [확장] line_nodes 테스트
test/open_mes/production/line_monitor_test.exs ← [신규] 상태 판정 순수 함수 테스트
```

경계:
- `Geometry` = 숫자만(line_nodes도 도메인 의존 0).
- `LineMonitor` = 판정 순수 함수 + `line_steps/0`(유일 쿼리, Reports/MasterData/Production 조합).
- `ChartComponents.line_monitor` = Geometry.line_nodes 호출 + SVG + 색 변환. 판정/쿼리 0.
- `ProductionReportLive` = LineMonitor 호출 + assign + 타이머. 계산 0.

---

## 8. domain-engineer 구현 지침 (순서)

1. **`Geometry.line_nodes/6`(확장)** — §4. `flow_nodes` 불변. 동시에 `geometry_test.exs`에 케이스 추가(count=10/rows=2 분배·serpentine·turn 엣지·count0·rows1).
2. **`Production.latest_operation_status_by_process/1`(신규 읽기)** — §6.2. distinct on `process_id` order by `inserted_at desc`(Postgres). 빈 목록 방어.
3. **`OpenMes.Production.LineMonitor`(신규)** — §2 순수 판정(`data_status/`, `equipment_status/`, `quality_status/`, `overall/`, `process_steps/4`, `line_summary/1`) + `line_steps/0`(조립·쿼리). 임계 상수 `@warn_rate 0.05` `@danger_rate 0.10`. Decimal→비율은 기존 패턴(0나눗셈 방어). 동시에 `line_monitor_test.exs`(순수 함수만; 5가지 시나리오 → green/amber/red/gray 검증, line_summary 집계·병목).
4. **`ChartComponents.line_monitor`(확장)** — §3.2/3.3. `Geometry.line_nodes` 호출, 노드 rect/신호등 3원/3축 칩/처리량 텍스트, 엣지 실선·빨강점선 분기, `status_color/1`(atom→기존 chart_color hex). 신규 색 코드 0. `role="img"`+aria.
5. **`ProductionReportLive` 교체** — §6 mount/load_line/타이머 + §3.1 레이아웃 render. 라인 요약 바(gauge 또는 텍스트 KPI 재활용) + line_monitor + 범례 + 상세 표. 빈 데이터 분기(공정 0개면 empty_state, 공정 있고 실적 0이면 회색 노드).
6. **seed 확장** — §5. 기존 블록 뒤 append, WO-INJ-1 가드 멱등. Operation 상태머신 순서 준수(pending→ready→running→completed). P07 설비 active:false, P09 pending 유지(실적 0), P10 running 유지.
7. **검증** — `mix compile` 무경고, `mix test`(기존 무손상 + 신규 Geometry/LineMonitor 단위테스트 통과), `mix run priv/repo/seeds.exs` 2회(멱등 중복 0), 실서버 `/admin/reports/production`에서 3색 신호등·점선 엣지·요약 바 노출 확인. 읽기 전용이므로 qa-auditor에는 "읽기 전용·집계 정확성·0나눗셈/빈데이터 방어·상태판정 규칙 정확성"만 요청(AuditLog/상태머신 쓰기 검증 대상 아님).

### 제약 (재강조)
- 외부 JS 차트 라이브러리 절대 금지. `<svg>` + 서버 순수 함수만.
- 스키마/마이그레이션 변경 0(공정↔설비는 코드 규약). 신규 FK·테이블 금지(pi).
- 도메인 쓰기 0(seed 제외) — 모니터의 모든 함수 SELECT만. seed는 기존 컨텍스트 함수·actor "seed" 경유(AuditLog 자동).
- 기존 무손상: `flow_nodes`·기존 5개 컴포넌트·`production_by_process`·router·20번 대시보드 시그니처 불변.
- Decimal: Geometry/컴포넌트 경계에서 float 정규화(기존 `normalize_num` 재사용).

---

## 부록 A. 공정 상태 판정 진리표 (요약)

| 상황 | data | equipment | quality | overall |
|------|------|-----------|---------|---------|
| 실적多·불량少·active·완료 | ok | ok | ok | **green** |
| 불량률 5~10% | ok | ok | warn | **amber** |
| 불량률 ≥10% | ok | ok | bad | **red** |
| 설비 active=false | ok | bad | (any) | **red** |
| 실적0·op=pending·매핑無 | bad | warn/unknown | unknown | **red** (데이터 미수신) |
| 실적0·op=ready | warn | warn | unknown | **amber** |
| 공정만 있고 전부 무데이터 | unknown | unknown | unknown | **gray** |

## 부록 B. 데모 라인 기대 신호등(seed 적용 후)

P01 green · P02 green · **P03 red(품질)** · P04 green · P05 amber · P06 green · **P07 red(장비)** · P08 green · **P09 red(데이터미수신)** · P10 green(진행중)
→ 정상 6 / 주의 1 / 이상 3, 병목=P03(불량률 최대). 3색 동시 노출 충족.
