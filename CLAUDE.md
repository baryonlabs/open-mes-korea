# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Open MES Korea는 한국 중소 제조업을 위한 오픈소스 MES(제조실행시스템)입니다. ERP 전체를 대체하는 것이 아니라 **현장 실행 + LOT 추적 + AI context/approval layer**를 핵심으로 합니다.

**핵심 차별점:** 설비 시계열 데이터(EXT-1, TimescaleDB)와 영상/미디어 데이터(EXT-2, MinIO)를 확보하고, **Claude(AI)가 이를 종합적으로 조사·분석할 수 있는 환경**을 구축한 AI native MES. AI는 시계열+미디어+생산 데이터를 단일 context로 종합 조사(Level 1 Read-only)하며, 라인 구성은 propose→승인으로 변경한다. 구현: `open_mes/lib/open_mes/ai/`.

## 기술 스택

- Backend: **Phoenix (Elixir) + Ecto** (확정)
- Frontend: Phoenix LiveView + Alpine.js (검토 중)
- Database: PostgreSQL (확정)
- Event: PostgreSQL outbox 패턴 → 추후 메시지 큐 확장
- Deployment: Docker Compose

AI 연동은 Claude (Anthropic) API를 사용합니다.

## 구현 원칙 (pi 원칙)

earendil-works/pi의 구현 철학을 따른다. **최소만 만들고, 확장은 나중에 붙인다.**

- **YAGNI**: 미리 추상화하거나 확장성을 위한 구조를 선제적으로 만들지 않는다. 지금 필요한 것만 구현한다.
- **인라인 우선**: 호출 지점이 1개뿐인 헬퍼 함수/모듈은 별도 파일로 분리하지 않는다.
- **확장 포인트는 유지**: 단, 도메인 로드맵상 명확히 확장될 지점(예: Event Outbox 이벤트 타입)은 확장 가능한 형태로 남긴다.
- **기능 제거는 확인 후**: 의도적으로 보이는 코드는 삭제 전 사유를 확인한다.
- **도메인 불변식은 "최소"에 포함**: AuditLog, LOT Genealogy, 상태 머신은 지금 필요한 핵심이므로 최소 구현에 반드시 포함된다. 이것을 빼는 것은 최소화가 아니라 결함이다.

## 데이터 확보 우선 원칙

> 데이터를 확보하기 위한 가장 편한 도구가 우선한다.

완벽한 분석 파이프라인보다 데이터를 쉽고 빠르게 모으는 것이 먼저다. 수집하지 못한 데이터는 영원히 잃는다. 수집 계층은 인프라 의존 최소(브로커리스 HTTP push 우선), 외부 브로커는 처리량이 실증될 때 producer 교체로 전환한다.

데이터 성격별 저장 분리: 도메인 트랜잭션 → PostgreSQL(AuditLog 필수) / 고빈도 시계열 스칼라 → TimescaleDB hypertable(AuditLog 불필요) / 대용량 바이너리(소음·영상) → object storage + 메타데이터. 상세: @docs/extension-roadmap.md

## 확장 모듈 구조

코어는 확장 없이 동작한다. 확장은 별도 네임스페이스 격리 + config on/off + behaviour 계약으로 코어에 침투하지 않는다. 확장 카탈로그(설비 수집/멀티미디어/예지보전/생산관리 고도화): @docs/extension-roadmap.md

## 언어 정책

- 코드 주석, 변수명, API 응답 등 모든 코드는 **한국어 우선**
- 업무 용어는 한국 제조 현장 용어를 그대로 사용 (예: 작업지시, LOT, 불량, 공정, 설비)
- 영문 식별자는 도메인 엔티티명과 필드명에 한함

## 도메인 모델

@docs/domain-model.md

핵심 엔티티 13개: Item, BillOfMaterial, Process, Routing, WorkOrder, Operation, ProductionResult, DefectRecord, MaterialLot, LotConsumption, AuditLog, AiInteraction

### 상태 머신 (절대 임의로 전이 추가 금지)

**WorkOrder**: draft → released → in_progress → completed / cancelled

**Operation**: pending → ready → running → paused → completed / skipped

**MaterialLot**: available → reserved → consumed / produced / quarantined / scrapped

**AI 승인 흐름**: proposed → reviewed → approved/rejected → executed/failed

## 아키텍처 원칙

### 이력성 우선
- 생산 실적, LOT 소비, 불량 기록은 수정하지 않고 정정 이력을 남김
- 중요 테이블은 append-only 또는 감사 로그 필수

### 모든 쓰기에 AuditLog 생성 필수
- actor_id, action, resource_type, resource_id, before, after, created_at
- WorkOrder 생성/변경, Operation 실적, LOT 소비, 불량 기록은 예외 없이 AuditLog 생성

### LOT Genealogy 명시적 기록
- 자재 투입은 LotConsumption을 통해서만 기록 (암묵적 소비 금지)
- 모든 LOT는 생산된 Operation과 연결

### Event Outbox
- 상태 변경 시 outbox 테이블에 이벤트 삽입 후 DB 트랜잭션 내에서 처리
- 주요 이벤트: `work_order.released`, `operation.started`, `operation.completed`, `material_lot.consumed`, `material_lot.produced`, `defect.recorded`, `ai_action.proposed`, `ai_action.approved`

## AI 안전 원칙

@docs/ai-native-architecture.md

- AI는 권한 없는 데이터를 볼 수 없음 (AI Context API 경유 필수)
- AI는 기본적으로 쓰기 권한 없음
- ProductionResult, LotConsumption, DefectRecord는 AI가 직접 삭제 불가
- AI 제안은 근거 데이터를 함께 표시 필수
- 모든 AI 상호작용은 AiInteraction에 기록

AI Context API 패턴: `GET /ai/context/{resource}` (직접 DB 쿼리 금지)

허용된 Tool Action만 등록 가능: `propose_*`, `draft_*`, `suggest_*`

## 커밋 메시지

Conventional Commits 형식:

```
docs: define mvp scope
feat: add work order api
fix: correct lot consumption validation
```

## API 원칙

- REST API 우선
- 모든 쓰기 API에 actor 정보 필수
- AI 호출 API는 읽기 / 제안 / 승인 요청 / 승인 후 실행을 명확히 구분

## 하네스: MES Build Team

**목표:** MES 기능 구현 시 설계 → 구현 → 감사 원칙 검증을 에이전트 팀이 협업으로 처리한다.

**에이전트 팀:**
| 에이전트 | 역할 |
|---------|------|
| `architect` | 기술 스택 결정, DB 스키마 설계, API 구조 설계 |
| `domain-engineer` | 엔티티 구현, 상태 머신 코드화, AuditLog 로직 구현 |
| `qa-auditor` | AuditLog·LOT Genealogy·Event Outbox·상태 머신 준수 검증 |
| `ai-safety-guardian` | AI 연동 코드 안전 원칙 검증 (AI 코드 포함 시만) |

**스킬:**
| 스킬 | 용도 | 사용 에이전트 |
|------|------|-------------|
| `mes-build` | 팀 전체 조율 오케스트레이터 | 오케스트레이터 |
| `scaffold` | 기술 스택 기반 초기 스캐폴딩 | architect |
| `domain-lookup` | 엔티티·상태 머신 빠른 참조 | domain-engineer |
| `audit-verify` | 이력성·AuditLog·LOT·상태머신 검증 | qa-auditor |
| `ai-safety-check` | AI 안전 원칙 검증 | ai-safety-guardian |

**실행 규칙:**
- MES 기능 구현, 코드 작성, 엔티티 구현 요청 시 `mes-build` 스킬로 에이전트 팀을 통해 처리하라
- 단순 질문(도메인 조회, 문서 확인)은 에이전트 팀 없이 직접 응답
- 모든 에이전트는 `model: "opus"` 사용
- 중간 산출물: `_workspace/` 디렉토리

**디렉토리 구조:**
```
.claude/
├── agents/
│   ├── architect.md
│   ├── domain-engineer.md
│   ├── ai-safety-guardian.md
│   └── qa-auditor.md
└── skills/
    ├── mes-build/SKILL.md        ← 오케스트레이터
    ├── audit-verify/SKILL.md
    ├── domain-lookup/SKILL.md
    ├── scaffold/SKILL.md
    └── ai-safety-check/SKILL.md
```

**변경 이력:**
| 날짜 | 변경 내용 | 대상 | 사유 |
|------|----------|------|------|
| 2026-06-13 | 초기 하네스 구성 | 전체 | MES 구현 팀 신규 구축 |
| 2026-06-13 | 기술 스택 확정 (Phoenix+Ecto), pi 최소 구현 원칙 도입 | CLAUDE.md, architect/domain-engineer/qa-auditor | WorkOrder API 구현 중 스택 확정 + 사용자 pi 원칙 지시 |
| 2026-06-13 | 데이터 확보 우선 원칙 + 확장 모듈 카탈로그 추가 | CLAUDE.md, docs/extension-roadmap.md | Broadway 수집 확장 + 소음/영상/예지보전 모듈 비전 |
| 2026-06-13 | EXT-1 Broadway 수집 + EXT-2 멀티미디어 NAS watch 구현 완료 | _workspace/06,07 | 설비/멀티미디어 데이터 확보 확장 (APPROVED) |
| 2026-06-13 | 확장 레지스트리 + 홈페이지 카탈로그 + 도메인 애드온 5개 구현 완료 | _workspace/10,11 | 확장 생태계 + 홈페이지 노출 (전부 APPROVED, 읽기 전용) |
| 2026-06-13 | Phoenix 앱 실통합 + 실행 검증 | open_mes/ | 컴파일 성공·마이그레이션 7개·테스트 282 passed·실서버 동작. 실행이 소스 버그 3건 발견·수정 |
| 2026-06-13 | 이종 도구 호환성(EXT-5) + 고도화 모듈군(EXT-6~12) 로드맵 등록 | docs/extension-roadmap.md, _workspace/14 | 디지털트윈/시뮬레이션 연동 + 사출 성형 고도화 기능 7종 카탈로그화 |
| 2026-06-13 | MES 운영 프론트 전체 구축 (G0 코어 11엔티티 + G1~G6 UI) | open_mes/ | 기준정보/생산관리/LOT추적/현장(/shopfloor)/조회·대시보드/관리자. mix test 359 passed, 19개 메뉴 라우트 동작, 라운드1·2 qa APPROVED |
| 2026-06-14 | 루트(/) 진입점을 생산현황 대시보드로 변경 | open_mes/ router·page_controller | 카탈로그는 /extensions로 분리 |
| 2026-06-14 | 공장 role 기반 화면 분리 + role 색상 표시 + 기초 seed | open_mes/ authorization, Worker.role, seeds.exs | role 5종(시스템관리자/생산관리자/품질관리자/자재담당/현장작업자), 2계층 접근제어(가시성+직접URL 인가), 상단바 역할 전환. mix test 393 passed, qa APPROVED |
| 2026-06-14 | SVG 시각 대시보드 + 공장 생산라인 모니터(/admin/reports/production) | open_mes/ charts/geometry, chart_components | 순수 SVG(외부 라이브러리 0) — 도넛·게이지·막대·공정흐름. 10공정 라인 신호등(데이터/장비/품질 3축 판정) |
| 2026-06-14 | 생산라인 구성 설정화 + AI 자연어 라인 구성 | open_mes/ production_line, ai/ | ProductionLine/Step 설정 페이지(/admin/settings/lines, 정규식 제거). AiInteraction + Provider(Mock/Claude) + propose→승인→apply(AI 직접 쓰기 0, 인간 승인). 설정 메뉴 5항목(라인/AI/Skill/MCP/Connector). mix test 461 passed, AI안전 APPROVED |
| 2026-06-14 | 커넥터 카탈로그에 위키/RAG/데이터베이스 추가 | open_mes/ connector_settings | 데이터 소스(위키·DB)→RAG→AI 인용 흐름 (RAG는 외부 커넥터) |
| 2026-06-14 | AI 종합 조사 환경(시계열+미디어+생산) 구축 — 핵심 차별점 | open_mes/ ai/investigation, ingest, media | Claude가 시계열(EXT-1)+영상미디어(EXT-2)+생산을 단일 context로 종합 조사(Level 1 Read-only, 쓰기 0). /admin/ai/investigate. Provider.investigate(Mock/Claude). mix test 482 passed, AI안전 APPROVED |
| 2026-06-14 | Claude 모델 ID 최신화 (opus-4-8) | open_mes/ ai/claude_provider | claude-opus-4-5→claude-opus-4-8, ANTHROPIC_MODEL override. 키 설정 시 자동 ClaudeProvider 전환 |
| 2026-06-14 | RAG 문서영역을 OKF(Open Knowledge Format)로 구현 | open_mes/ knowledge, okf | 표준작업서/매뉴얼/트러블슈팅을 OKF 번들(마크다운+YAML, type 필수, 관용적 소비)로. /admin/settings/knowledge, 번들 export/import(zip), 외부 dep 0. investigate가 설비별 관련 문서 검색·인용(RAG, 근거 referenced_resources). mix test 502 passed, AI안전 APPROVED |
| 2026-06-15 | 확장 시스템 디커플링 — 외부 repo 확장이 코어 0수정으로 결합 | open_mes_extension_api/(신규 path dep), open_mes/ router·ext.verify·확장8, open_mes_ext_demo/ | 강결합 4지점 해소: router if블록7→`mount_extension_routes()` 매크로(확장은 `route_spec/0` 순수 데이터) / category `atom()` 개방 + `known_categories/0` / ext.verify C7 `module_info(:compile)` 기반·C8 신규 / `open_mes_extension_api` 계약 패키지(Phoenix 미의존) + 자동발견(:auto, extra/exclude/:manual escape hatch, `mix ext.list`). 코어 도메인 미참조 단방향 유지. 기존 8확장 무중단 마이그레이션(phx.routes byte-identical). 외부 데모 확장 deps 1줄 자동노출 실증. mix test 512 passed, ext.verify 9/9, architect(_workspace/30)+qa(31) APPROVED |

---

## 개발 전 확인 문서

- `docs/vision.md` — 핵심 원칙과 비목표
- `docs/mvp-scope.md` — MVP 기능 범위
- `docs/domain-model.md` — 엔티티와 상태 머신
- `docs/system-architecture.md` — 백엔드/프론트엔드/DB 설계
- `docs/ai-native-architecture.md` — AI 연동 안전 설계
- `docs/roadmap.md` — 6단계 로드맵
