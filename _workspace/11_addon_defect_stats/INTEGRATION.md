# 애드온 ② 불량 통계 위젯(DefectStats) — 통합 가이드

설계 `09_architect_registry_catalog_design.md` §2 애드온② / §4(슬롯) 구현물.
**읽기 전용 + 새 테이블 0 + 코어 수정 0**. 통합 시 **3곳**(config 2줄, router 1블록)만 건드린다.

## 1. 소스 복사 (앱 트리 매핑)

| 출처(이 디렉토리) | 대상(앱 트리) |
|------|------|
| `lib/open_mes_addons/defect_stats.ex` | `lib/open_mes_addons/defect_stats.ex` |
| `lib/open_mes_addons/defect_stats/extension.ex` | `lib/open_mes_addons/defect_stats/extension.ex` |
| `lib/open_mes_addons/defect_stats/schemas.ex` | `lib/open_mes_addons/defect_stats/schemas.ex` |
| `lib/open_mes_addons/defect_stats/stats.ex` | `lib/open_mes_addons/defect_stats/stats.ex` |
| `lib/open_mes_web/live/addons/defect_stats_live.ex` | `lib/open_mes_web/live/addons/defect_stats_live.ex` |
| `test/open_mes_addons/defect_stats/*` | `test/open_mes_addons/defect_stats/` |
| `test/support/defect_stats_tables.exs` | `test/support/` (테스트 전용 — 운영 마이그레이션 아님) |

## 2. config 병합 — `config/config.exs`

### (a) `:extensions` 리스트에 카탈로그 노출 한 줄 (카탈로그 노출 스니펫)

```elixir
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  OpenMes.Addons.DefectStats.Extension,   # ← 애드온 ② 추가 (카탈로그에 카드로 노출)
  # ... 나머지 애드온 ...
]
```

> `Registry.all/0` 이 이 리스트를 읽으므로, 한 줄 추가만으로 카탈로그(`/`)에 카드가
> 자동 렌더된다(코드 변경 0). `category: :quality` → 카탈로그 "품질" 필터에 묶인다.

### (b) on/off 게이트 한 줄

```elixir
config :open_mes, OpenMes.Addons.DefectStats, enabled: true
```

미설정 시 기본 `false`(비침투). 읽기 전용이라 켜져도 코어에 영향 없음.
테스트에서는 `config/test.exs` 에 `enabled: true` 를 둬 라우트 등록 검증 가능.

## 3. router 병합 — `lib/open_mes_web/router.ex`

`skel/router.ex` 의 애드온 슬롯(주석)을 해제한다. **enabled 시에만 컴파일 타임 등록**(EXT 패턴):

```elixir
if OpenMes.Addons.DefectStats.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/defect-stats", DefectStatsLive, :index
  end
end
```

`home_path/0`(`/extensions/defect-stats`)와 이 라우트가 일치한다 → 카탈로그 "열기" 링크가
올바른 화면으로 이동한다.

## 4. 전제 테이블

집계는 `production_results`, `defect_records`(docs/domain-model.md) 를 **읽는다**.
- 운영: 코어/후속 작업이 두 테이블을 마이그레이션으로 제공한다(애드온은 마이그레이션 0개).
- 테스트: `test/support/defect_stats_tables.exs` 가 동일 스키마 임시 테이블을 만들어
  애드온 단위 테스트가 코어 없이도 자체적으로 돈다.

## 5. 비침투 검증 체크리스트

- [ ] `lib/open_mes/{production,audit,outbox}` 무수정 (`git diff` 0건)
- [ ] 애드온이 쓰기/AuditLog/Outbox 호출 0 (`grep -rE "Repo.(insert|update|delete)" lib/open_mes_addons/defect_stats` → 0)
- [ ] 새 운영 마이그레이션 0개
- [ ] 코어 도메인이 `OpenMes.Addons.DefectStats` 를 참조하지 않음(단방향 의존)
