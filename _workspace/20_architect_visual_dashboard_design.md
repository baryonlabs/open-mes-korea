# 20. Architect — 시각적 대시보드 설계 (LiveView + 순수 SVG)

대상: `/admin/dashboard` (= `/` 리다이렉트 첫 화면)
교체 대상: `open_mes/lib/open_mes_web/admin/reports/dashboard_live.ex`
원칙: pi(외부 차트 라이브러리 0, 순수 SVG + 서버 순수 함수), 읽기 전용(도메인 쓰기 0, AuditLog 무관)

---

## 0. 핵심 설계 결정 (요약 5)

1. **SVG 좌표/각도/path는 100% 서버 순수 함수로 계산한다.** 별도 신규 모듈 `OpenMes.Charts.Geometry`(web 아님, 순수/테스트 가능)가 도넛 arc path, 막대 높이, 게이지 각도, 진행바 폭, 다이어그램 노드 좌표를 산출한다. HEEx는 이미 계산된 숫자/문자열만 `<svg>`에 박는다. JS 계산 0.
2. **SVG 위젯은 stateless function component 모듈 `OpenMesWeb.ChartComponents` 한 곳에 모은다.** `donut_chart`, `bar_chart`, `gauge`, `flow_diagram`, `progress_bar`. attr로 이미 정규화된 데이터를 받는다(컴포넌트 안에서 집계/쿼리 금지). 호출 지점이 대시보드 1곳이라도, SVG path 계산 + 접근성 마크업이 반복·검증 대상이라 컴포넌트화는 pi의 "확장 포인트 유지"에 해당(과설계 아님).
3. **실시간 갱신은 MVP 최소 — `Process.send_after`(30초 주기) + 수동 새로고침 버튼.** PubSub/outbox 구독은 후속 옵션으로만 문서화하고 지금 구현하지 않는다(YAGNI). `mount` connected?일 때만 타이머 시작.
4. **색은 기존 팔레트 단일 원천을 재사용한다.** 상태색은 `AdminComponents.status_badge_class`와 동일 의미축(draft=zinc, released=blue, in_progress=indigo, completed=green, cancelled=red)을, 색 코드는 SVG `fill`용 hex 매핑 함수로 1곳(`ChartComponents`)에 둔다. 색만으로 구분 금지 — 모든 차트에 텍스트 라벨/범례 병기(접근성).
5. **빈 데이터가 기본 상태다.** 모든 위젯은 분모 0 / 빈 리스트에서 빈 상태 카드(`empty_state`) 또는 0값 정상 렌더로 떨어진다. 첫 화면이므로 seed 없거나 데이터 0건이어도 레이아웃이 깨지지 않게 설계. 0 나눗셈은 Geometry 순수 함수에서 차단.

---

## 1. 디렉토리 / 모듈 경계

```
lib/open_mes/
  charts/
    geometry.ex                ← [신규] 순수 SVG 기하 계산 (도메인 무관, 테스트 대상)
  production/
    reports.ex                 ← [확장] 신규 읽기 함수 2개 추가 (today_production_summary, daily_production_series)
lib/open_mes_web/
  components/
    chart_components.ex         ← [신규] SVG function components (donut/bar/gauge/flow/progress + 색 매핑)
  admin/reports/
    dashboard_live.ex           ← [교체] 시각적 대시보드 LiveView (위젯 조립 + 타이머)
test/open_mes/charts/
    geometry_test.exs           ← [신규] 기하 순수 함수 단위 테스트
```

경계 원칙:
- `Charts.Geometry` = 숫자만 다룬다(도메인/Ecto/HEEx 의존 0). 가장 순수한 계층.
- `Production.Reports`/`Lots.Reports` = Ecto 집계만(이미 존재 패턴 그대로). 신규 함수도 동일 방어(0 나눗셈, 빈 데이터).
- `ChartComponents` = Geometry 호출 + SVG 마크업 + 색 매핑. 데이터 집계 금지.
- `DashboardLive` = Reports 호출 → assign → ChartComponents에 데이터 전달 + 타이머. 계산 로직 금지.

---

## 2. 위젯 구성 (데이터소스 / SVG 표현 / 크기)

그리드: `grid-cols-12` 반응형. lg 기준 배치.

| # | 위젯 | 데이터소스(컨텍스트 함수) | SVG 표현 | 그리드/크기 |
|---|------|--------------------------|----------|-------------|
| W1 | KPI 카드 행 (4장) | `Production.Reports.today_production_summary/0`(신규), `work_order_status_counts/0`, `MasterData.list_equipment/1` | 큰 숫자 + 미니 sparkline(작은 막대 7일, `daily_production_series`) — KPI는 SVG sparkline만 SVG, 숫자는 텍스트 | 각 col-span-3 (sm: 2열, lg: 4열) |
| W2 | 작업지시 상태 분포 | `Production.Reports.work_order_status_counts/0` | **도넛 차트** (`donut_chart`) — 5상태 색 세그먼트 + 중앙 total + 우측 범례(라벨+건수) | col-span-6, lg: col-span-4 (정사각 ~220px) |
| W3 | 종합 불량률 게이지 | `Production.Reports.defect_summary/0` (전체기간 또는 오늘) | **반원 게이지** (`gauge`) — 0~100% 불량률 바늘/호, 임계색(양호 green / 주의 amber / 위험 red) + 중앙 수치 | col-span-6, lg: col-span-4 (반원 ~200x120) |
| W4 | 진행중 작업지시 진행바 | `Production.list_work_orders(%{"status"=>"in_progress"})` + `today_production_summary`의 wo별 실적(또는 계획 대비 실적 근사) | **진행바 묶음** (`progress_bar` 반복) — wo별 계획수량 대비 누적 양품 % | col-span-12, lg: col-span-4 (목록형, 각 행 1개 바) |
| W5 | 일별 생산량 (양품/불량 스택) | `Production.Reports.daily_production_series/1`(신규, 최근 7일) | **스택 막대 차트** (`bar_chart`) — 일자별 양품(green) 위에 불량(red) 스택 + x축 날짜 라벨 + y축 눈금 | col-span-12, lg: col-span-8 (~640x240) |
| W6 | 공정 흐름 미니 다이어그램 | `Production.Reports.production_by_process/0` + `MasterData` 공정명 | **flow_diagram** — 공정 노드(사각) → 화살표 엣지 가로 배치, 노드 안에 공정명 + 양품/불량 요약, 불량률로 노드 테두리색 | col-span-12, lg: col-span-4 (~360x240) |

위젯 우선순위(공간 부족/후속 분리 시): W1(KPI) → W2(도넛) → W5(일별막대) → W3(게이지) → W4(진행바) → W6(흐름). MVP는 6개 전부 구현하되, W6는 데이터 0건 시 빈 상태로 자연 축소.

### 신규 Reports 함수 사양 (domain-engineer 구현)

```elixir
# Production.Reports 에 추가 — 모두 읽기 전용, 빈 데이터/0 나눗셈 방어

@doc "오늘(서버 로컬일 또는 UTC일 기준 — UTC 일자로 단순화) 양품/불량/생산/불량률 요약 + 진행중 작업지시 건수."
def today_production_summary do
  # ProductionResult.inserted_at >= 오늘 0시(UTC) 인 것 합산.
  # 반환: %{good_quantity, defect_quantity, total_quantity, defect_rate(float 0..1),
  #         in_progress_work_orders(integer), active_equipment(integer)}
  # active_equipment: MasterData 의 active=true 설비 수(간단). 또는 별도 KPI 카드에서 직접 조회.
end

@doc "최근 N일(기본 7) 일자별 양품/불량 시계열(오름차순, 빈 날도 0으로 채움)."
def daily_production_series(days \\ 7) do
  # ProductionResult 를 inserted_at 일자(date_trunc/Date)로 group, good/defect 합.
  # 반환: [%{date: ~D[...], good_quantity: Decimal, defect_quantity: Decimal}] (오래된→최신, 길이 = days)
  # 누락 일자는 0/0 으로 채워 막대 차트 x축이 항상 days 칸이 되도록(빈 데이터 방어).
end
```

> KPI sparkline은 `daily_production_series`의 good_quantity만 사용해 7칸 미니 막대로 그린다(재사용).
> `active_equipment`는 KPI 카드에서 `MasterData.list_equipment(%{})` 길이로 단순 계산해도 됨(전용 함수 불필요 — 인라인, pi).

---

## 3. SVG 컴포넌트 모듈 설계 (`OpenMesWeb.ChartComponents`)

모두 stateless `Phoenix.Component`. attr로 정규화 데이터를 받고, 내부에서 `OpenMes.Charts.Geometry`를 호출해 path/좌표를 만든 뒤 인라인 `<svg>` 렌더. 데이터 집계 금지.

### 3.1 공통 규칙
- 모든 차트: `role="img"` + `aria-label`(요약 한국어) 부여. 색 옆에 텍스트 라벨/범례 병기.
- 빈/0 데이터: 컴포넌트가 자체적으로 빈 상태 placeholder(점선 박스 + "데이터 없음")를 렌더하거나, 호출부에서 `empty_state`로 감쌈(W단위 결정). 권장: 차트 컴포넌트는 0값도 그릴 수 있게 만들고, "행 0건"만 호출부에서 `empty_state` 처리.
- 색 매핑: `chart_color(key)` private — 상태/의미 key → hex. status_badge 색축과 일치.
  - draft=#a1a1aa(zinc), released=#3b82f6(blue), in_progress=#6366f1(indigo), completed=#22c55e(green), cancelled=#ef4444(red), good=#22c55e, defect=#ef4444, gauge: good=#22c55e / warn=#f59e0b / danger=#ef4444.

### 3.2 컴포넌트별 attr / 동작

**donut_chart** — 작업지시 상태 분포 (W2)
```
attr :segments, :list   # [%{key, label, value, color}] (value 0 포함 가능)
attr :total, :integer
attr :size, :integer, default: 220
attr :title, :string, default: nil
```
- Geometry: `donut_segments(values, cx, cy, r_outer, r_inner)` → 각 세그먼트 SVG `<path d=...>`(arc) 목록. 누적각으로 시작/끝각 계산, `total==0`이면 path 빈 리스트 + 회색 전체 링 1개.
- 렌더: `<svg>` 안에 path들 + 중앙 `<text>` total + 우측(또는 하단) 범례 ul(색 점 + 라벨 + 값).

**bar_chart** — 일별 양품/불량 스택 (W5)
```
attr :categories, :list  # [%{label, segments: [%{key,label,value,color}]}]  label=날짜
attr :width, :integer, default: 640
attr :height, :integer, default: 240
attr :y_unit_label, :string, default: "수량"
```
- Geometry: `bar_layout(categories, plot_w, plot_h, max_value)` → 각 막대 x/width, 각 세그먼트 y/height(스택), y축 눈금값(`nice_ticks(max)`). `max==0`이면 모든 height 0(빈 바닥선만).
- 렌더: x축 날짜 라벨, y축 눈금선+값, 스택 rect, 상단 범례(양품/불량).

**gauge** — 불량률/지표 반원 게이지 (W3)
```
attr :value, :float          # 0..1 (비율). 표시 시 %.
attr :thresholds, :map, default: %{warn: 0.05, danger: 0.1}  # 불량률 임계
attr :label, :string, default: "불량률"
attr :width, :integer, default: 200
```
- Geometry: `gauge_arc(value_0_1, cx, cy, r, start_deg, end_deg)` → 배경 반원 arc path + 값 arc path(0..1 → 각도), 바늘 좌표(옵션). value clamp 0..1.
- 색: value vs thresholds → good/warn/danger. 중앙 큰 `<text>` "x.x%". 임계 라벨 텍스트 병기.

**progress_bar** — 작업지시 계획 대비 실적 (W4, 행 반복)
```
attr :label, :string         # 작업지시번호 + 품목
attr :current, :decimal/number
attr :planned, :decimal/number
attr :color, :string, default: indigo
attr :height, :integer, default: 12
```
- Geometry: `progress_width(current, planned, track_w)` → 채움 폭(px). `planned<=0`이면 0, current>planned면 100% clamp(+초과 표식 옵션).
- 렌더: 배경 track rect + 채움 rect + 우측 "current/planned (xx%)" 텍스트.

**flow_diagram** — 공정 흐름 미니맵 (W6)
```
attr :nodes, :list   # [%{id,label, good, defect, defect_rate}]  순서 = 공정 순서(또는 실적순)
attr :width, :integer, default: 360
attr :height, :integer, default: 240
```
- Geometry: `flow_nodes(node_count, width, height, node_w, node_h)` → 각 노드 x/y(가로 등간격, 1행 또는 자동 줄바꿈), 인접 노드 간 엣지 선/화살표 좌표. node 0/1개 방어(엣지 0).
- 렌더: `<rect>` 노드(테두리색=불량률 임계) + 내부 `<text>` 공정명/양품·불량 + `<line>`/`<polygon>` 화살표 엣지. 색만 아니라 숫자 라벨 병기.

### 3.3 Geometry 순수 함수 목록 (테스트 대상)
```
donut_segments(values, cx, cy, r_out, r_in) -> [%{path, key?}]   # 0합 방어
polar_point(cx, cy, r, angle_deg) -> {x, y}                       # 공통 헬퍼
arc_path(cx, cy, r_out, r_in, start_deg, end_deg) -> binary       # SVG path d
bar_layout(values_or_categories, plot_w, plot_h, max) -> %{...}   # max 0 방어
nice_ticks(max, count \\ 4) -> [number]                           # max 0 -> [0]
gauge_arc(value_0_1, cx, cy, r, start_deg, end_deg) -> %{bg_path, val_path, needle?}
progress_width(current, planned, track_w) -> number               # planned<=0 -> 0, clamp
flow_nodes(count, w, h, node_w, node_h) -> %{nodes: [%{x,y}], edges: [%{x1,y1,x2,y2}]}
```
모든 함수: 분모 0 / 빈 입력 / 음수 입력에서 크래시 없이 안전 기본값. Decimal 입력은 호출부(컴포넌트)에서 float/round로 정규화 후 전달(Geometry는 숫자만).

---

## 4. LiveView 실시간 갱신 (`DashboardLive`)

```elixir
@refresh_ms 30_000

def mount(_p, _s, socket) do
  if connected?(socket), do: schedule_refresh()
  {:ok, socket |> assign(page_title: "생산 대시보드") |> load_data()}
end

def handle_info(:refresh, socket), do: {:noreply, socket |> load_data() |> tap(fn _ -> schedule_refresh() end)}
def handle_event("refresh", _p, socket), do: {:noreply, load_data(socket)}  # 수동 버튼

defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

defp load_data(socket) do
  socket
  |> assign(today: Production.Reports.today_production_summary())
  |> assign(wo_counts: Production.Reports.work_order_status_counts())
  |> assign(daily: Production.Reports.daily_production_series(7))
  |> assign(defect: Production.Reports.defect_summary())
  |> assign(by_process: Production.Reports.production_by_process())
  |> assign(in_progress: Production.list_work_orders(%{"status" => "in_progress", "limit" => "8"}))
  |> assign(processes: MasterData.processes_map(...))   # 공정명 라벨
  |> assign(items: MasterData.items_map(...))           # 진행바 품목 라벨
  |> assign(equipment_count: length(MasterData.list_equipment(%{})))
  |> assign(refreshed_at: DateTime.utc_now())
end
```
- 타이머는 `connected?`일 때만(최초 dead render에서 안 켬). `handle_info(:refresh)`에서 데이터 재적재 후 재예약(재귀 스케줄).
- 상단에 "마지막 갱신 HH:MM:SS" + 새로고침 버튼(`phx-click="refresh"`). 자동 30초.
- **후속 옵션(지금 구현 안 함, 문서만):** outbox 이벤트(`operation.completed`, `defect.recorded`) → `Phoenix.PubSub` broadcast 구독으로 즉시 갱신. MVP는 폴링으로 충분.

---

## 5. 레이아웃 / 접근성 / 첫 화면

- `admin_shell`(사이드바+상단바) 안. `page_header`에 roles=`["production_manager","quality_manager"]` 배지(기존 메뉴 매핑과 일치) + 우측 actions 슬롯에 갱신시각 + 새로고침 버튼.
- 반응형: `grid grid-cols-12 gap-4`. 카드 = `rounded-lg border border-zinc-200 bg-white p-4`(기존 톤 일치).
- 한국어 라벨: "오늘 생산량 / 불량률 / 진행중 작업지시 / 가동 설비", "작업지시 상태 분포", "일별 생산량(양품·불량)", "종합 불량률", "진행중 작업지시 진행", "공정 흐름".
- 접근성: 모든 차트 `aria-label` + 색 옆 텍스트 범례/숫자 병기(색맹 대응). KPI 추세 sparkline에도 수치 동반.
- **빈 상태(첫 화면 핵심):** seed 0건이어도 — KPI는 0/0.0%, 도넛은 회색 전체링+범례 0, 막대는 7칸 빈 바닥선, 게이지는 0%(green), 진행바 영역은 `empty_state`("진행중 작업지시가 없습니다"), 흐름도는 `empty_state`("공정 실적이 없습니다"). 레이아웃 무붕괴.
- 라우트/리다이렉트 무변경: `/` → `/admin/dashboard`(기존 유지), `dashboard_live.ex`만 교체. 기존 `wo_status_label`/`bar_width` 헬퍼는 제거(컴포넌트로 대체) 또는 라벨 함수만 ChartComponents로 이동.

---

## 6. domain-engineer 구현 지침 (순서)

1. **`OpenMes.Charts.Geometry`(신규)** — §3.3 순수 함수부터. Ecto/HEEx 의존 0. 각 함수 0/빈/음수 방어. 동시에 `test/open_mes/charts/geometry_test.exs` 작성(arc 각도 합, 0합 방어, max=0 ticks, planned<=0 progress=0, node 0/1개 edge=0).
2. **`Production.Reports` 확장** — `today_production_summary/0`, `daily_production_series/1` 추가(§2). 기존 모듈의 Decimal/0나눗셈 헬퍼(`to_decimal`, `decimal_ratio`) 재사용. 누락 일자 0 채움 로직 포함. 기존 함수 시그니처 불변(무손상).
3. **`OpenMesWeb.ChartComponents`(신규)** — §3.2 컴포넌트 5종 + `chart_color/1`. Geometry 호출, Decimal→숫자 정규화는 여기서. 모든 컴포넌트 `role="img"`+`aria-label`+텍스트 범례. 색은 status_badge 의미축과 일치.
4. **`DashboardLive` 교체** — §4 mount/load_data/타이머 + §5 레이아웃으로 render 재작성. 위젯 W1~W6 조립. 빈 상태 분기. `MasterData.processes_map`이 없으면 인라인 조회(또는 by_process의 process_id로 이름 map 구성 — 1곳이면 인라인, pi).
5. **검증** — `mix compile` 무경고, 기존 테스트 무손상(`mix test`), Geometry 단위 테스트 통과. 실서버에서 seed 0건/2건 모두 레이아웃 정상 확인(빈 상태). 읽기 전용이므로 AuditLog/상태머신 검증 대상 아님(qa-auditor에는 "읽기 전용·집계 정확성·0나눗셈 방어"만 요청).

### 주의/제약 (재강조)
- 외부 JS 차트 라이브러리(Chart.js/D3/ApexCharts 등) 도입 절대 금지. `<svg>` + 서버 계산만.
- 무거운 추상화 금지: 차트 컴포넌트는 5종으로 한정. 일반화된 "차트 엔진" 만들지 말 것.
- 도메인 쓰기 0: 어떤 위젯도 mutation 호출 금지(조회 함수만). 새 Reports 함수도 SELECT만.
- 기존 라우트/화면 무손상: `dashboard_live.ex` 교체만, router·다른 LiveView·components 시그니처 불변(ChartComponents는 신규라 충돌 없음).
- Decimal 처리: Geometry는 순수 숫자만 받는다. Decimal→float 변환은 ChartComponents 경계에서. 표시 반올림(불량률 소수 1자리 등)도 컴포넌트/뷰에서.

---

## 부록 A. 위젯↔데이터소스 매핑 표 (한눈)

| 위젯 | 컨텍스트 함수 | 신규? | SVG 컴포넌트 |
|------|--------------|------|-------------|
| W1 KPI | today_production_summary, work_order_status_counts, list_equipment, daily_production_series | 일부 신규 | (텍스트) + sparkline(bar 미니) |
| W2 상태 도넛 | work_order_status_counts | 기존 | donut_chart |
| W3 불량률 게이지 | defect_summary | 기존 | gauge |
| W4 진행바 | list_work_orders(in_progress) + today_production_summary | 기존+ | progress_bar(반복) |
| W5 일별 막대 | daily_production_series | 신규 | bar_chart |
| W6 공정 흐름 | production_by_process + 공정명 | 기존 | flow_diagram |
