# 17. QA 감사 — MES 라운드2 (G3 LOT추적 / G4 현장 / G5 조회 / G6 관리자)

- **감사자**: qa-auditor
- **감사일**: 2026-06-13
- **대상**: `lib/open_mes_web/admin/lots/`, `lib/open_mes_web/shopfloor/`, `lib/open_mes_web/admin/reports/` + `lib/open_mes/production/reports.ex` · `lib/open_mes/lots/reports.ex`, `lib/open_mes_web/admin/system/`
- **기준**: `docs/domain-model.md`, `CLAUDE.md`, `_workspace/15_architect_mes_frontend_design.md`
- **최종 판정**: ✅ **APPROVED** (권고 1건 — 차단/수정필요 아님)

---

## 1. LOT Genealogy (G3/G4 핵심)

| 항목 | 결과 | 근거 |
|------|------|------|
| 자재 소비가 `consume_lot`(LotConsumption 경유)만인가 | ✅ | `lots.ex:160` `consume_lot/4`가 단일 Multi로 LotConsumption insert + 잔량 차감. UI(LotLive `save_consume` L69, ScanLive `consume` L69)도 모두 `Lots.consume_lot` 경유. 암묵 소비 경로 없음. |
| UI에서 직접 LOT quantity 변경 없는가 | ✅ | web 레이어 전체에 `Repo.*` 호출 0건(grep 확인). LotLive에 수량 직접 수정 폼 없음. 잔량 변경은 `consume_lot` 내부 `apply_consumption`(L248)에서만. |
| 초과소비 차단(UI+컨텍스트) | ✅ | 컨텍스트: `guard_consumption`(L239) `insufficient_lot_quantity` 반환. UI: LotLive L83·ScanLive L78에서 flash 처리. 테스트 `lots_test.exs:110` 커버. |
| 종료 상태(consumed/scrapped) 재소비 차단 | ✅ | `guard_consumption`(L235) + 테스트 `lots_test.exs:117`. |
| 제품 LOT `source_operation_id` 연결 | ✅ | `produce_lot`(L84)가 `source_operation_id` cast. LotLive `save_produce` 패널(L230)에서 공정 선택. 테스트 `lots_test.exs:124`. |
| genealogy 조회 정확 | ✅ | `genealogy/1`(L208): source_operation → LotConsumption → input_lot 조인. GenealogyLive(L43) 재귀 트리(max_depth 5, 순환 방어). 테스트 `lots_test.exs:124,143`. |

**소비 진실의 원천 = LotConsumption** 원칙 준수. MaterialLot.quantity 차감은 LotConsumption insert와 동일 트랜잭션에서만 발생.

## 2. 상태전이 (G4 현장)

| 항목 | 결과 | 근거 |
|------|------|------|
| 허용 전이만 버튼 노출 | ✅ | OperationLive `assign_op`(L62) `OperationStateMachine.allowed_from(op.status)`로 버튼 생성. 종료 상태는 빈 목록 → "종료된 작업입니다". |
| 컨텍스트 경유 | ✅ | `transition` 핸들러(L32)가 `Production.ready/start/pause/complete/skip_operation` 호출. web 직접 Repo 0. |
| 멱등/불법 거부 | ✅ | 컨텍스트 상태머신(transition_changeset) 거부 → `{:error, _}` flash. 매핑 외 값은 `:invalid_transition`(L43). |

## 3. 이력성 (G4 실적)

| 항목 | 결과 | 근거 |
|------|------|------|
| ProductionResult append-only (수정/삭제 UI 없음) | ✅ | ResultLive는 `create_production_result`(L37)만. 화면 안내 "정정 이력(append-only) — 새 실적으로 정정"(L97). 컨텍스트에 `update_/delete_production_result` 함수 부재(grep). |
| DefectRecord append-only | ✅ | `record_defect`(L67)만. update/delete 함수 부재. |
| LotConsumption append-only | ✅ | create_changeset만. update/delete 부재. |
| 도메인 전체 Repo.delete | ✅ | `lib/open_mes` 전체 `Repo.delete` 0건. |

## 4. 읽기 전용 (G5/G6)

| 항목 | 결과 | 근거 |
|------|------|------|
| 조회/대시보드/감사로그/사용자 화면 도메인 쓰기 0 | ✅ | `admin/reports`·`admin/system` 전체에 `Repo.insert/update/delete` 및 컨텍스트 쓰기함수(create_/consume_/produce_/record_/start_/complete_ 등) 호출 0건(grep). |
| 집계가 LotConsumption 경유(재고 소비) | ✅ | `Lots.Reports.consumed_by_item`(reports.ex:96) LotConsumption→input_lot.item_id 조인 합계. 상태집계는 MaterialLot. |
| 0 나눗셈 방어 | ✅ | `Production.Reports.decimal_ratio`(L180) 분모 0 → 0.0. `Lots.Reports` 단순 합계(나눗셈 없음). |
| 빈 데이터 방어 | ✅ | `coalesce(sum, 0)`, `normalize_good_defect(nil)`(L174), 모든 LiveView `.empty_state`/`.sf_empty` 처리. |

- AuditLogLive: `Audit.list_audit_logs` 경유, append-only 조회만.
- UserLive: `MasterData.list_workers` 경유. "작업자 수정" 링크는 기준정보 화면 navigate(쓰기 아님).

## 5. 컨텍스트 경유 일관성

| 항목 | 결과 | 근거 |
|------|------|------|
| web 레이어 직접 Repo 쓰기 없음 | ✅ | `admin`+`shopfloor` 전체 `Repo.` 0건(grep). |
| 쓰기 = 컨텍스트(Lots/Production) 경유 | ✅ | G3/G4 모든 쓰기 `Lots.*`/`Production.*` 함수 경유. AuditLog/Outbox/상태머신/LotConsumption 컨텍스트 내장. |
| 읽기 = Reports 모듈/컨텍스트 읽기함수 경유 | ✅ | G5 4화면 모두 `Reports.*`. lot_history는 `Lots.list_lots`. today/shopfloor는 `Production.*`/`MasterData.*`. web에 raw `from(...)` 쿼리 없음. |

## 6. 회귀 — mix test

```
Result: 359 passed, 4 skipped
Finished in 0.9 seconds
```
✅ **359 passed**(보고 숫자 일치), 0 failures. (경고는 미디어 애드온 `File.stream!/3` deprecation — 라운드2 무관, 기존 코드.)

## 7. 무손상 — 라운드1 라우트

✅ `router.ex` 확인: `/`·`/extensions`(CatalogLive), `/api`(WorkOrder API), `/api`+require_actor, `/ingest`, 애드온 5개 scope(wo-csv-export, defect-stats, lot-qr-label, equipment-oee, daily-production-summary, 각 `enabled?` 게이트), `/admin` 기준정보(items/boms/processes/routings/equipment/workers)·생산관리(work-orders) 전부 유지. G3~G6은 **scope 추가만**(`/admin/lots`, `/admin/reports/*`, `/admin/dashboard`, `/admin/audit-logs`, `/admin/users`, `/shopfloor/*`)으로 충돌 없음. 컴파일/테스트 green이 무손상 입증.

---

## 권고 사항 (⚠️ 비차단 — 추적용)

### R-1. `consume_lot` 완전소비 시 상태머신 우회 — 코드/정의 불일치
- **위치**: `lib/open_mes/lots/lots.ex:248-265` `apply_consumption/2`
- **현상**: 잔량 0 도달 시 `available`/`produced` 상태에서 `transition_changeset`(상태머신 검증)을 거치지 않고 `Ecto.Changeset.change(changeset, status: "consumed")`로 직접 전이. 상태머신(`material_lot_state_machine.ex`)은 `reserved → consumed`만 허용하고 `available→consumed`·`produced→consumed`는 불허로 정의됨(`material_lot_state_machine_test.exs:19`도 `refute available→consumed`).
- **평가**: **의도된 설계**(주석 L254-256 명시) + 테스트 `lots_test.exs:100` green으로 커버. 데이터 무결성은 안전 — 소비 진실의 원천은 LotConsumption이고, 잔량 차감/마감은 가드 통과 후에만 발생하므로 genealogy·재고 집계 정확성에 영향 없음.
- **불일치점**: "허용 전이만 코드화" 원칙(설계 §0.3)과 상태머신 정의 간 표면적 모순이 코드에 잔존. 소비를 audit가 `lot.consume` 액션으로 남기므로 추적성은 유지되나, 상태머신 표가 실제 전이를 완전히 기술하지 못함.
- **권고(택1, 후속)**:
  1. 상태머신 `@transitions`에 `available → consumed`, `produced → consumed` 추가(소비 마감 경로 명시) — 가장 단순.
  2. 또는 `apply_consumption`이 잔량 0일 때 내부적으로 reserved 경유 없이 `consumed` 마감하는 현 동작을 상태머신 헬퍼(`finalize_consumed`)로 분리해 "소비 마감은 전이표 예외"임을 명시.
- **우선순위**: Low. 동작·테스트·무결성 모두 정상이므로 즉시 수정 불요.

---

## 최종 판정: ✅ APPROVED

- LOT Genealogy(LotConsumption 경유·초과소비 차단·source_operation 연결·genealogy 조회), 상태전이(허용 전이만·컨텍스트 경유), 이력성(append-only), 읽기전용(G5/G6 쓰기 0·집계 LotConsumption 경유·방어로직), 컨텍스트 경유 일관성 **전부 충족**.
- `mix test` 359 passed 0 failed. 라운드1 라우트 무손상.
- 비차단 권고 R-1(상태머신 표와 완전소비 마감 경로의 표면적 불일치) 1건 — 데이터 무결성·테스트 정상이므로 후속 정리 권고.
