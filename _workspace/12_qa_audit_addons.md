# 12. QA 감사: MES 도메인 애드온 5개 (읽기 전용 검증)

- **감사자**: qa-auditor
- **감사일**: 2026-06-13
- **대상**: 애드온 5개 (`_workspace/11_addon_*`)
- **기준**: `_workspace/10_.../extension.ex`(behaviour 계약), `_workspace/09_architect_registry_catalog_design.md`(§2 명세, §6 검증 포인트), `CLAUDE.md`(pi 원칙)
- **감사 범위**: 읽기 전용 불변식 / Extension 준수 / 코어 비침투 / 엣지케이스 / 카탈로그 노출 / pi 최소. (AI 안전은 범위 외 — ai-safety-guardian 담당)

> **오탐 금지 적용(설계 §6, 검증요청 7)**: 5개 모두 읽기 전용이므로 AuditLog/Outbox/LotConsumption 부재는 **의도된 설계**다. 위반으로 지적하지 않았다.

---

## 핵심 발견 요약

- **읽기 전용 불변식: 5개 전부 ✅**. lib/ 전체에서 `Repo.insert/update/delete/transaction`, `Multi`, 쓰기용 `changeset/cast/put_change`가 **실코드 0건**(매칭된 키워드는 전부 주석/문서). Repo 호출은 `Repo.get/one/all`(SELECT)만.
- **③ LOT QR 구조적 쓰기 차단 ✅**: `MaterialLot` 읽기 전용 스키마가 **changeset 미제공** → `Repo.insert/update`의 입력이 될 수 없다. LOT status 변경 경로가 코드 구조상 존재하지 않음.
- **코어 비침투 ✅**: 코어 파일 수정 0, 모든 코드 `lib/open_mes_addons/{addon}/`·`lib/open_mes_web/(live/addons|controllers)/`에 격리. **운영 마이그레이션 0개**(⑤의 test/support 마이그레이션은 코어 테이블의 테스트 지원용, `create_if_not_exists`, 통합 시 삭제 명시 — 운영 아님).
- **엣지케이스 방어 ✅**: ②불량률·④OEE 0 나눗셈, ⑤날짜 경계, 결측/Repo 미가용 degrade 모두 크래시 없이 처리. 계산 로직이 순수 함수로 분리(④ Calculator, ② defect_rate/ratio, ⑤ day_bounds/defect_rate)되어 DB 없이 테스트 고정.
- **pi 최소 ✅**: 외부 deps는 ③ `eqrcode`(경량 1개, 허용) 뿐. ① CSV는 직접 인코딩(deps 0). 차트/BI 라이브러리 미도입.
- **유일한 지적(⚠️ 경미)**: ⑤ id/home_path가 설계 §7.b-5 표기(`:addon_daily_summary` / `/extensions/daily-summary`)와 다름(`:addon_daily_production_summary` / `/extensions/daily-production-summary`). 안전·정합성 결함 아님(모듈명 `DailyProductionSummary`와 일치, 내부 정합·고유). 표기 통일 권고.

---

## 애드온별 검증 표

### ① WoCsvExport — 작업지시 CSV 내보내기

| 항목 | 결과 | 근거 |
|------|------|------|
| 읽기 전용 (쓰기 0) | ✅ | `csv.ex` 순수 직렬화, 퍼사드는 `Production.list_work_orders/1` 읽기 재사용. controller `download/2`는 `send_download`만. Repo 쓰기 0 |
| Extension behaviour | ✅ | `extension.ex` 6 콜백 + `home_path` 구현, `use OpenMes.Extensions.Definition`, id `:addon_wo_csv_export`(설계 일치·고유) |
| 코어 비침투 | ✅ | `lib/open_mes_addons/wo_csv_export/`·`lib/open_mes_web/controllers/wo_csv_export_controller.ex`. 코어 수정 0, 새 테이블 0 |
| 엣지케이스 | ✅ | RFC 4180 이스케이프 정확(`escape_field`), nil 셀/빈 목록→헤더만, Decimal/Date/DateTime 타입별 안전 변환 |
| 카탈로그 노출 | ✅ | `config/config.snippets.md`에 `:extensions` 등록 + enabled 게이트 명시 |
| pi 최소 | ✅ | NimbleCSV 미도입(직접 인코딩), 추가 deps 0 |
| 게이트 방어 | ✅ | controller가 비활성 시 404(라우터 컴파일 게이트 + 런타임 이중 방어) |

**판정: APPROVED**

### ② DefectStats — 불량 통계 위젯

| 항목 | 결과 | 근거 |
|------|------|------|
| 읽기 전용 (쓰기 0) | ✅ | `stats.ex` `Repo.one/all`만. `schemas.ex` 읽기 전용 스키마(changeset 없음) |
| Extension behaviour | ✅ | 6 콜백 + `home_path`, `use Definition`, id `:addon_defect_stats`(일치·고유), category `:quality` |
| 코어 비침투 | ✅ | `lib/open_mes_addons/defect_stats/`·`web/live/addons/`. 새 테이블 0(test/support/defect_stats_tables.exs는 테스트 지원) |
| 엣지케이스 (0 나눗셈) | ✅ | `defect_rate/2`·`ratio/2` 분모 0/음수/비수치 → `0.0`(raise/NaN 금지). `coalesce(sum,0)`로 nil 합계 방어. 0건 기간 안전 |
| 카탈로그 노출 | ✅ | `INTEGRATION.md`/`README.md`에 `:extensions` 등록 스니펫 |
| pi 최소 | ✅ | CSS 바(차트 라이브러리 미도입), deps 0 |

**판정: APPROVED**

### ③ LotQrLabel — LOT QR 라벨 생성

| 항목 | 결과 | 근거 |
|------|------|------|
| 읽기 전용 (쓰기 0) | ✅ | 퍼사드 `Repo.get/one/all`만. **LOT 상태 변경 코드 0** |
| **구조적 쓰기 차단** | ✅ | `material_lot.ex` 읽기 전용 스키마 — **changeset 미제공** → `Repo.insert/update/delete` 입력 불가(구조적 차단). LOT status 전이 경로 부재 |
| Extension behaviour | ✅ | 6 콜백 + `home_path`, `use Definition`, id `:addon_lot_qr_label`(일치·고유), category `:traceability` |
| 코어 비침투 | ✅ | `lib/open_mes_addons/lot_qr_label/`. 코어 LOT 스키마 수정 0, 새 테이블 0 |
| 엣지케이스 | ✅ | `qr_payload` nil/빈 lot_no 처리, `fetch` 미존재→nil, ILIKE 와일드카드(`%_\`) 이스케이프(`escape_like`) |
| 카탈로그 노출 | ✅ | `README.md`에 `:extensions` 등록 + enabled + router 스니펫 |
| pi 최소 | ✅ | `eqrcode` 경량 1개(설계 허용 범위), 그 외 deps 0. eqrcode가 다른 애드온에 누출 없음 |

**판정: APPROVED** — 설계 §6 핵심 불변식("LotQrLabel이 MaterialLot status/데이터를 변경하지 않는지") 충족. QR은 식별자(`OPENMES:LOT:<lot_no>`)만 인코딩(가변 status 미포함).

### ④ EquipmentOee — 설비 가동률 OEE

| 항목 | 결과 | 근거 |
|------|------|------|
| 읽기 전용 (쓰기 0) | ✅ | `oee.ex` `repo.all`만. `read_models.ex` 읽기 전용 스키마(changeset 없음) |
| Extension behaviour | ✅ | 6 콜백 + `home_path`, `use Definition`, id `:addon_equipment_oee`(일치·고유), category `:analytics` |
| 코어 비침투 | ✅ | `lib/open_mes_addons/equipment_oee/`·`web/live/addons/`. 새 테이블 0 |
| 엣지케이스 (0 나눗셈) | ✅ | `Calculator`: 계획시간/실가동 0·음수·결측→`nil`, 총생산 0→품질 `nil`, 한 요소 nil→OEE nil, 비율 0.0~1.0 클램프. `to <= from`→빈 목록 |
| 순수 함수 분리/degrade | ✅ | `Calculator.compute/1` 순수(DB 무관, 테스트 고정). `Oee.by_equipment`가 `opts[:repo]` 주입 지원(Repo 미가용 테스트 degrade) |
| 카탈로그 노출 | ✅ | `addon_equipment_oee.snippets.md`/`README.md`에 `:extensions` 등록 |
| pi 최소 | ✅ | MVP 근사(가동률+품질률), 정밀 OEE는 EXT-4로 미룸. deps 0 |

**판정: APPROVED**

### ⑤ DailyProductionSummary — 일일 생산 요약

| 항목 | 결과 | 근거 |
|------|------|------|
| 읽기 전용 (쓰기 0) | ✅ | `summary.ex` `Repo.one/all` + `Production.list_work_orders/1` 읽기. `schemas.ex` 읽기 전용(changeset 없음) |
| Extension behaviour | ✅ | 6 콜백 + `home_path`, `use Definition`. **id 표기 불일치(⚠️ 아래)** — 단 고유성·정합성은 충족 |
| 코어 비침투 | ✅ | `lib/open_mes_addons/daily_production_summary/`·`web/live/addons/`. **운영 마이그레이션 0** |
| 테스트 지원 마이그레이션 구분 | ✅ | `test/support/migrations/2026..._create_daily_summary_read_tables.exs` — 코어 items/operations/production_results를 `create_if_not_exists`로 테스트에서만 생성, 통합 시 삭제 명시. **운영 테이블 아님**(설계 §4.6, 검증요청 3 구분 적용) |
| 엣지케이스 (날짜 경계) | ✅ | `day_bounds/2` 반열린 구간 `[date 00:00, 다음날 00:00)`(자정 이중집계 방지), TZ DB 부재→UTC 폴백(raise 없음). 데이터 없는 날→빈 요약. `defect_rate` 분모 0→0.0 |
| 순수 함수 분리 | ✅ | `day_bounds/2`·`defect_rate/2` 순수 분리 |
| 카탈로그 노출 | ✅ | `config/config.snippets.md`/`README.md`에 `:extensions` 등록 |
| pi 최소 | ✅ | 집계 쿼리 + 카드, deps 0 |

**⚠️ 경미 (수정 권고, 차단 아님)**
- **위치**: `lib/open_mes_addons/daily_production_summary/extension.ex:15` (`def id, do: :addon_daily_production_summary`), `:35` (`def home_path, do: "/extensions/daily-production-summary"`)
- **내용**: 설계 §7.b-5는 id `:addon_daily_summary`, home_path `/extensions/daily-summary`로 표기. 구현은 모듈명(`DailyProductionSummary`)에 맞춰 풀네임 사용. 설계 §1.2/§5의 **모듈명**과는 일치하며, id 고유·라우터/config/home_path 내부 정합은 유지된다.
- **영향**: 기능/안전 결함 없음. 카탈로그 "열기" 링크 정상 동작(router 스니펫·home_path 일치).
- **수정 방법(택1)**: (a) 설계 표기에 맞추려면 id를 `:addon_daily_summary`, home_path를 `/extensions/daily-summary`로 변경하고 router scope 경로도 동기화. (b) 현 표기를 유지하려면 설계 §7.b-5의 id/home_path를 풀네임으로 정정(모듈명과 일관). **권고: (b)** — 모듈명·디렉토리와 일관되어 더 명확.

**판정: APPROVED (경미 권고 1건 — 차단 아님)**

---

## 종합 판정

| 애드온 | 읽기전용 | Extension | 비침투 | 엣지케이스 | 카탈로그 | pi | 판정 |
|--------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| ① WoCsvExport | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **APPROVED** |
| ② DefectStats | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **APPROVED** |
| ③ LotQrLabel | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **APPROVED** |
| ④ EquipmentOee | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | **APPROVED** |
| ⑤ DailyProductionSummary | ✅ | ⚠️ | ✅ | ✅ | ✅ | ✅ | **APPROVED** (경미 권고 1) |

### 전체 최종 판정: **APPROVED**

5개 애드온 모두 읽기 전용 불변식(쓰기 0, 코어 LOT/도메인 무변경), 코어 비침투(코어 수정 0, 운영 마이그레이션 0), Extension 계약, 엣지케이스 방어, pi 최소를 충족한다. 설계 §6의 핵심 검증 축("애드온은 코어를 읽기만, AuditLog 룰의 새 적용 대상 없음")이 코드로 실현됨. 유일한 지적(⑤ id 표기)은 안전·정합성 결함이 아닌 문서-코드 표기 통일 권고이므로 병합 차단 사유 아님.

> **차단(BLOCKED) 0건, NEEDS_FIX 0건.** ⑤ 표기 정합은 후속 정리 항목으로 architect/domain-engineer에 전달 권고.
