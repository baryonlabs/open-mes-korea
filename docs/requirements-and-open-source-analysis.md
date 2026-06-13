# 기능 요구사항 및 오픈소스 분석

조사일: 2026-06-13

## 분석 기준

Open MES Korea는 ERP 전체를 대체하지 않는다. 집중 범위는 다음 세 가지다.

```text
현장 실행 + LOT 추적 + AI context/approval layer
```

따라서 요구사항과 경쟁 분석도 이 기준으로 평가한다.

- 현장 작업자가 실제로 쓸 수 있는가
- 작업지시와 공정 실적이 단단한가
- LOT 투입, 생성, genealogy가 추적 가능한가
- 불량과 품질 이력이 남는가
- ERP/설비/바코드와 연결될 수 있는가
- AI가 안전하게 읽고 제안하고 승인 요청을 만들 수 있는가
- 한국 중소 제조업의 언어와 운영 방식에 맞는가

## 기능 요구사항 표

우선순위:

- Must: MVP 필수
- Should: 초기 공개 버전 필수 후보
- Could: 확장 기능
- Later: 장기 과제

| 영역 | 요구사항 | 우선순위 | MVP 단계 | 설명 | Open MES Korea 설계 방향 |
|---|---|---:|---:|---|---|
| 기준정보 | 품목 관리 | Must | 1 | 원자재, 반제품, 제품 구분과 단위 관리 | `Item`을 모든 생산/LOT 흐름의 기준 엔티티로 둔다 |
| 기준정보 | BOM 관리 | Must | 1 | 제품 또는 반제품의 구성 품목과 소요량 관리 | 다단 BOM은 지원하되 초기 UI는 단순 BOM부터 시작 |
| 기준정보 | 공정 관리 | Must | 1 | 절단, 가공, 조립, 검사, 포장 등 공정 정의 | 공정 코드는 회사별 커스터마이징 가능하게 설계 |
| 기준정보 | 라우팅 관리 | Must | 1 | 품목별 공정 순서 정의 | `Routing`과 `Operation`을 분리해 작업지시 생성 시 스냅샷화 |
| 기준정보 | 설비 관리 | Should | 2 | 공정에 사용되는 설비/라인 관리 | 초기에는 수동 선택, 이후 설비 데이터 연동 |
| 기준정보 | 작업자 관리 | Must | 1 | 현장 작업자, 생산관리자, 품질관리자 구분 | 권한과 감사 로그의 actor로 사용 |
| 기준정보 | 불량 코드 관리 | Must | 2 | 불량 유형과 원인 후보 관리 | 품질 분석과 AI 추천의 기준 데이터로 사용 |
| 기준정보 | 거래처 관리 | Could | 4 | 고객/공급사/외주처 | ERP 연동 전 최소 참조 정보만 보유 |
| 생산 실행 | 작업지시 생성 | Must | 1 | 생산할 품목, 수량, 납기, 우선순위 지정 | ERP/MRP가 없어도 수동 생성 가능해야 함 |
| 생산 실행 | 작업지시 릴리즈 | Must | 1 | 현장에 내릴 작업 확정 | draft/released 상태 분리 |
| 생산 실행 | 공정별 작업 목록 | Must | 1 | 작업자 화면에서 오늘/라인별 작업 표시 | 현장 태블릿 UX의 첫 화면 |
| 생산 실행 | 작업 시작/종료 | Must | 1 | 공정 작업의 실제 시작과 완료 기록 | one-tap 중심, 중복 시작 방지 |
| 생산 실행 | 작업 중지/재개 | Should | 2 | 자재 부족, 설비 고장, 휴식 등으로 중지 | downtime/andon 확장의 기반 |
| 생산 실행 | 생산수량 입력 | Must | 1 | 양품 수량 기록 | 작업 종료 또는 중간 실적 등록 시 입력 |
| 생산 실행 | 불량수량 입력 | Must | 2 | 불량 수량과 유형 기록 | 품질/AI 분석의 핵심 데이터 |
| 생산 실행 | 부분 완료 | Should | 2 | 한 작업지시를 여러 번 나누어 실적 처리 | batch/lot 단위 생산에 필요 |
| 생산 실행 | 재작업 처리 | Should | 3 | 불량품 재작업 또는 재검사 흐름 | 상태 모델을 먼저 열어둔다 |
| 생산 실행 | 공정 건너뛰기 | Could | 4 | 예외 상황에서 승인 기반 skip | 승인 로그 필수 |
| LOT 추적 | 원자재 LOT 등록 | Must | 2 | 입고 또는 기존 재고 LOT 생성 | 재고 전체보다 LOT ID와 수량 이력을 우선 |
| LOT 추적 | 공정 투입 LOT 기록 | Must | 2 | 작업/공정에 어떤 LOT가 투입됐는지 기록 | `LotConsumption`을 append-only 성격으로 설계 |
| LOT 추적 | 제품 LOT 생성 | Must | 2 | 생산 결과로 완제품/반제품 LOT 생성 | 작업지시, 공정, 투입 LOT와 연결 |
| LOT 추적 | LOT genealogy 조회 | Must | 3 | 완제품에서 원자재까지 역추적 | 식품/화장품/전자부품에서 핵심 차별점 |
| LOT 추적 | LOT 분할/병합 | Should | 3 | 일부 사용, 혼합, 재포장 처리 | 이력 손실 없이 event로 기록 |
| LOT 추적 | 격리/폐기 상태 | Should | 3 | 품질 문제 LOT의 사용 차단 | 품질 판정과 연결 |
| 품질 | 공정 불량 기록 | Must | 2 | 불량 코드, 수량, 메모, 사진 등 | 초기에는 코드/수량/메모, 이후 첨부 |
| 품질 | 검사 결과 기록 | Should | 3 | 합격/불합격, 측정값 | QMS 확장의 접점 |
| 품질 | 품질 이슈/조치 | Should | 3 | 이슈 발생, 담당자 확인, 조치 완료 | OpenMES의 issue/andon 구조를 참고 |
| 품질 | 품질 문서 연결 | Could | 4 | 검사 기준서, 작업표준서 연결 | AI RAG 문서 영역과 연결 |
| 현장 UX | 태블릿 최적화 | Must | 1 | 큰 버튼, 작은 입력, 높은 가독성 | 관리자 UI보다 우선순위가 높음 |
| 현장 UX | 바코드/QR 입력 | Must | 2 | 작업지시, 품목, LOT 스캔 | USB 스캐너는 키보드 입력으로 우선 지원 |
| 현장 UX | 오프라인 큐 | Should | 3 | 네트워크 불안정 시 입력 보관 | 현장 신뢰성에 중요 |
| 현장 UX | 다국어 | Could | 4 | 외국인 작업자 대응 | 한국어 기본, 영어/베트남어 확장 가능 |
| 현장 UX | 작업표준서 표시 | Should | 3 | 공정별 작업 지시 문서 표시 | AI 문서 검색과 연결 |
| 현장 UX | Andon/문제 호출 | Should | 3 | 작업자가 즉시 문제 신고 | 생산 중지/품질 이슈와 연결 |
| 조회/분석 | 작업지시 진행 현황 | Must | 1 | released/running/completed 조회 | 생산관리자 기본 화면 |
| 조회/분석 | 공정별 실적 | Must | 2 | 공정/작업자/설비별 실적 | 생산성과 병목 확인 |
| 조회/분석 | 불량 현황 | Must | 2 | 품목/공정/불량유형별 조회 | 품질 개선과 AI 분석 기반 |
| 조회/분석 | LOT 이력 조회 | Must | 3 | 투입/생산/격리/폐기 이력 | 리콜/클레임 대응 핵심 |
| 조회/분석 | OEE/설비 성능 | Could | 5 | 가동률, 성능, 품질 기반 OEE | Libre 같은 설비 중심 도구와 연동 가능 |
| 조회/분석 | CSV/Excel 내보내기 | Should | 2 | 실무 보고와 마이그레이션 | 한국 중소 제조업 도입에 중요 |
| 연동 | CSV/Excel 가져오기 | Must | 2 | 품목, 작업지시, LOT 초기 등록 | ERP 없이 시작하는 공장에 필요 |
| 연동 | ERP 연동 API | Should | 4 | 작업지시 수신, 실적 송신 | ERPNext/Odoo/SAP/custom ERP와 연결 |
| 연동 | Webhook/outbox | Should | 4 | 생산 이벤트 외부 전송 | 이벤트 기반 확장 |
| 연동 | 설비 데이터 수집 | Could | 5 | PLC/OPC UA/MQTT 등 | MVP에서는 직접 구현하지 않음 |
| 연동 | 라벨 출력 | Should | 3 | LOT/제품/포장 라벨 | 한국 현장 요구가 높음 |
| 권한/감사 | RBAC | Must | 1 | 관리자, 생산관리자, 작업자, 품질관리자 | 최소 권한 원칙 |
| 권한/감사 | 감사 로그 | Must | 1 | 누가 무엇을 변경했는지 기록 | 생산/LOT/AI 액션은 필수 |
| 권한/감사 | 정정 이력 | Must | 2 | 실적/LOT 오류 수정 시 원본 보존 | 삭제보다 correction event를 우선 |
| 권한/감사 | 승인 워크플로 | Should | 3 | 중요한 변경 승인 | AI action approval과 같은 구조 사용 |
| AI native | AI context API | Must | 3 | AI가 권한 필터링된 MES 데이터를 읽음 | DB 직접 접근 금지 |
| AI native | 자연어 조회 | Should | 4 | 생산/불량/LOT 질의응답 | read-only부터 시작 |
| AI native | 생산/LOT 요약 | Should | 4 | 작업지시, LOT genealogy 요약 | 현장/관리자 의사결정 지원 |
| AI native | 불량 패턴 후보 | Should | 5 | 반복 불량, 공정 편차 후보 제안 | 제안과 근거 데이터 분리 저장 |
| AI native | AI 제안 승인 | Must | 4 | 변경 액션은 승인 후 실행 | Open MES Korea의 핵심 차별점 |
| AI native | AI interaction audit | Must | 3 | 프롬프트, 참조 데이터, 응답 요약 기록 | 보안/품질/책임 추적 |
| AI native | 문서 RAG | Could | 5 | 작업표준서/품질기준/설비 매뉴얼 검색 | 생산 데이터와 문서 저장소 분리 |
| 배포/운영 | Docker Compose 설치 | Must | 1 | 단일 서버 설치 | 중소 제조업과 SI 도입에 필요 |
| 배포/운영 | 백업/복구 | Should | 3 | DB 백업과 복구 절차 | 제조 이력 데이터 보호 |
| 배포/운영 | 마이그레이션 | Must | 1 | DB schema 변경 관리 | 장기 유지보수 필수 |
| 배포/운영 | 온프레미스 운영 | Must | 1 | 공장 내부망 설치 | 국내 제조 현장 기본 요구 |
| 배포/운영 | 클라우드 운영 | Could | 4 | SaaS/managed 배포 | 오픈소스 코어 이후 선택지 |

## MVP 요구사항 압축

1. 품목, BOM, 공정, 라우팅
2. 작업지시 생성/릴리즈
3. 현장 작업 목록
4. 작업 시작/종료
5. 양품/불량 실적 입력
6. 원자재 LOT 투입
7. 제품 LOT 생성
8. 작업지시/공정/불량/LOT 조회
9. RBAC와 감사 로그
10. AI context API와 AI interaction audit

## 오픈소스 분석 요약표

GitHub 수치는 2026-06-13 기준 `gh` CLI와 공개 저장소 페이지로 확인했다.

| 프로젝트 | 성격 | GitHub 지표 | 라이선스/공개성 | 강점 | 약점 | Open MES Korea 관점 |
|---|---|---:|---|---|---|---|
| ERPNext | ERP + 제조 모듈 | 35.5k stars / 11.7k forks | 오픈소스 ERP | BOM, Work Order, Job Card, 재고, 회계까지 성숙 | MES보다 ERP/MRP 중심, 현장 태블릿 UX와 한국어 제조 기본값은 별도 설계 필요 | ERP 연동 대상으로 좋고, 기능 범위 벤치마크로 활용 |
| Odoo | ERP suite + MRP/MES 일부 | 52.4k stars / 32.8k forks | Community + Enterprise | 제조오더, work center, shop floor tablet, quality, barcode 생태계 | 핵심 고급 기능이 Enterprise에 있을 수 있고, ERP 전체 제품이라 복잡 | Shop floor UX와 barcode 흐름을 참고하되 ERP 경쟁은 피함 |
| Carbon | ERP + MES + QMS | 2.1k stars / 281 forks | README상 AGPL/상용 라이선스 구조 | 현대적 스택, API-first, traceability, MRP, MCP client/server, ABAC/RLS | 범위가 넓고 복잡, 한국 현장 기본값 아님 | AI/agent와 API-first 설계에서 강력한 참고 대상 |
| OpenMES | MES | 50 stars / 9 forks | AGPL-3.0 | 소규모 제조업, tablet-first, 작업자 UX, immutable audit, hook system, packaging barcode | 프로젝트 성숙도는 아직 작고 한국어/국내 LOT 업무는 별도 | 가장 직접적인 MES UX 경쟁/참고 대상 |
| Libre | MES + performance monitoring | 85 stars / 27 forks | Apache-2.0 | Grafana/Influx/Postgres 기반, 설비 지표, downtime, OEE | 작업지시/LOT/품질 중심 MES 코어는 약함 | OEE/설비 데이터 확장 시 연동 또는 참고 |
| qcadoo MES | MES | 911 stars / 448 forks | Community/AGPL로 안내 | 오래된 MES형 프로젝트, 생산관리 기능 범위 넓음 | UI/기술 현대성, 한국형 UX, AI native는 약함 | 전통 MES 기능 목록 참고 |
| IMES smart-industry | Job shop MES | 435 stars / 151 forks | Apache-2.0 | small/midsize job shop 대상, scheduling 키워드 | 기술 스택과 생태계 현대성 확인 필요, 한국어/AI 없음 | job shop 시나리오 참고 |
| mes4u | MES | 57 stars / 17 forks | 라이선스 확인 필요 | 제조 현장 경험 기반, core/master data 제공 | v1 범위 제한, inventory/material management는 향후 계획 | 한국/아시아형 MES 구조 참고 후보 |

## 기능 커버리지 비교표

평가:

- O: 명확히 지원하거나 문서화됨
- △: 일부 지원 또는 커스터마이징 필요
- X: 확인 어려움 또는 핵심 기능 아님
- ?: 공개 문서만으로 판단 부족

| 기능 | ERPNext | Odoo | Carbon | OpenMES | Libre | qcadoo | IMES | mes4u | Open MES Korea 목표 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 품목/BOM | O | O | O | △ | △ | O | △ | O | O |
| 라우팅/공정 | O | O | O | O | O | O | O | △ | O |
| 작업지시 | O | O | O | O | O | O | O | △ | O |
| Job card/operation tracking | O | O | O | O | △ | O | O | △ | O |
| 현장 태블릿 UX | △ | O | △ | O | △ | △ | △ | ? | O |
| 작업 시작/종료 | O | O | O | O | O | O | O | ? | O |
| 부분 완료/batch | △ | O | △ | O | △ | △ | ? | ? | O |
| 불량 기록 | O | O | O | O | △ | O | ? | ? | O |
| 품질 이슈/조치 | O | O | O | O | △ | △ | ? | ? | O |
| LOT 투입/생성 | △ | O | O | △ | X | △ | ? | ? | O |
| LOT genealogy | △ | △ | O | △ | X | ? | ? | ? | O |
| 바코드/QR | △ | O | △ | O | ? | ? | ? | ? | O |
| 오프라인 현장 입력 | X | △ | ? | O | ? | ? | ? | ? | Should |
| 설비/OEE | △ | △ | △ | △ | O | △ | ? | ? | Could |
| 생산 대시보드 | O | O | O | O | O | O | ? | ? | O |
| CSV/Excel import/export | O | O | △ | O | △ | ? | ? | ? | O |
| ERP 연동 API | 자체 ERP | 자체 ERP | O | O | △ | ? | ? | ? | O |
| Webhook/event 확장 | △ | △ | O | O | ? | ? | ? | ? | O |
| RBAC | O | O | O | O | △ | O | ? | ? | O |
| 감사 로그 | △ | △ | O | O | △ | ? | ? | ? | O |
| AI context API | X | X | △ | X | X | X | X | X | O |
| AI approval workflow | X | X | △ | X | X | X | X | X | O |
| 한국어/한국 제조 기본값 | △ | △ | X | X | X | X | △ | △ | O |

## 프로젝트별 상세 분석

### ERPNext

ERPNext는 제조업 전체 업무를 통합하려는 ERP입니다. 공식 문서 기준으로 Work Order는 생산할 품목과 수량을 shop floor에 전달하는 문서이며, BOM에서 자재 요구를 생성합니다. Work Order, Job Card, Plant Floor, BOM 관련 리포트, 품질 리포트, downtime analysis 등이 문서 구조에 포함되어 있습니다.

Open MES Korea가 배울 점:

- Work Order와 Job Card 분리
- BOM 기반 자재 소요와 공정 연결
- 제조 리포트의 기본 범위
- ERP 연동 시 주고받아야 할 데이터 구조

Open MES Korea가 피해야 할 점:

- 회계/구매/인사/재고 전체를 초기에 다루는 범위 확장
- ERP 화면 중심 UX
- MES 현장 입력이 ERP 문서 입력으로 느껴지는 구조

### Odoo

Odoo는 제조오더, work order, work center control panel, tablet shop floor, quality, maintenance, barcode scanner, IoT Boxes를 한 생태계에서 제공합니다. 공식 문서는 작업자가 태블릿으로 shop floor에서 work orders를 제어하고 maintenance, feedback loop, quality issues 등을 트리거할 수 있다고 설명합니다.

Open MES Korea가 배울 점:

- 작업자용 shop floor UX
- barcode와 manufacturing order 연결
- quality check를 작업 흐름 안에 넣는 방식
- 유지보수/품질 이슈를 생산 실행에서 바로 발생시키는 흐름

Open MES Korea가 피해야 할 점:

- ERP suite 전체와의 기능 경쟁
- Community/Enterprise 경계 때문에 생기는 오픈소스 사용성 불확실성

### Carbon

Carbon은 ERP, MES, QMS를 함께 제공하는 제조 운영 시스템입니다. README 기준 기능은 Custom Fields, Nested BoM, Traceability, MRP, Configurator, MCP Client/Server, API, Webhooks, Accounting, Capacity Planning, Simulation까지 넓습니다. 기술적으로 ABAC, RLS, realtime subscriptions, dependency graph, third-party integrations를 강조합니다.

Open MES Korea가 배울 점:

- API-first 구조
- traceability와 nested BOM
- MCP client/server 및 agentic platform 방향
- 권한 모델과 row-level security에 대한 높은 기준
- webhooks와 integration-first 사고

Open MES Korea가 피해야 할 점:

- 초기부터 ERP/MES/QMS/accounting을 모두 포함하는 과도한 범위
- 외부 서비스 의존성이 많은 개발/운영 구조

### OpenMES

OpenMES는 small manufacturers를 대상으로 한 오픈소스 MES입니다. README 기준 tablet-first, production planner, work order lifecycle, batch production, process templates, operator queue, one-tap actions, offline mode, issue/andon system, immutable audit logs, RBAC, hook system, ERP/IoT/barcode 확장을 제공합니다.

Open MES Korea가 배울 점:

- 소규모 제조업 대상의 명확한 범위
- tablet-first operator experience
- one-tap start/complete/problem report
- offline action queue
- hook 기반 확장성
- immutable audit logs

Open MES Korea가 차별화할 점:

- 한국어와 한국 제조 용어를 기본값으로 제공
- LOT genealogy를 더 중심 기능으로 배치
- AI context/approval layer를 제품 핵심으로 설계
- 국내 스마트공장 도입/유지보수 맥락 반영

### Libre

Libre는 Grafana, InfluxDB, PostgreSQL 기반의 manufacturing execution and performance monitoring 도구입니다. 마스터 데이터, machine metrics, orders, downtime reasons, OEE 시각화에 강합니다. 설비 데이터와 생산 성능 분석 중심입니다.

Open MES Korea가 배울 점:

- Grafana 기반 성능 모니터링
- downtime reason code
- OEE와 line performance
- 설비 데이터 historian 구조

Open MES Korea가 피해야 할 점:

- 설비/OEE부터 시작해 작업지시와 LOT 추적이 약해지는 방향
- Grafana dashboard가 현장 작업자 입력 UX를 대체한다고 보는 접근

### qcadoo MES

qcadoo MES는 오래된 오픈소스 MES 계열 프로젝트입니다. 공개 사이트는 Community Edition이 AGPL 라이선스 기반 오픈소스라고 안내합니다.

Open MES Korea가 배울 점:

- 전통 MES가 제공해야 하는 기능 범위
- production planning, technology/routing, order tracking 같은 도메인 구분

Open MES Korea가 차별화할 점:

- 현대적 개발/배포 경험
- 한국어 중심 UX
- AI native 구조
- 모바일/태블릿 현장 경험

### IMES / smart-industry

IMES는 small/midsize job shop manufacturer를 위한 오픈소스 MES입니다. Job shop, scheduling, PWA 키워드가 강합니다.

Open MES Korea가 배울 점:

- 다품종 소량생산/job shop 시나리오
- scheduling과 production status
- 작은 제조업을 대상으로 한 기능 범위

Open MES Korea가 차별화할 점:

- 기술 스택 현대화
- LOT/품질/AI approval 중심 설계
- 한국어 문서와 국내 도입 흐름

### mes4u

mes4u는 제조 현장에서 사용하던 MES 기능과 노하우를 바탕으로 공개된 MES입니다. README는 v1이 제조 현장에 필요한 core functions와 master data를 제공하며, 향후 inventory와 material management를 개선하겠다고 설명합니다.

Open MES Korea가 배울 점:

- 현장 경험 기반의 MES 기능 구성
- master data 중심의 초기 범위 설정

Open MES Korea가 차별화할 점:

- 라이선스와 운영 정책 명확화
- 더 넓은 커뮤니티 기여 구조
- AI context/approval과 LOT genealogy를 명확한 핵심으로 둠

## 기능 요구사항에서 얻은 제품 전략

### 1. ERP와의 경계

ERPNext/Odoo/Carbon은 ERP 전체 범위가 강합니다. Open MES Korea는 ERP 기능을 만들기보다 다음 API 경계를 명확히 해야 합니다.

| ERP가 담당 | Open MES Korea가 담당 |
|---|---|
| 판매 주문 | 작업지시 실행 |
| 구매 | 자재 LOT 투입 이력 |
| 회계 | 생산 실적 이벤트 |
| 인사/급여 | 작업자 actor/권한 |
| 재고 원장 | LOT genealogy와 공정 소비 |
| 원가 전체 | 공정 실적과 불량 데이터 |

### 2. Open MES Korea의 1차 차별 기능

| 차별 기능 | 이유 |
|---|---|
| 한국어 기본 용어 | 국내 중소 제조업 도입 장벽 감소 |
| 태블릿 현장 UX | MES 성공은 관리자 화면보다 작업자 입력 성공률에 좌우 |
| LOT genealogy 중심 모델 | 식품, 화장품, 전자부품, 의료기기에서 핵심 |
| append-only 생산/LOT 이벤트 | 정정 가능성과 감사 가능성 확보 |
| AI context API | AI가 DB를 직접 읽지 않게 하는 안전 계층 |
| AI approval workflow | AI native 시대의 운영 신뢰 확보 |
| Docker Compose 온프레미스 | 공장 내부망 설치에 적합 |

### 3. 첫 구현에서 제외할 기능

| 제외 기능 | 이유 | 대안 |
|---|---|---|
| 회계 | ERP 영역 | ERP 연동 API |
| 인사/급여 | MES 핵심 아님 | 사용자/권한만 보유 |
| 고급 APS | 복잡도 높음 | 작업지시 우선순위와 간단한 일정 |
| PLC/SCADA 범용 드라이버 | 설비별 편차 큼 | CSV/API/MQTT/OPC UA connector를 후순위 |
| 완전 자동 AI 실행 | 신뢰/책임 리스크 | 승인 기반 실행 |
| 복잡한 원가계산 | ERP/MRP 영역 | 공정 시간/수량 데이터만 제공 |

## 권장 도메인 모듈 구조

| 모듈 | 포함 기능 | MVP 여부 |
|---|---|---:|
| Master Data | 품목, BOM, 공정, 라우팅, 작업자, 설비 | O |
| Work Orders | 작업지시, 릴리즈, 상태, 우선순위 | O |
| Shop Floor | 작업 목록, 시작/종료, 수량 입력, 불량 입력 | O |
| Lot Traceability | 원자재 LOT, 투입, 제품 LOT, genealogy | O |
| Quality | 불량 코드, 불량 기록, 품질 이슈 | O |
| Audit | 변경 이력, 정정 이력, actor 기록 | O |
| AI Context | 권한 적용 조회 API, 참조 데이터 기록 | O |
| AI Approval | 제안, 검토, 승인, 실행 결과 | O |
| Integrations | CSV/Excel, ERP API, webhook/outbox | 일부 |
| Equipment | 설비, downtime, OEE, sensor bridge | 이후 |
| Documents | 작업표준서, 품질기준서, RAG index | 이후 |

## 권장 MVP 화면

| 화면 | 사용자 | 포함 요소 | 우선순위 |
|---|---|---|---:|
| 오늘 작업 목록 | 작업자 | 작업지시, 공정, 수량, 상태, 시작 버튼 | Must |
| 작업 실행 화면 | 작업자 | 시작/종료, 양품/불량, LOT 스캔, 메모 | Must |
| LOT 스캔 화면 | 작업자 | 원자재 LOT 입력, 수량, 오류 표시 | Must |
| 불량 입력 화면 | 작업자 | 불량 코드, 수량, 메모 | Must |
| 작업지시 관리 | 생산관리자 | 생성, 릴리즈, 취소, 상태 조회 | Must |
| 생산현황 | 생산관리자 | 작업지시별/공정별 진행률 | Must |
| LOT genealogy | 품질/생산관리자 | 제품 LOT에서 원자재 LOT 역추적 | Must |
| 불량 현황 | 품질관리자 | 품목/공정/불량유형별 집계 | Must |
| AI 질문 화면 | 생산관리자 | read-only 질문과 근거 링크 | Should |
| AI 승인함 | 생산관리자/관리자 | 제안, 근거, 승인/거절, 실행 로그 | Should |

## 결론

타 오픈소스 분석 결과, Open MES Korea가 경쟁해야 할 축은 "ERP 기능 수"가 아니다.

가장 좋은 포지션은 다음이다.

```text
한국 제조 현장용 오픈소스 MES 코어
= 작업지시 실행 + 현장 입력 + LOT genealogy + 불량 기록 + 감사 로그
+ AI context API + approval workflow
```

초기 구현은 ERPNext/Odoo처럼 넓어지면 안 되고, OpenMES처럼 현장 UX를 강하게 가져가되 Carbon처럼 API/AI/권한 설계를 처음부터 높게 잡아야 한다. Libre는 설비/OEE 확장 단계에서 참고하거나 연동 대상으로 두는 것이 좋다.

## 참고 자료

- [ERPNext Work Order documentation](https://docs.frappe.io/erpnext/work-order)
- [ERPNext GitHub](https://github.com/frappe/erpnext)
- [Odoo Manufacturing documentation](https://www.odoo.com/documentation/19.0/applications/inventory_and_mrp/manufacturing.html)
- [Odoo GitHub](https://github.com/odoo/odoo)
- [Carbon GitHub](https://github.com/crbnos/carbon)
- [OpenMES GitHub](https://github.com/Mes-Open/OpenMes)
- [Libre GitHub](https://github.com/Spruik/Libre)
- [qcadoo MES GitHub](https://github.com/qcadoo/mes)
- [qcadoo open source version](https://www.qcadoo.com/en/open-source-version/)
- [IMES / smart-industry GitHub](https://github.com/jukbot/smart-industry)
- [mes4u GitHub](https://github.com/sindohmes/mes4u)

