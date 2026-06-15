# 18. Architect 설계: 공장 Role별 화면 분리 + 화면별 Role 표시(색상) + 기초 Seed 데이터

- **작성자**: architect
- **작성일**: 2026-06-14
- **대상**: role 모델 / 화면-role 매핑(중앙 정의) / 접근 제어(가시성+인가) / role 표시·색상 UI / 기초 seed 데이터
- **기술 스택**: Phoenix + Ecto + LiveView + PostgreSQL (확정, 변경 없음)
- **참고**: docs/mvp-scope.md, CLAUDE.md(pi/도메인 원칙), `_workspace/15_architect_mes_frontend_design.md`(§2.5 인증 MVP 임시안), 실앱(router.ex / admin_components.ex / admin_live.ex / master_data/worker.ex / system/user_live.ex / master_data.ex)
- **수신자**: domain-engineer, qa-auditor

---

## 0. 설계 원칙 (이번 작업 한정)

1. **pi 최소**: 본격 RBAC/비밀번호/세션 로그인 시스템을 만들지 않는다. 만드는 것은 ① role enum(Worker), ② 세션 current_role, ③ role 전환 드롭다운(데모용), ④ role→화면 가시성/인가, ⑤ role 색상 표시, ⑥ seed. 그 이상은 금지(권한 매트릭스 DB화·정책 엔진·grant 테이블 전부 YAGNI).
2. **코어 비침투**: role 인가는 **web 계층(인가 모듈 + on_mount 훅)** 에만 둔다. 코어 컨텍스트(`Production`/`Lots`/`MasterData`)는 손대지 않는다. 단 `Worker` 스키마에 `role` 필드 1개만 추가(기준정보 작업자의 자연 속성 — 기존 §15 미해결 8.1 "작업자 속성"의 최소 확장).
3. **기존 화면/라우트/도메인 무손상**: router.ex 라우트는 그대로. 메뉴 트리(`@menu`)에 `roles:` 필드만 추가. on_mount는 기존 `AdminLive`에 인가 단계를 더한다(별 파이프라인 신설 없음).
4. **한국어 UI / 영문 식별자**: role 식별자는 영문 atom/string, 화면 표기는 한국어.
5. **중앙 단일 정의**: role 메타(식별자/한국어명/색)와 화면-role 매핑은 **한 모듈**(`OpenMesWeb.Authorization`)에 모은다. 메뉴 트리·배지·on_mount·seed가 전부 이 한 곳을 참조한다(중복 정의 금지).

---

## 1. Role 모델

### 1.1 Role 집합 (mvp-scope 대상 사용자 1:1)

| 식별자(영문, atom/string) | 한국어명 | 색(Tailwind 계열) | 사이드바 배지 클래스 | 접근 범위 요약 |
|---------------------------|----------|-------------------|----------------------|----------------|
| `system_admin` | 시스템 관리자 | **slate** | `bg-slate-100 text-slate-700` | **전체**(모든 화면 + role 전환 + 사용자/감사) |
| `production_manager` | 생산관리자 | **blue** | `bg-blue-100 text-blue-700` | 기준정보·생산관리·조회/대시보드 |
| `quality_manager` | 품질관리자 | **green** | `bg-green-100 text-green-700` | LOT추적·조회/대시보드(불량 중심) |
| `material_manager` | 자재·창고 담당자 | **amber** | `bg-amber-100 text-amber-700` | LOT추적·재고흐름 |
| `operator` | 현장 작업자 | **purple** | `bg-purple-100 text-purple-700` | 현장(/shopfloor) 전용 |

> 색은 기존 `status_badge`(zinc/blue/indigo/amber/green/red)와 충돌하지 않도록 role 전용으로 slate/blue/green/amber/purple 5색 고정. indigo는 사이드바 active 강조에 이미 쓰이므로 role 색에서 제외.

### 1.2 Role을 어디에 두나

- **Worker.role (enum 컬럼)**: 기준정보 작업자에 역할 부여. `workers.role` string, CHECK IN 5종, NOT NULL DEFAULT `'operator'`. → 사용자/권한 화면(`UserLive`)이 이 값을 표시(현재 하드코딩 `role_label/1` 제거).
- **세션 current_role**: 데모 role 전환의 실효 값. `session["current_role"]`. on_mount가 socket `:current_role` 로 주입. 없으면 기본 `"system_admin"`(데모 시작은 전체 보이게 — 기존 actor 기본값 "admin"과 정합).
- **actor와 role의 관계(MVP 단순화)**: 기존 §15 세션 actor(`actor_id`, 현재 기본 "admin")는 **그대로 유지**. role은 actor와 **독립된 데모 전환 값**으로 둔다(로그인하면 worker.role로 자동 세팅하는 본격 연동은 후속). 즉 상단바 드롭다운에서 role을 바꾸면 `current_role`만 바뀐다. → pi: actor-role 바인딩 테이블/세션 로그인 불필요.

### 1.3 Worker 스키마 변경(코어 최소 1필드)

`OpenMes.MasterData.Worker`:
```
field :role, :string, default: "operator"
```
- changeset: `cast([..., :role])` + `validate_inclusion(:role, Authorization.role_keys())`(또는 하드코딩 5종) + 기본값.
- 마이그레이션(신규): `alter table(:workers) add :role, :string, null: false, default: "operator"` + CHECK 제약 `role IN ('system_admin','production_manager','quality_manager','material_manager','operator')`.
- AuditLog: 기존 `MasterData.update_worker/3` 경로가 이미 worker.update AuditLog를 남기므로 role 변경도 자동 감사됨(추가 작업 0). **단 `snapshot/1`이 전체 필드를 캡처하므로 role도 before/after에 포함된다 — 별도 처리 불필요.**

---

## 2. 화면-Role 매핑 (중앙 정의)

### 2.1 매핑 표 (system_admin은 항상 전체 — 표에서 생략, 코드에서 자동 포함)

| 메뉴 그룹 | 경로 | 허용 role(system_admin 외) |
|-----------|------|-----------------------------|
| 기준정보 (품목/BOM/공정/라우팅/설비/작업자) | `/admin/items` 등 6 | `production_manager` |
| 생산관리 (작업지시/공정실적) | `/admin/work-orders*` | `production_manager` |
| LOT 추적 (자재LOT/계보) | `/admin/lots*` | `material_manager`, `quality_manager` |
| 조회/대시보드 — 생산현황 | `/admin/dashboard` | `production_manager`, `quality_manager` |
| 조회/대시보드 — 공정별 실적 | `/admin/reports/production` | `production_manager`, `quality_manager` |
| 조회/대시보드 — 불량 현황 | `/admin/reports/defects` | `production_manager`, `quality_manager` |
| 조회/대시보드 — LOT 이력 | `/admin/reports/lots` | `quality_manager`, `material_manager` |
| 조회/대시보드 — 재고 흐름 | `/admin/reports/inventory` | `material_manager`, `production_manager` |
| 관리자 — 사용자/권한 | `/admin/users` | (없음 — system_admin 전용) |
| 관리자 — 감사 로그 | `/admin/audit-logs` | (없음 — system_admin 전용) |
| 현장 (/shopfloor) | `/shopfloor*` | `operator` |
| 확장 카탈로그 | `/extensions` | (없음 — system_admin 전용) |

> **system_admin은 모든 화면 포함**(자동). 위 표는 "추가로 누구에게 보이나"를 정의한다.

### 2.2 단일 정의 위치 — `OpenMesWeb.Authorization` (신규 모듈)

순수 함수 모듈(상태 없음, 테스트 쉬움). web 계층에 둔다(`lib/open_mes_web/authorization.ex`).

제공 함수:
```
roles/0           # [%{key, label, badge_class, dot_class}] 순서 보존 리스트(§1.1)
role(key)         # 단건 메타 (없으면 fallback)
role_keys/0       # ~w(system_admin production_manager quality_manager material_manager operator)
role_label(key)   # 한국어명
role_badge_class(key)
allowed?(role, path)   # 경로 인가 판정 (system_admin → 항상 true; prefix 매칭)
roles_for_path(path)   # 그 경로를 볼 수 있는 role key 리스트(배지 렌더용, system_admin 포함)
visible_menu(role)     # 해당 role에게 보이는 메뉴 그룹/항목만 필터한 트리
```

매핑 원천 데이터는 **메뉴 트리(`@menu`)의 각 항목에 `roles:` 필드**로 둔다(가시성·인가·배지가 같은 트리를 본다). `Authorization`은 이 트리를 `AdminComponents.menu/0`에서 받아 판정한다. → 메뉴 한 줄 추가 = role 매핑·인가·배지 동시 반영(중복 0, §0-5).

`/shopfloor*`, `/extensions`는 admin 메뉴 트리에 없으므로 `Authorization`에 **별도 path 규칙 맵**(`@area_roles`)으로 보강:
```
%{"/shopfloor" => [:operator], "/extensions" => []}  # system_admin은 코드에서 항상 추가
```

---

## 3. 접근 제어 (가시성 + 인가, 직접 URL 차단 포함)

### 3.1 두 계층

1. **가시성(사이드바)**: `visible_menu(current_role)`로 필터 → 비-admin은 자기 허용 그룹/항목만 사이드바에 보임. system_admin은 전체 + 각 항목에 role 배지.
2. **인가(직접 URL 차단)**: on_mount 훅에서 `Authorization.allowed?(current_role, current_path)` 검사. 거부 시 **리다이렉트 + flash 안내**. (메뉴 숨김만으로는 직접 URL 진입을 못 막으므로 필수.)

### 3.2 on_mount 확장 (`OpenMesWeb.Admin.AdminLive`)

기존 `:assign_admin_context` 훅에 role 주입 + 인가 단계를 더한다(새 파이프라인·새 plug 없음 — pi):

```
def on_mount(:assign_admin_context, _params, session, socket) do
  actor = session["actor_id"] || "admin"
  role  = session["current_role"] || "system_admin"   # 데모 기본: 전체 보임

  socket =
    socket
    |> assign_new(:current_actor, fn -> actor end)
    |> assign_new(:current_role, fn -> role end)
    |> attach_hook(:track_admin_path, :handle_params, &track_path_and_authorize/3)

  {:cont, socket}
end

# handle_params 마다 경로 갱신 + 인가. 거부 시 redirect(halt).
defp track_path_and_authorize(_params, uri, socket) do
  path = URI.parse(uri).path || ""
  socket = assign(socket, :current_path, path)

  if Authorization.allowed?(socket.assigns.current_role, path) do
    {:cont, socket}
  else
    {:halt,
     socket
     |> Phoenix.LiveView.put_flash(:error, "이 화면에 접근할 권한이 없습니다. (현재 역할: #{Authorization.role_label(socket.assigns.current_role)})")
     |> Phoenix.LiveView.redirect(to: landing_path(socket.assigns.current_role))}
  end
end
```

- `landing_path/1`: role별 첫 허용 화면(예: operator→`/shopfloor`, production_manager→`/admin/work-orders`, material_manager→`/admin/lots`, quality_manager→`/admin/reports/defects`, system_admin→`/admin/items`). `Authorization.visible_menu/1`의 첫 항목으로 도출.
- 인가는 **handle_params 단계**라 직접 URL·navigate 모두 커버(SPA 내 이동 포함).

### 3.3 현장(/shopfloor) 영역

- `/shopfloor`는 `OpenMesWeb.Shopfloor.*Live`(별도 레이아웃). 이쪽에도 동일하게 **얇은 on_mount 인가**를 둔다(`Shopfloor`용 on_mount 또는 공용 인가 헬퍼 재사용). operator/system_admin만 허용, 그 외 role이 직접 진입 시 `/admin/...`(role landing)으로 리다이렉트.
- 단, 현장 LiveView가 admin on_mount를 쓰지 않으므로 **공용 인가 함수** `Authorization.allowed?/2`를 현장 on_mount에서도 호출(코드 1줄 공유). 별 모듈 신설은 최소화: 현장 베이스 LiveView가 있으면 거기에, 없으면 각 현장 LiveView mount 앞 `on_mount` 1개 추가.

### 3.4 비인가 시 처리 정책(확정)

- **사이드바**: 숨김(보이지 않음).
- **직접 URL / navigate**: 차단 → role landing 리다이렉트 + flash. (404가 아니라 "권한 없음" 안내 — 화면 자체는 존재하므로.)
- system_admin: 모든 검사 통과(항상 true).

---

## 4. Role 표시 + 색상 (UI)

### 4.1 색 팔레트 (확정 — §1.1 재확인)

system_admin=slate · production_manager=blue · quality_manager=green · material_manager=amber · operator=purple.
각 role 메타에 두 클래스: `badge_class`(배경+글자, 배지용), `dot_class`(작은 점 표시용, 예 `bg-blue-500`).

### 4.2 재사용 컴포넌트 — `role_badge` (AdminComponents에 추가)

```
attr :role, :string, required: true   # role key
attr :size, :string, default: "sm"    # sm | xs
def role_badge(assigns)   # <span class={badge_class}> {한국어명} </span>
```
- 색 점 + 한국어명. 미지정/미지 role은 zinc fallback.
- 여러 role을 한 줄에 나열하는 `role_badges`(list) 보조도 같이(사이드바 메뉴 항목용).

### 4.3 적용 지점

| 위치 | 표시 내용 | 비고 |
|------|-----------|------|
| **사이드바 메뉴 항목** | 그 화면을 볼 수 있는 role들의 **색 점/배지** | **system_admin이 볼 때만** 표시(자기 화면이 어느 role 것인지 식별). 비-admin은 자기 화면만 보이므로 배지 불필요(노이즈 제거). |
| **각 화면 상단 `page_header`** | 이 화면의 허용 role 배지 묶음 | `page_header`에 `roles` attr(옵션) 추가 → 우측/제목 옆에 배지. `roles_for_path(@current_path)` 자동 주입 가능. |
| **상단바(`admin_topbar`)** | 현재 role 배지 + **role 전환 드롭다운** | 데모용. 드롭다운 선택 → role 전환. |
| **사용자/권한 화면(`UserLive`)** | 각 Worker의 role 배지 | 현재 하드코딩 `role_label/1`을 `worker.role` 기반 `role_badge`로 교체. |

### 4.4 Role 전환 드롭다운 (데모용)

- 위치: `admin_topbar` 우측("작업자: …" 옆).
- 구현: `details/summary`(기존 모바일 메뉴와 동일 패턴, 외부 JS 0) 또는 LiveView `phx-click`. **세션에 써야** 다른 LiveView로 navigate해도 유지되므로, role 전환은 **일반 컨트롤러 GET/POST 경유 세션 기록**이 필요(LiveView는 세션 직접 못 씀).
  - 방식(pi 최소): 작은 `SessionController.set_role` (`POST /session/role` 또는 `GET /session/role/:role`) → `put_session(:current_role, role)` → redirect back. 드롭다운 항목은 이 경로로 가는 링크/폼.
  - 라우터에 `:browser` scope 한 블록 추가(2~3줄). on_mount는 세션에서 role을 읽으므로 navigate 후에도 유지.
- system_admin 포함 5개 role 전부 선택 가능(데모). 현재 role은 배지로 강조.

> 대안(더 단순): URL 쿼리 `?role=` 없이, **세션 기록 컨트롤러 1개**가 가장 견고. LiveView만으로 세션을 못 바꾸므로 컨트롤러 경유는 불가피(이게 최소 해법).

---

## 5. 기초 Seed 데이터 (`priv/repo/seeds.exs`)

### 5.1 원칙

- **멱등**: 자연키(worker_code/item_code/process_code/equipment_code/lot_no/work_order 번호)로 존재 확인 후 없을 때만 생성. 여러 번 실행해도 중복 0.
- **AuditLog 경유**: 가능한 한 **기존 컨텍스트 함수**(`MasterData.create_*`, `Production.create_work_order/release/create_operation/start/create_production_result/record_defect`, `Lots.receive_lot/produce_lot/consume_lot`)로 생성 → AuditLog/Outbox 자동 동반(CLAUDE.md 준수). actor_id는 seed 전용 상수 `"seed"` 사용.
- **데이터가 화면을 채우도록**: 대시보드/조회/불량/재고 화면이 비어 보이지 않게 최소 실데이터.
- **append-only 존중**: ProductionResult/DefectRecord/LotConsumption은 컨텍스트 경유 insert만(수정 없음).

### 5.2 멱등 헬퍼 패턴

```
# 예: worker
fn code, attrs ->
  case Repo.get_by(Worker, worker_code: code) do
    nil  -> {:ok, _} = MasterData.create_worker(Map.put(attrs, :worker_code, code), "seed")
    rec  -> rec   # 이미 있으면 skip
  end
end
```
같은 패턴을 item/process/equipment 등에 적용. 생산/LOT는 "해당 work_order 번호/ lot_no 이미 있으면 전체 블록 skip".

### 5.3 Seed 구성 (최소 데모셋)

**A. 작업자(role별 1~2명) — `workers.role` 부여**
| worker_code | name | role |
|-------------|------|------|
| W-ADMIN | 관리자 김 | system_admin |
| W-PROD1 | 생산관리 이 | production_manager |
| W-QC1 | 품질관리 박 | quality_manager |
| W-MAT1 | 자재창고 최 | material_manager |
| W-OP1 | 현장작업 정 | operator |
| W-OP2 | 현장작업 한 | operator |

**B. 기준정보**
- 품목 4: `RM-001`(원자재 강판, raw, kg), `RM-002`(원자재 볼트, raw, EA), `SF-001`(반제품 브라켓, semi, EA), `FP-001`(완제품 조립품, product, EA).
- 공정 3: `P-CUT`(절단), `P-WELD`(용접), `P-ASSY`(조립).
- 설비 3: `EQ-CUT01`(절단기), `EQ-WELD01`(용접기), `EQ-ASSY01`(조립대).
- BOM 2: FP-001 ← SF-001 ×1, SF-001 ← RM-001 ×0.5(loss_rate 0.02).
- 라우팅(FP-001): seq1 P-CUT, seq2 P-WELD, seq3 P-ASSY (standard_cycle_time 임의).

**C. 생산**
- 작업지시 2건: WO-1(FP-001, 수량 100, release→start하여 `in_progress`), WO-2(FP-001, 수량 50, `released`까지만).
- WO-1에 Operation 3개(라우팅 순서대로 `create_operation`). 1번 Operation `start_operation`→running, 또는 1건 `complete` 처리해 실적 표시.
- ProductionResult 1~2건(완료/진행 Operation에 양품 80/불량 5 등) → 대시보드·공정별 실적 채움.
- DefectRecord 1~2건(`record_defect`, defect_code 예 `D-SCRATCH` 흠집, `D-DIM` 치수불량) → 불량 현황 채움.

**D. LOT**
- 원자재 LOT 2~3건 `receive_lot`(RM-001, RM-002 → available).
- WO-1 Operation에 `consume_lot`(원자재 투입 → LotConsumption + 상태전이) → 재고흐름/LOT이력 채움.
- 생산 LOT 1건 `produce_lot`(SF-001 또는 FP-001, source_operation_id 연결 → produced) → LOT 계보 화면 데모.

**E. seed 안내 출력**: 콘솔에 "role별 데모 계정/전환 방법" 한국어 안내 1줄(예: 상단바 드롭다운에서 role 전환).

> seed는 **마이그레이션(workers.role 추가) 이후** 실행. role 컬럼이 있어야 작업자 role seed 가능.

---

## 6. 핵심 설계 결정 5가지

1. **Role은 web 인가 계층 + Worker.role 단 1필드** — 코어 도메인/컨텍스트 무침투. 본격 RBAC(grant 테이블/정책 엔진) 도입 안 함(pi/YAGNI). Worker.role은 기준정보 작업자의 자연 속성으로 최소 추가.
2. **매핑은 메뉴 트리 `roles:` 한 곳 + `Authorization` 모듈 단일 판정** — 가시성·인가·배지·landing이 같은 원천을 본다. 메뉴 한 줄 = 4개 동작 동시 반영(중복 정의 금지).
3. **가시성(사이드바 숨김) + 인가(on_mount 직접URL 차단) 2계층** — 메뉴 숨김만으로 부족하므로 handle_params 인가로 직접 URL/navigate까지 차단. 거부 시 role landing 리다이렉트 + 한국어 flash.
4. **데모 role 전환은 세션 + 컨트롤러 1개** — LiveView는 세션을 못 쓰므로 `SessionController.set_role`(세션 기록 후 redirect) 경유. on_mount가 `session["current_role"]`(기본 system_admin)을 socket에 주입. actor와 role은 독립(로그인-role 자동바인딩은 후속).
5. **Seed는 기존 컨텍스트 함수 + 멱등** — `MasterData/Production/Lots` 컨텍스트 경유로 AuditLog/Outbox/append-only/상태머신 자동 준수. 자연키 존재확인으로 멱등. actor_id="seed". 모든 조회/대시보드 화면이 데이터를 갖도록 작업지시·실적·불량·LOT까지 최소 1흐름 구성.

---

## 7. domain-engineer 구현 지침 요약

### 7.1 코어(최소)
- `OpenMes.MasterData.Worker`: `field :role, :string, default: "operator"` 추가. changeset `cast`/`validate_inclusion`(5종)/기본값. (AuditLog는 기존 update_worker 경로가 자동 처리 — 추가 작업 없음.)
- 신규 마이그레이션: `priv/repo/migrations/..._add_role_to_workers.exs` — `add :role, null: false, default: "operator"` + CHECK 제약(5종).

### 7.2 web 인가 모듈(신규)
- `lib/open_mes_web/authorization.ex` (`OpenMesWeb.Authorization`): §2.2 함수 셋. role 메타(§1.1) + `@area_roles`(/shopfloor,/extensions) 정의. `allowed?/2`는 system_admin 항상 true, 그 외 메뉴 트리 `roles:`/`@area_roles` prefix 매칭. `visible_menu/1`은 트리 필터.
- 메뉴 원천은 `AdminComponents.menu/0`를 참조(또는 트리를 Authorization로 이관 — 둘 중 단일화. 권장: 트리 정의는 AdminComponents에 두고 Authorization이 읽음).

### 7.3 메뉴 트리 변경(`AdminComponents`)
- `@menu` 각 그룹/항목에 `roles:` 키 추가(§2.1). 그룹 단위 role(그룹 내 모든 항목 동일)이면 그룹에, 화면별 상이(조회/대시보드)면 항목에.
- `admin_sidebar`: `visible_menu(@current_role)`로 필터된 트리 렌더. system_admin일 때 각 항목 옆 `role_badges`(색 점) 표시.
- `role_badge`/`role_badges` 컴포넌트 추가(§4.2). `page_header`에 `roles` attr(옵션) 추가 → role 배지 줄.
- `admin_topbar`: 현재 role 배지 + role 전환 드롭다운(§4.4, `details/summary` + `SessionController` 링크). 사이드바·shell에 `current_role` attr 전달(현재 `current_actor`만 전달 중 → `current_role` 추가).

### 7.4 on_mount / 인가(`AdminLive` + 현장)
- `AdminLive.on_mount`: `current_role` 주입 + `track_path_and_authorize/3`(경로 갱신 + `allowed?` 검사 + 거부 시 redirect/flash, §3.2). `landing_path/1` 구현.
- 현장(`Shopfloor.*`): 동일 인가(operator/system_admin) on_mount 1개. `Authorization.allowed?/2` 재사용.

### 7.5 세션 컨트롤러(신규, 최소)
- `OpenMesWeb.SessionController.set_role/2`: `put_session(:current_role, role)`(role_keys 검증) → `redirect(back)`. 라우터 `:browser` scope에 `post "/session/role"`(또는 `get "/session/role/:role"`) 추가. role 미검증 값은 무시.

### 7.6 화면 반영(`UserLive`)
- `role_label/1` 하드코딩 제거 → `<.role_badge role={w.role} />`. role 컬럼 표시. (worker.role이 채워지므로 seed 후 자연히 표시.)

### 7.7 Seed(`priv/repo/seeds.exs`)
- §5 구성. 멱등 헬퍼 + 기존 컨텍스트 함수(actor `"seed"`). 마이그레이션 후 `mix run priv/repo/seeds.exs`. 재실행 안전.

### 7.8 검증(qa-auditor 위임 포인트)
- Worker.role 변경이 AuditLog(worker.update) before/after에 role 포함되는지.
- seed가 모든 생산/LOT 쓰기를 컨텍스트 경유(AuditLog/Outbox/LotConsumption/상태머신 준수)로 하는지, append-only 위반 없는지, 2회 실행 멱등인지.
- 비-admin role로 비허용 URL 직접 진입 시 차단(리다이렉트)되는지, system_admin은 전체 접근되는지.
- 인가는 web 계층에만 — 코어 컨텍스트 변경 없음 확인.

### 7.9 무손상 확인
- 기존 라우트/도메인/애드온 테이블·컬럼 변경 0(workers.role 추가만). `mix compile` + `mix test` + 애드온 LiveView 접속 회귀 확인.
