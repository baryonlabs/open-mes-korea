# 31 · QA 감사 — 확장 시스템 디커플링 (feat/extension-decoupling)

감사자: qa-auditor · 2026-06-15
대상 설계: `_workspace/30_architect_extension_decoupling_design.md`
대상 브랜치: `feat/extension-decoupling` (디커플링 변경은 전부 워킹트리 미커밋 상태, baseline = HEAD `72a34b5`)
검증 성격: **확장/인프라 계층** 변경. 표준 도메인 불변식은 회귀 관점으로만.

## 최종 판정: ✅ APPROVED

7개 핵심 디커플링 요건 전부 PASS, 3개 설계 이탈점 전부 타당. 보고된 수치(512 passed / ext.verify 9·9, C1~C8) 전부 재현. 단방향 의존·라우트 정합(0 diff)·외부확장 무의존 자동노출 실증 완료. 차단/수정 필요 항목 없음. 경미한 권고 2건(블로킹 아님)은 §보완권고.

추정 0 — 모든 항목 직접 명령 실행으로 확인. 검증 중 가한 임시 변경(dev.exs 데모 활성화, demo extension.ex 코어쓰기 주입)은 전부 원복 확인, 워킹트리 부작용 0.

---

## 항목별 결과

### ✅ 1. 단방향 의존 (최우선) — PASS

코어 도메인 디렉토리 전수 검사 `grep -rln "OpenMes.Extension"`:
```
production:0  audit:0  outbox:0  lots:0  master_data:0
ai:0  knowledge:0  charts:0  okf:0  production_line:0
```
`OpenMes.Extension` 참조는 (a) `lib/open_mes/extensions/*`(호환 shim 디렉토리 — 확장 서브시스템 자체, 코어 도메인 아님), (b) `_web/`(Router·CatalogLive·GuideLive), (c) 확장 모듈들, (d) mix task뿐. **코어 도메인 0건.** `mix.exs`에 `{:open_mes_extension_api, path: "../open_mes_extension_api"}` path dep 확인 — 의존 방향: 코어 도메인 ─▶(무참조) extension_api, Web/확장 ─▶ extension_api. 설계 §3.2 단방향 엄수.

### ✅ 2. 라우트 정합 — PASS (0 diff, 결정적)

baseline(HEAD, 구 `if X.enabled?()` 블록 8개) vs feature(`mount_extension_routes()` 매크로 1줄) 각각 `mix phx.routes` → 정렬 → diff:
```
baseline lines: 83   feature lines: 83
diff: (완전 동일) → 라우트 추가/삭제/변경 0
```
baseline은 별도 worktree(`/tmp/omk_baseline`, 독립 _build)에서 컴파일·캡처. **라우트 테이블 바이트 단위 동일.** 매크로 교체가 동작을 정확히 보존.

### ✅ 3. 테스트·검증 그린 — PASS (보고치 재현)

- `mix compile`: 에러 0 (Gettext/File.stream! 사전존재 deprecation 경고뿐).
- `mix test`: **512 passed, 4 skipped** (보고된 512 정확 재현).
- `mix ext.verify`: **9/9 확장 통과**, 각 **8/8 (C1~C8)**.
  ```
  ✅ Ingest/Media/WoCsvExport/DefectStats/LotQrLabel/EquipmentOee/
     DailyProductionSummary/DureClaw/OpenMesExtDemo  (각 8/8)
  합계: 9/9 ✅ (종료코드 0)
  ```

> 주의(아래 §보완권고-1): `mix ext.verify`를 **stale `_build`** 상태에서 처음 실행 시 `check_c2`가 `mod.__info__(:attributes)`에서 `UndefinedFunctionError`로 **raise**(rescue 미적용). `mix compile --force` 후 9/9 정상. 그린 재현 자체는 확인됨.

### ✅ 4. 외부확장 증명 진위 — PASS (전부 실증)

- `open_mes_ext_demo/mix.exs` deps: `{:open_mes_extension_api, path}` + `{:phoenix_live_view}` 뿐. **`:open_mes` 무의존** 확인.
- `router.ex`·`config.exs`에 demo 언급 **각 0건**.
- 데모 활성화 실증: `config :open_mes_ext_demo, ..., enabled: true` 한 줄만 추가(router.ex 0수정) → 재컴파일 → `GET /extensions/demo` **자동 마운트** 확인.
- 원복 후 재컴파일 → 데모 라우트 **0건**(기본 비활성 복귀) 확인.
- demo `enabled?`는 `Application.get_env(..., default: false)` → 기본 off.

### ✅ 5. enabled? 컴파일타임 게이트 정합 — PASS

`RouterMount.mount_extension_routes`(매크로 본문=컴파일타임) → `Discovery.route_specs/0` → `safe_enabled?` 필터. off 확장은 라우트 미기여.
- **off 게이트 실증**: 데모(`enabled:false`, dev override 없음) → `/extensions/demo` **부재**.
- dev 환경 라우트의 Ingest/DailyProductionSummary 출현은 **회귀 아님** — `config/dev.exs`가 둘 다 `enabled: true`로 override(`config.exs` 기본 `false`를 dev에서 켬). baseline도 동일하게 출현(§2 diff 0이 증명). 즉 dev=켜짐이라 라우트가 있는 게 정상.
- 이탈점 #2(애드온 `enabled?`가 `compile_env` 미통일, 런타임 `get_env` 유지)에도 **off-gating은 실효** — 매크로가 컴파일타임에 `get_env`를 평가하고, 그 시점 config 값이 라우트 등재를 결정. demo 토글 실증으로 교차검증됨. (단 §보완권고-2.)

### ✅ 6. 호환 shim — PASS

구 `OpenMes.Extensions.{Registry,Extension,Definition}` 위임 동작 실증(`mix run`):
- `Extensions.Registry.modules/all` == `Extension.Registry.modules/all` (각 9개 일치).
- `Extensions.Extension.categories()` → `Extension.known_categories()` 위임 일치(7종).
- `Extensions.Definition` `use` 매크로 컴파일 OK(새 매크로 위임). 컴파일/참조 깨짐 0.

### ✅ 7. 견고성 — PASS

`Discovery`: `discover_modules`/`implements_extension?`/`safe_enabled?`/`safe_route_spec` 전부 `rescue → []/false/nil`. `RouterMount.ensure_apps_loaded`도 rescue. `Registry`: `safe_enabled?` rescue, `maybe/2`로 선택 콜백 방어. 한 확장 오류가 발견·라우트 전체를 깨지 않음.
- 경미 갭(§보완권고-2): `Registry.to_entry`의 필수 콜백(`id/name/category/version`) 호출은 rescue 미적용 → 발견된 확장이 이들에서 raise 시 카탈로그 렌더 경로가 깨질 수 있음. 단 ext.verify C4가 이를 사전 검출하고, 라우트 경로(`route_specs`)는 완전 rescue라 빌드는 안전.

---

## 설계 이탈점 3건 — 타당성 평가

### ✅ #1 C7 스캔 범위 축소 (트리 전체 → Extension 자기 소스 파일) — 타당

- **위협 여전히 잡힘(결정 실증)**: demo `extension.ex`의 `def id`에 `OpenMes.Repo.insert(%{})` 주입 → `mix ext.verify OpenMesExtDemo.Extension` → **❌ C7 (extension.ex:16), 5/8**. 즉 "외부 확장이 코어 도메인에 직접 쓰기"를 정확히 검출. 원복 확인.
- **축소 정당**: `module_info(:compile)[:source]` 기반으로 외부 dep 실경로(`open_mes_ext_demo/.../extension.ex`)를 정확히 해소(구 `lib/` 글롭은 경로 불일치로 외부 dep 도달 불가 = 검증 불능). 트리 전체 글롭은 EXT-1/2의 정당한 own-table(`equipment_measurements`/`media_assets`) insert까지 false-positive. 구 글롭은 경로 불일치로 사실상 0파일 스캔(허위 그린)이었다는 구현자 진단도 사실. C7은 grep 1차 가드이며 도메인 쓰기 확장은 audit-verify 필수라는 한계 표기 유지.

### ✅ #2 애드온 enabled? compile_env 미통일 (런타임 get_env 유지) — 수용 가능

- 라우트 off-gating은 항목 5에서 실증으로 보장됨(데모 토글 + baseline diff 0). 매크로의 컴파일타임 호출이 그 시점 config 값을 평가하므로, 환경별 config(`config/dev.exs` 등)가 라우트 등재의 단일 진실로 동작. 기존 런타임 토글 테스트도 보존(512 passed).
- 잔여 위험: "런타임에 env로 끄면 라우트는 컴파일타임 값이라 안 빠짐". 이는 컴파일타임 게이트의 본질이며 baseline과 동일. 권고만(§보완권고-2).

### ✅ #3 Discovery.all에 :extensions(self) 병합 — 무결성 OK

- `self_declared(config :extensions 8개) ++ discovered(auto 스캔) → Enum.uniq`. 실측: **Discovery.all = 9개, 중복 모듈 0, id 충돌 0**, 외부 demo 발견 true.
- self 병합 사유 타당: 라우터 컴파일 시점에 호스트(`:open_mes`) 자신의 `.app` 모듈 목록이 미생성 → `:application.get_key`로 self-introspection 불가. 외부 dep은 이미 컴파일·로드되어 스캔으로 잡힘(demo 발견이 증명). 누락(호스트 in-tree 확장이 config로 보강)·중복(uniq + C5 빈도검사) 모두 방어.

---

## 도메인 불변식 회귀 점검 — PASS

`git status` 변경 파일 중 코어 도메인(`production/audit/outbox/lots/master_data/ai`) **0건**. 모든 `lib/` 변경은 `extensions/`·`addons/`·`connect/`·`ingest/`·`media/`·`_web/`·`mix/tasks` 한정. AuditLog/LOT Genealogy/Outbox/상태머신 코드 미변경 → 회귀 위험 구조적으로 0. `mix test` 512 passed가 도메인 테스트 그린 보증.

---

## 보완권고 (블로킹 아님, S6/후속)

1. **ext.verify C2 rescue 추가**: `check_c2`의 `mod.__info__(:attributes)`가 미로드 모듈에서 `UndefinedFunctionError` raise(stale `_build`에서 재현). `verify_module`이 `Code.ensure_loaded(mod)`를 호출하나 BEAM 부재 시 로드 실패 → C2에서 죽음. C4/C5/C7 수준의 rescue로 감싸 "C2 ❌ 모듈 미로드"로 보고하면 견고성·UX 개선. (run 진입에서 `Mix.Task.run("compile")` 하므로 정상 흐름에선 안 터지나, 부분 빌드 시 노출.)
2. **(택1) 라우트 기여 확장 enabled? compile_env 통일 또는 계약 문구 완화**: 현재 RouterMount moduledoc은 "enabled?는 `Application.compile_env`를 써야 한다"고 명시하나, 실제 애드온/Ingest/demo는 `get_env`. 동작은 정합(컴파일타임 평가)하나 문서-코드 불일치. 통일하거나 moduledoc을 "컴파일타임에 평가되는 config 기반이면 충분"으로 정정 권장.
3. **(선택) Registry.to_entry 필수 콜백 rescue**: 발견된 외부 확장의 `id/name/category`가 raise하면 카탈로그 렌더 경로가 깨질 수 있음(라우트 경로는 안전). C4가 사전검출하므로 우선순위 낮음.

---

## 실행 명령 근거 요약

- 단방향: `grep -rln "OpenMes.Extension" lib/open_mes/{각 도메인}` → 0건.
- 라우트: baseline worktree(HEAD) vs feature `mix phx.routes | sort | diff` → 0.
- 그린: `mix compile`(0 err) / `mix test`(512 passed,4 skipped) / `mix ext.verify`(9·9, 8/8).
- 외부확장: demo mix.exs deps 검사 + dev.exs 1줄 토글로 `/extensions/demo` 자동마운트·원복 부재 실증.
- C7: demo extension.ex에 `OpenMes.Repo.insert` 주입 → C7 ❌ → 원복.
- Discovery: `mix run`으로 self 8 + 발견 → uniq 9, 중복0·id충돌0·demo발견 확인.
- shim: `mix run`으로 구/신 Registry·categories 위임 일치 확인.
- 정리: `/tmp/omk_baseline` worktree 제거, 임시 변경 전부 원복(워킹트리 부작용 0 확인).
