# 28 · AI 안전 감사 — OKF 지식베이스(RAG) + investigate 연동 (독립 검증)

**검증자:** ai-safety-guardian (독립 검증)
**일자:** 2026-06-14
**기준 문서:** `docs/ai-native-architecture.md`(RAG 문서 영역·안전 원칙), `_workspace/27_architect_okf_knowledge.md`(§5 AI 안전 체크포인트), `CLAUDE.md`
**검증 방법:** 실코드 grep + 파일 정독 + `mix test`(okf/knowledge/investigation 36건)
**최종 판정: ✅ APPROVED**

---

## 요약

OKF 지식베이스(RAG)와 AI investigate 연동은 ai-native-architecture의 **"RAG 문서는 생산 데이터와 분리, AI는 검색·인용만(쓰기 0)"** 원칙을 코드 수준에서 정확히 구현했다. 8개 안전 체크포인트 중 **7개 ✅ 완전 준수, 1개 ⚠️ 경미한 UI 표현 보강 권장**(안전 위반 아님). 안전 위반(❌) 0건. 36개 관련 테스트 전부 통과.

---

## 체크포인트별 결과

### 1. AI 쓰기 0 (RAG 읽기·인용만) — ✅

- investigate/build_context/build_knowledge 경로에 KnowledgeDocument 또는 도메인 쓰기 **0건**.
  - grep `insert|update|delete` on `investigation.ex` → `inserted_at`(읽기) 2건만 매칭, Repo 쓰기 0.
  - `build_knowledge/2`(investigation.ex:244-266)는 `Knowledge.search_for_subject`(읽기) + `Knowledge.excerpt`(순수)만 호출.
- `investigate/3`(investigation.ex:296-340)의 유일한 쓰기는 **AiInteraction 감사 1건 + AuditLog 1건**(단일 Multi). proposed_action=nil, Outbox 없음, 승인 흐름 없음(Level 1 읽기 즉시).
- 문서 CRUD는 사람 UI 경로(`Knowledge.create_document/update_document`)로 완전 분리되며 AuditLog 동반(체크포인트 6).
- **테스트 증거:** `knowledge_test.exs:135` "investigate(mock)…문서 변경 0" → `Repo.aggregate(KnowledgeDocument, :count) == before_count`. `ai_investigation_test.exs:174` "도메인 쓰기 0(생산/측정 불변)".

### 2. Provider DB 직접 접근 0 — ✅

- `build_knowledge`가 만든 **plain map(발췌 포함)**만 context에 들어가고, `Provider.active().investigate(context, query)`(investigation.ex:300)로 map+query만 전달.
- grep `Repo|Knowledge|Ecto|from(` on `mock_provider.ex`/`claude_provider.ex` → **주석(불변식 설명)에서만 매칭, 코드 0건**. 구조적 Repo 차단.
  - mock_provider.ex:59 `Map.get(context, :knowledge, %{})` — context map에서만 읽음.
  - claude_provider.ex:42-54 `Jason.encode!(context)` — context를 그대로 직렬화, DB 접근 없음.
- 발췌가 이미 context에 포함되므로 Provider가 원문을 추가 조회할 필요 자체가 없음(설계 27번 §4.4 준수).

### 3. 권한 필터 — ✅

- `build_knowledge`는 `build_context/3`의 `authorize(role)`(investigation.ex:64) **통과 후**에 호출됨(investigation.ex:72). 미인가 role은 `{:error, :unauthorized}`로 컨텍스트 자체를 못 받음 → 지식 문서도 못 봄.
- `@investigation_roles = system_admin/production_manager/quality_manager`(investigation.ex:31).
- 만료/비활성 제외: `search_for_subject`(knowledge.ex:176-182) `WHERE active == true AND (valid_until IS NULL OR valid_until >= today)`.
- **테스트 증거:** `ai_investigation_test.exs:88` operator 거부, `:92` investigate도 미인가 거부. `knowledge_test.exs:90` "태그 매칭 + 만료/비활성 제외" → 만료문서·비활성 문서가 결과에서 배제 확인.

### 4. 근거 표시(인용) — ✅ (UI는 ⚠️ 보강 권장, 안전 위반 아님)

- 인용 URI 추적 체인이 코드로 완결됨:
  - `build_knowledge`가 각 문서의 `resource`(없으면 canonical_uri)를 documents에 담음(investigation.ex:259).
  - `knowledge_refs/1`(investigation.ex:278)가 `referenced.knowledge` = 인용 resource URI 목록 생성(investigation.ex:92).
  - investigate가 `stringify(context.referenced)`를 `AiInteraction.referenced_resources`(jsonb)에 저장(investigation.ex:301, 308) → **감사에 인용 URI 영구 보존**.
- AiInteraction 스키마에 `referenced_resources` 필드 존재(ai_interaction.ex:47, optional 캐스트 61).
- **UI 표시:** investigate_live.ex:208-213 findings 블록이 MockProvider의 knowledge findings(`[okf_type] title (resource) 참조`, mock_provider.ex:117-128)를 렌더 → 사용자에게 인용 근거 노출됨.
- **⚠️ 보강 권장(안전 위반 아님):** investigate_live.ex:287-296의 전용 "근거(referenced)" 패널은 시계열/미디어/생산만 명시하고 **지식 문서 인용 URI를 별도 항목으로 표기하지 않음**(`referenced.knowledge`, `knowledge_documents_count` 미표시). Claude Provider 사용 시 findings가 비어(claude_provider.ex:95 `findings: []`) 인용이 분석 텍스트에만 의존할 수 있음. 인용 근거가 감사에는 항상 남으므로 안전 원칙 위반은 아니나, "AI 제안은 근거 데이터를 함께 보여줘야 한다"(ai-native L116)의 UI 가시성 강화를 위해 referenced 패널에 인용 문서 목록(`{ctx.referenced.knowledge_documents_count}건 · resource 링크`) 추가 권장.
  - **수정 위치/방법:** `investigate_live.ex:294` 소스 줄 다음에
    ```heex
    <p :if={ctx.referenced.knowledge_documents_count > 0} class="mt-1 text-xs text-zinc-600">
      인용 지식 문서 {ctx.referenced.knowledge_documents_count}건:
      {Enum.join(ctx.referenced.knowledge, ", ")}
    </p>
    ```

### 5. RAG 분리 — ✅

- `OpenMes.Knowledge`는 별도 바운디드 컨텍스트(`lib/open_mes/knowledge/`). grep `Production|LotConsumption|ProductionResult|DefectRecord|LOT` on knowledge.ex/knowledge_document.ex → **0건**. 생산 트랜잭션과 완전 분리.
- `knowledge_documents` 테이블은 독립(설계 27번 §1.2), 생산 엔티티 FK 없음. 연관은 `tags`(예: `["EQ-P03"]`)와 `resource` URI 참조만(스키마 대체 아님).
- investigate context에서 production(investigation.ex:209-228)과 knowledge(investigation.ex:244-266)는 별도 키·별도 빌더로 분리. 생산 데이터와 지식 문서가 같은 트랜잭션에 섞이지 않음.

### 6. 전수 감사 — ✅

- 문서 CRUD: `create_document`(knowledge.ex:82) / `update_document`(knowledge.ex:100) 모두 `Ecto.Multi` + `Audit.put_log`로 AuditLog 동반(action `knowledge_document.create`/`.update`, before/after 스냅샷). import도 동일 경로(upsert_by_resource → create/update).
- investigate: AiInteraction(intent="query", answered) + AuditLog(`ai_interaction.query`) 단일 Multi(investigation.ex:314-331).
- Seed: `seeds.exs:526-528`이 `Knowledge.create_document`(AuditLog 내장)로 5건 멱등 시드 → seed도 감사 동반.
- **테스트 증거:** `knowledge_test.exs:27` create AuditLog, `:45` update before/after AuditLog. `ai_investigation_test.exs:162` investigate AuditLog +1.

### 7. OKF 관용적 소비(안전 측면) — ✅

- `Frontmatter.parse/1`(frontmatter.ex:20)는 **항상 성공** — 구분자 없으면 `{%{}, 전체본문, 경고}`(frontmatter.ex:26), 파싱 불가 줄은 무시+경고 누적(frontmatter.ex:108). reject/raise **0건**(grep의 `:error`는 generate 내부 `fetch/2` 반환값, parse 경로 아님).
- `Document.parse/2`(document.ex:25)는 type 없으면 "미분류"+경고(document.ex:31), 미지 필드는 `extra` 보존(document.ex:34). 절대 reject 안 함.
- 악의적/손상 문서가 AI 컨텍스트를 깨뜨리지 않음: 파싱 실패는 경고로 흡수, body는 그대로 발췌되어 excerpt(600자 상한)로 절단 → 깨진 입력도 컨텍스트 구조 안정.
- **테스트 증거:** `okf_test.exs:76` "깨진 입력도 reject 하지 않음", `:42` 구분자 없으면 전체 본문, `:65` type 누락 경고, `:71` 미지 필드 extra 보존.

### 8. 토큰 방어 — ✅

- 지식 문서 raw 전량 금지: `search_for_subject`(knowledge.ex:163) `limit \\ 5`(상한 N건), 각 문서 `excerpt`(knowledge.ex:189-201) 600자 truncate+"…(이하 생략)".
- build_knowledge가 documents에 `excerpt: Knowledge.excerpt(d.body)`만 담음(investigation.ex:261) → 본문 전량이 Provider에 가지 않음. 최대 5건 × ~600자 ≈ 3KB 상한.
- **테스트 증거:** `knowledge_test.exs:102` excerpt ≤620자 truncate + "생략" 표기 확인.

---

## mix test 결과

```
mix test test/open_mes/okf_test.exs test/open_mes/knowledge_test.exs test/open_mes/ai_investigation_test.exs
...
Result: 36 passed
```

안전 체크포인트별 직접 커버 테스트:
- 쓰기 0: knowledge_test(investigate 후 문서 count 불변), ai_investigation_test:174
- 권한 거부: ai_investigation_test:88, :92
- 만료/비활성 제외: knowledge_test:90
- AuditLog 동반: knowledge_test:27/:45, ai_investigation_test:162
- 인용 URI 추적: knowledge_test:123(referenced.knowledge), :133
- 관용적 비-reject: okf_test:76, :42, :65, :71
- 토큰 방어 excerpt: knowledge_test:102

---

## 위반 / 보강 요약

| # | 항목 | 판정 | 위치 | 조치 |
|---|------|:---:|------|------|
| 1 | AI 쓰기 0 | ✅ | investigation.ex:244-340 | — |
| 2 | Provider DB 접근 0 | ✅ | mock/claude_provider.ex | — |
| 3 | 권한 필터 | ✅ | investigation.ex:64-72, knowledge.ex:176-182 | — |
| 4 | 근거 표시(인용) | ✅(UI ⚠️) | investigation.ex:278/92, investigate_live.ex:287-296 | referenced 패널에 인용 문서 목록 표기 권장(안전 위반 아님) |
| 5 | RAG 분리 | ✅ | knowledge.ex(생산 참조 0) | — |
| 6 | 전수 감사 | ✅ | knowledge.ex:82/100, investigation.ex:314 | — |
| 7 | 관용적 소비 | ✅ | frontmatter.ex:20-28, document.ex:25-49 | — |
| 8 | 토큰 방어 | ✅ | knowledge.ex:163/189, investigation.ex:261 | — |

**안전 위반(❌): 0건. 차단 사유 없음.**

---

## 최종 판정: ✅ APPROVED

OKF 지식베이스 RAG와 investigate 연동은 ai-native-architecture의 RAG 분리·읽기 전용·인용·감사 원칙을 코드와 테스트로 정확히 구현했다. 체크포인트 4의 UI 인용 가시성 보강은 권장 사항(후속)이며 감사·안전 불변식을 침해하지 않으므로 승인을 보류하지 않는다.
