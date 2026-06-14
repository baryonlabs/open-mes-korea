# 13 QA 감사 — Phoenix 통합 패키지 정적 정확성 검증

- 대상: `_workspace/13_integration_package/` 전체
- 대조 원본: 02 / 06 / 07 / 10 / 11_addon_* 실제 파일 (grep 교차 대조)
- 검증 방식: merge_files 선언값 ↔ 각 산출물 실제 `defmodule`/`home_path`/config 키/마이그레이션 파일명 1:1 대조
- 날짜: 2026-06-13
- 컴파일 검증: 불가(환경에 elixir/mix 없음). 정적 일치성만 검증.

---

## 최종 판정: APPROVED ✅ (조건부 — ⚠️ 1건 권고)

7개 :extensions 모듈명, integrate.sh 경로 매핑, 마이그레이션 순서, router↔home_path,
deps 정합, config 게이트, 코어 비침투 모두 일치. 실행을 깨는 불일치(❌) 없음.
⚠️ 1건은 컴파일/실행에 영향 없는 파일 배치 컨벤션 불일치이므로 차단 사유 아님.

---

## 항목 1 — 7개 :extensions 모듈명 정확성 (가장 중요) ✅

`merge_files/config.exs` L21-31 `:extensions` 목록 ↔ 각 산출물 실제 `defmodule` 대조:

| config.exs 선언 | 실제 defmodule (파일:줄) | 결과 |
|---|---|---|
| `OpenMes.Ingest.Extension` | `10_registry_catalog_impl/lib/open_mes_ingest/extension.ex:1` | ✅ |
| `OpenMes.Media.Extension` | `10_registry_catalog_impl/lib/open_mes_media/extension.ex:1` | ✅ |
| `OpenMes.Addons.WoCsvExport.Extension` | `11_addon_wo_csv_export/.../wo_csv_export/extension.ex:1` | ✅ |
| `OpenMes.Addons.DefectStats.Extension` | `11_addon_defect_stats/.../defect_stats/extension.ex:1` | ✅ |
| `OpenMes.Addons.LotQrLabel.Extension` | `11_addon_lot_qr_label/.../lot_qr_label/extension.ex:1` | ✅ |
| `OpenMes.Addons.EquipmentOee.Extension` | `11_addon_equipment_oee/.../equipment_oee/extension.ex:1` | ✅ |
| `OpenMes.Addons.DailyProductionSummary.Extension` | `11_addon_daily_summary/.../daily_production_summary/extension.ex:1` | ✅ |

7/7 정확 일치. 특히 ⑤는 디렉토리명이 `daily_summary`인데 모듈은 `DailyProductionSummary`로 정확히 선언됨(혼동 포인트인데 맞게 적힘).

---

## 항목 2 — integrate.sh 경로 매핑 ✅

- **소스→타겟 매핑**: 02/06/07/10/11 각 lib 서브디렉토리(audit/outbox/production/extensions/open_mes_ingest/open_mes_media/open_mes_addons + open_mes_web 하위)와 실제 디렉토리 구조 일치.
- **patches/skel/snippet/CORE_PATCH/README 제외**: EXCLUDES에 `--exclude='skel/'`, `--exclude='patches/'`, `--exclude='config/'`, `--exclude='*.md'`(README/CORE_PATCH.md/INTEGRATION.md/*.snippets.md 전부 포함), `--exclude='*.snippets.md'` 명시 → lib 복사 대상에서 제외됨. ✅
- **router.ex 미복사**: 02만 자체 `router.ex` 보유. integrate.sh가 `lib/open_mes_web`를 통째로 복사하지 않고 `controllers/`·`plugs/`만 개별 복사 → router.ex 미복사(L기준 [1] 블록 NOTE 일치). ✅ (06/07/10/11엔 router.ex 없음 확인)
- **테스트 마이그레이션 누수 없음**: 애드온 운영 마이그레이션 0개(`find 11_addon_* -path "*priv/repo/migrations*"` → 빈 결과). 테스트 임시 테이블(`daily_summary` migration, `defect_stats_tables.exs`)은 `test/support/` 하위에만 존재 → integrate.sh `test/support` 복사로만 이동, `priv/repo/migrations`로 새지 않음. ✅
- **멱등성**: `rsync -a` 사용, 파괴적 `rm`/`mv` 없음, `mkdir -p` + trailing-slash 병합 → 반복 실행 안전. ✅

---

## 항목 3 — 마이그레이션 순서/의존성 ✅

MIGRATION_ORDER.md 표 ↔ 실제 파일명(`find ... priv/repo/migrations`) 대조:

| 순서 | MIGRATION_ORDER 타임스탬프 | 실제 파일 | 결과 |
|---|---|---|---|
| 1 | 20260613000001_create_audit_logs | 02/.../20260613000001_create_audit_logs.exs | ✅ |
| 2 | 20260613000002_create_outbox_events | 02/.../20260613000002_create_outbox_events.exs | ✅ |
| 3 | 20260613000003_create_work_orders | 02/.../20260613000003_create_work_orders.exs | ✅ |
| 4 | 20260613000010_create_media_assets | 07/.../20260613000010_create_media_assets.exs | ✅ |
| 5 | 20260613100001_enable_timescaledb | 06/.../20260613100001_enable_timescaledb.exs | ✅ |
| 6 | 20260613100002_create_equipment_measurements | 06/.../20260613100002_create_equipment_measurements.exs | ✅ |
| 7 | 20260613100003_create_ingest_dead_letters | 06/.../20260613100003_create_ingest_dead_letters.exs | ✅ |

- **timescaledb(5) < equipment_measurements hypertable(6)**: 타임스탬프 `100001 < 100002` → Ecto 오름차순 실행에서 확장 생성이 hypertable보다 먼저. ✅
- 파일 타임스탬프 실제 순서와 표 순서 모순 없음. 애드온/레지스트리 운영 마이그레이션 0개 명시도 실제와 일치. ✅

---

## 항목 4 — router 경로 ↔ home_path 일치 ✅

`merge_files/router.ex` 라우트 ↔ 각 extension.ex `home_path/0` 대조:

| 확장 | home_path (실제 extension.ex) | router 라우트 (router.ex:줄) | 결과 |
|---|---|---|---|
| EXT-1 Ingest | `/ingest/health` | `scope "/ingest"` + `get "/health"` (L67-72) → `/ingest/health` | ✅ |
| EXT-2 Media | `home_path` 기본 nil(자체 화면 없음) | 라우트 없음(L74 주석) | ✅ |
| ① WoCsvExport | `/extensions/wo-csv-export` | `live "/wo-csv-export"` (L79) | ✅ |
| ② DefectStats | `/extensions/defect-stats` | `live "/defect-stats"` (L89) | ✅ |
| ③ LotQrLabel | `/extensions/lot-qr-label` | `live "/lot-qr-label"` (L98) | ✅ |
| ④ EquipmentOee | `/extensions/equipment-oee` | `live "/equipment-oee"` (L107) | ✅ |
| ⑤ DailyProductionSummary | `/extensions/daily-production-summary` | `live "/daily-production-summary"` (L118) | ✅ |

- **EXT-1 `/ingest/health` 06 라우트 실존 확인**: `06/.../ingest_controller.ex:47` `def health/2` 존재, router의 `get "/health" -> IngestController, :health` 매핑됨. ✅
- **⑤ 경로 교정(domain-engineer 보고) 확인**: router.ex L112-113 주석이 "10/skel router는 /daily-summary로 표기했으나 실제는 /daily-production-summary"라고 명시하고 L118에서 `/daily-production-summary`로 교정 적용 → home_path와 일치. ✅ 교정 정확.
- **router LiveView/Controller 모듈명**: `WoCsvExportLive/WoCsvExportController/DefectStatsLive/LotQrLabelLive/EquipmentOeeLive/DailyProductionSummaryLive/CatalogLive/IngestController/WorkOrderController` 모두 실제 `defmodule`로 존재 확인. ✅

---

## 항목 5 — deps 버전 정합 ✅

`merge_files/mix.deps.exs` ↔ 각 산출물 실제 라이브러리 사용 대조:

| dep | 선언 | 실제 사용처 | 결과 |
|---|---|---|---|
| `broadway ~> 1.1` | O | 06 pipeline.ex/buffer_producer.ex/loader.ex/ingest.ex (`Broadway`) | ✅ |
| `ex_aws ~> 2.5` + `ex_aws_s3` | O | 07 s3_object_store.ex (`ExAws`) | ✅ |
| `sweet_xml ~> 0.7` | O | ex_aws_s3 XML 파싱 트랜스이티브 의존(표준) | ✅ |
| `hackney ~> 1.20` | O | ex_aws HTTP 클라이언트(표준) | ✅ |
| `file_system ~> 1.0` | O | 07 watch/scanner.ex(FS 감시) | ✅ |
| `eqrcode ~> 0.2` | O | 11_addon_lot_qr_label/lot_qr_label.ex:184-185 (`EQRCode.encode/svg`) | ✅ |
| `nimble_csv` | **미선언** | 사용처 없음. wo_csv는 `IO.iodata_to_binary` 직접 인코딩(controller:31). 11_addon_wo_csv config.snippets.md:63·README:98이 "nimble_csv 미도입" 명시 | ✅ 올바르게 제외 |

- 애드온 ②④⑤·레지스트리/카탈로그: 추가 deps 0(순수 Ecto/LiveView) → 정확히 추가 안 함. ✅

---

## 항목 6 — application.ex / config 게이트 ✅

- **ingest/media child 조건부**: `application.ex` `ingest_children/0`(L_if `OpenMes.Ingest.enabled?()`), `media_children/0`(if `OpenMes.Media.enabled?()`) → 코어 children 뒤에 `++ ingest_children() ++ media_children()`. 비활성 시 빈 리스트 → 코어만 기동. ✅
- **child 모듈 실존**: `OpenMes.Ingest.Pipeline`, `OpenMes.Media.Transfer.TransferSupervisor`, `OpenMes.Media.Watch.Scanner`, `OpenMes.Media.Transfer.Dispatcher` 모두 실제 `defmodule` 존재. 기동 순서(TransferSupervisor→Scanner→Dispatcher) 주석대로 배치. ✅
- **게이트 키 정합** (config.exs/dev.exs/runtime.exs ↔ 각 enabled?/0 읽는 키):
  - `OpenMes.Ingest`: ingest.ex `config()`가 `Application.get_env(:open_mes, __MODULE__=OpenMes.Ingest)` → config 키 `config :open_mes, OpenMes.Ingest` 일치 ✅
  - `OpenMes.Media`: media.ex `@config_key {:open_mes, __MODULE__=OpenMes.Media}` → `config :open_mes, OpenMes.Media` 일치 ✅
  - 애드온 5종: 각 퍼사드 `Application.get_env(:open_mes, __MODULE__)` (`OpenMes.Addons.WoCsvExport`/`DefectStats`/`LotQrLabel`/`EquipmentOee`/`DailyProductionSummary`) → config 키 5개 모두 동일 모듈명으로 일치 ✅
- **기본값 정책 일관**: config.exs는 ⑤만 off·나머지 on, runtime.exs ENV 기본값(`DAILY_SUMMARY_ENABLED` 기본 false, 나머지 true), dev.exs는 ⑤ 포함 전부 on — 3파일 모두 모순 없음. 기본 `enabled: false`(미설정 시) fallback도 각 facade에 존재. ✅
- **코어 무확장 동작**: 기본 config에서 EXT-1/2 enabled:false → application.ex 빈 리스트 → 코어만 기동. router `/api` scope는 확장 게이트 밖 무조건 등록. ✅

---

## 항목 7 — 코어 비침투 유지 ✅

- application.ex: 코어 children 리스트는 그대로, `++ ingest/media_children()`만 append. 애드온/레지스트리는 supervised child 추가 안 함(주석대로 상태 없는 조회 모듈). ✅
- router.ex: `/api` 코어 scope는 확장 enabled와 무관하게 항상 등록. 확장 scope만 컴파일타임 `if enabled?()` 게이트. ✅
- 코어 코드를 확장에 의존하게 바꾼 흔적 없음(통합은 파일 배치 + 게이트 배선뿐). ✅

---

## ⚠️ 권고 사항 (차단 아님)

**W-1. 애드온 LiveView 파일 배치 컨벤션 불일치 (⚠️, 실행 영향 없음)**

- `defect_stats`/`equipment_oee`/`daily_summary`의 LiveView는 `lib/open_mes_web/live/addons/*.ex`에 위치.
- 그러나 `wo_csv_export`/`lot_qr_label`의 LiveView는 `lib/open_mes_addons/.../live/`에 위치:
  - `11_addon_wo_csv_export/lib/open_mes_addons/wo_csv_export/live/export_live.ex` (module `OpenMesWeb.Addons.WoCsvExportLive`)
  - `11_addon_lot_qr_label/lib/open_mes_addons/lot_qr_label/live/lot_qr_label_live.ex` (module `OpenMesWeb.Addons.LotQrLabelLive`)
- **영향 분석**: integrate.sh 애드온 루프가 `lib/open_mes_addons`와 `lib/open_mes_web/live/addons`를 **둘 다** 복사하므로 5개 LiveView 파일 모두 타겟에 도착함. Elixir는 모듈을 경로가 아닌 이름으로 해석하므로 router의 `WoCsvExportLive`/`LotQrLabelLive` 참조도 정상 해석됨 → **컴파일/실행 깨지지 않음**.
- 권고: 일관성/유지보수성을 위해 후속에서 wo_csv·lot_qr LiveView도 `lib/open_mes_web/live/addons/`로 이동 검토(현재 패키지 실행에는 무영향이므로 차단하지 않음).

---

## 검증 메타

- 모든 모듈명/경로/순서는 grep으로 실제 파일에서 추출해 대조함(merge_files 선언값을 신뢰하지 않고 원본 대조).
- 컴파일 검증 불가 환경이므로, 정적 일치성 100% 확인 후에도 최초 `mix compile` / `mix ecto.migrate`는 사용자가 실행해 확인 권장(INTEGRATION_GUIDE Step 0 동일 안내).
