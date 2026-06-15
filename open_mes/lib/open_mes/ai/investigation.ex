defmodule OpenMes.Ai.Investigation do
  @moduledoc """
  AI 종합 조사 컨텍스트 + 조사 진입점 — 설계 25번 §1/§2. **Level 1 Read-only(쓰기 0)**.

  시계열(EXT-1 equipment_measurements) + 미디어(EXT-2 media_assets) + 생산(코어)을
  설비 1대 기준점으로 **권한 role 필터**한 단일 plain map(`ai_investigation_context`)으로 묶고,
  Provider.investigate(context, query) 로 조사 요약을 얻는다.

  AI 안전 불변식(23번 동형 — 위반 금지):
    - AI 는 DB 직접 접근 0: `build_context/3` 가 만든 plain map 만 Provider 에 전달.
      Provider 구현체는 map + query 만 받으므로 구조적으로 Repo 접근 불가.
    - 쓰기 0: 조사는 읽기 전용. insert/update/delete 0(AiInteraction 감사 기록 1건 제외).
      Outbox 없음(읽기 이벤트 불요), 승인 흐름 없음(읽기는 즉시).
    - 모든 조사 = AiInteraction(intent="query", approval_status="answered") + AuditLog(ai_interaction.query).
    - 권한 role 필터(@investigation_roles): 미인가 role 은 {:error, :unauthorized}.
    - 대량 시계열 집계+다운샘플(raw 전량 금지), 미디어 메타+링크만(바이너리 0), 상한 N건.

  키 브리지(설계 결정 #4): equipment_code(문자열) ↔ equipment.id(binary_id).
    - EXT-1/EXT-2 는 equipment_code 문자열(디바이스 키)로 조회.
    - 코어 생산은 equipment.id(binary_id)로 조회. 브리지는 build_production 한 곳에 격리.
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Ai.{AiInteraction, Provider}
  alias OpenMes.{Audit, Ingest, Knowledge, Media, Repo}
  alias OpenMes.MasterData
  alias OpenMes.Production.Reports

  # 조사 전용 권한(품질관리자 포함 — 시계열/미디어 조사 핵심 사용자). 23번 쓰기 권한과 분리.
  @investigation_roles ~w(system_admin production_manager quality_manager)

  @media_limit 20
  @defect_limit 20
  @downsample_buckets 60
  # 다운샘플 시리즈 기반 단순 이상치 임계(평균±3σ 초과 개수).
  @anomaly_sigma 3.0

  @doc "조사 허용 role 목록(메뉴/라우트 인가와 공유)."
  def investigation_roles, do: @investigation_roles

  @doc "기간 프리셋 목록(UI 셀렉트용)."
  def period_presets do
    [
      {"최근 1시간", "1h"},
      {"최근 24시간", "24h"},
      {"최근 7일", "7d"}
    ]
  end

  # ──────────────────────────────────────────────────────────────────
  # build_context/3 — 권한 필터 종합 컨텍스트(쓰기 0). AI 가 보는 유일한 입력.
  # ──────────────────────────────────────────────────────────────────

  @doc """
  설비 기준 종합 조사 컨텍스트 구성. **role 인가 내장** — 미인가 시 {:error, :unauthorized}.

  opts: `:period`(프리셋 문자열 "1h"|"24h"|"7d", 기본 "24h").
  반환: {:ok, context_map} | {:error, :unauthorized | :equipment_not_found}.
  """
  def build_context(equipment_code, opts, actor) do
    role = actor_role(actor)

    with :ok <- authorize(role),
         {:ok, equipment} <- fetch_equipment(equipment_code) do
      {from_dt, to_dt, label} = resolve_period(Keyword.get(opts, :period, "24h"))

      timeseries = build_timeseries(equipment_code, from_dt, to_dt)
      media = build_media(equipment_code, from_dt, to_dt)
      production = build_production(equipment, from_dt, to_dt)
      # ★ 27번 — 관련 OKF 지식 문서 N건 + 발췌(읽기 전용 RAG, 생산 데이터와 분리).
      knowledge = build_knowledge(equipment, production)

      context = %{
        subject: %{
          equipment_code: equipment.equipment_code,
          equipment_name: equipment.name,
          equipment_id: equipment.id
        },
        period: %{from: from_dt, to: to_dt, label: label},
        timeseries: timeseries,
        media: media,
        production: production,
        knowledge: knowledge,
        referenced: %{
          equipment_code: equipment.equipment_code,
          sources: ["equipment_measurements", "media_assets", "production_results", "knowledge_documents"],
          timeseries_points_sampled: Map.get(timeseries, :total_points, 0),
          timeseries_metric_count: Map.get(timeseries, :metric_count, 0),
          media_assets_count: Map.get(media, :total, 0),
          knowledge_documents_count: Map.get(knowledge, :total, 0),
          knowledge: knowledge_refs(knowledge),
          knowledge_docs: knowledge_doc_refs(knowledge),
          role: role,
          generated_at: DateTime.utc_now()
        }
      }

      {:ok, context}
    end
  end

  defp fetch_equipment(equipment_code) do
    case MasterData.get_equipment_by_code(equipment_code) do
      nil -> {:error, :equipment_not_found}
      equipment -> {:ok, equipment}
    end
  end

  # ── (A) 시계열: 집계 요약 + 다운샘플 + 추세/이상치 판정(순수 함수) ──
  defp build_timeseries(equipment_code, from_dt, to_dt) do
    summaries = Ingest.summarize_metrics(equipment_code, from_dt, to_dt)

    metrics =
      Enum.map(summaries, fn s ->
        sample = Ingest.downsample(equipment_code, s.metric_key, from_dt, to_dt, @downsample_buckets)
        values = Enum.map(sample, & &1.v)

        s
        |> Map.put(:sample, sample)
        |> Map.put(:trend, trend_of(values))
        |> Map.put(:anomaly_count, anomaly_count(values))
      end)

    %{
      metrics: metrics,
      metric_count: length(metrics),
      total_points: metrics |> Enum.map(& &1.count) |> Enum.sum()
    }
  end

  # 다운샘플 시리즈의 선형 기울기 부호로 추세 판정(순수). rising | falling | flat.
  @doc false
  def trend_of(values) when is_list(values) do
    pts = Enum.filter(values, &is_number/1)
    n = length(pts)

    if n < 2 do
      "flat"
    else
      xs = Enum.to_list(0..(n - 1)) |> Enum.map(&(&1 * 1.0))
      mean_x = Enum.sum(xs) / n
      mean_y = Enum.sum(pts) / n

      {num, den} =
        Enum.zip(xs, pts)
        |> Enum.reduce({0.0, 0.0}, fn {x, y}, {num, den} ->
          {num + (x - mean_x) * (y - mean_y), den + (x - mean_x) * (x - mean_x)}
        end)

      slope = if den == 0.0, do: 0.0, else: num / den
      threshold = abs(mean_y) * 0.01 + 1.0e-9

      cond do
        slope > threshold -> "rising"
        slope < -threshold -> "falling"
        true -> "flat"
      end
    end
  end

  # 평균±3σ 초과 개수(순수, 단순 요약 신호 — 완벽 통계 아님).
  @doc false
  def anomaly_count(values) when is_list(values) do
    pts = Enum.filter(values, &is_number/1)
    n = length(pts)

    if n < 3 do
      0
    else
      mean = Enum.sum(pts) / n
      variance = Enum.reduce(pts, 0.0, fn v, acc -> acc + (v - mean) * (v - mean) end) / n
      sigma = :math.sqrt(variance)

      if sigma == 0.0 do
        0
      else
        Enum.count(pts, fn v -> abs(v - mean) > @anomaly_sigma * sigma end)
      end
    end
  end

  # ── (B) 미디어: 메타 + 타입별 개수 + 참조 링크(바이너리 0) ──
  defp build_media(equipment_code, from_dt, to_dt) do
    assets = Media.list_assets_by_equipment(equipment_code, from_dt, to_dt, @media_limit)
    counts = Media.count_by_type(equipment_code, from_dt, to_dt)

    asset_maps =
      Enum.map(assets, fn a ->
        %{
          id: a.id,
          media_type: a.media_type,
          captured_at: a.captured_at || a.inserted_at,
          object_key: a.object_key,
          state: a.state,
          file_size: a.file_size,
          reference: Media.reference_for(a),
          meta: a.meta
        }
      end)

    %{
      assets: asset_maps,
      counts_by_type: counts,
      total: counts |> Map.values() |> Enum.sum()
    }
  end

  # ── (C) 생산 + 키 브리지(equipment_code → equipment.id binary_id) ──
  defp build_production(_equipment, from_dt, to_dt) do
    # 키 브리지: equipment 는 이미 binary_id 보유(build_context 가 코드로 조회). MVP 는
    # 기간 기준 전체 실적 요약(Reports.defect_summary — Decimal). 설비별 세분은 후속.
    summary = Reports.defect_summary(%{from: from_dt, to: to_dt})

    good = to_num(summary.good_quantity)
    defect = to_num(summary.defect_quantity)
    total = to_num(summary.total_quantity)

    %{
      process_summary: %{
        good: good,
        defect: defect,
        total: total,
        defect_rate: to_num(summary.defect_rate)
      },
      recent_defects: recent_defects(from_dt, to_dt),
      line_status: %{overall: line_overall(to_num(summary.defect_rate))}
    }
  end

  defp recent_defects(from_dt, to_dt) do
    Reports.defects_by_code(%{from: from_dt, to: to_dt})
    |> Enum.take(@defect_limit)
    |> Enum.map(fn d ->
      %{defect_code: d.defect_code, quantity: to_num(d.quantity)}
    end)
  end

  defp line_overall(rate) when rate >= 0.1, do: :red
  defp line_overall(rate) when rate >= 0.05, do: :amber
  defp line_overall(_), do: :green

  # ── (D) 지식 문서(OKF RAG) — 27번. 읽기 전용. equipment_code/공정코드 ↔ tags 매칭. ──
  # AI 에는 plain map(발췌 포함)만 전달. Repo 접근 0(Provider 는 map+query 만).
  defp build_knowledge(equipment, production) do
    process_codes = production_process_codes(production)

    docs =
      Knowledge.search_for_subject(
        %{equipment_code: equipment.equipment_code, process_codes: process_codes},
        5
      )

    %{
      documents:
        Enum.map(docs, fn d ->
          %{
            okf_type: d.okf_type,
            title: d.title,
            resource: d.resource || canonical_uri(d),
            tags: d.tags,
            excerpt: Knowledge.excerpt(d.body)
          }
        end),
      total: length(docs)
    }
  end

  # 생산 컨텍스트에서 공정 연관 키 수집(MVP: 불량코드 — 확장 포인트). equipment_code 가 주 매칭키.
  defp production_process_codes(production) do
    production
    |> Map.get(:recent_defects, [])
    |> Enum.map(&Map.get(&1, :defect_code))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # 인용 문서의 resource URI 목록(감사·근거 추적 — referenced.knowledge).
  defp knowledge_refs(%{documents: docs}), do: Enum.map(docs, & &1.resource)

  # UI 표시용 인용 문서 메타(type/제목/URI). 감사용 knowledge(URI 목록)와 별개.
  defp knowledge_doc_refs(%{documents: docs}),
    do: Enum.map(docs, &Map.take(&1, [:okf_type, :title, :resource]))

  defp canonical_uri(doc), do: OpenMes.Okf.Document.canonical_resource(doc)

  # ──────────────────────────────────────────────────────────────────
  # investigate/3 — 조사 진입점. build_context → Provider → AiInteraction + AuditLog.
  # 쓰기 0(AiInteraction 감사 1건 제외), Outbox 없음, 승인 없음(읽기 즉시).
  # ──────────────────────────────────────────────────────────────────

  @doc """
  종합 조사 실행. 흐름:
    1) build_context(인가 내장) — 권한 필터 종합 컨텍스트(쓰기 0).
    2) Provider.active().investigate(context, query) — map+query 만(Repo 불가).
    3) AiInteraction(intent="query", answered, proposed_action: nil, referenced_resources)
       + AuditLog(ai_interaction.query) — 단일 Multi. **Outbox/승인 없음.**

  반환: {:ok, %{interaction, context, result}} | {:error, term}.
  """
  def investigate(equipment_code, query, actor, opts \\ []) do
    actor_id = actor_id(actor)

    with {:ok, context} <- build_context(equipment_code, opts, actor),
         {:ok, result} <- Provider.active().investigate(context, query) do
      referenced = stringify(context.referenced)

      attrs = %{
        actor_id: actor_id,
        intent: "query",
        prompt: query,
        response_summary: result.analysis,
        referenced_resources: referenced,
        proposed_action: nil,
        approval_status: "answered",
        provider: Provider.label(Provider.active())
      }

      Multi.new()
      |> Multi.insert(:record, AiInteraction.changeset(%AiInteraction{}, attrs))
      |> Audit.put_log(:audit, fn %{record: rec} ->
        %{
          actor_id: actor_id,
          action: "ai_interaction.query",
          resource_type: "ai_interaction",
          resource_id: rec.id,
          before: nil,
          after: %{
            intent: "query",
            approval_status: "answered",
            equipment_code: equipment_code,
            provider: rec.provider
          }
        }
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{record: rec}} ->
          {:ok, %{interaction: rec, context: context, result: result}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc "특정 설비의 최근 조사 이력(intent=query). 감사 가시성."
  def list_query_interactions(equipment_code, limit \\ 10) do
    Repo.all(
      from a in AiInteraction,
        where: a.intent == "query",
        where:
          fragment("?->>'equipment_code' = ?", a.referenced_resources, ^to_string(equipment_code)),
        order_by: [desc: a.inserted_at],
        limit: ^limit
    )
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp authorize(role) when role in @investigation_roles, do: :ok
  defp authorize(_role), do: {:error, :unauthorized}

  # 기간 프리셋 → {from, to, label}. to=now.
  defp resolve_period("1h"), do: shift(3_600, "최근 1시간")
  defp resolve_period("7d"), do: shift(7 * 86_400, "최근 7일")
  defp resolve_period(_), do: shift(86_400, "최근 24시간")

  defp shift(seconds, label) do
    to_dt = DateTime.utc_now()
    from_dt = DateTime.add(to_dt, -seconds, :second)
    {from_dt, to_dt, label}
  end

  defp actor_id(actor) when is_binary(actor), do: actor
  defp actor_id(%{actor_id: id}), do: id
  defp actor_id(%{"actor_id" => id}), do: id

  defp actor_role(%{role: role}), do: role
  defp actor_role(%{"role" => role}), do: role
  defp actor_role(role) when is_binary(role), do: role
  defp actor_role(_), do: nil

  defp to_num(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_num(n) when is_number(n), do: n
  defp to_num(_), do: 0

  # referenced_resources(jsonb) 저장용: atom 키 → 문자열 키.
  defp stringify(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp stringify(other), do: other
end
