# 11. 애드온 ② 불량 통계 위젯 (DefectStats)

설계 `09_architect_registry_catalog_design.md` **§2 애드온②** 구현물.
작고 독립적인 **읽기 전용** 품질 확장. `DefectRecord`/`ProductionResult` 를 읽어
불량 유형별 수량/비율과 기간별 불량률을 집계해 위젯으로 보여준다.

## 불변 원칙 (설계 §0)

- **읽기 전용**: Repo SELECT 만. 쓰기/AuditLog/Outbox 0, 새 운영 테이블 0.
- **코어 비침투**: 코어 수정 0. `lib/open_mes_addons/defect_stats/` 격리.
  코어 스키마는 읽기 매핑만(설계 §2 결정 — 읽기는 침투 아님).
- **0 나눗셈 방어**: 생산수량(good+defect)이 0 이면 불량률 `0.0`(raise/NaN 금지).
- **pi**: 외부 차트 라이브러리 없음. 서버 집계 + CSS 텍스트 막대.
- **한국어 UI, 영문 식별자**(`:addon_defect_stats`).

## 파일 구조

```text
11_addon_defect_stats/
├── lib/
│   ├── open_mes_addons/
│   │   ├── defect_stats.ex              # 퍼사드(config on/off 게이트) enabled?/0
│   │   └── defect_stats/
│   │       ├── extension.ex             # ★ Extension behaviour 구현(메타데이터)
│   │       ├── schemas.ex               # 읽기 전용 Ecto 스키마(DefectRecord/ProductionResult 매핑, changeset 없음)
│   │       └── stats.ex                 # ★ 집계(읽기 쿼리 + 순수 계산, 0 나눗셈 방어)
│   └── open_mes_web/live/addons/
│       └── defect_stats_live.ex         # LiveView(기간 필터 + 표 + 텍스트 막대 + 불량률)
├── test/
│   ├── support/defect_stats_tables.exs           # 테스트 전용 테이블 헬퍼(운영 마이그레이션 아님)
│   └── open_mes_addons/defect_stats/
│       ├── stats_pure_test.exs          # 순수 계산(불량률/비율, 0 나눗셈) — DB 불필요
│       ├── stats_test.exs               # 집계 정확성 + 기간 필터 — DB 사용
│       └── extension_test.exs           # behaviour 준수 + enabled?/0 게이트
├── INTEGRATION.md                       # config/router 병합 + 카탈로그 노출 스니펫
└── README.md
```

## 핵심 모듈 역할

| 모듈 | 역할 |
|------|------|
| `OpenMes.Addons.DefectStats` | config 게이트 `enabled?/0`(미설정 기본 false) |
| `OpenMes.Addons.DefectStats.Extension` | 카탈로그 메타데이터. id `:addon_defect_stats`, category `:quality`, home_path `/extensions/defect-stats`. enabled?/0 → 퍼사드 위임 |
| `OpenMes.Addons.DefectStats.Schemas` | `production_results`/`defect_records` 읽기 전용 매핑(changeset 없음 → 쓰기 불가) |
| `OpenMes.Addons.DefectStats.Stats` | `summary/1`(기간 불량률), `defects_by_code/2`(유형별 수량/비율). 순수 함수 `defect_rate/2`·`ratio/2`(0 나눗셈 방어) |
| `OpenMesWeb.Addons.DefectStatsLive` | 기간 필터(시작/종료일) → 요약 카드(불량률) + 유형별 표/텍스트 막대 |

## 집계 정의

- **불량률** = `defect_quantity / (good_quantity + defect_quantity)`.
  분모 0 → `0.0`(`Stats.defect_rate/2` 가 명시 처리).
- **유형별 비율** = `유형 수량 / 전체 불량 수량`. 전체 0 → `0.0`(`Stats.ratio/2`).
- **기간 필터**: `ProductionResult.ended_at` 기준(`defects_by_code/2` 는 조인된 실적의 ended_at).

## 통합

`INTEGRATION.md` 참조. 통합 시 **3곳**만 건드린다:
1. `config/config.exs` `:extensions` 에 `OpenMes.Addons.DefectStats.Extension` 한 줄(카탈로그 노출)
2. `config/config.exs` 게이트 `config :open_mes, OpenMes.Addons.DefectStats, enabled: true`
3. `router.ex` 조건부 scope 1블록(enabled 시 `/extensions/defect-stats`)

애드온이 추가되면 카탈로그(`/`)는 코드 변경 없이 카드를 자동으로 더 그린다
(`Registry.all/0` 이 `:extensions` 리스트를 읽으므로).
