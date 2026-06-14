---
name: audit-verify
description: Open MES Korea 감사 원칙 코드 검증 스킬. 구현 코드가 AuditLog 필수 생성, LOT Genealogy(LotConsumption 경유), Event Outbox(동일 트랜잭션), 상태 머신 전이 규칙을 준수하는지 확인한다. qa-auditor 에이전트가 사용한다. 코드 작성 후 "감사 원칙 검증", "AuditLog 확인", "LOT 추적 검증" 요청 시 이 스킬을 사용한다.
---

# Audit Verify — 감사 원칙 검증

## 검증 절차

### Step 1: 코드 읽기

지정된 구현 파일을 읽는다. 파일이 지정되지 않은 경우 `_workspace/02_domain_engineer_*/` 하위 파일 전체를 읽는다.

### Step 2: AuditLog 검증

모든 쓰기 경로를 추적한다.

**쓰기 경로란:** DB에 INSERT/UPDATE/DELETE를 수행하는 함수, 메서드, API 핸들러.

각 쓰기 경로에 대해 확인:
- AuditLog 생성 코드가 동일 트랜잭션 내에 있는가?
- AuditLog에 `actor_id`, `action`, `resource_type`, `resource_id`, `before`, `after`, `created_at`이 모두 포함되는가?
- `before`와 `after`가 실제 데이터 변경 내용을 담는가? (단순 ID만 저장하면 불충분)

### Step 3: LOT Genealogy 검증

MaterialLot와 관련된 코드를 찾아 확인:
- 자재 소비 시 `LotConsumption` 레코드를 생성하는가?
- `MaterialLot.quantity`를 직접 감소시키는 코드가 없는가?
- 제품 LOT 생성 시 소비된 원자재 LOT ID와 연결되는가?

### Step 4: 상태 머신 검증

`docs/domain-model.md`의 허용 전이 목록과 코드를 비교한다.

허용 전이 (이것만 코드에 존재해야 함):
- WorkOrder: `draft→released`, `released→in_progress`, `in_progress→completed`, `in_progress→cancelled`
- Operation: `pending→ready`, `ready→running`, `running→paused`, `paused→running`, `running→completed`, `running→skipped`
- MaterialLot: `available→reserved`, `reserved→available`, `reserved→consumed`, `available→produced`, `any→quarantined`, `quarantined→scrapped`

불허 전이 시도 시 에러를 반환하는 코드가 있는가?

### Step 5: Event Outbox 검증

상태 변경 코드와 outbox 이벤트 삽입 코드가 동일 DB 트랜잭션 안에 있는가?

허용 이벤트 타입 목록:
`work_order.released`, `operation.started`, `operation.completed`, `material_lot.consumed`, `material_lot.produced`, `defect.recorded`, `ai_action.proposed`, `ai_action.approved`

### Step 6: 이력성 원칙 검증

ProductionResult, LotConsumption, DefectRecord에 DELETE 쿼리가 없는가? 수정이 필요한 경우 정정 레코드(correction_of 필드나 별도 correction 테이블)를 사용하는가?

### Step 7: 결과 리포트 작성

`_workspace/03_qa_audit_{feature}.md`에 저장:

```markdown
# QA 감사 리포트: {기능명}

## AuditLog 검증
- ✅/❌ {쓰기 경로명}: {결과}
...

## LOT Genealogy 검증
- ✅/❌ {항목}: {결과}
...

## 상태 머신 검증
- ✅/❌ {엔티티}: {결과}
...

## Event Outbox 검증
- ✅/❌ {이벤트}: {결과}
...

## 이력성 원칙 검증
- ✅/❌ {항목}: {결과}
...

## 최종 판정

**APPROVED** / **NEEDS_FIX** / **BLOCKED**

### 수정 필요 항목
| 파일:줄 | 위반 내용 | 수정 방법 |
|--------|---------|---------|
| ... | ... | ... |
```

## 주의사항

- "파일이 없다"는 것과 "원칙을 위반한다"는 것을 구별한다. 파일 미존재는 domain-engineer가 아직 구현하지 않은 것일 수 있다.
- 위반이 의도된 경우(예: 소프트 삭제 전략)는 architect에게 확인 후 판정한다.
- 모든 ❌ 항목에는 반드시 수정 방법을 코드 예시와 함께 제시한다.
