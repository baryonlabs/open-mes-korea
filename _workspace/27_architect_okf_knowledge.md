# 27 · Architect — OKF 지식베이스 (RAG 문서 영역)

**대상 기능:** Open MES Korea의 RAG 문서 영역을 OKF(Open Knowledge Format) 번들로 구현. 표준작업서·설비 매뉴얼·품질 기준서·검사 기준·교육 문서·트러블슈팅 문서를 OKF 개념 문서(YAML 프론트매터 + 마크다운)로 관리하고, AI 종합 조사(`investigate`)가 설비/공정 연관 문서를 검색·발췌·인용하게 한다.

**선행 설계:** 23(AI 라인 구성/Provider/AiInteraction), 25(AI 종합 조사 — `investigation.ex`), EXT-5 커넥터 카탈로그(RAG 외부 커넥터). 본 설계는 **RAG를 외부 커넥터에서 내부 OKF 번들로 전환/보완**한다(extension-roadmap.md L171 "RAG는 외부 커넥터" → 내부 OKF로 1차 충족).

**원칙 준수:** pi(최소 필드·순수함수·과설계 금지), 이력성(AuditLog 필수 = OKF `log.md` 대응), AI 안전(읽기·인용만, 쓰기 0, AiInteraction 감사), 한국어 UI / 영문 식별자, OKF 관용적 소비(깨진 것 거부 금지).

---

## 0. 핵심 결정 5가지 (요약)

1. **저장은 DB(PostgreSQL) 단일 원천, OKF 번들은 import/export 표현.** 웹앱 현실상 KnowledgeDocument 테이블이 단일 진실. OKF 마크다운 디렉토리(`priv/knowledge/`)는 **git 교환·인간 열람·타 OKF 도구 호환**을 위한 직렬화 형태일 뿐. DB↔번들 양방향 변환은 순수함수 파서/생성기가 담당.

2. **OKF 파서/생성기는 순수함수 + 경량 YAML(외부 dep 0).** 프론트매터는 단순(스칼라/리스트/문자열)하므로 `yaml_elixir` dep 도입 대신 **`OpenMes.Okf.Frontmatter` 경량 파서**를 직접 구현. `---` 구분, `key: value`, `tags:` YAML 리스트(`- item` / `[a, b]`)만 지원. 미지 필드는 **그대로 보존**(관용적 소비). 이유: pi(deps 최소), 프론트매터 스펙이 작다, 우리가 생성한 것을 우리가 읽는 닫힌 루프가 주 경로.

3. **`okf_type`만 필수, 나머지 전부 선택.** 미지 type("표준작업서"·"트러블슈팅"·임의 문자열) 허용, 미지 필드 보존, 깨진 크로스링크/누락 index 거부 금지. 최소 적합성 위반(type 없음/YAML 파싱 실패)은 **reject가 아니라 경고(import 시 type 기본값 주입 + 경고 누적)**.

4. **AI는 OKF 문서를 읽고 인용만 — 쓰기 0.** `investigate` 컨텍스트에 **관련 문서 N건 + 본문 발췌(토큰 방어)**를 추가. 검색은 설비/공정 키(equipment_code/process_code) ↔ 문서 `tags`/`resource` 매칭. 인용 문서의 `resource` URI를 `referenced_resources.knowledge`에 기록. RAG 문서는 생산 데이터와 분리(읽기 전용 컨텍스트, 별도 바운디드 컨텍스트 `OpenMes.Knowledge`).

5. **기존 화면/라우트/AI 연동 무손상.** `investigate`는 기존 시계열+미디어+생산 종합을 유지하고 **`knowledge` 섹션을 컨텍스트에 추가**만 한다(`build_context/3`에 한 줄). 라인구성(propose→승인)·investigate 상태머신 그래프 변경 0. 새 메뉴는 "설정" 그룹 아래 "지식베이스" 항목 추가.

---

## 1. OKF 데이터 모델

### 1.1 새 바운디드 컨텍스트 — `OpenMes.Knowledge`

생산 데이터와 분리(ai-native-architecture "RAG 문서 영역은 생산 데이터와 분리"). 디렉토리:

```
lib/open_mes/knowledge/
├── knowledge.ex            # 컨텍스트(CRUD + AuditLog + 검색 + import/export 조율)
├── knowledge_document.ex   # Ecto 스키마 + changeset
└── ../okf/                 # 순수함수 OKF 파서/생성기 (§2, 컨텍스트와 분리)
    ├── frontmatter.ex      # 경량 YAML 프론트매터 파서/생성기
    ├── document.ex         # 문서 1건 parse/generate
    └── bundle.ex           # 번들(디렉토리) import/export, index.md/log.md
```

**pi 주의:** `okf/`는 순수함수 3모듈로 분리한다(파서는 테스트 가능한 순수 로직이고 컨텍스트와 책임이 다르므로 분리 정당 — 인라인 우선 예외). `knowledge.ex`는 MasterData와 동형의 컨텍스트(CRUD + Multi + AuditLog).

### 1.2 KnowledgeDocument 엔티티 (최소 필드)

테이블 `knowledge_documents`, `binary_id` PK(코어 일관). **OKF 필드 + RAG 추적 필드만.**

| 필드 | 타입 | null | OKF 매핑 | 설명 |
|------|------|:---:|---------|------|
| `id` | binary_id | PK | — | binary_id |
| `okf_type` | string | **NOT NULL** | `type` (필수) | "표준작업서"/"설비매뉴얼"/"품질기준서"/"검사기준"/"교육문서"/"트러블슈팅" 등. **자유 문자열**(미지 type 허용) |
| `title` | string | null | `title` (권장) | 문서 제목(한국어) |
| `description` | string | null | `description` (권장) | 한 줄 요약 |
| `resource` | string | null | `resource` (권장) | 정규 URI. 없으면 export 시 자동 생성(§2.3) |
| `tags` | `{:array, :string}` | NOT NULL default `[]` | `tags` (YAML 리스트) | 설비/공정 연관 + 분류. 예: `["EQ-P03", "P-INJECTION", "사출"]` |
| `body` | text | NOT NULL default `""` | 마크다운 본문 | 문서 본문(마크다운) |
| `extra` | `:map` (jsonb) | NOT NULL default `%{}` | **미지 프론트매터 필드 보존** | 관용적 소비 — 모르는 키를 버리지 않고 round-trip 보존 |
| `version` | string | null | (RAG 추적) | 문서 버전("1.0", "2025-rev2"). MVP는 문자열(증가 로직 없음 — YAGNI) |
| `uploaded_by` | string | NOT NULL | (RAG 추적) | 업로드/작성 actor_id |
| `valid_until` | date | null | (RAG 추적) | 유효기간(있으면 만료 표시, 검색 시 만료 문서 제외 옵션) |
| `active` | boolean | NOT NULL default true | — | MasterData 동형(삭제 없음, active=false 비활성) |
| `inserted_at`/`updated_at` | utc_datetime_usec | — | `timestamp`(권장, ISO 8601) | export 시 `updated_at`을 `timestamp`로 |

**제외(YAGNI):** 원본 파일 바이너리(업로드 파일 저장)는 MVP 미포함 — 본문은 마크다운 텍스트로 직접 관리. 첨부 파일은 후속(`resource`로 외부 URI 참조 가능). 벡터 임베딩 컬럼 미포함(검색은 키워드/태그 매칭 — §4.1, 임베딩은 검증되면 후속).

### 1.3 인덱스 / 제약

```elixir
create table(:knowledge_documents, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :okf_type, :string, null: false
  add :title, :string
  add :description, :string
  add :resource, :string
  add :tags, {:array, :string}, null: false, default: []
  add :body, :text, null: false, default: ""
  add :extra, :map, null: false, default: %{}
  add :version, :string
  add :uploaded_by, :string, null: false
  add :valid_until, :date
  add :active, :boolean, null: false, default: true
  timestamps(type: :utc_datetime_usec)
end

create index(:knowledge_documents, [:okf_type])
create index(:knowledge_documents, [:active])
create index(:knowledge_documents, [:tags], using: "gin")   # tags 배열 검색(설비/공정 매칭 핵심)
create unique_index(:knowledge_documents, [:resource],
  where: "resource IS NOT NULL", name: :knowledge_documents_resource_index)
```

- `tags` GIN 인덱스: 설비 `EQ-P03` → `tags @> ['EQ-P03']` 문서 매칭(§4.1)의 성능 핵심.
- `resource` partial unique: URI 있으면 유일(OKF 정규 URI). nil 허용(권장 필드).
- **append-only 아님**(문서는 수정 가능) — 단 **모든 수정에 AuditLog**가 변경 이력 = OKF `log.md` 대응(§1.4).

### 1.4 AuditLog = OKF `log.md` 대응

`knowledge_document.create` / `.update` AuditLog가 OKF 번들의 `log.md`(변경 이력) 원천. export 시 AuditLog를 조회해 `log.md` 생성(§2.3). resource_type = `"knowledge_document"`.

### 1.5 관계 (설비/공정 ↔ 문서)

**MVP는 `tags` 매칭 + OKF 크로스링크로 표현(별도 link 테이블 없음 — YAGNI).**

- 문서가 설비/공정과 연관 → `tags`에 `equipment_code`/`process_code`를 넣는다(예: `["EQ-P03"]`, `["P-INJECTION"]`). AI 검색이 이 태그로 매칭(§4.1).
- OKF 크로스링크: 본문 마크다운에 상대/절대 링크(`[EQ-P03 설비 매뉴얼](../설비매뉴얼/eq-p03.md)`)로 문서 간 관계 표현. **관용적 소비 — 깨진 링크 거부 금지**(검증·차단 안 함, 그대로 보존).
- `resource`는 도메인 엔티티 참조에도 사용 가능(예: `mes://equipment/EQ-P03`) — 단 **기존 스키마 대체 아님, 참조만**.
- 별도 `KnowledgeLink` 테이블은 다대다 관계가 실제로 복잡해질 때 후속(확장 포인트로 남김).

---

## 2. OKF 파서 / 생성기 (순수 함수)

### 2.1 `OpenMes.Okf.Frontmatter` — 경량 YAML 프론트매터 (외부 dep 0)

순수함수. `---\n...\n---\n본문` 분리 + 최소 YAML 파싱.

```elixir
@doc "마크다운 텍스트 → {:ok, %{frontmatter: map(문자열키), body: String.t}}. 관용적: 항상 ok."
def parse(text) when is_binary(text)
# 1) "---\n" 로 시작 → 다음 "---\n" 까지가 프론트매터, 나머지가 body.
#    프론트매터 구분자 없으면 frontmatter: %{}, body: 전체 (거부 안 함 — 관용적).
# 2) 각 줄 "key: value" 파싱. value 스칼라(문자열/숫자/불리언/ISO 날짜는 문자열 보존).
# 3) "tags:" 다음 들여쓴 "- item" 블록 또는 "tags: [a, b]" 인라인 → 리스트.
# 4) 파싱 불가 줄은 무시(경고 누적 가능) — 거부 금지.
# 5) 미지 키 전부 보존(map 그대로).

@doc "frontmatter map → YAML 프론트매터 문자열(--- 포함). 결정적 순서."
def generate(frontmatter_map) when is_map(frontmatter_map)
# 권장 필드 순서(type 먼저) → 미지 필드 → tags 리스트. 값에 따옴표 필요 시 quote.
```

**파싱 지원 범위(의도적 최소):** 스칼라 문자열/숫자/불리언, 문자열 리스트(`tags`), 중첩 없음. 복잡한 중첩 YAML은 **`extra`에 원문 보존하되 파싱 실패는 경고**(거부 아님). 닫힌 루프(우리 생성→우리 소비)에선 충분, 외부 OKF 도구가 만든 단순 프론트매터도 수용.

> **대안 검토:** `yaml_elixir` dep 도입 — 완전한 YAML이지만 pi(deps 최소) 위반, 프론트매터가 단순해 과함. **경량 파서 채택.** 단 domain-engineer가 구현 중 중첩 프론트매터 요구가 실증되면 dep 전환 가능(파서 인터페이스 `parse/1`·`generate/1` 유지 → 교체 격리).

### 2.2 `OpenMes.Okf.Document` — 문서 1건 변환

```elixir
@doc "OKF 마크다운 → KnowledgeDocument attrs. type 없으면 경고 + 기본값."
def parse(text, default_uploaded_by) :: {attrs :: map, warnings :: [String.t]}
# Frontmatter.parse → 권장 필드(type→okf_type, title, description, resource, tags, timestamp)를
# 컬럼에 매핑. 나머지 미지 필드 → extra. type 없으면 okf_type: "미분류" + 경고.

@doc "KnowledgeDocument → OKF 마크다운 텍스트(.md)."
def generate(%KnowledgeDocument{} = doc) :: String.t
# 프론트매터(okf_type→type, title, description, resource(없으면 §2.3 생성), tags,
#   timestamp(updated_at ISO8601), version, valid_until) + extra 병합 → Frontmatter.generate
#   ++ "\n" ++ doc.body.
```

### 2.3 `OpenMes.Okf.Bundle` — 번들 import/export (예약 파일)

```elixir
@doc "KnowledgeDocument 목록 → OKF 번들 디렉토리 구조 맵(파일경로 → 내용). 쓰기는 호출측."
def export(documents, audit_logs_by_doc) :: %{String.t => String.t}
# 산출:
#   "index.md"              루트 목록 + okf_version: "0.1" 프론트매터
#   "{okf_type}/{slug}.md"  각 문서(Document.generate). slug = title 또는 id.
#   "{okf_type}/index.md"   type별 목록(예약 파일)
#   "log.md"                AuditLog → 변경 이력(예약 파일)

@doc "번들 디렉토리(파일맵) → [{attrs, warnings}]. 누락 index/log 허용(관용적)."
def import_bundle(file_map, default_uploaded_by) :: [{map, [String.t]}]
# index.md/log.md 없어도 진행. *.md 중 예약 파일 제외하고 Document.parse.
# okf_version 미지/없음 허용.
```

**루트 `index.md` 프론트매터(OKF 적합성):**
```yaml
---
okf_version: "0.1"
title: Open MES Korea 지식베이스
type: 색인
---
```

### 2.4 최소 적합성 검증 (거부 아님 — 경고)

`OpenMes.Okf.Document.parse`가 누적하는 경고:
- `type` 필드 누락 → "type 필드가 없어 '미분류'로 처리합니다" + `okf_type: "미분류"`.
- 프론트매터 구분자(`---`) 없음 → "프론트매터 없음 — 전체를 본문으로 처리".
- 파싱 불가 줄 → "n번째 줄 파싱 실패(무시)".

**import UI는 경고를 표시하되 저장은 진행**(관용적 소비). 절대 reject 하지 않음.

---

## 3. 문서 관리 UI

### 3.1 라우트 (router.ex — "설정" scope 내 추가, 기존 무손상)

```elixir
# 설정 그룹 하위 — 23번 settings 라우트 블록에 이어서
live "/settings/knowledge", KnowledgeLive, :index
live "/settings/knowledge/new", KnowledgeLive, :new
live "/settings/knowledge/:id", KnowledgeLive, :show
live "/settings/knowledge/:id/edit", KnowledgeLive, :edit
# OKF export/import는 컨트롤러(파일 다운로드/업로드 — LiveView 부적합)
get "/settings/knowledge/export", KnowledgeExportController, :export   # zip 번들 다운로드
post "/settings/knowledge/import", KnowledgeImportController, :import   # zip 업로드
```

### 3.2 화면

- **목록(`index`):** 문서 카드/테이블. 필터 — `okf_type` 셀렉트, `tags` 검색(부분일치), `active`. 만료(`valid_until` 경과) 배지. "OKF 내보내기" 버튼(번들 zip), "OKF 가져오기" 버튼(zip 업로드 → 경고 표시 후 저장).
- **상세(`show`):** 프론트매터 메타 + 마크다운 렌더 본문 + 변경 이력(해당 문서 AuditLog) + 단건 `.md` 다운로드.
- **편집(`new`/`edit`):** 폼 — okf_type(셀렉트+자유입력), title, description, resource, tags(쉼표/리스트 입력), version, valid_until, **body 마크다운 에디터(textarea + 미리보기 토글)**. 미리보기는 기존 마크다운 렌더 헬퍼 재사용(없으면 textarea만 — pi).

### 3.3 메뉴 (admin_components.ex — "설정" 그룹에 항목 추가)

```elixir
%{label: "지식베이스", path: "/admin/settings/knowledge", enabled: true,
  roles: ["quality_manager"]},   # system_admin 항상, quality_manager 추가
```

품질관리자가 품질기준서/검사기준/표준작업서의 주 관리자. `system_admin`은 전체. 생산관리자도 필요 시 roles에 추가 가능(사용자 확인 — MVP는 system_admin + quality_manager).

### 3.4 권한

- 문서 **쓰기**(생성/수정/import): `system_admin`, `quality_manager`(Authorization.allowed?/2 prefix 매칭이 라우트 자동 인가).
- 문서 **읽기**(AI 검색 컨텍스트): `investigate` role(`system_admin`/`production_manager`/`quality_manager`)이 이미 인가됨 — 문서 검색은 그 안에서 일어남(§4).

---

## 4. AI investigate 연동 (핵심 — RAG)

### 4.1 문서 검색 (`OpenMes.Knowledge.search_for_subject/2`) — 순수 읽기

```elixir
@doc """
설비/공정 기준 관련 OKF 문서 검색(읽기 전용). tags ⊇ {equipment_code, process_codes}
또는 resource/제목 매칭. 만료(valid_until < today) 제외. active=true. 상한 N건.
반환: 문서 N건(본문 발췌 포함) — 토큰 방어로 raw 전량 금지.
"""
def search_for_subject(%{equipment_code: code, process_codes: codes}, limit \\ 5)
# WHERE active AND (valid_until IS NULL OR valid_until >= today)
#   AND tags && [code | codes]          # 배열 교집합(GIN 인덱스)
# ORDER BY (태그 매칭 수 desc, updated_at desc)
# LIMIT limit. 각 문서 body → 발췌(excerpt/2, §4.2).
```

매칭 키:
- 설비: `equipment_code`(예 `EQ-P03`)가 문서 `tags`에 포함.
- 공정: 해당 설비/기간의 `process_code`(들)가 `tags`에 포함.
- (확장 포인트) 키워드 검색은 후속 — MVP는 태그 교집합으로 충분(seed가 태그로 연관 보장).

### 4.2 발췌 (토큰 방어 — 순수함수)

```elixir
@doc "마크다운 본문 → 앞부분 + 헤더 요약 발췌(최대 max_chars). raw 전량 금지."
def excerpt(body, max_chars \\ 600)
# 본문 선두 max_chars + 잘림 표시. (MVP: 단순 truncate. 헤더 추출 고도화는 후속.)
```

문서당 ~600자, 최대 5건 → 컨텍스트 추가 ~3KB 상한. 시계열/미디어/생산 컨텍스트 토큰 예산 침해 최소.

### 4.3 `build_context/3` 연동 (investigation.ex — 한 곳 추가, 기존 무손상)

```elixir
# build_context/3 안, production 다음 줄에 추가:
knowledge = build_knowledge(equipment, production)   # 신규

context = %{
  subject: %{...},          # 기존
  period: %{...},           # 기존
  timeseries: timeseries,   # 기존
  media: media,             # 기존
  production: production,   # 기존
  knowledge: knowledge,     # ★ 신규 — 관련 OKF 문서 N건 + 발췌
  referenced: %{
    ...,                                          # 기존
    sources: [... | "knowledge_documents"],       # 출처에 추가
    knowledge: knowledge_refs(knowledge)          # ★ 인용 resource URI 목록
  }
}
```

```elixir
defp build_knowledge(equipment, production) do
  process_codes = production_process_codes(production)   # 생산 컨텍스트에서 공정코드 수집
  docs = Knowledge.search_for_subject(
    %{equipment_code: equipment.equipment_code, process_codes: process_codes}, 5)

  %{
    documents: Enum.map(docs, fn d ->
      %{okf_type: d.okf_type, title: d.title, resource: d.resource || canonical_uri(d),
        tags: d.tags, excerpt: Knowledge.excerpt(d.body)}
    end),
    total: length(docs)
  }
end

# referenced.knowledge — Claude가 인용할 resource URI 목록(감사·인용 추적).
defp knowledge_refs(%{documents: docs}),
  do: Enum.map(docs, & &1.resource)
```

- **기존 시계열+미디어+생산 종합 유지**(추가만). `investigate/3` 흐름·AiInteraction·AuditLog·상태머신 변경 0.
- `referenced_resources.knowledge`가 AiInteraction에 저장(이미 `stringify(context.referenced)` 경로 통과) → Claude가 근거로 인용한 문서 URI가 감사에 남음.

### 4.4 Provider 프롬프트 (인용 유도 — investigate_system_prompt 보강)

`ClaudeProvider.investigate_system_prompt`에 한 줄 추가(MockProvider도 동형):
> "조사 컨텍스트의 `knowledge` 문서(표준작업서·트러블슈팅 등)를 근거로 인용할 때는 해당 문서의 `resource`를 함께 제시하라. 컨텍스트에 없는 문서를 인용하지 마라."

context+query만 받는 구조 유지(Repo 접근 불가) — 문서 발췌는 이미 context에 들어가 있음.

---

## 5. AI 안전 체크포인트 (ai-safety-guardian 검증 대상)

| 항목 | 준수 방법 |
|------|----------|
| AI 쓰기 0 | 문서 검색·발췌는 **읽기 전용**. AI는 문서를 생성/수정/삭제하지 못함. `investigate`에 insert/update/delete 추가 0(기존 AiInteraction 감사 1건 유지). |
| DB 직접 접근 0 | `build_knowledge`가 만든 **plain map(발췌 포함)**만 Provider에 전달. Provider는 map+query만 받음 → 구조적 Repo 차단(기존 불변식 동형). |
| 권한 필터 | 문서 검색은 `build_context/3`의 `authorize/1`(investigation_roles) **안에서** 호출 → 미인가 role은 컨텍스트 자체를 못 받음. 만료/비활성 문서 제외. |
| 근거 표시 | 인용 문서 `resource` URI를 `referenced.knowledge`에 기록 → AiInteraction.referenced_resources에 저장 → UI가 근거로 표시. |
| 감사 | 모든 조사 = AiInteraction(intent="query", answered) + AuditLog(ai_interaction.query). 문서 검색이 포함돼도 기존 감사 1건에 출처(`knowledge_documents`) 추가만. |
| 생산 데이터 분리 | `OpenMes.Knowledge`는 별도 바운디드 컨텍스트. 문서는 생산 트랜잭션과 분리, `resource`로 참조만(스키마 대체 아님). |
| 문서 쓰기 감사 | 사람이 하는 문서 CRUD/import도 **AuditLog 필수**(knowledge_document.create/update). AI가 아닌 사람 작성도 이력 보존(OKF log.md). |

---

## 6. Seed (멱등, 데모 OKF 문서 3~5건)

`priv/repo/seeds.exs`에 멱등 블록 추가(`resource` 기준 upsert 또는 존재 시 skip). 태그로 설비/공정 연관 보장(EQ-P03, P-INJECTION 등 — 기존 seed 설비/공정 코드와 정합).

| # | okf_type | title | tags(연관) | resource | 용도 |
|---|----------|-------|-----------|----------|------|
| 1 | 표준작업서 | 사출 성형 표준작업서 | `["P-INJECTION","사출","SOP"]` | `mes://knowledge/sop/injection-molding` | 공정 SOP — investigate가 사출 설비 조사 시 인용 |
| 2 | 설비매뉴얼 | EQ-P03 사출기 설비 매뉴얼 | `["EQ-P03","사출기","설비"]` | `mes://knowledge/manual/eq-p03` | 설비 매뉴얼 — EQ-P03 조사 시 매칭 |
| 3 | 트러블슈팅 | EQ-P03 진동 이상 트러블슈팅 | `["EQ-P03","진동","이상","트러블슈팅"]` | `mes://knowledge/troubleshooting/eq-p03-vibration` | 진동 이상 조사 시 원인·조치 인용 |
| 4 | 품질기준서 | 사출품 외관 품질 기준서 | `["P-INJECTION","품질","외관"]` | `mes://knowledge/quality/injection-appearance` | 불량 조사 시 기준 인용 |
| 5 | 검사기준 | 사출품 치수 검사 기준 | `["P-INJECTION","검사","치수"]` | `mes://knowledge/inspection/injection-dimension` | 검사 기준 |

- 각 문서 본문은 마크다운(헤더·목록·크로스링크 포함). 문서 3은 문서 2를 크로스링크(`[설비 매뉴얼](../설비매뉴얼/eq-p03.md)`)로 참조 → OKF 크로스링크 시연.
- `uploaded_by: "system"`, `version: "1.0"`. seed AuditLog는 actor "system"으로 1건씩.
- 멱등: `Repo.get_by(KnowledgeDocument, resource: uri)` 존재 시 skip.

---

## 7. OKF 적합성 준수 체크리스트

| OKF 요구 | 구현 |
|----------|------|
| 개념 문서 = 프론트매터 + 마크다운 | `Okf.Document.generate` (`---` YAML + 본문) |
| `type` 필수 | `okf_type` NOT NULL. import 시 없으면 경고 + 기본값(reject 아님) |
| 권장 필드 | title/description/resource/tags/timestamp 매핑 |
| `tags` YAML 리스트 | `{:array,:string}` ↔ `- item`/`[a,b]` 파싱·생성 |
| `timestamp` ISO 8601 | export 시 `updated_at` → ISO8601 문자열 |
| 번들 = 디렉토리 | `Okf.Bundle.export` 디렉토리 구조 맵 |
| 예약 `index.md`/`log.md` | export 자동 생성, import 인식+선택적 |
| 루트 `okf_version: "0.1"` | 루트 index.md 프론트매터 |
| 관용적 소비 | 미지 필드(`extra` 보존)·미지 type·깨진 링크·누락 index 거부 0 |
| 크로스링크 | 본문 마크다운 절대/상대 링크(검증·차단 안 함) |
| resource로 참조만 | 기존 스키마 대체 아님 — URI 참조 |
| 타 도구 호환 | 경량 파서가 표준 프론트매터 수용, export가 표준 번들 생성 |

---

## 8. domain-engineer 구현 지침

**구현 순서(작은 단위, 각 단계 컴파일·테스트 가능):**

1. **마이그레이션** `priv/repo/migrations/2026061412XXXX_create_knowledge_documents.exs` — §1.3 그대로(GIN 인덱스 `using: "gin"`, partial unique resource 주의).

2. **스키마** `lib/open_mes/knowledge/knowledge_document.ex` — §1.2. `binary_id`, `@foreign_key_type :binary_id`. changeset: `@required [:okf_type, :uploaded_by]`, `@optional` 나머지. `validate_length(:okf_type)`, tags 캐스트(`{:array,:string}`), resource unique_constraint(partial). MasterData 스키마 패턴 동형.

3. **OKF 순수함수**(컨텍스트보다 먼저 — 의존 방향):
   - `lib/open_mes/okf/frontmatter.ex` — §2.1. `parse/1`(항상 `{:ok, ...}`), `generate/1`. **외부 dep 0**(직접 파싱). 경고 누적은 단순 리스트.
   - `lib/open_mes/okf/document.ex` — §2.2. `parse/2`→`{attrs, warnings}`, `generate/1`. canonical resource 생성(`mes://knowledge/{okf_type slug}/{id}`).
   - `lib/open_mes/okf/bundle.ex` — §2.3. `export/2`(파일맵), `import_bundle/2`. zip 패킹/언패킹은 `:zip`(Erlang 기본, dep 0) — 컨트롤러에서.
   - **순수함수 단위 테스트 필수**(parse↔generate round-trip, 미지 필드 보존, type 누락 경고, 깨진 입력 비-reject).

4. **컨텍스트** `lib/open_mes/knowledge/knowledge.ex` — MasterData 동형:
   - `list_documents/1`(필터 okf_type/tags/active), `get_document/1`, `change_document/2`.
   - `create_document/2`·`update_document/2`(actor_id) — **`Ecto.Multi` + `Audit.put_log`** (resource_type `"knowledge_document"`, action `.create`/`.update`, before/after 스냅샷). **AuditLog 누락 금지.**
   - `import_documents/2`(번들 attrs 목록 + actor_id) — 각 문서 create/update를 트랜잭션, 경고 수집 반환.
   - `search_for_subject/2`·`excerpt/2` — §4.1/§4.2 (읽기, AuditLog 무관).
   - `document_audit_logs/1`(상세 화면 변경 이력 — Audit 조회 재사용).

5. **investigate 연동** `investigation.ex`:
   - `alias`에 `OpenMes.Knowledge` 추가.
   - `build_context/3`에 `knowledge = build_knowledge(equipment, production)` 추가 + context map에 `knowledge:` 키 + `referenced.sources`/`referenced.knowledge` 추가(§4.3).
   - `defp build_knowledge/2`, `defp production_process_codes/1`, `defp knowledge_refs/1`, `defp canonical_uri/1` 추가.
   - **`investigate/3`·AiInteraction·AuditLog·상태머신 변경 절대 금지** — `build_context`에만 추가.
   - 기존 investigation 테스트 회귀 0 확인(context map에 키 추가뿐).

6. **Provider 프롬프트** `claude_provider.ex`·`mock_provider.ex`: `investigate_system_prompt`에 인용 유도 한 줄 추가(§4.4). MockProvider는 knowledge 발췌를 분석 텍스트에 단순 반영(키 있을 때).

7. **UI**:
   - `lib/open_mes_web/admin/settings/knowledge_live.ex` — index/show/new/edit(§3.2). 폼은 기존 LiveView 폼 패턴 재사용. 마크다운 미리보기는 textarea + 토글(간단).
   - `knowledge_export_controller.ex`/`knowledge_import_controller.ex` — `Bundle.export`/`import_bundle` + `:zip` + `send_download`/업로드 파싱. import는 경고를 flash로.
   - 라우트 §3.1, 메뉴 §3.3(admin_components "설정" 그룹).

8. **seed** §6 — 멱등 블록, 태그로 연관, AuditLog 동반.

**불변식 재확인(qa-auditor 검증 포인트):**
- 모든 문서 쓰기에 AuditLog(Multi 동일 트랜잭션). 삭제 없음(active=false).
- AI 경로는 읽기·인용만, 쓰기 0, Provider에 plain map만.
- OKF 관용적 소비: parse는 절대 reject 하지 않음(경고만), 미지 필드 `extra` 보존.
- 기존 라우트/메뉴/investigate/라인구성 무손상(추가만).
- 외부 dep 0(YAML 경량 파서, zip은 Erlang `:zip`).

**확장 포인트(지금 만들지 않음 — YAGNI):** 벡터 임베딩 검색, 첨부 파일 바이너리 저장, KnowledgeLink 다대다 테이블, version 자동 증가, 중첩 YAML(파서 인터페이스 유지로 dep 교체 격리), EXT-5 외부 RAG 커넥터와의 병행(내부 OKF가 1차 충족).

---

## 9. 산출물 경로

- 본 설계: `/Users/hongsw/dev/open-mes-korea/_workspace/27_architect_okf_knowledge.md`
- domain-engineer 구현 대상(신규):
  - `open_mes/priv/repo/migrations/*_create_knowledge_documents.exs`
  - `open_mes/lib/open_mes/knowledge/{knowledge,knowledge_document}.ex`
  - `open_mes/lib/open_mes/okf/{frontmatter,document,bundle}.ex`
  - `open_mes/lib/open_mes_web/admin/settings/knowledge_live.ex`
  - `open_mes/lib/open_mes_web/controllers/knowledge_{export,import}_controller.ex`
- 수정(기존 무손상 추가만):
  - `open_mes/lib/open_mes/ai/investigation.ex` (build_context에 knowledge 추가)
  - `open_mes/lib/open_mes/ai/{claude_provider,mock_provider}.ex` (인용 프롬프트 1줄)
  - `open_mes/lib/open_mes_web/router.ex` (지식베이스 라우트)
  - `open_mes/lib/open_mes_web/components/admin_components.ex` (설정 메뉴 항목)
  - `open_mes/priv/repo/seeds.exs` (데모 OKF 문서)
