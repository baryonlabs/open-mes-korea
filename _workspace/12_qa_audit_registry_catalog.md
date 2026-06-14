# 12. QA 감사: 확장 레지스트리 + 홈페이지 카탈로그 + 앱 골격 (기반 작업)

- **감사자**: qa-auditor
- **감사일**: 2026-06-13
- **대상**: `_workspace/10_registry_catalog_impl/` 전체
- **설계 기준**: `_workspace/09_architect_registry_catalog_design.md` (§1, §3, §4)
- **원칙**: `CLAUDE.md` (pi, 확장 모듈 구조)
- **최종 판정**: ✅ **APPROVED**

> 이 작업물은 **도메인 쓰기 0**(레지스트리/카탈로그/EXT 메타데이터는 메타데이터 조회 + 화면 렌더뿐)이다.
> 설계 §6 명시대로 AuditLog/LOT/Outbox 룰의 새 적용 대상이 없다 → 해당 룰 부재는 정상(오탐 금지 준수).
> 감사 축은 **의존 방향 단방향 / 계약 안정성 / 상태 없음·견고성 / 카탈로그 / EXT 비침투 / 골격 일관성 / pi 최소** 7개.

---

## 항목별 결과

### 1. 의존 방향 단방향 (가장 중요) — ✅

코어 도메인이 확장/레지스트리를 참조하지 않아야 한다는 불변식을 grep으로 검증.

- 02(코어 audit/outbox/production/web), 06(EXT-1 ingest), 07(EXT-2 media) 전체에서
  `OpenMes.Extensions` / `OpenMes.Addons` 참조 **0건**.
- 의존 방향: `확장/카탈로그 → Registry ← 확장`만 성립.
  - `registry.ex`는 `Application.get_env(:open_mes, :extensions)`만 읽고 코어 도메인을 일절 import/alias하지 않음.
  - `catalog_live.ex:13`은 `OpenMes.Extensions.Registry`만 alias.
  - `open_mes_ingest/extension.ex:9` / `open_mes_media/extension.ex:12`는 `use OpenMes.Extensions.Definition`(확장 → 레지스트리 방향, 정상).
- 레지스트리/카탈로그를 통째로 들어내도 WorkOrder API는 그대로 동작함(코어 무의존 확인). CLAUDE.md L37-39 "코어는 확장 없이 동작" 원칙 유지.

**판정: ✅ 통과.** 가장 중요한 불변식이 코드 수준에서 깨끗하게 성립.

### 2. Extension behaviour 계약 안정성 — ✅

- `extension.ex`: 필수 6개(`id/0`, `name/0`, `description/0`, `category/0`, `version/0`, `enabled?/0`) + 선택 2개(`home_path/0`, `icon/0`) 콜백이 `@callback`으로 명확히 정의(L44-76). `@optional_callbacks [home_path: 0, icon: 0]`(L79)로 선택 콜백 지정.
- `category` 타입(L42)이 6개 atom 합집합으로 고정 → 카탈로그 필터/라벨과 일치.
- `definition.ex`: `__using__` 매크로가 `@behaviour` 채택 + `home_path/0`/`icon/0`에 **기본값 nil 주입**(L36-40) + `defoverridable`(L43)로 화면 있는 확장만 override 가능. 설계 §1.1 매크로와 정확히 일치.
- 계약 안정성 검증: `extension_test.exs`가 EXT-1/EXT-2 모듈의 필수 콜백 타입(L17-39), 선택 콜백 nil/String(L41-53), behaviour 채택 여부(L55-67), id 고유성(L69-74)을 검증. 애드온 5개는 `@extension_modules` 리스트(L12-15)에 한 줄 추가만으로 동일 검증 — "애드온 5개가 이 계약으로 안정적으로 꽂힐 수 있는가"를 구조적으로 보장.
- 매크로가 `def home_path, do: nil`을 주입하므로 `Registry.maybe/2`의 `function_exported?` 가드와 무관하게 항상 안전(EXT-2가 home_path를 override하지 않아도 nil 반환 — `media/extension.ex:34` 주석으로 의도 명시).

**판정: ✅ 통과.**

### 3. Registry 상태 없음 + 견고성 — ✅

- **상태 없음**: `registry.ex`는 GenServer/ETS/DB 없음. `Application.get_env`(L39) + 각 모듈 콜백 호출(L65-77)뿐. `all/0`/`enabled/0`/`by_category/0` 모두 순수 조회. 설계 §1.3 "상태 없는 순수 조회 모듈" 일치.
- **견고성**: `safe_enabled?/1`(L82-86)이 `enabled?/0`의 raise를 rescue → 예외 시 `false`로 간주. 한 확장이 죽어도 카탈로그 전체가 살아남음.
- **회귀 테스트로 고정**:
  - `registry_test.exs:62-71`: `Raising` 픽스처(`enabled?`가 raise) 포함 시에도 `all/0`이 4개 엔트리 반환, 해당 확장은 `enabled=false`.
  - `registry_test.exs:98-106`: 확장 0개에서 `all/enabled/by_category` 모두 안전.
- `to_entry`의 `id/name/description/category/version`은 `safe_enabled?`로 감싸지 않음 — 단, 이들은 컴파일 타임 상수 반환 함수라 raise 가능성이 사실상 없음(애드온 계약상 정적 메타데이터). 설계 의도(enabled?만 config 의존이라 방어)와 일치. **결함 아님.**

**판정: ✅ 통과.**

### 4. 카탈로그 LiveView — ✅

- **전체 노출**: `catalog_live.ex:27`이 `Registry.all/0`(비활성 포함) 사용 → 등록 7개(현재 EXT 2개) 전부 카드. `catalog_live_test.exs:35-42`가 4개 픽스처 전부 렌더 확인.
- **enabled/disabled 배지**: `badge_class/1`(L136-140) 활성=초록/비활성=회색, "활성"/"비활성" 텍스트(L105). 테스트 L44-49.
- **카테고리 필터**: 상단 "전체" + 카테고리 버튼(L70-87), `handle_event("filter", ...)`(L46-55)로 `visible` 갱신. `String.to_existing_atom`(L52)으로 임의 atom 생성 방지 — 카테고리 atom은 등록 확장 `category/0`로 이미 정의되어 있으므로 안전. 테스트 L67-95(필터 적용 + 전체 복원).
- **화면 링크**: `open_link?/1`(L131-132)이 `enabled and is_binary(path) and path != ""` → 활성+화면 있는 확장만 "열기". 비활성/무화면은 링크 숨김. 테스트 L51-58(활성+화면 링크 노출, 비활성+화면 링크 미노출).
- **전체 비활성 회귀**: `catalog_live_test.exs:98-115` 명시 — 모든 확장 비활성이어도 정상 렌더(비활성 카드만), 확장 0개여도 죽지 않음. **요구된 회귀 테스트 존재.**
- pi 준수: phx.new core_components/layout 재사용, `~H` 인라인 템플릿, 새 CSS/차트 라이브러리 미도입.

**판정: ✅ 통과.**

### 5. EXT-1/EXT-2 메타 모듈 — ✅

- **기존 파이프라인 무변경**: 06/07 디렉토리에 `OpenMes.Extensions`/`OpenMes.Addons` 참조 0건(항목 1). 추가된 것은 `open_mes_ingest/extension.ex`, `open_mes_media/extension.ex` **메타데이터 모듈 1개씩뿐**. 기존 `OpenMes.Ingest.*`/`OpenMes.Media.*` 파이프라인 코드 손대지 않음.
- **enabled? 위임**:
  - `ingest/extension.ex:29` → `OpenMes.Ingest.enabled?()` (06 `ingest.ex:23`에 실존).
  - `media/extension.ex:32` → `OpenMes.Media.enabled?()` (07 `media.ex:27`에 실존).
  - 위임 정확성을 `extension_test.exs:76-84`가 등가 검증(`Extension.enabled? == Facade.enabled?`).
- **home_path 정합성**:
  - EXT-1 `home_path = "/ingest/health"`(L32) — 06 router 패치/컨트롤러에 `GET /ingest/health` 실존(검증됨).
  - EXT-2는 자체 HTML 화면 없는 백그라운드 파이프라인 → `home_path` 기본값 nil 유지(L34 주석). 카탈로그에서 "열기" 링크 없이 카드만 노출 — 올바름.

**판정: ✅ 통과.**

### 6. 앱 골격 통합 전략 — ✅

- **mix.exs(`skel/mix.deps.exs`)**: phx.new 기본 deps + EXT-1(`broadway`) + EXT-2(`ex_aws`/`ex_aws_s3`/`sweet_xml`/`hackney`/`file_system`) 병합. 애드온 deps(`eqrcode`/`nimble_csv`)는 범위 밖이라 주석 처리(L41-42). 레지스트리/카탈로그는 추가 deps 0(순수 Elixir + phx.new LiveView 스택)임을 명시(L44-45). **병합 가이드임을 헤더에 명시(재작성 아님).**
- **config(`config/config.exs`)**: `:extensions` 명시 목록(현재 EXT 2개, 애드온 5개는 주석 슬롯) + EXT-1/2 기본 `enabled: false` 게이트. `import_config` 유지 주석(L53-54). 설계 §5 일치.
- **runtime.exs / test.exs**: `INGEST_*`/`MEDIA_*` 환경변수 게이트, test에서 EXT-1 `enabled: true`(라우트 테스트용). phx.new prod/test 보일러플레이트 유지를 헤더에 명시.
- **application.ex(`skel/`)**: phx.new children + `++ ingest_children() ++ media_children()`. 조건부 게이트(`if enabled?`)로 off 시 빈 리스트. 애드온은 supervised child 없음(읽기 전용) 주석으로 명시. 설계 §4.4 일치.
- **router.ex(`skel/`)**: `:browser` 파이프라인(phx.new 기본) + `/`·`/extensions` → CatalogLive + 코어 `/api`(02) + 조건부 `/ingest`(06, 컴파일 타임 `if enabled?` 게이트). 애드온 scope 5개는 주석 슬롯(L76-110)으로 미리 표시.
- **README 통합 매핑**: §1 매핑표가 02/10/06/07 출처→대상을 정확히 기술. §2 마이그레이션 순서(타임스탬프 오름차순, 코어 먼저), §3 통합 순서, §4 애드온 슬롯 3곳 명시. "phx.new 보일러플레이트 재작성 금지" 원칙 일관.

> **경미(결함 아님, 통합 시 주의)**: `skel/router.ex`/`application.ex`/`config.exs`는 phx.new 골격 위 **병합 기준 파일**이지 통째 교체 파일이 아님을 각 헤더가 명확히 함. 다만 `application.ex`는 phx.new가 생성하는 추가 코어 child(있다면)를 보존해야 하므로 통합 시 "끝에 `++`만 추가" 원칙을 지킬 것 — README §3에 이미 반영됨.

**판정: ✅ 통과 (phx.new 보일러플레이트 재작성 없이 얹는 구조).**

### 7. pi 최소 — ✅

- 마켓플레이스/동적 설치/원격 다운로드/버전 호환성 매트릭스/의존성 해석기 **없음**. 레지스트리는 config 명시 목록 조회 + 콜백 호출까지만.
- 새 DB 테이블 0, GenServer/ETS/상태 0. 레지스트리/카탈로그/EXT 메타데이터는 도메인 쓰기 0.
- **(오탐 금지 준수)** 레지스트리/카탈로그에 AuditLog/Outbox가 없는 것은 도메인 쓰기가 없기 때문이며 정상 — 이를 위반으로 지적하지 않음(설계 §6, 사용자 지시 7번 준수).
- 카드 컴포넌트 인라인(별도 파일 분리 안 함), 헬퍼 인라인 — pi "인라인 우선" 일치.

**판정: ✅ 통과.**

---

## 위반 / 수정 필요 항목

**없음.** 7개 항목 모두 통과. 차단/수정 필요 위반 0건.

---

## 통합 시 참고 메모 (결함 아님 — 후속 작업자용)

1. **애드온 통합 시 3곳만 수정**: `config.exs`의 `:extensions` + 게이트, `router.ex` 조건부 scope(주석 해제), `lib/open_mes_addons/{addon}/`. 카탈로그는 코드 변경 없이 자동 노출.
2. **`extension_fixtures.ex` 위치**: `test/support/`에 둠 — phx.new 기본 test_helper의 support 컴파일 경로(`elixirc_paths(:test)`)에 포함되어야 컴파일됨(phx.new 기본 mix.exs가 `test/support`를 포함하므로 정상).
3. **마이그레이션 0개**: 이 기반 작업은 새 테이블이 없어 마이그레이션 의존성 추가 없음.

---

## 최종 판정

# ✅ APPROVED

확장 레지스트리 + 카탈로그 + 앱 골격 기반 작업은 설계 §1/§3/§4와 pi 원칙을 충실히 구현했다.
- **의존 방향 단방향**(가장 중요)이 코드 수준에서 깨끗하게 성립(코어→확장 참조 0건).
- behaviour 계약이 안정적이고, Definition 매크로가 선택 콜백 nil을 올바르게 주입하여 애드온 5개가 안정적으로 꽂힐 구조.
- 레지스트리는 상태 없음 + `safe_enabled?` 견고성을 갖추고 회귀 테스트로 고정됨.
- 카탈로그는 전체 노출/배지/필터/링크/전체 비활성 회귀 테스트를 모두 충족.
- EXT-1/2 메타 모듈은 기존 파이프라인 무변경 + 기존 게이트 위임.
- 앱 골격은 phx.new 보일러플레이트 재작성 없이 얹는 병합 구조이며 README 매핑이 정확.

도메인 쓰기가 0이므로 AuditLog/LOT/Outbox 룰의 새 적용 대상이 없으며, 그 부재를 위반으로 지적하지 않았다(오탐 금지 준수).
