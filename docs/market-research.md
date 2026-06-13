# 시장조사

조사일: 2026-06-13

## 결론

Open MES Korea의 기회는 "무료 MES" 자체가 아니라, 한국 중소 제조업이 실제로 도입할 수 있는 한국어 MES 코어와 AI native 운영 구조를 오픈소스로 제공하는 데 있습니다.

현재 시장은 세 방향으로 움직입니다.

1. 스마트공장/MES 수요는 계속 성장한다.
2. 한국 정부 정책은 단순 보급에서 AI 기반 제조혁신과 고도화로 이동하고 있다.
3. 오픈소스 대안은 존재하지만 한국 제조 현장, 작업자 UX, LOT 추적, AI 승인 흐름까지 포함한 제품은 부족하다.

따라서 이 프로젝트는 ERP 전체를 대체하려 하기보다, "현장 실행 + LOT 추적 + AI context/approval layer"에 집중하는 것이 맞습니다.

## 시장 흐름

### 글로벌 스마트팩토리 시장

MarketsandMarkets는 글로벌 스마트팩토리 시장이 2025년 1,044.2억 달러에서 2030년 1,697.3억 달러로 성장하고, 2025~2030년 CAGR은 10.2%라고 제시합니다. 같은 자료에서 MES는 스마트팩토리 솔루션 영역의 중심 구성요소로 언급됩니다.

핵심 의미:

- MES는 스마트팩토리의 주변 기능이 아니라 핵심 운영 레이어입니다.
- AI, IIoT, 디지털 트윈, 실시간 분석의 확산은 MES의 데이터 품질 요구를 높입니다.
- 제조 현장의 데이터가 정리되지 않으면 AI 도입 효과가 제한됩니다.

### 한국 스마트공장 정책

중소벤처기업부는 2025년 스마트제조혁신 지원사업을 공고했고, 중소·중견기업의 제조혁신 경쟁력 제고를 목표로 스마트공장 구축, 로봇자동화, 클라우드형 종합솔루션, 제조데이터 관련 지원을 포함했습니다.

2026년에는 방향이 더 명확해졌습니다. 중기부의 2026년 예산 보도자료에 따르면 ICT융합스마트공장보급확산 예산은 2025년 2,361억원에서 2026년 4,021억원으로 늘었고, 지역 주도형 AI 대전환 예산도 2025년 추경 350억원에서 2026년 490억원으로 확대되었습니다.

핵심 의미:

- 한국 시장은 여전히 정부 지원사업과 강하게 연결되어 있습니다.
- "스마트공장 구축"보다 "고도화, AI, 데이터 활용"의 비중이 커지고 있습니다.
- 도입 후 유지보수와 개선 수요도 시장의 일부입니다. 중소벤처기업진흥공단의 스마트공장 AS 지원사업은 MES, ERP, PLM 등 솔루션과 연동된 H/W, S/W 개선 및 유지관리를 지원 대상으로 둡니다.

## 오픈소스 경쟁 환경

### ERPNext

ERPNext는 제조 기능을 가진 대표적인 오픈소스 ERP입니다. BOM, work order, inventory, accounting, HR 등을 포함하고, 제조 모듈에는 MRP, routing, capacity planning 등이 포함됩니다.

강점:

- ERP 전체 범위가 넓습니다.
- 커뮤니티와 문서가 큽니다.
- 중소기업의 통합 업무 시스템으로 접근하기 좋습니다.

약점:

- 현장 작업자 중심 MES라기보다 ERP/MRP 성격이 강합니다.
- 한국어 제조 현장 용어와 UX를 기본값으로 보기 어렵습니다.
- AI native 권한/승인/감사 구조는 별도 설계가 필요합니다.

### Odoo

Odoo는 제조, MRP, 품질, 유지보수 등 모듈을 가진 오픈소스 기반 ERP입니다. Community Edition은 진입 장벽이 낮고, Enterprise Edition은 더 많은 자동화와 분석 기능을 제공합니다.

강점:

- 모듈 생태계가 큽니다.
- ERP 전체 확장성이 좋습니다.
- PostgreSQL 기반입니다.

약점:

- MES 특화 오픈소스라기보다는 ERP suite입니다.
- 고급 기능은 Enterprise로 갈 가능성이 큽니다.
- 한국 중소 제조 현장 맞춤 UX는 별도 구현이 필요합니다.

### Carbon

Carbon은 ERP, MES, QMS를 결합한 오픈소스 제조 시스템입니다. 복잡 조립, 계약 제조, configure-to-order 제조에 초점을 둡니다. GitHub 설명에 MCP server와 agentic platform 키워드가 포함되어 있어 AI/agent 방향을 의식하고 있습니다.

강점:

- ERP/MES/QMS를 함께 다룹니다.
- TypeScript, PostgreSQL, Supabase 등 현대적 스택을 사용합니다.
- agentic platform 방향성이 있습니다.

약점:

- 한국어와 한국 제조 현장 기본값은 아닙니다.
- Open MES Korea가 겨냥하는 경량 한국형 shop floor UX와는 포지션이 다릅니다.

### Libre

Libre는 Grafana, InfluxDB, PostgreSQL 기반의 제조 실행 및 성능 모니터링 도구입니다. 설비 데이터, OEE, downtime 분석에 강점이 있습니다.

강점:

- machine metrics와 OEE 중심의 데이터 수집/시각화에 적합합니다.
- Grafana 생태계를 활용합니다.
- 설비 데이터 기반 성능 개선에 유리합니다.

약점:

- 기준정보, 작업지시, LOT genealogy, 품질 기록 중심의 한국형 MES 코어로 보기에는 범위가 다릅니다.
- 작업자 입력 UX와 업무 프로세스는 별도 보강이 필요합니다.

### IMES / smart-industry

IMES는 small-midsize job shop manufacturer를 대상으로 한 오픈소스 MES입니다.

강점:

- MES 자체를 직접 지향합니다.
- job shop 제조에 초점을 둡니다.

약점:

- 최근 생태계 활성도와 기술 스택 현대성 확인이 필요합니다.
- 한국어, AI native, 국내 지원사업 맥락과는 거리가 있습니다.

## 상용 MES/스마트팩토리 흐름

상용 MES 시장은 AI assistant, low-code, cloud MES, digital twin, predictive analytics 방향으로 움직이고 있습니다. 2025년 MES Technology Value Matrix 자료에서는 42Q가 Amazon Bedrock 기반 AI 챗봇을 출시해 MES 환경에서 실시간 인사이트와 사용자 안내를 제공한다고 소개합니다.

핵심 의미:

- AI는 MES의 별도 부가기능이 아니라 사용자 인터페이스와 운영 의사결정 레이어로 들어오고 있습니다.
- 하지만 상용 시스템의 AI는 특정 벤더 플랫폼에 묶이는 경향이 큽니다.
- 오픈소스 MES는 AI 기능을 vendor-neutral하게 설계할 수 있습니다.

## 고객 세그먼트

### 1차 목표

한국 중소 제조업 중 아래 조건에 해당하는 기업입니다.

- 엑셀, 수기, 카카오톡, 전화로 생산 실적을 관리한다.
- 정부 스마트공장 사업을 검토했거나 도입 후 유지보수에 어려움이 있다.
- ERP는 있거나 없지만, 현장 실적과 LOT 추적이 약하다.
- 제품/자재 LOT, 불량 이력, 작업지시 진행 현황이 필요하다.
- 외산/상용 MES의 비용과 커스터마이징 부담이 크다.

### 우선 업종 후보

- 식품/화장품: LOT 추적, 유통기한, 품질 기록 중요
- 전자부품/조립: 공정 이력, serial/lot 추적 중요
- 금속가공/기계가공: job shop, 공정 실적, 설비 가동 이력 중요
- 플라스틱/사출: 작업조건, 설비, 불량 유형 중요
- 의료기기/바이오 부품: 품질 문서, 추적성, 승인 이력 중요

## 포지셔닝

Open MES Korea는 다음 포지션을 가져야 합니다.

```text
한국어 우선 + 현장 실행 중심 + LOT 추적 + AI context/approval layer
```

하지 말아야 할 포지션:

- ERPNext/Odoo와 ERP 전체 기능으로 경쟁
- 고가 상용 MES의 모든 기능을 한 번에 복제
- 설비 자동화/PLC 드라이버를 처음부터 포괄
- AI가 데이터를 마음대로 수정하는 자동화 제품

## 차별화 전략

### 한국어 도메인 기본값

메뉴와 데이터 모델의 기본 용어를 한국 제조 현장에 맞춥니다.

- 품목
- BOM
- 공정
- 작업지시
- 생산실적
- 불량
- LOT
- 입고/출고/투입
- 현장작업자

### 현장 작업자 UX

관리자 대시보드보다 현장 입력의 성공률을 우선합니다.

- 오늘 작업 목록
- 큰 버튼 기반 시작/종료
- 바코드/QR 입력
- 불량 사유 빠른 선택
- 네트워크 오류와 중복 입력 방지

### AI native 데이터 구조

AI가 잘 작동하려면 데이터가 먼저 정리되어야 합니다.

- 모든 핵심 엔티티에 상태와 이력 부여
- LOT genealogy를 구조화
- 작업지시, 공정, 불량, 설비, 작업자 context API 제공
- AI가 참고한 데이터 범위 기록
- AI 제안과 실행 요청을 감사 로그에 저장

### 승인 기반 AI 액션

초기 AI는 읽기와 제안에 집중합니다.

- 생산 현황 요약
- LOT 이력 설명
- 불량 패턴 후보
- 납기 지연 위험 후보
- 품질 이슈 보고서 초안

작업지시 변경, LOT 정정, 품질 판정 같은 액션은 승인 후 실행만 허용합니다.

## MVP 재정의

시장조사 기준으로 MVP는 아래 순서가 가장 현실적입니다.

1. 작업지시와 공정 실적
2. LOT 투입/생성 이력
3. 불량 기록
4. 현장 태블릿 화면
5. 관리자 생산현황
6. AI read-only context API
7. AI 요약/질문 응답
8. AI 제안 승인 워크플로

## 리스크

### 도입 리스크

제조 현장은 업종별 차이가 큽니다. 범용성을 과하게 추구하면 아무 업종에도 맞지 않는 제품이 됩니다.

대응:

- 첫 버전은 discrete manufacturing과 job shop 중심으로 제한합니다.
- process manufacturing은 별도 확장 모듈로 둡니다.

### 오픈소스 지속성 리스크

MES는 현장 요구가 많아 유지보수 부담이 큽니다.

대응:

- core와 industry extension을 분리합니다.
- 기능보다 데이터 모델 안정성을 우선합니다.

### AI 신뢰 리스크

AI가 틀린 제안을 하거나 권한 없는 데이터를 보면 MES 신뢰가 무너집니다.

대응:

- AI는 기본 read-only로 시작합니다.
- 모든 응답에 근거 데이터 링크를 남깁니다.
- 쓰기 액션은 approval workflow를 통과합니다.

## 오픈소스 프로젝트 기회

한국 제조 현장에는 "완전 무료라서 쓰는 MES"보다 "도입 전 검증 가능하고, 내부 개발자가 이해할 수 있고, 공급사 종속을 줄일 수 있는 MES"가 더 큰 가치입니다.

Open MES Korea는 다음 사용자에게 매력적일 수 있습니다.

- MES를 직접 구축하려는 제조기업 IT 담당자
- 스마트공장 공급기업
- SI/컨설팅 회사
- 제조 데이터/AI 스타트업
- 대학/연구기관의 스마트제조 교육 프로젝트

## 권장 다음 단계

1. Git 저장소 초기화
2. FastAPI + PostgreSQL 기반 backend skeleton 생성
3. Next.js 기반 admin/shop-floor skeleton 생성
4. 작업지시, 공정 실적, LOT 도메인부터 구현
5. AI context API는 DB 직접 접근이 아니라 backend permission layer 뒤에 배치
6. 프로젝트 README에 "not ERP, not chatbot, MES core with AI-ready operations" 메시지 명확화

## 참고 자료

- [MarketsandMarkets, Smart Factory Market Size Report 2025-2030](https://www.marketsandmarkets.com/Market-Reports/smart-factory-market-1227.html)
- [중소벤처기업부, 2025년 스마트제조혁신 지원사업 통합공고](https://www.mss.go.kr/site/smba/ex/bbs/View.do?bcIdx=1053672&cbIdx=310&parentSeq=1053672)
- [중소벤처기업부, 2025년도 정부일반형 스마트공장 구축지원사업 공고](https://www.mss.go.kr/site/smba/ex/bbs/View.do?bcIdx=1053701&cbIdx=310&parentSeq=1053701)
- [중소벤처기업부, 2026년 예산 국회 통과 보도자료](https://mss.go.kr/site/smba/ex/bbs/View.do?bcIdx=1063750&cbIdx=86)
- [중소벤처기업진흥공단, 스마트공장 AS 지원사업](https://www.kosmes.or.kr/nsh/SH/RET/SHRET015M0.do)
- [Carbon GitHub repository](https://github.com/crbnos/carbon)
- [Libre GitHub repository](https://github.com/Spruik/Libre)
- [IMES / smart-industry GitHub repository](https://github.com/jukbot/smart-industry)
- [MDCplus, Free Open-Source ERP for Manufacturing 2026](https://mdcplus.fi/blog/top-free-erp-open-source-manufacturing/)
- [Infor/Nucleus Research, MES Technology Value Matrix 2025](https://dam.infor.com/api/public/content/c047ca0ee3404e09a8e1f5f4710f6297?v=693177d1)
