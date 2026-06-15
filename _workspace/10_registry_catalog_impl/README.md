# 10. 확장 레지스트리 + 홈페이지 카탈로그 + Phoenix 앱 골격 (기반 작업)

설계 `09_architect_registry_catalog_design.md` **§7-a 기반 작업**의 구현물이다.
이 디렉토리는 (1) 확장 레지스트리 메커니즘, (2) 홈페이지 확장 카탈로그(LiveView),
(3) EXT-1/EXT-2 메타데이터 모듈, (4) Phoenix 앱 통합 골격(deps/config/배선)을 담는다.

> **범위**: 기반 작업만. 애드온 5개(§7-b)는 이 작업물에 **포함되지 않는다.**
> 단 애드온이 꽂힐 자리(config/router/`:extensions` 슬롯)는 모두 표시해 두었다.

---

## 이 디렉토리의 파일 구조

```text
10_registry_catalog_impl/
├── lib/
│   ├── open_mes/
│   │   └── extensions/
│   │       ├── extension.ex          # ★ Extension behaviour (애드온 구현자가 따를 계약)
│   │       ├── definition.ex         # use 매크로(선택 콜백 nil 기본값 주입)
│   │       └── registry.ex           # 레지스트리(config 명시 목록 조회, 상태 없음)
│   ├── open_mes_ingest/
│   │   └── extension.ex              # EXT-1 메타데이터 모듈(기존 파이프라인 무변경)
│   ├── open_mes_media/
│   │   └── extension.ex              # EXT-2 메타데이터 모듈(기존 파이프라인 무변경)
│   └── open_mes_web/
│       └── live/
│           └── catalog_live.ex       # 카탈로그 LiveView(카드/필터/배지, ~H 인라인 템플릿)
├── config/
│   ├── config.exs                    # :extensions 명시 목록 + EXT 게이트(병합 기준)
│   ├── runtime.exs                   # INGEST_*/MEDIA_* 환경변수 게이트(병합 기준)
│   └── test.exs                      # 테스트 게이트(병합 기준)
├── skel/
│   ├── application.ex                # 통합 application.ex(ingest/media child 배선)
│   ├── router.ex                     # 통합 router.ex(/ 카탈로그 + 조건부 확장 scope)
│   └── mix.deps.exs                  # mix.exs deps 병합 가이드
└── test/
    ├── support/extension_fixtures.ex          # 테스트용 더미 확장 모듈
    ├── open_mes/extensions/registry_test.exs  # 레지스트리(all/enabled/by_category/견고성)
    ├── open_mes/extensions/extension_test.exs # behaviour 준수(EXT-1/2 + 게이트 위임)
    └── open_mes_web/live/catalog_live_test.exs # 카탈로그(렌더/필터/배지/링크/회귀)
```

> `config/*` 와 `skel/*` 는 **phx.new 골격 위에 얹는 병합 기준 파일**이다(통째 교체가 아니라
> 명시된 블록만 병합). `lib/*` 와 `test/*` 는 실제 앱 트리로 그대로 복사한다.

---

## 0. 전제: 사용자가 로컬에서 phx.new 실행

이 환경에는 elixir/mix 가 없으므로 골격 생성은 **사용자가 로컬에서** 실행한다.
카탈로그가 LiveView 이므로 LiveView 스택을 살린다(`--no-dashboard` 붙이지 않음).

```bash
# 프로젝트 루트(/Users/hongsw/dev/open-mes-korea)에서:
mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer
# "."(현재 디렉토리) 생성 시 기존 파일 충돌은 phx.new 가 물어본다 → 아래 통합 순서대로.
```

phx.new 가 잘 만드는 것(endpoint, web.ex, components, core_components, layouts, assets,
repo, telemetry)은 **재작성하지 않는다**(pi). 우리는 (a) 도메인/확장 소스, (b) deps/config,
(c) application.ex·router.ex 배선만 얹는다.

---

## 1. `_workspace` 코드 → 실제 앱 트리 매핑

루트: `/Users/hongsw/dev/open-mes-korea/` (phx.new `.` 생성 후).

### (a) 코어 02 — WorkOrder

| 출처(_workspace) | 대상(앱 트리) |
|------|------|
| `02_.../lib/open_mes/audit/*` | `lib/open_mes/audit/*` |
| `02_.../lib/open_mes/outbox/*` | `lib/open_mes/outbox/*` |
| `02_.../lib/open_mes/production/*` | `lib/open_mes/production/*` |
| `02_.../lib/open_mes_web/controllers/*` | `lib/open_mes_web/controllers/*` |
| `02_.../lib/open_mes_web/plugs/require_actor.ex` | `lib/open_mes_web/plugs/require_actor.ex` |
| `02_.../lib/open_mes_web/router.ex` | (router 는 §3 통합 router 로 흡수) |
| `02_.../priv/repo/migrations/2026061300000{1,2,3}_*` | `priv/repo/migrations/` |

### (b) 기반 작업 10 (이 디렉토리) — 레지스트리/카탈로그/골격

| 출처(이 디렉토리) | 대상(앱 트리) |
|------|------|
| `10_.../lib/open_mes/extensions/{extension,definition,registry}.ex` | `lib/open_mes/extensions/` |
| `10_.../lib/open_mes_web/live/catalog_live.ex` | `lib/open_mes_web/live/` |
| `10_.../lib/open_mes_ingest/extension.ex` | `lib/open_mes_ingest/extension.ex` |
| `10_.../lib/open_mes_media/extension.ex` | `lib/open_mes_media/extension.ex` |
| `10_.../config/{config,runtime,test}.exs` | `config/` (블록 병합) |
| `10_.../skel/application.ex` | `lib/open_mes/application.ex` (병합 기준) |
| `10_.../skel/router.ex` | `lib/open_mes_web/router.ex` (병합 기준) |
| `10_.../skel/mix.deps.exs` | `mix.exs` `deps/0` (블록 병합) |
| `10_.../test/support/extension_fixtures.ex` | `test/support/` |
| `10_.../test/open_mes/extensions/*` | `test/open_mes/extensions/` |
| `10_.../test/open_mes_web/live/*` | `test/open_mes_web/live/` |

### (c) EXT-1 06 / EXT-2 07

| 출처(_workspace) | 대상(앱 트리) |
|------|------|
| `06_.../lib/open_mes_ingest/*` | `lib/open_mes_ingest/*` (extension.ex 는 위 (b) 것 사용) |
| `06_.../lib/open_mes_web/controllers/ingest_*` | `lib/open_mes_web/controllers/` |
| `06_.../lib/open_mes_web/plugs/require_device_token.ex` | `lib/open_mes_web/plugs/` |
| `06_.../priv/repo/migrations/202606131000*` | `priv/repo/migrations/` |
| `07_.../lib/open_mes_media/*` | `lib/open_mes_media/*` (extension.ex 는 위 (b) 것 사용) |
| `07_.../priv/repo/migrations/20260613000010_create_media_assets.exs` | `priv/repo/migrations/` |

> EXT-1/EXT-2 의 application.ex/router.ex 패치는 §3 통합 골격(`skel/`)이 이미 흡수했다.
> 06/07 의 patches/CORE_PATCH 를 따로 적용하지 말고 `skel/` 파일을 병합 기준으로 쓴다.

---

## 2. 마이그레이션 순서 (설계 §4.6)

Ecto 는 **파일명 타임스탬프 오름차순**으로 실행한다. 현재 번호 그대로 두면 안전하다.

```text
20260613000001  create_audit_logs        (코어 02)   ← 가장 먼저(토대)
20260613000002  create_outbox_events     (코어 02)
20260613000003  create_work_orders       (코어 02)
20260613000010  create_media_assets      (EXT-2 07)  ← work_orders 뒤(독립)
20260613100001  enable_timescaledb       (EXT-1 06)
20260613100002  create_equipment_measurements (EXT-1 06)
20260613100003  create_ingest_dead_letters    (EXT-1 06)
```

- 코어(audit/outbox/work_orders)가 가장 먼저. EXT-1/EXT-2 테이블은 코어를 FK 참조하지
  않으므로 상호 순서 자유.
- **레지스트리/카탈로그/EXT 메타데이터 모듈/애드온 5개는 마이그레이션 0개**(새 테이블 없음).
- 새 마이그레이션 추가 시 코어(`00000x`) 뒤 번호를 쓴다.

---

## 3. 통합 순서 (권장)

```text
[0] mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer   (로컬)

[1] 코어(02) 통합 — 토대
    a. lib/open_mes/{audit,outbox,production}/* 복사
    b. lib/open_mes_web/{controllers,plugs}/* 복사
    c. 마이그레이션 000001/2/3 복사
    d. mix ecto.create && mix ecto.migrate && mix test  (코어 단독 통과)

[2] 기반 작업(10, 이 디렉토리) — 확장 노출 토대
    a. lib/open_mes/extensions/{extension,definition,registry}.ex 복사
    b. lib/open_mes_web/live/catalog_live.ex 복사
    c. config/config.exs 에 :extensions 블록 병합(처음엔 [] 로 시작 가능)
    d. skel/router.ex 의 :browser 파이프라인 + / 카탈로그 scope 병합
    e. skel/application.ex 의 Telemetry/PubSub child(LiveView 필요) 확인
    f. mix phx.server → / 접속, 빈(또는 EXT 2개) 카탈로그 렌더 확인
    g. mix test (registry/catalog/extension 테스트 통과)

[3] EXT-1(06) 통합   — TimescaleDB 인프라 필요
    a. lib/open_mes_ingest/* + (10의) extension.ex 복사
    b. skel/application.ex 의 ingest_children, skel/router.ex 의 /ingest scope 적용
    c. 마이그레이션 100001/2/3 복사
    d. config :extensions 에 OpenMes.Ingest.Extension 확인(이미 config.exs 에 있음)

[4] EXT-2(07) 통합   — MinIO 인프라 필요
    a. lib/open_mes_media/* + (10의) extension.ex 복사
    b. skel/application.ex 의 media_children 적용
    c. 마이그레이션 000010 복사
    d. config :extensions 에 OpenMes.Media.Extension 확인

[5] 애드온 ①~⑤(§7-b, 별도 작업) — 서로 독립, §4 자리에 꽂음

[6] 전체 검증: mix test, / 접속 → 카드 확인(enabled 토글로 배지 변화)
```

---

## 4. 애드온 5개가 들어올 자리 (슬롯)

애드온(§7-b)은 동일한 `Extension` behaviour 로 카탈로그에 꽂힌다. 통합 시 **3곳**만 건드린다.

### 4-1. `config/config.exs` — `:extensions` 리스트에 한 줄 + 게이트 한 줄

```elixir
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  OpenMes.Addons.WoCsvExport.Extension,           # ← 추가
  OpenMes.Addons.DefectStats.Extension,           # ← 추가
  OpenMes.Addons.LotQrLabel.Extension,            # ← 추가
  OpenMes.Addons.EquipmentOee.Extension,          # ← 추가
  OpenMes.Addons.DailyProductionSummary.Extension # ← 추가
]

config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true   # 읽기 전용이라 기본 on 안전
# ... 나머지 4개 동일 ...
```

### 4-2. `lib/open_mes_web/router.ex` — 각 애드온 조건부 scope 블록

`skel/router.ex` 하단에 주석으로 5개 블록을 미리 표시해 두었다. 주석을 해제하면 된다.

```elixir
if OpenMes.Addons.DefectStats.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/defect-stats", DefectStatsLive, :index
  end
end
```

### 4-3. `lib/open_mes_addons/{addon}/` — 애드온 소스(별도 작업 산출물)

각 애드온: `extension.ex`(behaviour 구현) + 로직 모듈 + `live/` 1개 (+ ①만 다운로드 컨트롤러).
애드온은 **읽기 전용 + 새 테이블 0**. application.ex 에 child 추가 불필요(백그라운드 프로세스 없음).

> 애드온이 추가되면 카탈로그는 코드 변경 없이 자동으로 카드를 더 그린다
> (`Registry.all/0` 이 `:extensions` 리스트를 읽으므로).

---

## 5. pi / 비침투 준수 메모

- **레지스트리는 얇은 코어 유틸**: behaviour 정의 + config 리스트 조회 + 콜백 호출뿐.
  DB/상태/GenServer 없음. 마켓플레이스/설치/원격 다운로드 구조 **없음**.
- **의존 방향 단방향**: 코어 도메인(`OpenMes.Production`/`WorkOrder`/`Audit`/`Outbox`)은
  `OpenMes.Extensions.*` 를 참조하지 않는다. 레지스트리/카탈로그를 통째로 들어내도
  WorkOrder API 는 그대로 동작한다. (검증: `grep -r "OpenMes.Extensions" lib/open_mes/{production,audit,outbox}` → 0건이어야 함.)
- **EXT-1/EXT-2 무변경**: 메타데이터 모듈(`extension.ex`) 1개씩 추가 외에 기존 파이프라인
  코드는 손대지 않는다. `enabled?/0` 는 기존 게이트에 위임.
- **AuditLog/Outbox 무관**: 레지스트리/카탈로그/EXT 메타데이터는 도메인 쓰기가 0 → 감사 룰
  적용 대상 아님(설계 §6 — 오탐 금지).
