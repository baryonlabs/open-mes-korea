defmodule OpenMes.Ai do
  @moduledoc """
  AI 바운디드 컨텍스트 — 자연어 라인 구성 제안(propose)→승인→실행 — 설계 23번 §A.

  AI 안전 불변식(절대 위반 금지):
    - AI 는 DB 직접 접근 0: `ProductionLine.ai_context/2`(plain map)만 LLM 에 전달.
    - AI 는 직접 쓰기 0: `propose_line_config` 는 AiInteraction(proposed) + diff 만 생성.
      실제 step 쓰기는 인간 승인 후 `apply_proposal`(actor=승인자)에서만.
    - 모든 AI 상호작용 AiInteraction 기록 + AuditLog + (제안/승인 시) Outbox.
    - 상태머신 강제: propose→reviewed→approved→executed/failed (allowed_transition?).
    - Tool Action 화이트리스트: SkillRegistry 에 등록된 intent 만 제안 가능.

  step 쓰기는 ProductionLine 컨텍스트 경유(직접 Repo step insert 금지).
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Ai.{AiInteraction, Provider, SkillRegistry}
  alias OpenMes.{Audit, Outbox, ProductionLine, Repo}
  alias OpenMes.MasterData

  @intent "propose_line_config"

  # ──────────────────────────────────────────────────────────────────
  # 조회 (읽기 — AuditLog 불필요)
  # ──────────────────────────────────────────────────────────────────

  @doc "AI 상호작용 목록(최근순). 필터: line_id, status."
  def list_interactions(opts \\ []) do
    query = from(a in AiInteraction, order_by: [desc: a.inserted_at])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(a in query, where: a.approval_status == ^status)
      end

    interactions = Repo.all(query)

    case Keyword.get(opts, :line_id) do
      nil -> interactions
      line_id -> Enum.filter(interactions, &(line_id_of(&1) == line_id))
    end
  end

  def get_interaction(id), do: Repo.get(AiInteraction, id)

  def fetch_interaction(id) do
    case Repo.get(AiInteraction, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # [3] 제안(propose) — 부수효과: AiInteraction(proposed) 생성만. step 쓰기 0.
  # ──────────────────────────────────────────────────────────────────

  @doc """
  자연어 라인 구성 제안. 흐름:
    1) ProductionLine.ai_context(line_id, actor_role) — 권한 필터 읽기 컨텍스트(인가 내장).
    2) Provider.propose_line_diff(context, prompt) — LLM 어댑터(Repo 접근 불가).
    3) AiInteraction(proposed) 생성 + AuditLog(ai_interaction.propose) + Outbox(ai_action.proposed).

  반환: {:ok, %AiInteraction{}} | {:error, :unauthorized | :not_found | term}.
  **step 쓰기 0** — 제안 레코드(데이터)만 만든다.
  """
  def propose_line_config(line_id, prompt, actor) do
    actor_id = actor_id(actor)
    role = actor_role(actor)

    with true <- SkillRegistry.allowed?(@intent) || {:error, :skill_not_allowed},
         {:ok, context} <- ProductionLine.ai_context(line_id, role),
         {:ok, result} <- Provider.active().propose_line_diff(context, prompt) do
      proposed_action = %{
        "line_id" => line_id,
        "ops" => result.diff
      }

      attrs = %{
        actor_id: actor_id,
        intent: @intent,
        prompt: prompt,
        response_summary: result.summary,
        referenced_resources: stringify(result.referenced),
        proposed_action: proposed_action,
        approval_status: "proposed",
        provider: Provider.label(Provider.active())
      }

      Multi.new()
      |> Multi.insert(:record, AiInteraction.changeset(%AiInteraction{}, attrs))
      |> Audit.put_log(:audit, fn %{record: rec} ->
        %{
          actor_id: actor_id,
          action: "ai_interaction.propose",
          resource_type: "ai_interaction",
          resource_id: rec.id,
          before: nil,
          after: %{approval_status: "proposed", intent: @intent, line_id: line_id}
        }
      end)
      |> Outbox.put_event(:event, fn %{record: rec} ->
        %{
          event_type: "ai_action.proposed",
          aggregate_type: "ai_interaction",
          aggregate_id: rec.id,
          occurred_at: DateTime.utc_now(),
          payload: %{intent: @intent, line_id: line_id, provider: rec.provider}
        }
      end)
      |> Repo.transaction()
      |> normalize(:record)
    else
      {:error, _} = err -> err
      false -> {:error, :skill_not_allowed}
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # [4] 승인 / 거부 (상태 전이 — AuditLog 동반)
  # ──────────────────────────────────────────────────────────────────

  @doc "제안 승인(proposed|reviewed → approved). AuditLog + Outbox(ai_action.approved)."
  def approve_proposal(id, reviewer) do
    reviewer_id = actor_id(reviewer)

    with {:ok, interaction} <- fetch_interaction(id) do
      from_status = interaction.approval_status

      Multi.new()
      |> Multi.update(
        :record,
        AiInteraction.transition_changeset(interaction, "approved", %{
          reviewer_id: reviewer_id,
          reviewed_at: DateTime.utc_now()
        })
      )
      |> Audit.put_log(:audit, fn %{record: rec} ->
        %{
          actor_id: reviewer_id,
          action: "ai_interaction.approve",
          resource_type: "ai_interaction",
          resource_id: rec.id,
          before: %{approval_status: from_status},
          after: %{approval_status: "approved", reviewer_id: reviewer_id}
        }
      end)
      |> Outbox.put_event(:event, fn %{record: rec} ->
        %{
          event_type: "ai_action.approved",
          aggregate_type: "ai_interaction",
          aggregate_id: rec.id,
          occurred_at: DateTime.utc_now(),
          payload: %{reviewer_id: reviewer_id}
        }
      end)
      |> Repo.transaction()
      |> normalize(:record)
    end
  end

  @doc "제안 거부(→ rejected). AuditLog. 사유 기록."
  def reject_proposal(id, reason, reviewer) do
    reviewer_id = actor_id(reviewer)

    with {:ok, interaction} <- fetch_interaction(id) do
      from_status = interaction.approval_status

      Multi.new()
      |> Multi.update(
        :record,
        AiInteraction.transition_changeset(interaction, "rejected", %{
          reviewer_id: reviewer_id,
          reviewed_at: DateTime.utc_now(),
          execution_result: %{"rejected_reason" => reason}
        })
      )
      |> Audit.put_log(:audit, fn %{record: rec} ->
        %{
          actor_id: reviewer_id,
          action: "ai_interaction.reject",
          resource_type: "ai_interaction",
          resource_id: rec.id,
          before: %{approval_status: from_status},
          after: %{approval_status: "rejected", reason: reason}
        }
      end)
      |> Repo.transaction()
      |> normalize(:record)
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # [5] 적용(apply) — 여기서 처음으로 실제 step 쓰기(actor=승인자).
  # status==approved 가드. 단일 Multi(원자성). 실패 시 전체 롤백 + failed.
  # ──────────────────────────────────────────────────────────────────

  @doc """
  승인된 제안 적용. **status==approved 가드** — proposed/rejected/executed 직접 적용 차단.

  단일 Ecto.Multi: diff op → ProductionLine.multi_create/update/delete_step(각 AuditLog)
  + AiInteraction approved→executed + AuditLog(ai_interaction.execute).
  op 중 available_* 화이트리스트 외 process_code → 검증 실패 → 전체 롤백 + failed.
  """
  def apply_proposal(id, reviewer) do
    actor_id = actor_id(reviewer)

    with {:ok, interaction} <- fetch_interaction(id),
         :ok <- guard_approved(interaction),
         {:ok, line_id, ops} <- extract_ops(interaction),
         {:ok, plan} <- build_apply_plan(line_id, ops) do
      run_apply(interaction, line_id, plan, actor_id)
    else
      {:error, :not_approved} ->
        {:error, :not_approved}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {:invalid_op, reason}} ->
        mark_failed(id, %{"error" => reason}, actor_id)
        {:error, {:invalid_op, reason}}
    end
  end

  defp guard_approved(%AiInteraction{approval_status: "approved"}), do: :ok
  defp guard_approved(_), do: {:error, :not_approved}

  defp extract_ops(%AiInteraction{proposed_action: %{"line_id" => line_id, "ops" => ops}})
       when is_binary(line_id) and is_list(ops),
       do: {:ok, line_id, ops}

  defp extract_ops(_), do: {:error, :invalid_proposal}

  # op 목록을 실제 적용 가능한 plan(작업 목록)으로 번역 + 화이트리스트 검증.
  # 반환: {:ok, %{adds: [...], removes: [...], reorders: [...], applied: [...요약...]}}
  #       | {:error, {:invalid_op, reason}}
  defp build_apply_plan(line_id, ops) do
    active_processes = MasterData.list_processes(%{"active" => true})
    active_equipment = MasterData.list_equipment(%{"active" => true})
    current_steps = ProductionLine.list_steps(line_id)

    process_by_code = Map.new(active_processes, &{&1.process_code, &1})
    equipment_by_code = Map.new(active_equipment, &{&1.equipment_code, &1})

    Enum.reduce_while(ops, {:ok, [], []}, fn op, {:ok, actions, summary} ->
      case translate_op(op, process_by_code, equipment_by_code, current_steps) do
        {:ok, action, desc} -> {:cont, {:ok, actions ++ [action], summary ++ [desc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_op, reason}}}
      end
    end)
    |> case do
      {:ok, actions, summary} ->
        {:ok, %{line_id: line_id, actions: actions, summary: summary, current: current_steps}}

      err ->
        err
    end
  end

  defp translate_op(%{"op" => "add_step"} = op, processes, equipment, _current) do
    code = op["process_code"]

    case Map.get(processes, code) do
      nil ->
        {:error, "선택 가능 목록에 없는 공정입니다: #{inspect(code)}"}

      proc ->
        equip_code = op["equipment_code"]
        equip = equip_code && Map.get(equipment, equip_code)

        if equip_code && is_nil(equip) do
          {:error, "선택 가능 목록에 없는 설비입니다: #{inspect(equip_code)}"}
        else
          {:ok,
           {:add, %{process_id: proc.id, equipment_id: equip && equip.id, after: op["after_process_code"]}},
           "추가: #{proc.name}"}
        end
    end
  end

  defp translate_op(%{"op" => "remove_step"} = op, processes, _equipment, current) do
    code = op["process_code"]

    with proc when not is_nil(proc) <- Map.get(processes, code),
         step when not is_nil(step) <- Enum.find(current, &(&1.process_id == proc.id)) do
      {:ok, {:remove, %{step_id: step.id}}, "삭제: #{proc.name}"}
    else
      _ -> {:error, "삭제할 공정 단계를 찾지 못했습니다: #{inspect(code)}"}
    end
  end

  defp translate_op(%{"op" => "reorder"} = op, processes, _equipment, current) do
    code = op["process_code"]

    with proc when not is_nil(proc) <- Map.get(processes, code),
         step when not is_nil(step) <- Enum.find(current, &(&1.process_id == proc.id)) do
      {:ok, {:reorder, %{step_id: step.id, to: op["to"] || "last"}}, "순서변경: #{proc.name} → #{op["to"]}"}
    else
      _ -> {:error, "순서변경할 공정 단계를 찾지 못했습니다: #{inspect(code)}"}
    end
  end

  defp translate_op(op, _p, _e, _c), do: {:error, "알 수 없는 op: #{inspect(op)}"}

  # plan 의 actions 를 단일 Multi 로 적용. 모든 step 쓰기는 ProductionLine 헬퍼 경유(AuditLog 동반).
  # sequence 충돌 회피: 기존 step 들을 임시 양수 park 로 옮긴 뒤 최종 순서로 재배열.
  defp run_apply(interaction, line_id, plan, actor_id) do
    final_order = compute_final_order(plan)

    multi =
      Multi.new()
      # 1) 삭제 대상 먼저 제거.
      |> apply_removes(plan, actor_id)
      # 2) 남는/추가 step 들을 임시 park sequence 로 이동(unique 충돌 회피).
      |> park_existing(plan)
      # 3) 신규 추가 step insert(park 영역에) + 최종 순서로 전부 재배열.
      |> apply_final_order(line_id, final_order, actor_id)
      # 4) AiInteraction approved→executed + AuditLog.
      |> Multi.update(
        :interaction,
        AiInteraction.transition_changeset(interaction, "executed", %{
          execution_result: %{"applied" => plan.summary, "step_count" => length(final_order)}
        })
      )
      |> Audit.put_log(:interaction_audit, fn %{interaction: rec} ->
        %{
          actor_id: actor_id,
          action: "ai_interaction.execute",
          resource_type: "ai_interaction",
          resource_id: rec.id,
          before: %{approval_status: "approved"},
          after: %{approval_status: "executed", line_id: line_id}
        }
      end)

    case Repo.transaction(multi) do
      {:ok, %{interaction: rec}} ->
        {:ok, rec}

      {:error, _step, reason, _changes} ->
        error_payload = %{"error" => "적용 실패: #{inspect(reason)}"}
        mark_failed(interaction.id, error_payload, actor_id)
        {:error, reason}
    end
  end

  # 최종 step 순서(process_id/equipment_id 목록)를 계산. 추가/삭제/순서변경 반영.
  defp compute_final_order(plan) do
    # 현재 step 들로 시작.
    base =
      Enum.map(plan.current, fn s ->
        %{kind: :existing, step_id: s.id, process_id: s.process_id, equipment_id: s.equipment_id}
      end)

    # 삭제 제거.
    removed_ids = for {:remove, %{step_id: id}} <- plan.actions, do: id
    base = Enum.reject(base, &(&1.step_id in removed_ids))

    # 추가 삽입(after_process_code 위치).
    base =
      Enum.reduce(plan.actions, base, fn
        {:add, add}, acc ->
          new_node = %{kind: :new, process_id: add.process_id, equipment_id: add.equipment_id}
          insert_after(acc, new_node, add.after, plan.current)

        _, acc ->
          acc
      end)

    # 순서변경(to=last/first) 적용.
    base =
      Enum.reduce(plan.actions, base, fn
        {:reorder, %{step_id: id, to: to}}, acc ->
          {node, rest} = Enum.split_with(acc, &(Map.get(&1, :step_id) == id)) |> then(fn {n, r} -> {List.first(n), r} end)
          if node, do: place(rest, node, to), else: acc

        _, acc ->
          acc
      end)

    base
  end

  defp insert_after(list, node, nil, _current), do: list ++ [node]

  defp insert_after(list, node, after_code, current) do
    # after_code(process_code) 에 해당하는 current step 의 process_id 뒤에 삽입.
    after_step = Enum.find(current, &match_process_code(&1, after_code))

    case after_step do
      nil ->
        list ++ [node]

      step ->
        idx = Enum.find_index(list, &(Map.get(&1, :step_id) == step.id))
        if idx, do: List.insert_at(list, idx + 1, node), else: list ++ [node]
    end
  end

  # current step 은 monitor 가 아닌 list_steps 결과(process_id 보유)라 code 매칭 위해 조회.
  defp match_process_code(step, code) do
    case MasterData.get_process(step.process_id) do
      nil -> false
      proc -> proc.process_code == code
    end
  end

  defp place(list, node, "first"), do: [node | list]
  defp place(list, node, _last), do: list ++ [node]

  # 삭제 적용.
  defp apply_removes(multi, plan, actor_id) do
    plan.actions
    |> Enum.filter(&match?({:remove, _}, &1))
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {{:remove, %{step_id: id}}, i}, acc ->
      step = ProductionLine.get_step(id)
      if step, do: ProductionLine.multi_delete_step(acc, :"remove_#{i}", step, actor_id), else: acc
    end)
  end

  # 남는 기존 step 들을 임시 park sequence 로 이동(unique[line_id,sequence] 충돌 회피).
  defp park_existing(multi, plan) do
    removed_ids = for {:remove, %{step_id: id}} <- plan.actions, do: id
    survivors = Enum.reject(plan.current, &(&1.id in removed_ids))

    survivors
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {step, i}, acc ->
      Multi.update(acc, :"park_#{i}", OpenMes.ProductionLine.LineStep.changeset(step, %{sequence: 2_000_000 + i}))
    end)
  end

  # 최종 순서대로: 기존 step 은 sequence 갱신, 신규 step 은 insert. 각 AuditLog 동반.
  defp apply_final_order(multi, line_id, final_order, actor_id) do
    final_order
    |> Enum.with_index(1)
    |> Enum.reduce(multi, fn {node, seq}, acc ->
      case node do
        %{kind: :existing, step_id: step_id} ->
          # park 된 step 을 최종 sequence 로 update.
          key = :"final_#{step_id}"

          Multi.merge(acc, fn _changes ->
            step = ProductionLine.get_step(step_id)
            ProductionLine.multi_update_step(Multi.new(), key, step, %{sequence: seq}, actor_id)
          end)

        %{kind: :new, process_id: pid, equipment_id: eid} ->
          attrs = %{line_id: line_id, process_id: pid, equipment_id: eid, sequence: seq}
          ProductionLine.multi_create_step(acc, :"add_#{seq}", attrs, actor_id)
      end
    end)
  end

  # 적용 실패 시 approved→failed 전이 + AuditLog(별도 트랜잭션 — 롤백된 본 트랜잭션과 분리).
  defp mark_failed(id, error_payload, actor_id) do
    case fetch_interaction(id) do
      {:ok, %{approval_status: "approved"} = interaction} ->
        Multi.new()
        |> Multi.update(
          :record,
          AiInteraction.transition_changeset(interaction, "failed", %{execution_result: error_payload})
        )
        |> Audit.put_log(:audit, fn %{record: rec} ->
          %{
            actor_id: actor_id,
            action: "ai_interaction.fail",
            resource_type: "ai_interaction",
            resource_id: rec.id,
            before: %{approval_status: "approved"},
            after: %{approval_status: "failed", error: error_payload}
          }
        end)
        |> Repo.transaction()

      _ ->
        :noop
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp line_id_of(%AiInteraction{proposed_action: %{"line_id" => line_id}}), do: line_id
  defp line_id_of(_), do: nil

  # actor 는 문자열(actor_id) 또는 %{actor_id, role} map 둘 다 허용.
  defp actor_id(actor) when is_binary(actor), do: actor
  defp actor_id(%{actor_id: id}), do: id
  defp actor_id(%{"actor_id" => id}), do: id

  defp actor_role(%{role: role}), do: role
  defp actor_role(%{"role" => role}), do: role
  # 문자열 actor 만 주어지면 데모 기본 권한자(system_admin) — 컨텍스트 함수가 재차 인가.
  defp actor_role(_), do: "system_admin"

  # jsonb 직렬화: atom 키 map 을 문자열 키로(referenced_resources 저장용).
  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp normalize({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp normalize({:error, _step, %Ecto.Changeset{} = cs, _}, _key), do: {:error, cs}
  defp normalize({:error, _step, reason, _}, _key), do: {:error, reason}
end
