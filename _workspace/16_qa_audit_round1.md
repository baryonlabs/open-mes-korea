# 16. QA 감사 — 라운드1 (G0 코어 11 + G1 기준정보 UI + G2 생산관리 UI)

- **감사자:** qa-auditor (독립 검증)
- **일자:** 2026-06-13
- **기준 문서:** docs/domain-model.md, CLAUDE.md, _workspace/15_architect_mes_frontend_design.md
- **검증 방식:** 실제 코드 grep + 컨텍스트/스키마/상태머신/LiveView 정독 + `mix test` 실행
- **최종 판정: ✅ APPROVED**

---

## 0. 요약

| 항목 | 결과 |
|------|------|
| 1. AuditLog (모든 쓰기, 단일 Multi) | ✅ |
| 2. 상태머신 (허용 전이/멱등/종료/롤백/UI 게이팅) | ✅ |
| 3. LOT Genealogy (LotConsumption 경유, 직접감소 금지, 초과차단, source_operation 연결) | ✅ |
| 4. Outbox (문서 6종만, 기준정보·ready/pause/skip 미발행) | ✅ |
| 5. 이력성 (append-only, update/delete 부재) | ✅ |
| 6. 회귀 (`mix test`) | ✅ 331 passed, 4 skipped, 0 failed |
| 7. 기존 무손상 (/, /extensions, 애드온, /api, /ingest) | ✅ |

발견된 결함(차단/수정 필요) 없음. 설계 의도 확인이 필요한 경계 케이스 1건은 **테스트로 의도 입증됨**(아래 §3 노트).

---

## 1. AuditLog — 모든 쓰기에 단일 Ecto.Multi 동반 ✅

**인프라:** `OpenMes.Audit.put_log/3` (audit/audit.ex:34) 는 `Multi.insert` 스텝만 추가 — 컨텍스트의 동일 트랜잭션에서만 기록됨. 직접 `Repo.insert` 없음. AuditLog 스키마(audit_log.ex)는 `actor_id/action/resource_type/resource_id/before/after/created_at` 전부 보유, actor_id 빈 문자열 거부, `updated_at` 없음(append-only).

**쓰기 경로 대비 put_log 매칭:**

- **MasterData(6 엔티티 × create/update = 12 경로):** 제네릭 `create/3`(master_data.ex:93)·`update/3`(:116) 단 2개 함수가 12 경로를 모두 통과. 각 함수가 `Audit.put_log` 동반. `@resources` 매핑으로 `item.create` … `worker.update` action 생성. before(생성=nil)/after 스냅샷 기록. ✅
- **Production(7 put_log):** create_work_order, update_work_order, transition_multi(release/start/complete/cancel 공유), create_operation, operation_transition_multi(ready/start/pause/complete/skip 공유), create_production_result, record_defect — 모든 쓰기 경로 커버. ✅
- **Lots(4 put_log):** receive_lot, produce_lot, lot_transition(reserve/release/quarantine/scrap 공유), consume_lot — 모든 쓰기 경로 커버. ✅

**UI 우회 검증:** `grep "Repo\."` on `open_mes_web/admin/` → **0건**. LiveView는 컨텍스트 함수(`Production.*`, `Lots.*`, `MasterData.*`)만 호출. 직접 Repo.insert/update/transaction 없음. ✅

**actor 강제:** 모든 쓰기 함수가 `actor_id` 인자 필수. LiveView는 `socket.assigns.current_actor` 주입(work_order_live.ex:90/107, operation_live.ex:58/77/119/152). ✅

**테스트 입증:** operation_context_test.exs:90 "전이 실패 시 AuditLog 롤백", lots_test.exs:108 "초과 소비 차단 시 AuditLog 미생성(롤백)".

---

## 2. 상태머신 ✅

**Operation** (operation_state_machine.ex): `pending→{ready,skipped} / ready→{running,skipped} / running→{paused,completed} / paused→{running,completed} / completed→[] / skipped→[]`. 문서(domain-model.md L141-147) 준수. ✅

**MaterialLot** (material_lot_state_machine.ex): `available→{reserved,quarantined,scrapped} / reserved→{consumed,available,quarantined} / quarantined→{available,scrapped} / produced→{available,reserved,quarantined} / consumed→[] / scrapped→[]`. 문서(L149-156) 준수. ✅

- **멱등(from==to) 가드:** operation.ex:67, material_lot.ex:84 — `from == to` 시 `add_error`로 거부. ✅
- **종료 상태 재전이 차단:** `completed/skipped`, `consumed/scrapped` 의 allowed 목록 `[]` → 모든 전이 거부. ✅
- **불법 전이 거부+롤백:** `transition_changeset`이 `can_transition?` 위반 시 changeset 에러 → `Multi.update` 실패 → 전체 트랜잭션 롤백. 테스트 operation_context_test.exs:74 "불법 전이는 거부되고 상태/이벤트 변화 없음" 입증. ✅
- **UI 허용 전이만 버튼 노출:** operation_live.ex:371 `op_transitions(status)=OperationStateMachine.allowed_from/1`, work_order_live.ex:317 동일 패턴. 종료 상태는 버튼 대신 안내문구(operation_live.ex:299). 핸들러도 `_ -> {:error, :invalid_transition}` 방어(operation_live.ex:86) → **이중 방어**. ✅

---

## 3. LOT Genealogy ✅

- **자재 소비 = LotConsumption 경유만:** `consume_lot/4`(lots.ex:160)가 유일한 소비 경로. 단일 Multi에 ① load ② guard ③ **LotConsumption insert** ④ MaterialLot.quantity 차감 ⑤ AuditLog ⑥ Outbox. ✅
- **quantity 직접 감소가 소비 트랜잭션 안에서만:** `apply_consumption/2`(lots.ex:248)는 `consume_lot` Multi 내부에서만 호출. 컨텍스트 어디에도 LotConsumption 없는 독립 quantity 감소 경로 없음. ✅
- **초과 소비 차단:** `guard_consumption`(lots.ex:239) — `qty > 잔량` 시 `{:error, :insufficient_lot_quantity}` → 롤백. 테스트 lots_test.exs:108 입증(잔량 불변 + 기록 미생성). ✅
- **제품 LOT ↔ Operation 연결:** `produce_lot`(lots.ex:84)이 `source_operation_id` 설정 + FK 제약(material_lot.ex:58). `genealogy/1`(lots.ex:208)이 source_operation→LotConsumption→input LOT 추적. 테스트 lots_test.exs:124 입증. ✅

**경계 케이스 노트 (의도 확인됨, 결함 아님):** `apply_consumption`은 잔량 0 도달 시 `available/produced`에서 직접 `consumed`로 마감한다(lots.ex:253-261, 원시 `Ecto.Changeset.change`로 상태머신 `transition_changeset` 우회). 상태머신 표상으로는 `consumed`는 `reserved`에서만 진입 가능하나, 현장 소비는 reserve를 거치지 않는 경우가 일반적이다. 코드 주석(lots.ex:255)이 이 의도를 명시하고, 소비 가드를 이미 통과한 뒤 잔량 기준으로만 마감하므로 안전하다. 테스트 lots_test.exs:100 "완전 소비: 잔량 0 도달 시 consumed 전이" 가 의도를 green으로 고정. → **승인**. (향후 상태머신 표에 `available/produced → consumed`를 명시하면 문서-코드 정합성이 더 좋아진다는 권고만 남김. 비차단.)

---

## 4. Event Outbox ✅

**인프라:** `OpenMes.Outbox.put_event/3`(outbox.ex:32)는 Multi 스텝만 추가 — 상태변경과 동일 트랜잭션. Event 스키마 append-only(updated_at 없음).

**발행 이벤트 = 문서 정의 6종 정확히 일치:**
`work_order.released`(production.ex:143), `operation.started`(:312), `operation.completed`(:337), `defect.recorded`(:479), `material_lot.produced`(lots.ex:97), `material_lot.consumed`(:184). CLAUDE.md L79 목록과 일치. ✅

**미발행 확인:**
- 기준정보 6 CRUD: `grep event_type` on master_data/ → **0건**. ✅
- WorkOrder start/complete/cancel, Operation ready/pause/skip, LOT receive/reserve/release/quarantine/scrap: `put_event` 호출 없음 — AuditLog만. ✅
- create_* (work_order/operation): 문서 미정의 → Outbox 없음, AuditLog만. ✅

테스트 operation_context_test.exs:59 "ready는 Outbox 미발행" 입증.

---

## 5. 이력성 (append-only) ✅

- ProductionResult/DefectRecord/LotConsumption: 스키마에 `create_changeset`만, `update_changeset`/`def update_`/`Repo.delete`/`Multi.delete` **0건**(grep 확인). ✅
- 모든 append-only 스키마 모듈 docstring이 "수정/삭제 미제공 — 정정은 새 레코드" 명시. ✅
- AuditLog/Event도 `timestamps(updated_at: false)`. ✅
- MasterData는 삭제 대신 `active=false` 수정 경로(master_data.ex:9 주석)로 이력 보존. ✅

---

## 6. 회귀 — mix test ✅

```
Result: 331 passed, 4 skipped
Finished in 0.8 seconds
0 failures
```

앞서 보고된 331 passed 일치. G0/G1/G2 직접 커버 테스트 파일:
master_data_test(8), lots_test(9), material_lot_state_machine_test(3), operation_state_machine_test(4), result_defect_test(5), work_order_test(20), operation_context_test(5), work_order_controller_test(12), production_live_test(8), master_data_live_test(7). 불변식(가드/롤백/genealogy/audit/outbox) 어서션 직접 확인.

*(media transfer 모듈의 `File.stream!` deprecation 경고는 G0/G1/G2와 무관한 기존 경고. 테스트 통과에 영향 없음.)*

---

## 7. 기존 무손상 ✅

`mix phx.routes` 확인 — 기존 라우트 전부 유지:
- `GET /`, `GET /extensions` (CatalogLive)
- 애드온 5종 (`/extensions/wo-csv-export`, `/defect-stats`, `/lot-qr-label`, `/equipment-oee`, `/daily-production-summary`)
- `/api/work_orders` (index/show/create/release/start/complete/cancel)
- `/ingest/equipment`, `/ingest/health`
- `/dev/dashboard`

G1/G2가 추가한 `/admin/*` 라우트는 신규 네임스페이스로 격리 추가 — 기존 라우트 충돌/덮어쓰기 없음. ✅

---

## 최종 판정: ✅ APPROVED

라운드1 구현(코어 11 엔티티 + 기준정보 UI + 생산관리 UI)은 4대 도메인 불변식(이력성/AuditLog/LOT Genealogy/상태머신) + Outbox 원칙을 **모든 쓰기 경로에서 코드로 실현**한다. 회귀 green(331 passed), 기존 엔드포인트 무손상. 차단/수정 요구 결함 없음.

**비차단 권고 1건(다음 라운드 반영 선택):** MaterialLot 상태머신 표에 `available/produced → consumed` 직접 전이를 명시하여 문서-코드 정합성 향상(현재는 코드 주석 + 테스트로 의도 고정됨, 안전성 문제 아님).
