# 애드온 ⑤ 일일 생산 요약 (DailyProductionSummary)

설계 `09_architect_registry_catalog_design.md` §2 애드온⑤ / §7-b 의 구현물.
**작고 독립적인 읽기 전용 확장** — 선택한 날짜의 생산 현황을 한 장으로 요약한다.

---

## 무엇을 하나

날짜를 선택하면 그 날의:
- **작업지시 상태별 건수**(작성/발행/진행중/완료/취소)와 **가동(in_progress) 작업지시 수**
- 그 날 **종료된 실적**(`ProductionResult.ended_at`) 기준 **총 양품/불량 수량**과 **불량률**
- **품목별 양품/불량 합산**(상위 N, 양품 내림차순)

을 카드 + 표로 보여준다. AI 요약 API(mvp-scope §6)의 입력 데이터 소스로도 재사용 가능.

---

## 파일 구조

```text
11_addon_daily_summary/
├── lib/
│   ├── open_mes_addons/
│   │   ├── daily_production_summary.ex                 # 퍼사드(공개 진입점 + enabled? 게이트)
│   │   └── daily_production_summary/
│   │       ├── extension.ex                            # ★ Extension behaviour 구현(카탈로그 메타데이터)
│   │       ├── schemas.ex                              # 읽기 전용 스키마(ProductionResult/Operation/Item)
│   │       └── summary.ex                              # 집계 모듈(읽기 전용 + 순수 함수 분리)
│   └── open_mes_web/
│       └── live/addons/
│           └── daily_production_summary_live.ex        # LiveView(날짜 선택 + 요약 카드/표)
├── config/
│   └── config.snippets.md                             # :extensions/게이트/router 병합 스니펫
├── test/
│   ├── support/migrations/
│   │   └── 20260613200001_create_daily_summary_read_tables.exs  # 테스트 지원(코어 테이블, 통합 시 삭제)
│   └── open_mes_addons/daily_production_summary/
│       ├── summary_test.exs                            # 집계 정확성(날짜 경계/품목 합산/빈 날/카운트)
│       └── extension_test.exs                          # enabled? 게이트 + behaviour 준수
└── README.md
```

> `lib/*` 와 `test/*` 는 실제 앱 트리로 그대로 복사한다(경로 동일). `config/config.snippets.md`
> 는 phx.new/통합 골격 위에 **병합**한다(통째 교체 아님).

---

## 코어 비침투 / 읽기 전용 보증 (필수 준수)

| 항목 | 보증 |
|------|------|
| **쓰기** | 없음. 코어 데이터 INSERT/UPDATE/DELETE 0. AuditLog 0, Outbox 0. |
| **새 테이블** | 0개. 애드온은 기존 테이블을 읽기만 한다. |
| **코어 수정** | 0. `lib/open_mes_addons/daily_production_summary/` 에 격리. |
| **WorkOrder 읽기** | 코어 공개 함수 `OpenMes.Production.list_work_orders/1` 재사용(상태별 카운트). |
| **ProductionResult/Operation/Item 읽기** | 애드온 전용 **읽기 전용 스키마**(`Schemas`, changeset 없음 → 쓰기 경로 불가)로 SELECT 집계만. |
| **읽기 전용 불변식** | `Schemas` 의 스키마는 changeset 을 제공하지 않으므로 Repo 쓰기의 입력이 될 수 없다. |

> 설계 §2 결정: 코어에 조회 함수가 부족하면 추가하지 않고 애드온에서 읽기 쿼리를 짠다.
> 코어 스키마/테이블을 **읽기 쿼리에 쓰는 것은 침투가 아니다**(쓰기/스키마 변경만 금지).

---

## 날짜 경계 처리 (정확성 핵심)

- "선택일"은 **타임존이 있는 날짜**다. UTC 로 저장된 `ended_at` 을 해당 타임존의
  **`[date 00:00:00, 다음날 00:00:00)`** 반열린 구간으로 필터한다(시작 포함 / 끝 배타).
- 자정 경계가 양쪽 날짜에 **중복 집계되지 않는다**(끝 배타).
- 경계 계산은 순수 함수 `Summary.day_bounds/2` 로 분리 — 테스트로 고정.
- 타임존 DB 가 없거나 알 수 없는 타임존이면 **UTC 로 안전 폴백**(raise 없음).
- 데이터 없는 날은 `total_good=0`, `by_item=[]` 등 **빈 요약**으로 안전 반환.

기본 타임존은 `"Etc/UTC"`. 운영에서 한국 시간 기준이 필요하면
`summarize(date, time_zone: "Asia/Seoul")`(tz database 의존성 설치 필요).

---

## pi 준수

- 집계는 **서버에서**(LiveView assign). 무거운 리포팅 엔진/외부 차트 라이브러리 도입 없음.
- **순수 함수 분리**: `day_bounds/2`, `defect_rate/2` 는 Repo 의존 없는 순수 함수 → 단위 테스트 용이.
- 품목별 합산은 단일 `group_by` 집계 쿼리 1번 + 실적 총계 쿼리 1번. 과한 N+1 없음.
- LiveView 화면 1개 + 집계 모듈 1개 + 메타데이터 1개 — 설계의 "작음(~3 파일)" 준수.

---

## 카탈로그 노출 스니펫 (명시)

이 애드온은 동일한 `Extension` behaviour 로 홈페이지 카탈로그에 자동 노출된다.

```elixir
# config/config.exs — :extensions 리스트에 한 줄(이 줄이 카탈로그 카드를 만든다)
config :open_mes, :extensions, [
  # ... 기존 확장 ...
  OpenMes.Addons.DailyProductionSummary.Extension
]

# on/off 게이트(기본 off — 명시적으로 켜야 라우트 등록)
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true
```

```elixir
# lib/open_mes_web/router.ex — enabled 일 때만 화면 라우트 등록
if OpenMes.Addons.DailyProductionSummary.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/daily-production-summary", DailyProductionSummaryLive, :index
  end
end
```

카드 메타데이터: 이름 "일일 생산 요약", 카테고리 `:production`, 버전 `0.1.0`,
home_path `/extensions/daily-production-summary`. enabled=true 면 카드에 "열기" 링크가 뜬다.

자세한 병합 위치는 `config/config.snippets.md` 참조.

---

## 테스트

```bash
mix test test/open_mes_addons/daily_production_summary/
```

- `summary_test.exs` — 날짜 경계(자정 포함/배타, nil ended_at 제외, day_bounds 폴백),
  품목별 합산/정렬/top_n, 가동 작업지시 카운트, 데이터 없는 날 빈 요약, defect_rate.
- `extension_test.exs` — enabled? 게이트(기본 false/true/false/잘못된 값),
  Extension behaviour 필수 6 콜백 + home_path + 게이트 위임.

> `summary_test.exs` 는 읽기 대상 테이블(`items`/`operations`/`production_results`)이 필요하다.
> 코어가 아직 이 테이블을 마이그레이션하지 않은 MVP 단계에서는
> `test/support/migrations/20260613200001_create_daily_summary_read_tables.exs` 로 제공한다
> (코어가 정식 구현하면 이 지원 마이그레이션은 삭제).
