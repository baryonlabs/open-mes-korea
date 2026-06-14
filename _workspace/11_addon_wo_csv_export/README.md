# 11. 애드온 ① 작업지시 CSV 내보내기 (WoCsvExport)

설계 `09_architect_registry_catalog_design.md` **§2 애드온 ①** / **§7-b**의 구현물이다.
작고 독립적인 **읽기 전용** MES 도메인 애드온. 작업지시(WorkOrder) 목록을 상태/기간 필터로
조회해 CSV 파일로 내려받는다.

> 기반작업(10, 레지스트리/카탈로그/Phoenix 골격) 위에 꽂힌다. 코어 파일 수정 0개,
> 새 DB 테이블 0개, 추가 deps 0개.

---

## 파일 구조

```text
11_addon_wo_csv_export/
├── lib/
│   ├── open_mes_addons/
│   │   ├── wo_csv_export.ex                  # 퍼사드: enabled?/0 게이트 + to_csv/1 + filename/1
│   │   └── wo_csv_export/
│   │       ├── extension.ex                  # Extension behaviour 구현(메타데이터 6+home_path)
│   │       ├── csv.ex                        # CSV 직렬화(RFC 4180 이스케이프, deps 0, 순수 함수)
│   │       └── live/
│   │           └── export_live.ex            # OpenMesWeb.Addons.WoCsvExportLive (필터 폼 + 미리보기)
│   └── open_mes_web/
│       └── controllers/
│           └── wo_csv_export_controller.ex   # OpenMesWeb.Addons.WoCsvExportController (send_download)
├── config/
│   └── config.snippets.md                    # config/router 병합 스니펫(실제 파일은 기반작업이 관리)
└── test/
    └── open_mes_addons/wo_csv_export/
        ├── csv_test.exs                       # CSV 정확성(헤더/행/이스케이프) — DB 불필요
        ├── extension_test.exs                 # behaviour 준수 + enabled? 게이트
        ├── wo_csv_export_test.exs             # 퍼사드 filename/enabled?(DB 불필요)
        └── integration_test.exs              # to_csv 필터 + 컨트롤러(앱 통합 후, :integration 태그)
```

---

## 모듈 역할

| 모듈 | 계층 | 역할 |
|------|------|------|
| `OpenMes.Addons.WoCsvExport` | 도메인(퍼사드) | `enabled?/0`(config 게이트), `to_csv/1`(필터→조회→CSV), `filename/1`. 필터 화이트리스트 정리. |
| `OpenMes.Addons.WoCsvExport.Csv` | 도메인(순수) | 작업지시 목록 → CSV iodata. RFC 4180 이스케이프(쉼표/따옴표/개행), 상태 한국어 라벨, CRLF. **외부 라이브러리 없음**. |
| `OpenMes.Addons.WoCsvExport.Extension` | 메타데이터 | `Extension` behaviour 구현. 카탈로그 카드용 메타(id/name/description/category/version/enabled?/home_path). |
| `OpenMesWeb.Addons.WoCsvExportLive` | 웹(LiveView) | 상태/납기일 필터 폼 + 실시간 건수 미리보기 + "CSV 다운로드" 링크. |
| `OpenMesWeb.Addons.WoCsvExportController` | 웹(컨트롤러) | `download/2` — 필터로 CSV 생성 후 `send_download`(첨부). LiveView 는 파일을 직접 못 보내므로 분리. |

---

## 코어 의존(읽기 전용)

- `OpenMes.Production.list_work_orders/1` — **공개 조회 함수**만 호출(설계 §2 읽기 경로 재사용).
  status / item_id / due_date / limit / offset 필터 지원.
- `OpenMes.Production.WorkOrder` — 스키마 alias(읽기 행 매핑용). **쓰기/스키마 변경 없음**.

> **"품목" 컬럼 주의**: 현재 코어에 `Item` 스키마/`items` 테이블이 없다(WorkOrder.item_id 는
> 단순 binary_id, `work_order.ex` L26-27). 따라서 "품목" 컬럼은 현재 `item_id` 값을 출력한다.
> 추후 Item 조인이 생기면 `Csv.work_order_to_row/1` 의 품목 추출만 교체하면 된다(다른 코드 무변경).

---

## CSV 출력 명세

- 컬럼(설계 §2): `작업지시번호, 품목, 계획수량, 납기일, 상태, 생성일`.
- 인코딩: UTF-8, 행 구분자 CRLF(`\r\n`), 빈 목록도 헤더 행 포함.
- 이스케이프(RFC 4180): 필드에 `, " \r \n` 중 하나라도 있으면 따옴표로 감싸고 내부 `"` 는 `""` 로 이중화.
- 상태 라벨: draft→초안, released→확정, in_progress→진행중, completed→완료, cancelled→취소.
- 파일명: `work_orders_YYYYMMDD_HHMMSS.csv`.

---

## 통합 슬롯 (코어 3곳 — `config/config.snippets.md` 참조)

1. **`config/config.exs`** — `:extensions` 리스트에 `OpenMes.Addons.WoCsvExport.Extension` 추가
   + 게이트 `config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true`.
2. **`config/test.exs`** — 테스트 게이트 `enabled: true`.
3. **`lib/open_mes_web/router.ex`** — 조건부 scope(애드온 enabled 시 컴파일 타임 등록):
   ```elixir
   if OpenMes.Addons.WoCsvExport.Extension.enabled?() do
     scope "/extensions", OpenMesWeb.Addons do
       pipe_through :browser
       live "/wo-csv-export", WoCsvExportLive, :index
       get "/wo-csv-export/download", WoCsvExportController, :download
     end
   end
   ```

> 카탈로그는 코드 변경 없이 카드를 자동으로 더 그린다(`Registry.all/0` 이 `:extensions` 를 읽음).

---

## 비침투 / pi 준수

- **읽기 전용**: 코어 데이터는 Repo 읽기(공개 함수)만. 쓰기/DELETE/AuditLog/Outbox 없음 →
  감사 룰 적용 대상 아님(설계 §6 — 오탐 금지).
- **코어 비침투**: 코어 파일 수정 0. `lib/open_mes_addons/wo_csv_export/` 로 격리.
- **새 테이블 0 / 새 마이그레이션 0 / 추가 deps 0**(CSV 직접 인코딩, `nimble_csv` 미도입).
- **코드 주석/UI 텍스트 한국어, 식별자 영문**.

---

## 테스트 실행

```bash
# 순수 단위(DB 불필요) — CSV 정확성/behaviour/게이트
mix test test/open_mes_addons/wo_csv_export/csv_test.exs \
         test/open_mes_addons/wo_csv_export/extension_test.exs \
         test/open_mes_addons/wo_csv_export/wo_csv_export_test.exs

# 통합(앱 통합 + work_orders 테이블 필요) — to_csv 필터/컨트롤러
mix test --include integration test/open_mes_addons/wo_csv_export/integration_test.exs
```
