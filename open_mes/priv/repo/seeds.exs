# priv/repo/seeds.exs — 기초 데모 시드(설계 §5).
#
#     mix run priv/repo/seeds.exs
#
# 원칙:
#   - 멱등: 자연키(worker_code/item_code/.../lot_no/work_order_no)로 존재 확인 후 없을 때만 생성.
#     여러 번 실행해도 중복 0.
#   - AuditLog/Outbox/상태머신/append-only 준수: 모든 쓰기는 기존 컨텍스트 함수 경유
#     (MasterData/Production/Lots), actor_id 는 seed 전용 상수 "seed".
#   - 조회/대시보드 화면이 비어 보이지 않게 작업지시·실적·불량·LOT 까지 최소 1흐름.

import Ecto.Query

alias OpenMes.Repo
alias OpenMes.{MasterData, Production, Lots, ProductionLine}

alias OpenMes.MasterData.{Item, Process, Equipment, Worker, BillOfMaterial, Routing}
alias OpenMes.Production.WorkOrder
alias OpenMes.Lots.MaterialLot

actor = "seed"

# ── 멱등 헬퍼: 자연키로 조회 후 없으면 컨텍스트 함수로 생성 ────────────────
get_or_create = fn schema, key_field, key_value, create_fun ->
  case Repo.get_by(schema, [{key_field, key_value}]) do
    nil ->
      {:ok, rec} = create_fun.()
      rec

    rec ->
      rec
  end
end

# ── A. 작업자(role 별) ──────────────────────────────────────────────────
workers = [
  {"W-ADMIN", "관리자 김", "system_admin"},
  {"W-PROD1", "생산관리 이", "production_manager"},
  {"W-QC1", "품질관리 박", "quality_manager"},
  {"W-MAT1", "자재창고 최", "material_manager"},
  {"W-OP1", "현장작업 정", "operator"},
  {"W-OP2", "현장작업 한", "operator"}
]

worker_recs =
  Map.new(workers, fn {code, name, role} ->
    rec =
      get_or_create.(Worker, :worker_code, code, fn ->
        MasterData.create_worker(%{worker_code: code, name: name, role: role}, actor)
      end)

    {code, rec}
  end)

# ── B. 기준정보 ─────────────────────────────────────────────────────────
items = [
  {"RM-001", "원자재 강판", "raw", "kg"},
  {"RM-002", "원자재 볼트", "raw", "EA"},
  {"SF-001", "반제품 브라켓", "semi", "EA"},
  {"FP-001", "완제품 조립품", "product", "EA"}
]

item_recs =
  Map.new(items, fn {code, name, type, unit} ->
    rec =
      get_or_create.(Item, :item_code, code, fn ->
        MasterData.create_item(
          %{item_code: code, name: name, item_type: type, unit: unit},
          actor
        )
      end)

    {code, rec}
  end)

processes = [
  {"P-CUT", "절단"},
  {"P-WELD", "용접"},
  {"P-ASSY", "조립"}
]

process_recs =
  Map.new(processes, fn {code, name} ->
    rec =
      get_or_create.(Process, :process_code, code, fn ->
        MasterData.create_process(%{process_code: code, name: name}, actor)
      end)

    {code, rec}
  end)

equipment = [
  {"EQ-CUT01", "절단기"},
  {"EQ-WELD01", "용접기"},
  {"EQ-ASSY01", "조립대"}
]

equipment_recs =
  Map.new(equipment, fn {code, name} ->
    rec =
      get_or_create.(Equipment, :equipment_code, code, fn ->
        MasterData.create_equipment(%{equipment_code: code, name: name}, actor)
      end)

    {code, rec}
  end)

# BOM 2건 — (parent_item_id, child_item_id)로 멱등 판정.
ensure_bom = fn parent, child, qty, loss ->
  existing =
    Repo.one(
      from b in BillOfMaterial,
        where: b.parent_item_id == ^parent.id and b.child_item_id == ^child.id,
        limit: 1
    )

  unless existing do
    {:ok, _} =
      MasterData.create_bom(
        %{parent_item_id: parent.id, child_item_id: child.id, quantity: qty, loss_rate: loss},
        actor
      )
  end
end

ensure_bom.(item_recs["FP-001"], item_recs["SF-001"], Decimal.new("1"), Decimal.new("0"))
ensure_bom.(item_recs["SF-001"], item_recs["RM-001"], Decimal.new("0.5"), Decimal.new("0.02"))

# 라우팅(FP-001) 3 seq — (item_id, sequence)가 자연키.
ensure_routing = fn item, process, seq, cycle ->
  existing =
    Repo.one(
      from r in Routing,
        where: r.item_id == ^item.id and r.sequence == ^seq,
        limit: 1
    )

  unless existing do
    {:ok, _} =
      MasterData.create_routing(
        %{item_id: item.id, process_id: process.id, sequence: seq, standard_cycle_time: cycle},
        actor
      )
  end
end

fp = item_recs["FP-001"]
ensure_routing.(fp, process_recs["P-CUT"], 1, Decimal.new("30"))
ensure_routing.(fp, process_recs["P-WELD"], 2, Decimal.new("45"))
ensure_routing.(fp, process_recs["P-ASSY"], 3, Decimal.new("60"))

# ── C. 생산: WO-1 (release→start, Operation 3개, 실적/불량/LOT 흐름) ───────
unless Repo.get_by(WorkOrder, work_order_no: "WO-1") do
  {:ok, wo} =
    Production.create_work_order(
      %{work_order_no: "WO-1", item_id: fp.id, planned_quantity: Decimal.new("100")},
      actor
    )

  {:ok, _} = Production.release_work_order(wo.id, actor)
  {:ok, _} = Production.start_work_order(wo.id, actor)

  {:ok, op1} =
    Production.create_operation(
      %{work_order_id: wo.id, process_id: process_recs["P-CUT"].id, sequence: 1},
      actor
    )

  {:ok, op2} =
    Production.create_operation(
      %{work_order_id: wo.id, process_id: process_recs["P-WELD"].id, sequence: 2},
      actor
    )

  {:ok, _op3} =
    Production.create_operation(
      %{work_order_id: wo.id, process_id: process_recs["P-ASSY"].id, sequence: 3},
      actor
    )

  # 1번 공정(절단): pending→ready→running, 실적/불량, → completed.
  {:ok, _} = Production.ready_operation(op1.id, actor)
  {:ok, _} = Production.start_operation(op1.id, actor)

  {:ok, result} =
    Production.create_production_result(
      %{
        operation_id: op1.id,
        worker_id: worker_recs["W-OP1"].id,
        equipment_id: equipment_recs["EQ-CUT01"].id,
        good_quantity: Decimal.new("80"),
        defect_quantity: Decimal.new("5")
      },
      actor
    )

  {:ok, _} =
    Production.record_defect(
      %{production_result_id: result.id, defect_code: "D-SCRATCH", quantity: Decimal.new("3"), note: "표면 흠집"},
      actor
    )

  {:ok, _} =
    Production.record_defect(
      %{production_result_id: result.id, defect_code: "D-DIM", quantity: Decimal.new("2"), note: "치수 불량"},
      actor
    )

  {:ok, _} = Production.complete_operation(op1.id, actor)

  # 2번 공정(용접): ready→running (진행 중 — 대시보드 표시).
  {:ok, _} = Production.ready_operation(op2.id, actor)
  {:ok, _} = Production.start_operation(op2.id, actor)

  # ── D. LOT 흐름 (genealogy): 원자재 입고 → consume → 생산 LOT ──
  {:ok, rm_lot} =
    Lots.receive_lot(
      %{lot_no: "LOT-RM001-001", item_id: item_recs["RM-001"].id, lot_type: "raw", quantity: Decimal.new("500")},
      actor
    )

  {:ok, _} =
    Lots.receive_lot(
      %{lot_no: "LOT-RM002-001", item_id: item_recs["RM-002"].id, lot_type: "raw", quantity: Decimal.new("1000")},
      actor
    )

  # 강판 50 투입(소비) → op1 (LotConsumption).
  {:ok, _} = Lots.consume_lot(op1.id, rm_lot.id, Decimal.new("50"), actor)

  # 반제품 LOT 생산(source_operation_id=op1) — 계보 데모.
  {:ok, _} =
    Lots.produce_lot(
      %{
        lot_no: "LOT-SF001-001",
        item_id: item_recs["SF-001"].id,
        lot_type: "semi",
        quantity: Decimal.new("80"),
        source_operation_id: op1.id
      },
      actor
    )
end

# WO-2: released 까지만.
unless Repo.get_by(WorkOrder, work_order_no: "WO-2") do
  {:ok, wo2} =
    Production.create_work_order(
      %{work_order_no: "WO-2", item_id: fp.id, planned_quantity: Decimal.new("50")},
      actor
    )

  {:ok, _} = Production.release_work_order(wo2.id, actor)
end

# ── F. 사출 성형 라인(10공정) — 공장 생산라인 모니터 데모(설계 21번 §5) ──────
#   공정 P01~P10 / 설비 EQ-P01~EQ-P10(규약: "EQ-"<>process_code, P07만 active:false) /
#   품목 FP-INJ / 라우팅 10 / WO-INJ-1 + Operation·실적(상태 혼합).
#   멱등: 마스터는 get_or_create, 생산 흐름은 WO-INJ-1 가드로 전체 감싼다.

inj_processes = [
  {"P01", "자재투입"},
  {"P02", "건조"},
  {"P03", "사출"},
  {"P04", "냉각"},
  {"P05", "취출"},
  {"P06", "1차검사"},
  {"P07", "후가공"},
  {"P08", "조립"},
  {"P09", "2차검사"},
  {"P10", "포장출하"}
]

inj_process_recs =
  Map.new(inj_processes, fn {code, name} ->
    rec =
      get_or_create.(Process, :process_code, code, fn ->
        MasterData.create_process(%{process_code: code, name: name}, actor)
      end)

    {code, rec}
  end)

# 설비(규약 매핑): P07 만 active:false(장비 이상 데모).
inj_equipment = [
  {"EQ-P01", "자재투입기", true},
  {"EQ-P02", "건조기", true},
  {"EQ-P03", "사출기", true},
  {"EQ-P04", "냉각기", true},
  {"EQ-P05", "취출로봇", true},
  {"EQ-P06", "비전검사기", true},
  {"EQ-P07", "트리밍기", false},
  {"EQ-P08", "조립로봇", true},
  {"EQ-P09", "측정기", true},
  {"EQ-P10", "포장기", true}
]

inj_equipment_recs =
  Map.new(inj_equipment, fn {code, name, active} ->
    rec =
      get_or_create.(Equipment, :equipment_code, code, fn ->
        MasterData.create_equipment(%{equipment_code: code, name: name, active: active}, actor)
      end)

    {code, rec}
  end)

inj_item =
  get_or_create.(Item, :item_code, "FP-INJ", fn ->
    MasterData.create_item(%{item_code: "FP-INJ", name: "사출 완제품", item_type: "product", unit: "EA"}, actor)
  end)

# 라우팅 FP-INJ × P01..P10, sequence 1..10, 표준 C/T(초).
inj_routing = [
  {"P01", 1, 20}, {"P02", 2, 40}, {"P03", 3, 35}, {"P04", 4, 30}, {"P05", 5, 15},
  {"P06", 6, 25}, {"P07", 7, 30}, {"P08", 8, 50}, {"P09", 9, 25}, {"P10", 10, 20}
]

Enum.each(inj_routing, fn {code, seq, cycle} ->
  ensure_routing.(inj_item, inj_process_recs[code], seq, Decimal.new(cycle))
end)

# 생산 흐름(상태 혼합) — WO-INJ-1 가드로 멱등.
#   상태머신 준수: pending→ready→running(→completed). 직접 running 금지.
unless Repo.get_by(WorkOrder, work_order_no: "WO-INJ-1") do
  {:ok, inj_wo} =
    Production.create_work_order(
      %{work_order_no: "WO-INJ-1", item_id: inj_item.id, planned_quantity: Decimal.new("200")},
      actor
    )

  {:ok, _} = Production.release_work_order(inj_wo.id, actor)
  {:ok, _} = Production.start_work_order(inj_wo.id, actor)

  # 공정별 시나리오: {process_code, good, defect, mode}
  #   :complete = ready→start→실적→complete (정상/주의/품질이상/장비이상)
  #   :running  = ready→start→실적(미완료, 진행 중)
  #   :none     = Operation 미생성(op_status=nil, 실적0) → 데이터 미수신(red)
  inj_scenarios = [
    {"P01", 190, 5, :complete},
    {"P02", 188, 4, :complete},
    {"P03", 150, 40, :complete},
    {"P04", 185, 3, :complete},
    {"P05", 180, 12, :complete},
    {"P06", 182, 2, :complete},
    {"P07", 60, 5, :complete},
    {"P08", 178, 4, :complete},
    {"P09", 0, 0, :none},
    {"P10", 90, 2, :running}
  ]

  Enum.each(inj_scenarios, fn {code, good, defect, mode} ->
    if mode != :none do
      {_c, seq, _ct} = Enum.find(inj_routing, fn {c, _s, _ct} -> c == code end)

      {:ok, op} =
        Production.create_operation(
          %{work_order_id: inj_wo.id, process_id: inj_process_recs[code].id, sequence: seq},
          actor
        )

      {:ok, _} = Production.ready_operation(op.id, actor)
      {:ok, _} = Production.start_operation(op.id, actor)

      {:ok, _} =
        Production.create_production_result(
          %{
            operation_id: op.id,
            worker_id: worker_recs["W-OP1"].id,
            equipment_id: inj_equipment_recs["EQ-#{code}"].id,
            good_quantity: Decimal.new(good),
            defect_quantity: Decimal.new(defect)
          },
          actor
        )

      if mode == :complete, do: {:ok, _} = Production.complete_operation(op.id, actor)
    end
  end)
end

# ── G. 생산라인 구성(설정화) — 모니터가 정규식 대신 이 라인을 읽는다(설계 22번) ──
#   기존 §F(P01~P10 공정/설비) 유지 + 라인 "사출 성형 라인"(LINE-INJ) + 단계 10건.
#   equipment_id 는 EQ-Pnn 명시 FK(규약 "EQ-"<>code → 데이터로 고정). 멱등.
inj_line =
  get_or_create.(ProductionLine.Line, :line_code, "LINE-INJ", fn ->
    ProductionLine.create_line(
      %{line_code: "LINE-INJ", name: "사출 성형 라인", description: "사출 성형 10공정 데모 라인"},
      actor
    )
  end)

# (line_id, sequence) 자연키 가드로 멱등.
ensure_line_step = fn line, process_id, equipment_id, seq ->
  existing =
    Repo.one(
      from s in ProductionLine.LineStep,
        where: s.line_id == ^line.id and s.sequence == ^seq,
        limit: 1
    )

  unless existing do
    {:ok, _} =
      ProductionLine.create_step(
        %{line_id: line.id, process_id: process_id, equipment_id: equipment_id, sequence: seq},
        actor
      )
  end
end

inj_line_steps = [
  {"P01", 1}, {"P02", 2}, {"P03", 3}, {"P04", 4}, {"P05", 5},
  {"P06", 6}, {"P07", 7}, {"P08", 8}, {"P09", 9}, {"P10", 10}
]

Enum.each(inj_line_steps, fn {code, seq} ->
  ensure_line_step.(inj_line, inj_process_recs[code].id, inj_equipment_recs["EQ-#{code}"].id, seq)
end)

# ── H. 지식베이스(OKF RAG 문서) — AI 조사가 설비/공정 연관 문서를 인용(설계 27번) ──
#   멱등: resource 기준 존재 시 skip. 태그로 설비(EQ-P03)/공정(P-INJECTION) 연관 보장.
#   문서 간 크로스링크(트러블슈팅·표준작업서 → 설비매뉴얼)로 OKF 크로스링크 시연.
alias OpenMes.Knowledge
alias OpenMes.Knowledge.KnowledgeDocument

knowledge_docs = [
  %{
    okf_type: "표준작업서",
    title: "사출 성형 표준작업서",
    description: "사출 성형 공정 표준작업 절차(SOP)",
    resource: "mes://knowledge/sop/injection-molding",
    tags: ["P-INJECTION", "사출", "SOP"],
    version: "1.0",
    body: """
    # 사출 성형 표준작업서

    ## 1. 작업 준비
    - 금형 온도 확인(설정값 ±5℃ 이내)
    - 원자재 건조 상태 점검

    ## 2. 사출 조건
    - 사출 압력, 보압, 냉각 시간 표준값 준수
    - 관련 설비: [EQ-P03 설비 매뉴얼](../설비매뉴얼/eq-p03-사출기-설비-매뉴얼.md)

    ## 3. 품질 확인
    - 외관/치수는 별도 품질기준서·검사기준 참조
    """
  },
  %{
    okf_type: "설비매뉴얼",
    title: "EQ-P03 사출기 설비 매뉴얼",
    description: "EQ-P03 사출기 운전·점검 매뉴얼",
    resource: "mes://knowledge/manual/eq-p03",
    tags: ["EQ-P03", "사출기", "설비"],
    version: "1.0",
    body: """
    # EQ-P03 사출기 설비 매뉴얼

    ## 일상 점검
    - 유압 라인 누유 점검
    - 진동/소음 이상 여부 확인

    ## 이상 발생 시
    - 진동 이상은 [진동 이상 트러블슈팅](../트러블슈팅/eq-p03-진동-이상-트러블슈팅.md) 참조
    """
  },
  %{
    okf_type: "트러블슈팅",
    title: "EQ-P03 진동 이상 트러블슈팅",
    description: "EQ-P03 사출기 진동 이상 원인 및 조치",
    resource: "mes://knowledge/troubleshooting/eq-p03-vibration",
    tags: ["EQ-P03", "진동", "이상", "트러블슈팅"],
    version: "1.0",
    body: """
    # EQ-P03 진동 이상 트러블슈팅

    ## 증상
    - 가동 중 진동값 상승 추세, 평균 대비 이상치 증가

    ## 가능 원인
    1. 금형 체결 불량
    2. 베어링 마모
    3. 불균형 하중

    ## 조치
    - 체결 토크 재점검 → 베어링 상태 확인 → 필요 시 정비 요청
    - 기준 운전 절차는 [설비 매뉴얼](../설비매뉴얼/eq-p03-사출기-설비-매뉴얼.md) 참조
    """
  },
  %{
    okf_type: "품질기준서",
    title: "사출품 외관 품질 기준서",
    description: "사출 성형품 외관 불량 판정 기준",
    resource: "mes://knowledge/quality/injection-appearance",
    tags: ["P-INJECTION", "품질", "외관"],
    version: "1.0",
    body: """
    # 사출품 외관 품질 기준서

    ## 판정 항목
    - 플래시, 싱크마크, 웰드라인, 변색

    ## 합부 기준
    - 한도견본 대비 육안 판정, 한계 초과 시 불량
    """
  },
  %{
    okf_type: "검사기준",
    title: "사출품 치수 검사 기준",
    description: "사출 성형품 치수 검사 항목·공차",
    resource: "mes://knowledge/inspection/injection-dimension",
    tags: ["P-INJECTION", "검사", "치수"],
    version: "1.0",
    body: """
    # 사출품 치수 검사 기준

    ## 검사 항목
    - 주요 치수 3개소(공차 ±0.1mm)

    ## 검사 주기
    - 초중종물 + 2시간 주기 샘플 검사
    """
  }
]

Enum.each(knowledge_docs, fn attrs ->
  unless Repo.get_by(KnowledgeDocument, resource: attrs.resource) do
    {:ok, _} = Knowledge.create_document(Map.put(attrs, :uploaded_by, "system"), actor)
  end
end)

knowledge_count = Repo.aggregate(KnowledgeDocument, :count, :id)

lot_count = Repo.aggregate(MaterialLot, :count, :id)
wo_count = Repo.aggregate(WorkOrder, :count, :id)
line_step_count = Repo.aggregate(ProductionLine.LineStep, :count, :id)

# ── E. 안내 출력 ─────────────────────────────────────────────────────────
IO.puts("""

[seed 완료] 작업자 #{map_size(worker_recs)}명 / 품목 #{map_size(item_recs)} / 공정 #{map_size(process_recs)} / 설비 #{map_size(equipment_recs)} / 작업지시 #{wo_count}건 / LOT #{lot_count}건
역할별 데모 계정: W-ADMIN(시스템관리자) W-PROD1(생산관리자) W-QC1(품질관리자) W-MAT1(자재창고) W-OP1/W-OP2(현장작업자)
역할 전환: 관리자 화면 우상단 '역할' 드롭다운에서 전환하면 해당 역할 화면만 보이고 비허용 화면은 차단됩니다.
사출 라인 10공정 시드 완료(P01~P10): /admin/reports/production 에서 신호등 3색 확인(P03 품질이상·P07 장비이상·P09 데이터미수신).
생산라인 구성 LINE-INJ(단계 #{line_step_count}건) 시드 완료 — /admin/settings/lines 에서 편집.
지식베이스(OKF) 문서 #{knowledge_count}건 시드 완료 — /admin/settings/knowledge. EQ-P03 조사 시 AI 가 설비매뉴얼·진동 트러블슈팅 인용.
""")
