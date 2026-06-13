# AI Native Architecture

Open MES Korea의 AI native 방향은 챗봇 추가가 아니라 MES 운영 구조를 AI가 안전하게 이해하고 사용할 수 있게 만드는 것입니다.

## 목표

- 생산 데이터를 자연어로 조회한다.
- 작업지시, 공정, 불량, LOT 이력을 요약한다.
- 이상 징후와 확인할 항목을 제안한다.
- 표준작업서, 품질 문서, 설비 매뉴얼을 검색한다.
- 중요한 변경은 사람의 승인을 거친다.
- 모든 AI 상호작용은 감사 가능해야 한다.

## AI 기능 레벨

### Level 1: Read-only Assistant

AI는 데이터를 읽고 설명합니다.

예시:

- "오늘 미완료 작업지시 보여줘"
- "A제품 LOT-20260613-001의 원자재 투입 이력 요약해줘"
- "이번 주 불량률이 높은 공정 알려줘"

### Level 2: Decision Support

AI는 후보와 이유를 제안합니다. 직접 변경하지 않습니다.

예시:

- 납기 지연 위험 작업지시 후보
- 반복 불량 패턴 후보
- 재고 부족 위험 품목 후보
- 설비 점검 필요 후보

### Level 3: Approval-based Action

AI가 변경 액션을 제안하고, 사용자가 승인하면 시스템이 실행합니다.

예시:

- 작업지시 일정 조정안 생성
- 불량 원인 분석 태그 초안 생성
- 품질 이슈 보고서 초안 생성

### Level 4: Guarded Automation

반복적이고 낮은 위험의 작업만 정책 기반으로 자동 실행합니다. 초기 버전에서는 목표로 하지 않습니다.

## 핵심 설계

### AI Context API

AI가 직접 DB를 읽지 않고, 권한과 필터가 적용된 context API를 사용합니다.

예시 endpoint:

- `GET /ai/context/work-orders`
- `GET /ai/context/lots/{lot_no}`
- `GET /ai/context/defects`
- `GET /ai/context/operations`

### Tool Action API

AI가 실행 가능한 작업은 명시적으로 등록된 tool action만 허용합니다.

예시:

- `propose_work_order_schedule_change`
- `draft_quality_issue_report`
- `suggest_defect_cause_tags`

### Approval Flow

AI가 생성한 변경 요청은 아래 상태를 가집니다.

- proposed
- reviewed
- approved
- rejected
- executed
- failed

### Audit

모든 AI 요청은 다음 정보를 남깁니다.

- 요청자
- 요청 시각
- 사용한 데이터 범위
- 모델 또는 provider
- 응답 요약
- 제안 액션
- 승인자
- 실행 결과

## RAG 문서 영역

AI가 검색할 문서는 생산 데이터와 분리합니다.

- 표준작업서
- 설비 매뉴얼
- 품질 기준서
- 검사 기준
- 교육 문서
- 트러블슈팅 문서

문서는 원본 파일, 버전, 업로드 사용자, 유효 기간을 추적해야 합니다.

## 안전 원칙

- AI는 권한 없는 데이터를 볼 수 없습니다.
- AI는 기본적으로 쓰기 권한이 없습니다.
- 생산 실적, LOT, 불량 기록은 AI가 직접 삭제할 수 없습니다.
- AI 제안은 근거 데이터를 함께 보여줘야 합니다.
- 중요한 변경은 승인자와 감사 로그가 필요합니다.

