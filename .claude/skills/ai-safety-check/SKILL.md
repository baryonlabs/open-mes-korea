---
name: ai-safety-check
description: AI 연동 코드가 docs/ai-native-architecture.md의 안전 원칙을 준수하는지 검증합니다. AI 기능 구현 전후에 사용하세요.
---

사용자가 `/ai-safety-check`로 호출하거나 AI 연동 코드 리뷰를 요청하면 실행합니다.

## 수행 방법

1. `docs/ai-native-architecture.md`를 읽는다.
2. 현재 변경된 파일 또는 사용자가 지정한 파일을 읽는다.
3. 아래 체크리스트를 기준으로 각 항목을 검증하고 결과를 보고한다.

## 체크리스트

### 데이터 접근
- [ ] AI가 직접 DB를 쿼리하지 않고 AI Context API (`/ai/context/...`)를 경유하는가?
- [ ] AI에게 노출되는 데이터에 권한 필터가 적용되어 있는가?

### 쓰기 권한
- [ ] AI가 직접 ProductionResult, LotConsumption, DefectRecord를 생성/수정/삭제하지 않는가?
- [ ] AI의 쓰기 작업은 등록된 Tool Action (`propose_*`, `draft_*`, `suggest_*`)을 통해서만 이루어지는가?

### 승인 흐름
- [ ] AI 제안 액션이 proposed → reviewed → approved/rejected → executed/failed 상태를 가지는가?
- [ ] 승인 없이 실행되는 AI 액션이 없는가?

### 감사 로그
- [ ] 모든 AI 요청이 AiInteraction 테이블에 기록되는가?
- [ ] AiInteraction에 요청자, 요청 시각, 사용 데이터 범위, 응답 요약, 제안 액션, 승인자가 포함되는가?

### AI 레벨 준수
- [ ] Level 1 (읽기 전용): 데이터 조회만 하는가?
- [ ] Level 2 (의사결정 지원): 직접 변경하지 않고 후보만 제안하는가?
- [ ] Level 3 (승인 기반 실행): 사용자 승인 후에만 시스템이 실행하는가?
- [ ] Level 4 자동화가 초기 버전에 포함되지 않는가?

## 출력 형식

각 항목별 ✅ / ❌ / ⚠️ 표시와 구체적인 코드 위치 및 수정 방법을 한국어로 출력합니다.
