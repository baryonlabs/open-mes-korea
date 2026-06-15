defmodule OpenMes.ProductionLine do
  @moduledoc """
  생산라인 구성(ProductionLine) 바운디드 컨텍스트 — 라인 + 라인 공정 단계 CRUD.

  라인 모니터(`Production.LineMonitor`)의 정규식 하드코딩을 대체하는 설정 데이터의
  소유자. 라인 = 공정·설비 조합 구성(집합체), Step = "라인의 N번째 공정/설비" 매핑.
  Routing(생산 실행용)과 무관 — 라인 모니터 표시 구성만 담는다.

  핵심 불변식(MasterData 패턴 복제 — 새 감사 메커니즘 발명 금지):
    - 모든 쓰기(라인/단계 생성·수정·순서변경·삭제)는 단일 `Ecto.Multi` 안에서
      AuditLog 1건(순서변경은 swap 2건)을 동반한다.
    - 모든 쓰기 함수는 actor_id 를 명시적으로 받는다(actor 없는 쓰기 금지).
    - 라인 삭제는 없다(이력 보존, active=false). 단계는 구성 요소라 hard delete 허용.

  AuditLog action: production_line.create/update,
    production_line_step.create/update/delete.

  AI 확장 슬롯(이번 미구현 — YAGNI): 향후 `propose_line_config/2`(AI 자연어 →
    라인 구성 제안, status: proposed)를 이 컨텍스트에 둔다. AI 는 propose_* 경로로만
    진입하고, 쓰기 함수(create/update/delete_step)는 actor 인간 승인자 경유로만 호출한다
    (CLAUDE.md AI 안전: 제안→승인→적용, 직접 쓰기 금지). 함수 stub 은 만들지 않는다.
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Audit
  alias OpenMes.MasterData
  alias OpenMes.ProductionLine.{Line, LineStep}
  alias OpenMes.Repo

  # AI 라인 구성 컨텍스트를 호출/적용할 수 있는 role(설계 23번 §A.4/§A.8).
  @ai_roles ~w(system_admin production_manager)

  # ──────────────────────────────────────────────────────────────────
  # 라인 조회 (읽기 — AuditLog 불필요)
  # ──────────────────────────────────────────────────────────────────

  @doc "라인 목록(line_code 오름차순). active: true 면 활성만."
  def list_lines(opts \\ []) do
    query = from(l in Line, order_by: [asc: l.line_code])

    query =
      if Keyword.get(opts, :active),
        do: from(l in query, where: l.active == true),
        else: query

    Repo.all(query)
  end

  def get_line(id), do: Repo.get(Line, id)

  def fetch_line(id) do
    case Repo.get(Line, id) do
      nil -> {:error, :not_found}
      line -> {:ok, line}
    end
  end

  @doc "라인별 단계 수 맵: %{line_id => count}."
  def step_counts do
    from(s in LineStep, group_by: s.line_id, select: {s.line_id, count(s.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ──────────────────────────────────────────────────────────────────
  # 단계 조회
  # ──────────────────────────────────────────────────────────────────

  @doc "라인의 단계 목록(sequence 오름차순)."
  def list_steps(line_id) do
    from(s in LineStep, where: s.line_id == ^line_id, order_by: [asc: s.sequence])
    |> Repo.all()
  end

  def get_step(id), do: Repo.get(LineStep, id)

  def fetch_step(id) do
    case Repo.get(LineStep, id) do
      nil -> {:error, :not_found}
      step -> {:ok, step}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 폼용 changeset 빌더 (쓰기 아님 — UI 폼 렌더/검증용)
  # ──────────────────────────────────────────────────────────────────

  def change_line(%Line{} = line, attrs \\ %{}), do: Line.changeset(line, attrs)
  def change_step(%LineStep{} = step, attrs \\ %{}), do: LineStep.changeset(step, attrs)

  # ──────────────────────────────────────────────────────────────────
  # 라인 생성 / 수정 (AuditLog 동반)
  # ──────────────────────────────────────────────────────────────────

  @doc "라인 생성(AuditLog: production_line.create)."
  def create_line(attrs, actor_id),
    do: create(Line, "production_line", attrs, actor_id)

  @doc "라인 수정(AuditLog: production_line.update). 활성토글도 이 경로(active=false)."
  def update_line(id, attrs, actor_id),
    do: update(Line, "production_line", id, attrs, actor_id)

  # ──────────────────────────────────────────────────────────────────
  # 단계 생성 / 수정 / 삭제 (AuditLog 동반)
  # ──────────────────────────────────────────────────────────────────

  @doc "단계 생성(AuditLog: production_line_step.create)."
  def create_step(attrs, actor_id),
    do: create(LineStep, "production_line_step", attrs, actor_id)

  @doc "단계 수정(AuditLog: production_line_step.update). 공정/설비 변경."
  def update_step(id, attrs, actor_id),
    do: update(LineStep, "production_line_step", id, attrs, actor_id)

  @doc "단계 삭제(AuditLog: production_line_step.delete, before=스냅샷/after=nil)."
  def delete_step(id, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load(repo, LineStep, id) end)
    |> Multi.delete(:record, fn %{load: record} -> record end)
    |> Audit.put_log(:audit, fn %{load: before_rec} ->
      %{
        actor_id: actor_id,
        action: "production_line_step.delete",
        resource_type: "production_line_step",
        resource_id: before_rec.id,
        before: snapshot(before_rec),
        after: nil
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:record)
  end

  @doc """
  단계 순서변경 — `:up`/`:down` 으로 인접 단계와 sequence 를 맞바꾼다(swap).
  1 트랜잭션에서 두 단계를 모두 갱신하고 AuditLog 2건(각 step.update)을 남긴다.
  경계(첫 단계 :up, 마지막 단계 :down)면 변경 없이 {:ok, step} 반환.
  """
  def reorder_step(step_id, direction, actor_id) when direction in [:up, :down] do
    with {:ok, step} <- fetch_step(step_id) do
      siblings = list_steps(step.line_id)
      index = Enum.find_index(siblings, &(&1.id == step.id))
      neighbor_index = if direction == :up, do: index - 1, else: index + 1

      # 경계(첫 단계 :up → -1, 마지막 단계 :down → 범위 초과)는 변경 없음.
      # (Enum.at 의 음수 인덱스 wrap-around 회피 위해 명시 가드.)
      if neighbor_index < 0 do
        {:ok, step}
      else
        case Enum.at(siblings, neighbor_index) do
          nil -> {:ok, step}
          neighbor -> swap_sequence(step, neighbor, actor_id)
        end
      end
    end
  end

  # 두 단계의 sequence 를 맞바꾼다(unique[line_id, sequence] 회피 위해 임시 양수값 경유).
  defp swap_sequence(step, neighbor, actor_id) do
    park_seq = max(step.sequence, neighbor.sequence) + 1_000_000

    Multi.new()
    |> Multi.update(:park, LineStep.changeset(step, %{sequence: park_seq}))
    |> Multi.update(:neighbor, LineStep.changeset(neighbor, %{sequence: step.sequence}))
    |> Multi.update(:record, fn %{park: parked} ->
      LineStep.changeset(parked, %{sequence: neighbor.sequence})
    end)
    |> Audit.put_log(:audit_step, fn %{record: rec} ->
      step_update_audit(actor_id, step, rec)
    end)
    |> Audit.put_log(:audit_neighbor, fn %{neighbor: rec} ->
      step_update_audit(actor_id, neighbor, rec)
    end)
    |> Repo.transaction()
    |> normalize_result(:record)
  end

  defp step_update_audit(actor_id, before_rec, after_rec) do
    %{
      actor_id: actor_id,
      action: "production_line_step.update",
      resource_type: "production_line_step",
      resource_id: after_rec.id,
      before: snapshot(before_rec),
      after: snapshot(after_rec)
    }
  end

  # ──────────────────────────────────────────────────────────────────
  # 라인 모니터 입력 조립 (순수 조회 — 쓰기 0)
  # ──────────────────────────────────────────────────────────────────

  @doc """
  라인(:default | line_code | line_id) → 모니터 입력용 단계 리스트(sequence 오름차순).

  반환: [%{process_id, process_code, name, sequence,
           equipment_id, equipment_active, equipment_name}]
  공정/설비 라벨은 조인으로 해석(equipment 는 LEFT JOIN — equipment_id nullable).
  equipment_id=nil 단계는 equipment_* 전부 nil(모니터 :unknown 안전 처리).
  빈 라인/라인 0개면 []. :default 는 활성 라인 중 line_code 오름차순 첫 라인.
  """
  def steps_for_monitor(:default) do
    case list_lines(active: true) do
      [line | _] -> steps_for_monitor(line.id)
      [] -> []
    end
  end

  def steps_for_monitor(line_code_or_id) when is_binary(line_code_or_id) do
    case resolve_line(line_code_or_id) do
      nil -> []
      line -> monitor_steps_query(line.id)
    end
  end

  # line_code(예 "LINE-INJ") 또는 binary_id 로 라인 해석.
  defp resolve_line(line_code_or_id) do
    Repo.get_by(Line, line_code: line_code_or_id) || Repo.get(Line, line_code_or_id)
  rescue
    Ecto.Query.CastError -> Repo.get_by(Line, line_code: line_code_or_id)
  end

  defp monitor_steps_query(line_id) do
    from(s in LineStep,
      where: s.line_id == ^line_id,
      order_by: [asc: s.sequence],
      left_join: p in "processes",
      on: p.id == s.process_id,
      left_join: e in "equipment",
      on: e.id == s.equipment_id,
      select: %{
        process_id: s.process_id,
        process_code: p.process_code,
        name: p.name,
        sequence: s.sequence,
        equipment_id: s.equipment_id,
        equipment_active: e.active,
        equipment_name: e.name
      }
    )
    |> Repo.all()
  end

  # ──────────────────────────────────────────────────────────────────
  # AI Context API (읽기 전용 — 권한 필터, 쓰기 0). 설계 23번 §A.4.
  # ──────────────────────────────────────────────────────────────────

  @doc """
  AI 에 제공할 권한 필터된 라인 구성 컨텍스트(읽기 전용). AI 는 DB 직접 접근 금지 —
  이 함수가 반환한 plain map 만 LLM 어댑터에 전달된다(docs/ai-native-architecture.md AI Context API).

  인가: actor_role 이 라인 구성 권한(system_admin|production_manager)일 때만 컨텍스트 반환.
  그 외 {:error, :unauthorized}.

  반환: {:ok, %{
    line: %{id, line_code, name},
    current_steps: [%{sequence, process_code, process_name, equipment_code, equipment_name}],
    available_processes: [%{process_code, name}],   # 활성 공정 — AI add 대상 화이트리스트
    available_equipment: [%{equipment_code, name}]  # 활성 설비
  }}
  """
  def ai_context(line_id, actor_role) when actor_role in @ai_roles do
    case fetch_line(line_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, line} ->
        steps =
          monitor_steps_query(line.id)
          |> Enum.map(fn s ->
            %{
              sequence: s.sequence,
              process_code: s.process_code,
              process_name: s.name,
              equipment_name: s.equipment_name
            }
          end)

        processes =
          MasterData.list_processes(%{"active" => true})
          |> Enum.map(&%{process_code: &1.process_code, name: &1.name})

        equipment =
          MasterData.list_equipment(%{"active" => true})
          |> Enum.map(&%{equipment_code: &1.equipment_code, name: &1.name})

        {:ok,
         %{
           line: %{id: line.id, line_code: line.line_code, name: line.name},
           current_steps: steps,
           available_processes: processes,
           available_equipment: equipment
         }}
    end
  end

  def ai_context(_line_id, _role), do: {:error, :unauthorized}

  @doc "라인 구성 권한 role 목록(AI 컨텍스트/제안/승인/적용 게이트 — 설계 23번)."
  def ai_roles, do: @ai_roles

  @doc "role 이 AI 라인 구성 권한자인가."
  def ai_authorized?(role), do: role in @ai_roles

  # ──────────────────────────────────────────────────────────────────
  # AI 제안 적용용 step 쓰기 Multi 합성 헬퍼 (설계 23번 §A.6).
  # apply_proposal 이 단일 Multi 안에서 op→step 쓰기를 합성하도록 노출한다.
  # 각 step 변경은 AuditLog 를 동반한다(누락 0). 직접 호출 금지 — OpenMes.Ai 전용.
  # ──────────────────────────────────────────────────────────────────

  @doc """
  주어진 Multi 에 단계 INSERT + AuditLog 스텝을 합성한다(step_key 로 식별).
  attrs 는 %{line_id, process_id, equipment_id, sequence}.
  """
  def multi_create_step(%Multi{} = multi, step_key, attrs, actor_id) do
    audit_key = :"#{step_key}_audit"

    multi
    |> Multi.insert(step_key, LineStep.changeset(%LineStep{}, attrs))
    |> Audit.put_log(audit_key, fn changes ->
      record = Map.fetch!(changes, step_key)

      %{
        actor_id: actor_id,
        action: "production_line_step.create",
        resource_type: "production_line_step",
        resource_id: record.id,
        before: nil,
        after: snapshot(record)
      }
    end)
  end

  @doc "주어진 Multi 에 단계 DELETE + AuditLog 스텝을 합성한다(이미 로드된 record 기준)."
  def multi_delete_step(%Multi{} = multi, step_key, %LineStep{} = record, actor_id) do
    audit_key = :"#{step_key}_audit"

    multi
    |> Multi.delete(step_key, record)
    |> Audit.put_log(audit_key, fn _changes ->
      %{
        actor_id: actor_id,
        action: "production_line_step.delete",
        resource_type: "production_line_step",
        resource_id: record.id,
        before: snapshot(record),
        after: nil
      }
    end)
  end

  @doc "주어진 Multi 에 단계 UPDATE(sequence 등) + AuditLog 스텝을 합성한다."
  def multi_update_step(%Multi{} = multi, step_key, %LineStep{} = record, attrs, actor_id) do
    audit_key = :"#{step_key}_audit"

    multi
    |> Multi.update(step_key, LineStep.changeset(record, attrs))
    |> Audit.put_log(audit_key, fn changes ->
      after_rec = Map.fetch!(changes, step_key)

      %{
        actor_id: actor_id,
        action: "production_line_step.update",
        resource_type: "production_line_step",
        resource_id: after_rec.id,
        before: snapshot(record),
        after: snapshot(after_rec)
      }
    end)
  end

  # ──────────────────────────────────────────────────────────────────
  # 제네릭 생성/수정 (AuditLog — MasterData 패턴 복제)
  # ──────────────────────────────────────────────────────────────────

  defp create(schema_mod, resource_type, attrs, actor_id) do
    Multi.new()
    |> Multi.insert(:record, schema_mod.changeset(struct(schema_mod), attrs))
    |> Audit.put_log(:audit, fn %{record: record} ->
      %{
        actor_id: actor_id,
        action: "#{resource_type}.create",
        resource_type: resource_type,
        resource_id: record.id,
        before: nil,
        after: snapshot(record)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:record)
  end

  defp update(schema_mod, resource_type, id, attrs, actor_id) do
    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load(repo, schema_mod, id) end)
    |> Multi.update(:record, fn %{load: record} -> schema_mod.changeset(record, attrs) end)
    |> Audit.put_log(:audit, fn %{load: before_rec, record: after_rec} ->
      %{
        actor_id: actor_id,
        action: "#{resource_type}.update",
        resource_type: resource_type,
        resource_id: after_rec.id,
        before: snapshot(before_rec),
        after: snapshot(after_rec)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:record)
  end

  defp load(repo, schema_mod, id) do
    case repo.get(schema_mod, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp normalize_result({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp normalize_result({:error, :load, :not_found, _}, _key), do: {:error, :not_found}
  defp normalize_result({:error, _step, %Ecto.Changeset{} = cs, _}, _key), do: {:error, cs}
  defp normalize_result({:error, _step, reason, _}, _key), do: {:error, reason}

  defp snapshot(%mod{} = record) do
    mod.__schema__(:fields)
    |> Enum.reject(&(&1 in [:id, :inserted_at, :updated_at]))
    |> Map.new(fn field -> {field, Map.get(record, field)} end)
  end
end
