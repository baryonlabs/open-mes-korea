---
name: scaffold
description: Open MES Korea의 아키텍처 문서를 기반으로 초기 코드 스캐폴딩을 도와줍니다. 기술 스택 선택부터 디렉토리 구조, 첫 번째 엔티티 코드 생성까지 안내합니다.
disable-model-invocation: true
---

사용자가 `/scaffold $ARGUMENTS`로 호출합니다. `$ARGUMENTS`가 없으면 전체 스캐폴딩 흐름을 안내하고, 특정 엔티티명이 있으면 해당 엔티티의 코드 뼈대를 생성합니다.

## 수행 방법

### 전체 스캐폴딩 (인자 없음)

1. 먼저 아래 문서를 읽는다:
   - `docs/system-architecture.md`
   - `docs/domain-model.md`
   - `docs/ai-native-architecture.md`
   - `README.md` (기술 방향 섹션)

2. 사용자에게 기술 스택을 확인한다:
   - Backend: Phoenix LiveView (Elixir) / FastAPI (Python) / Django (Python)?
   - Frontend: Alpine.js / Next.js / React?

3. 선택된 스택에 맞는 디렉토리 구조를 제안한다.

4. 핵심 설계 원칙을 지키는 초기 구조 예시를 작성한다:
   - PostgreSQL 연결 설정
   - AuditLog 미들웨어/훅 위치
   - AI Context API 라우트 분리
   - Event Outbox 테이블

### 특정 엔티티 스캐폴딩 (예: /scaffold WorkOrder)

1. `docs/domain-model.md`에서 해당 엔티티 정보를 읽는다.
2. DB 스키마 (마이그레이션 코드)를 작성한다.
3. 상태 머신을 코드로 구현한다 (허용된 전이만).
4. 기본 CRUD API 엔드포인트를 작성한다.
5. 모든 쓰기 작업에 AuditLog 생성 코드를 포함한다.

## 절대 지켜야 할 원칙

- 상태 머신: `docs/domain-model.md`에 정의된 전이만 허용
- AuditLog: 모든 쓰기 API에 자동 생성
- LOT 소비는 LotConsumption 엔티티를 통해서만
- AI가 직접 쓰기 API를 호출하는 코드 생성 금지
- 커밋 메시지 형식: Conventional Commits (`feat:`, `fix:`, `docs:` 등)
