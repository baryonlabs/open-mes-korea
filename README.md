# Open MES Korea

Open MES Korea는 한국 제조 현장에서 바로 이해하고 확장할 수 있는 오픈소스 MES 프로젝트입니다.

목표는 거대한 통합 시스템을 한 번에 만드는 것이 아니라, 중소 제조업에서 가장 먼저 필요한 흐름을 단단하게 만드는 것입니다.

이 프로젝트는 ERP 전체를 대체하려 하지 않습니다. 핵심은 **현장 실행 + LOT 추적 + AI context/approval layer**입니다.

- 작업지시
- 공정 진행
- 생산 실적
- 불량 기록
- 자재 및 LOT 추적
- 현장 작업자 입력 화면
- 관리자용 생산 현황
- AI native 운영 준비

## 왜 필요한가

국내 제조 현장의 MES는 업종, 공정, 설비, ERP 연동 방식이 모두 달라서 범용 제품만으로는 도입이 어렵습니다. 반대로 오픈소스 MES는 한국어, 국내 업무 용어, 현장 입력 경험, LOT 추적, 바코드 운영, 엑셀 기반 전환 시나리오가 부족한 경우가 많습니다.

이 프로젝트는 다음 기준을 우선합니다.

- 한국어 우선 UI와 문서
- 현장 작업자가 쓸 수 있는 단순한 화면
- 제조 데이터의 이력성과 추적성
- API-first 구조
- Docker 기반 쉬운 설치
- AI agent가 안전하게 사용할 수 있는 데이터와 액션 경계

## 초기 제품 범위

첫 번째 목표는 아래 흐름을 실제로 동작하게 만드는 것입니다.

```text
품목/BOM/공정 등록
→ 작업지시 생성
→ 공정별 작업 시작/종료
→ 생산수량/불량수량 입력
→ 자재 LOT 투입 기록
→ 제품 LOT 생성
→ 생산현황 및 LOT 이력 조회
```

ERP의 회계, 인사, 구매, 영업 전체 기능은 초기 목표가 아닙니다. Open MES Korea는 ERP와 연동 가능한 현장 실행 레이어로 시작합니다.

## AI Native 방향

AI 기능은 단순 챗봇이 아니라 MES 운영 구조 안에 들어가야 합니다.

- 자연어 생산 현황 조회
- 작업지시, 불량, LOT 이력 요약
- 이상 징후 탐지 후보 생성
- 표준작업서, 설비 매뉴얼, 품질 기준 문서 검색
- 생산관리자 승인 기반 액션 실행
- 모든 AI 제안과 실행 요청 감사 로그 기록

자세한 방향은 [AI Native Architecture](docs/ai-native-architecture.md)를 참고하세요.

## 문서

- [프로젝트 비전](docs/vision.md)
- [MVP 범위](docs/mvp-scope.md)
- [도메인 모델](docs/domain-model.md)
- [시스템 아키텍처](docs/system-architecture.md)
- [AI Native Architecture](docs/ai-native-architecture.md)
- [시장조사](docs/market-research.md)
- [로드맵](docs/roadmap.md)

## 기술 방향

초기 권장 스택은 다음과 같습니다.

- Backend: FastAPI 또는 Django
- Frontend: Next.js 또는 React
- Database: PostgreSQL
- Queue/Event: Redis 또는 PostgreSQL 기반 outbox
- Deployment: Docker Compose
- API: REST 우선, 이후 event/webhook 확장

구체 스택은 첫 번째 코드 스캐폴딩 단계에서 확정합니다.

## 라이선스

초기 라이선스는 MIT를 기본 후보로 둡니다. 실제 공개 전 `LICENSE` 파일과 저작권 표기를 확정합니다.
