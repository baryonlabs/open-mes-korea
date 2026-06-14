# 애드온 ⑤ 일일 생산 요약 — config 병합 스니펫

설계 §4-1(애드온 슬롯). 통합 시 **3곳**만 건드린다: ① `:extensions` 리스트,
② 애드온 게이트 config, ③ router 조건부 scope. 아래 스니펫을 `config/`·`router.ex` 에 병합한다.

---

## 1. `config/config.exs` — 카탈로그 노출 + 게이트

```elixir
# (1) :extensions 리스트에 한 줄 추가 — 이 줄이 있어야 카탈로그에 카드로 노출된다.
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  # ... 다른 애드온 ...
  OpenMes.Addons.DailyProductionSummary.Extension # ← 애드온 ⑤ (카탈로그 노출)
]

# (2) on/off 게이트 — 읽기 전용이라 운영상 안전하나, EXT 컨벤션상 기본 off.
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: false
```

> `:extensions` 리스트에 모듈이 들어가면 `Registry.all/0` 이 이를 읽어 **카탈로그에
> 자동으로 카드를 그린다**(enabled=false 면 '비활성' 배지, true 면 '열기' 링크).
> 카드 메타데이터는 `OpenMes.Addons.DailyProductionSummary.Extension` 이 제공한다:
> 이름 "일일 생산 요약", 카테고리 `:production`, 버전 "0.1.0",
> home_path `/extensions/daily-production-summary`.

## 2. `config/test.exs` — 테스트에서 켜기(LiveView 라우트 필요 시)

```elixir
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true
```

## 3. `config/dev.exs` (선택) — 개발 중 켜기

```elixir
config :open_mes, OpenMes.Addons.DailyProductionSummary, enabled: true
```

## 4. (선택) 런타임 환경변수 게이트 — `config/runtime.exs`

```elixir
config :open_mes, OpenMes.Addons.DailyProductionSummary,
  enabled: System.get_env("DAILY_SUMMARY_ENABLED", "false") == "true"
```

---

## router 병합 스니펫 — `lib/open_mes_web/router.ex`

`skel/router.ex` 의 애드온 슬롯 영역에 아래 조건부 scope 를 추가(주석 해제). 활성일 때만 등록된다.

```elixir
if OpenMes.Addons.DailyProductionSummary.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/daily-production-summary", DailyProductionSummaryLive, :index
  end
end
```

> `home_path/0`(`/extensions/daily-production-summary`)와 라우트 경로가 일치해야
> 카탈로그 "열기" 링크가 올바로 동작한다.
