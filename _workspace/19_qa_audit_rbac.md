# 19. QA 감사: Role 기반 화면 분리 + Role 표시 + Seed

- **감사자**: qa-auditor
- **감사일**: 2026-06-14
- **대상 설계**: `_workspace/18_architect_rbac_design.md`
- **기준 문서**: `docs/mvp-scope.md`, `CLAUDE.md`(pi/도메인 불변식)
- **실앱**: `/Users/hongsw/dev/open-mes-korea/open_mes`

---

## 최종 판정: APPROVED

설계 §0~§7 전 항목이 코드로 실현됨. 인가는 메뉴 숨김이 아니라 on_mount handle_params에서 실제 리다이렉트로 강제되고, 코어 도메인은 role에 전혀 침투하지 않았으며(Worker.role 1필드 + web 인가 계층만), seed는 컨텍스트 함수 경유 + 멱등(2회 실행 중복 0)이 실증됨. `mix test` 393 passed / 4 skipped(green). 차단/수정 필요 항목 없음. 경미한 정보성 1건(⚠️ 색 중복)만 기록.

---

## 항목별 결과

### 1. 인가(직접 URL 차단) — ✅ (가장 중요)

- **단일 판정 함수**: `Authorization.allowed?/2`(authorization.ex:97~103). `allowed?("system_admin", _) → true`, 그 외는 `roles_for_path/1` 포함 여부. prefix 매칭(`path_match?/2` line 183~184)으로 하위 경로까지 커버.
- **실제 강제 지점(메뉴 숨김 아님)**:
  - admin: `AdminLive.track_path_and_authorize/3`(admin_live.ex:59~75) — **handle_params 훅**에 attach. 거부 시 `{:halt, redirect(landing) + put_flash}`. handle_params 단계라 직접 URL·navigate 모두 차단.
  - shopfloor: `ShopfloorLive.authorize/3`(shopfloor_live.ex:58~73) — 동일 패턴, `Authorization.allowed?/2` 재사용(코드 1줄 공유).
- **전 라우트 커버 확인**: `/admin/*` 18개 LiveView 전부 `use OpenMesWeb.Admin.AdminLive`, `/shopfloor/*` 4개 라우트 LiveView 전부 `use ...Shopfloor.ShopfloorLive`. 인가 우회 라우트 0(grep 검증). 
- **테스트 실증**(`role_access_test.exs`):
  - production_manager → `/admin/lots` 차단, `/admin/items`로 redirect + flash "접근할 권한이 없습니다"/"생산관리자"(line 25~32).
  - production_manager → `/admin/users`(전용) 차단(line 34~37).
  - material_manager → `/admin/work-orders` 차단 → `/admin/lots`(line 39~43).
  - operator → `/admin/items` 차단 → `/shopfloor`(line 45~48).
  - system_admin → items/lots/work-orders/users/audit-logs 전부 통과(line 63~70).
  - 세션 role 없을 때 기본 system_admin 전체 통과(line 72~74).
- **판정**: 메뉴 숨김이 아니라 코드 인가가 강제됨. admin(system_admin) 전체 통과 확인.

### 2. 가시성 — ✅

- `Authorization.visible_menu/1`(authorization.ex:122~129)이 `AdminComponents.menu()` 트리를 role로 필터, 빈 그룹 제거. system_admin은 `allowed_for_item?("system_admin", _) → true`(line 155)로 전체.
- `admin_sidebar`(admin_components.ex:110~160)가 `visible_menu(role)` 렌더, system_admin일 때만 `role_dots`(색 점) 표시(line 141, `@admin?` 가드).
- **단일 원천 확인**: role→path 매핑은 `@menu`의 `:roles` 필드(admin_components.ex:25~97) + `@area_roles`(authorization.ex:64~67) 두 곳뿐. grep으로 그 외 위치에 role 식별자 매핑 중복 0 확인. 메뉴 한 줄 추가 = 가시성·인가·배지·landing 동시 반영.
- 테스트: production_manager 사이드바에 LOT추적/관리자 그룹 숨김, operator는 admin 메뉴 빈 트리(authorization_test.exs:123~126, role_access_test.exs:89~98).

### 3. Role 표시/색 — ✅ (정보성 ⚠️ 1건)

- `role_badge`(admin_components.ex:301~316): 점+한국어명, 5종 색 정확(authorization.ex:21~52): system_admin=slate / production_manager=blue / quality_manager=green / material_manager=amber / operator=purple. 미지 role은 zinc fallback(line 54~59).
- 적용 지점 4곳 확인:
  - 상단바(admin_topbar): 현재 role 배지 + 전환 드롭다운(admin_components.ex:211~233).
  - page_header: `roles` attr → `role_badges`(admin_components.ex:283).
  - 사이드바: system_admin에 `role_dots`(line 141).
  - UserLive: `<.role_badge role={w.role} />`(user_live.ex:53) — Worker.role 구동(하드코딩 role_label 제거됨).
- **⚠️ 색 중복(차단 아님, 정보성)**: role 배지(blue/green/amber)와 `status_badge`(blue/green/amber, admin_components.ex:378~385)가 일부 Tailwind 색조를 공유. 단 ① role 배지는 항상 "색 점 + 한국어 역할명(생산관리자 등)"을, status 배지는 상태 텍스트(작성중/완료 등)를 렌더해 텍스트로 구별되고 ② 서로 다른 UI 컨텍스트(role=상단바/헤더/사용자열, status=작업지시/공정 테이블)에 위치하며 ③ 설계 §1.1이 indigo(사이드바 active)만 명시 회피하고 blue/green/amber 공유는 수용함. 기능 결함 아님 → 권고 없음, 인지만.

### 4. 코어 비침투 — ✅

- `grep -rn "role" lib/open_mes/`(worker.ex 제외) → **0건**. Production/Lots/MasterData 비즈니스 로직 어디에도 role 의존 없음.
- role은 정확히 ① web 인가 계층(`OpenMesWeb.Authorization` + 두 on_mount) ② `Worker.role` 1필드(worker.ex:21)에만 존재.
- 마이그레이션(`20260614000001_add_role_to_workers.exs`): `workers`에 role 1컬럼 + CHECK(5종) + index. 다른 테이블 변경 0.
- AuditLog 자동 동반: `create_worker`/`update_worker`(master_data.ex:113~114) → 제네릭 `create`/`update`가 `Ecto.Multi` + `Audit.put_log`로 `snapshot/1`(전 필드) 캡처. 실 데이터 확인 — worker.create AuditLog after에 `"role" => "operator"` 포함. role 변경도 별도 작업 없이 감사됨.

### 5. Seed 멱등 + 무결성 — ✅

- **컨텍스트 경유**: seeds.exs 내 `Repo.insert/update/delete` **0건**(grep). 모든 도메인 쓰기가 `MasterData.create_*` / `Production.create_work_order|release|start|create_operation|ready|start|complete|create_production_result|record_defect` / `Lots.receive_lot|consume_lot|produce_lot` 경유 → AuditLog/Outbox/LotConsumption/상태머신 자동 준수. actor_id="seed".
- **append-only 준수**: ProductionResult/DefectRecord/LotConsumption은 insert만, 수정/삭제 호출 없음.
- **상태머신 준수**: WO draft→released→in_progress, Operation pending→ready→running→completed(op1), ready→running(op2), MaterialLot available→consumed/produced — 모두 컨텍스트 함수 경유라 전이 규칙 강제.
- **멱등 실증**(`MIX_ENV=dev mix run priv/repo/seeds.exs` 2회):
  | 엔티티 | 1회 후 | 2회 후 |
  |--------|--------|--------|
  | worker | 6 | 6 |
  | item | 4 | 4 |
  | process | 3 | 3 |
  | equipment | 3 | 3 |
  | bom | 2 | 2 |
  | routing | 3 | 3 |
  | work_order | 2 | 2 |
  | operation | 3 | 3 |
  | production_result | 1 | 1 |
  | defect_record | 2 | 2 |
  | material_lot | 3 | 3 |
  | lot_consumption | 1 | 1 |
  
  → 전 엔티티 카운트 불변, **중복 0**. 자연키 존재확인(`get_or_create`/`ensure_bom`/`ensure_routing` + WO `unless Repo.get_by`)이 정상 동작.

### 6. 회귀(mix test) — ✅

- `mix test` 결과: **393 passed, 4 skipped** (green, 1.0s). 보고된 393과 실제 일치.
- 출력의 warning은 무관 모듈(media transfer `File.stream!` deprecation)의 사전 존재 경고로 role 도입과 무관. 실패 0.

### 7. 무손상 — ✅

- 기존 라우트 19개 메뉴 전부 유지(router.ex). 추가는 `post "/session/role/:role"` 1줄(line 51).
- 도메인 불변식(AuditLog/LOT Genealogy/Event Outbox/상태머신) role 도입으로 손상 없음 — seed 컨텍스트 경유로 오히려 재검증됨.
- 393 passed가 기존 359 → 증가(role 테스트 추가분 포함)이며 기존 테스트 회귀 없음.

---

## pi(최소 구현) 평가 — ✅

- 본격 RBAC(grant 테이블/정책 엔진/세션 로그인) 미도입. 만든 것: role enum 1필드, 세션 current_role, 전환 컨트롤러 1개, 인가 모듈 1개, 색 배지, seed. YAGNI 위반(호출처 0~1 선제 헬퍼) 미발견.
- `SessionController`(컨트롤러 1개, 31줄), `Authorization`(순수 함수 모듈) 모두 다중 호출처 보유 — 과분리 아님. 인가/배지/landing은 도메인 기능이므로 제거 대상 아님.
- 확장 포인트(메뉴 트리 `:roles` 단일 원천)는 적절히 유지.

---

## 위반 / 수정 필요

없음.

## 핵심 파일

- `open_mes/lib/open_mes_web/authorization.ex` — 인가 단일 원천
- `open_mes/lib/open_mes_web/admin/admin_live.ex:59~75` — admin on_mount 인가 강제
- `open_mes/lib/open_mes_web/shopfloor/shopfloor_live.ex:58~73` — shopfloor on_mount 인가 강제
- `open_mes/lib/open_mes_web/components/admin_components.ex` — visible_menu 필터 / role_badge / role_dots
- `open_mes/lib/open_mes_web/controllers/session_controller.ex` — role 전환(valid_role 검증)
- `open_mes/lib/open_mes/master_data/worker.ex:21` — Worker.role 1필드(코어 최소)
- `open_mes/priv/repo/migrations/20260614000001_add_role_to_workers.exs` — role 컬럼 + CHECK
- `open_mes/priv/repo/seeds.exs` — 멱등 seed(컨텍스트 경유)
- `open_mes/test/open_mes_web/authorization_test.exs`, `test/open_mes_web/live/role_access_test.exs` — 인가 검증
