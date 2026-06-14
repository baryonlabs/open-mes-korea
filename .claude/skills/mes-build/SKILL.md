---
name: mes-build
description: Open MES Korea MES 구현 오케스트레이터. MES 기능 구현, 엔티티 코드 작성, 스캐폴딩, API 설계, DB 스키마 작성 등 개발 작업 시 에이전트 팀(architect + domain-engineer + qa-auditor + ai-safety-guardian)을 구성하여 협업으로 처리한다. "WorkOrder 구현해줘", "LOT 추적 API 만들어줘", "스캐폴딩 시작하자", "MES 기능 만들자", "다시 실행", "재실행", "수정해줘", "보완해줘" 등 MES 개발 요청 시 이 스킬을 사용한다.
disable-model-invocation: false
---

# MES Build — MES 구현 오케스트레이터

## Phase 0: 컨텍스트 확인

시작 전 기존 작업 상태를 확인한다.

```
_workspace/ 존재 여부 확인
  → 없음: 초기 실행 → Phase 1로 이동
  → 있음 + 사용자가 부분 수정 요청: 해당 에이전트만 재호출 (부분 재실행)
  → 있음 + 새 기능 요청: _workspace를 _workspace_prev/로 이동 후 새 실행
```

## Phase 1: 요청 파악 및 팀 구성

### 1-1. 요청 분류

사용자 요청을 읽고 분류한다:

| 요청 유형 | 참여 에이전트 |
|---------|------------|
| 기술 스택 결정 + 스캐폴딩 | architect 단독 |
| 단일 엔티티 구현 | architect → domain-engineer → qa-auditor |
| AI 연동 코드 구현 | architect → domain-engineer → qa-auditor + ai-safety-guardian |
| 복수 엔티티 구현 | architect → domain-engineer(병렬) → qa-auditor + ai-safety-guardian |

AI 연동이 포함되지 않으면 ai-safety-guardian은 호출하지 않는다.

### 1-2. 기술 스택 확인

`CLAUDE.md`의 기술 스택 섹션을 확인한다. 스택이 "미확정"이면 architect에게 우선 결정을 요청한다.

### 1-3. 에이전트 팀 구성

```
에이전트 팀:
- architect: 설계 담당
- domain-engineer: 구현 담당
- qa-auditor: 감사 원칙 검증 담당
- ai-safety-guardian: AI 안전 검증 담당 (AI 연동 시만)
```

## Phase 2: 설계 (architect)

architect에게 다음을 전달한다:
- 구현할 기능/엔티티
- 기술 스택 (확정된 경우)
- 이전 설계 문서 경로 (있는 경우)

architect 산출물: `_workspace/01_architect_{feature}_design.md`

architect 완료 신호를 받으면 Phase 3으로 이동.

## Phase 3: 구현 (domain-engineer)

domain-engineer에게 architect 설계 문서 경로를 전달한다.

domain-engineer 산출물: `_workspace/02_domain_engineer_{feature}_impl/`

구현 완료 신호를 받으면 Phase 4로 이동.

## Phase 4: 검증 (qa-auditor + ai-safety-guardian)

### 4-1. QA 감사 (항상 실행)

qa-auditor에게 구현 파일 경로를 전달.
산출물: `_workspace/03_qa_audit_{feature}.md`

### 4-2. AI 안전 검증 (AI 코드 포함 시만)

ai-safety-guardian에게 AI 연동 코드 경로를 전달.
산출물: `_workspace/03_ai_safety_report_{feature}.md`

두 에이전트를 동시에 호출하여 병렬 검증한다.

### 4-3. 검증 결과 처리

```
APPROVED: Phase 5(최종화)로 이동
NEEDS_FIX: domain-engineer에게 수정 요청 → Phase 4 재실행 (1회 한도)
BLOCKED: 사용자에게 보고 후 중단
```

## Phase 5: 최종화

### 5-1. 결과 요약

사용자에게 보고:
- 구현된 파일 목록
- QA 감사 결과 요약
- AI 안전 검증 결과 요약 (해당 시)
- 남은 작업 (다음 로드맵 Phase)

### 5-2. 기술 스택 확정 시 CLAUDE.md 업데이트

스택이 이번 세션에서 확정되었다면 `CLAUDE.md`의 기술 스택 섹션을 업데이트한다.

## 에러 핸들링

- architect 설계 실패: 요구사항 명확화 후 재시도
- domain-engineer 구현 실패: 설계 문서 재검토 후 재시도 (1회)
- 검증 BLOCKED: 사용자에게 구체적 위반 내용과 해결 방안 보고 후 중단
- 에이전트 응답 없음: 30초 후 재호출, 재실패 시 단독 실행으로 전환

## 데이터 전달 프로토콜

| 단계 | 파일 경로 | 설명 |
|-----|---------|------|
| 설계 | `_workspace/01_architect_{feature}_design.md` | architect → domain-engineer |
| 구현 | `_workspace/02_domain_engineer_{feature}_impl/` | domain-engineer → qa-auditor, ai-safety-guardian |
| 감사 | `_workspace/03_qa_audit_{feature}.md` | qa-auditor → 오케스트레이터 |
| AI 검증 | `_workspace/03_ai_safety_report_{feature}.md` | ai-safety-guardian → 오케스트레이터 |

중간 산출물은 `_workspace/`에 보존한다 (감사 추적용).

## 테스트 시나리오

### 정상 흐름

```
요청: "WorkOrder API 구현해줘"
1. architect가 WorkOrder 스키마 + API 설계 작성
2. domain-engineer가 마이그레이션 + API 구현 (AuditLog 포함)
3. qa-auditor가 AuditLog, 상태 머신, Event Outbox 검증 → APPROVED
4. 결과 요약 보고
```

### 에러 흐름

```
요청: "LotConsumption 구현해줘"
1. architect 설계
2. domain-engineer 구현 (AuditLog 누락)
3. qa-auditor → NEEDS_FIX (AuditLog 누락 지적)
4. domain-engineer 수정 → qa-auditor 재검증 → APPROVED
```

## 참고 문서

- `docs/domain-model.md` — 엔티티와 상태 머신
- `docs/system-architecture.md` — API 원칙
- `docs/ai-native-architecture.md` — AI 안전 원칙
- `docs/roadmap.md` — 구현 우선순위
