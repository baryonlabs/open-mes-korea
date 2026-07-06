# 에이전트 예시 — API로 MES를 직접 조정하기

Open MES Korea는 **REST API**로 열려 있습니다. 누구나 자기 규칙의 에이전트를 만들어
작업지시를 조회하고, **직접 수정·변경·조정**할 수 있습니다. 핵심은 아래 한 가지 규칙입니다.

> **모든 쓰기에는 `X-Actor-Id` 헤더가 필수이며, 그 값이 그대로 AuditLog에 남습니다.**

사람이 UI로 바꾸든, 에이전트가 API로 바꾸든, "누가 언제 무엇을 어떻게(before→after)" 바꿨는지가
MES DB 한 곳(AuditLog + Event Outbox)에 모입니다. 이것이 **단일 진실 공급원(SSOT)** 입니다.
에이전트를 아무리 많이 붙여도 진실은 흩어지지 않습니다.

## API 표면 (코어 작업지시)

| 목적 | 메서드 · 경로 | actor |
|------|--------------|:-----:|
| 목록 조회 | `GET /api/work_orders` | 불필요 |
| 단건 조회 | `GET /api/work_orders/:id` | 불필요 |
| 생성 | `POST /api/work_orders` | **필수** |
| 수정 | `PATCH /api/work_orders/:id` | **필수** |
| 착수 준비 | `POST /api/work_orders/:id/release` | **필수** |
| 시작 | `POST /api/work_orders/:id/start` | **필수** |
| 완료 | `POST /api/work_orders/:id/complete` | **필수** |
| 취소 | `POST /api/work_orders/:id/cancel` | **필수** |

- 상태 전이는 동사형 하위 엔드포인트로 분리되어 감사 action / 이벤트명과 1:1로 매핑됩니다
  (예: `release` → AuditLog `action="work_order.release"`, Outbox `work_order.released`).
- 상태 머신을 벗어나는 전이(예: `completed` → `draft`)는 API가 거부합니다. 진실은 규칙 안에서만 바뀝니다.

## 실행

```bash
# 데모 서버 대상(공개)
BASE_URL=https://openmes-demo.fly.dev ACTOR=agent-release-bot python3 work_order_agent.py

# 로컬 대상
BASE_URL=http://localhost:4002 ACTOR=agent-demo python3 work_order_agent.py
```

`work_order_agent.py`는 외부 의존성 없이(표준 라이브러리만) 다음을 보여줍니다.

1. `GET /api/work_orders`로 작업지시를 **조회**한다(actor 불필요).
2. `draft`를 찾아 `release`를 **actor 없이** 호출 → **거부**(쓰기에는 actor 강제).
3. `X-Actor-Id`를 붙여 다시 호출 → 전이 성공.
4. 그 전이가 `AuditLog(actor_id, action, before, after)` + `Event Outbox`에 남는다.
   `/admin/system/audit-log`에서 그 actor 이름으로 이력을 확인할 수 있습니다.

## 왜 이 구조인가 (SSOT)

- **이식 가능한 진실**: 모든 상태·이력·감사가 PostgreSQL 한 곳에 있고, CSV·API로 빼낼 수 있습니다.
  특정 분석 제품/AI에 종속되지 않습니다.
- **감사·역추적**: 잘못된 변경도 누가 했는지 남습니다. 생산 실적·LOT·불량은 수정 대신 정정 이력을 남깁니다.
- **에이전트 친화**: AI/자동화 에이전트는 이 API만 쓰면 되고, 위험한 변경은 상태 머신과 actor 강제가 막습니다.
  (AI가 직접 삭제/임의 전이를 못 하도록 설계 — `docs/ai-native-architecture.md`.)

## 나만의 에이전트 만들기

`work_order_agent.py`를 복제해 `main()`의 정책만 바꾸세요. 예:

- 납기 임박 작업지시를 찾아 `release`.
- 완료 조건을 만족한 작업지시를 `complete`.
- 외부 ERP/스프레드시트를 읽어 신규 작업지시를 `POST /api/work_orders`로 생성.

무엇을 하든, `X-Actor-Id`에 에이전트 이름을 넣으면 그 이름으로 감사됩니다.
