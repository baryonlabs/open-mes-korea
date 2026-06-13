# 시스템 아키텍처

## 기본 구조

```text
Browser / Tablet
    ↓
Frontend
    ↓
Backend API
    ↓
PostgreSQL
```

초기 구조는 단순하게 시작하되, 제조 데이터의 이력성과 AI 확장을 고려합니다.

## Backend

Backend는 다음 책임을 가집니다.

- 인증과 권한
- 기준정보 관리
- 작업지시 관리
- 공정 실적 기록
- LOT 추적
- 감사 로그
- AI context API

## Frontend

Frontend는 두 종류의 화면을 분리합니다.

- 관리자 화면: 기준정보, 작업지시, 조회, 설정
- 현장 화면: 작업 목록, 시작/종료, 실적 입력, LOT 스캔

## Database

PostgreSQL을 기본으로 사용합니다.

중요 테이블은 append-only 이벤트 또는 감사 로그를 남길 수 있어야 합니다. 생산 결과, LOT 소비, AI 실행 요청은 수정보다 정정 이력을 남기는 방향을 우선합니다.

## Event Outbox

초기에는 PostgreSQL outbox 테이블로 시작합니다.

이벤트 예시는 다음과 같습니다.

- work_order.released
- operation.started
- operation.completed
- material_lot.consumed
- material_lot.produced
- defect.recorded
- ai_action.proposed
- ai_action.approved

이 구조는 이후 메시지 큐나 외부 연동으로 확장할 수 있습니다.

## API 원칙

- REST API를 우선합니다.
- 모든 쓰기 API는 actor 정보를 남깁니다.
- 생산 데이터 변경은 감사 로그를 남깁니다.
- AI가 호출할 수 있는 API는 읽기, 제안, 승인 요청, 승인 후 실행을 구분합니다.

