# 도메인 모델

초기 도메인은 MES 코어에 필요한 최소 단위로 시작합니다.

## 주요 엔티티

### Item

품목입니다. 원자재, 반제품, 제품을 모두 포함합니다.

- item_code
- name
- item_type
- unit
- active

### BillOfMaterial

제품 또는 반제품을 만들기 위한 구성 품목입니다.

- parent_item_id
- child_item_id
- quantity
- loss_rate

### Process

공정 정의입니다.

- process_code
- name
- description
- active

### Routing

품목별 공정 순서입니다.

- item_id
- process_id
- sequence
- standard_cycle_time

### WorkOrder

생산 작업지시입니다.

- work_order_no
- item_id
- planned_quantity
- due_date
- status

### Operation

작업지시의 공정별 실행 단위입니다.

- work_order_id
- process_id
- sequence
- status
- started_at
- completed_at

### ProductionResult

공정 실적입니다.

- operation_id
- worker_id
- equipment_id
- good_quantity
- defect_quantity
- started_at
- ended_at

### DefectRecord

불량 기록입니다.

- production_result_id
- defect_code
- quantity
- note

### MaterialLot

자재 또는 제품 LOT입니다.

- lot_no
- item_id
- lot_type
- quantity
- status
- created_at

### LotConsumption

공정에서 어떤 LOT가 투입되었는지 기록합니다.

- operation_id
- input_lot_id
- quantity

### AuditLog

중요 변경 이력입니다.

- actor_id
- action
- resource_type
- resource_id
- before
- after
- created_at

### AiInteraction

AI 조회, 제안, 실행 요청 이력입니다.

- actor_id
- intent
- prompt
- response_summary
- referenced_resources
- proposed_action
- approval_status
- created_at

## 상태 모델

### WorkOrder status

- draft
- released
- in_progress
- completed
- cancelled

### Operation status

- pending
- ready
- running
- paused
- completed
- skipped

### MaterialLot status

- available
- reserved
- consumed
- produced
- quarantined
- scrapped

