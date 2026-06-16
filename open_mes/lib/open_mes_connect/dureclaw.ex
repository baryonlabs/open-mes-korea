defmodule OpenMes.Connect.DureClaw do
  @moduledoc """
  EXT-5 연동 허브 — DureClaw 분산 에이전트 협력 버스 연동 (`category: :integration`).

  설계 `docs/extension-roadmap.md` (A) 연동 허브: 이종 외부 프로그램을 *받아들이는* 계층.
  DureClaw 는 여러 머신(엣지 Pi·GPU·Mac)을 하나의 협동 AI 팀으로 묶는 Phoenix WS 버스다.
  이 확장은 그 버스의 **presence·Work Key·health 를 읽기 전용으로 관측**한다.

  ## pi 준수 / 안전

    - **읽기 전용**: 버스 REST(`/api/...`)를 GET 으로 조회만 한다. 코어 도메인 쓰기 0,
      AuditLog 0, Outbox 0, 새 테이블 0 (애드온 컨벤션과 동일).
    - **코어 비침투**: `OpenMes.Production`/`WorkOrder`/`Audit` 등 코어를 참조하지 않는다.
    - **config 게이트**: `config :open_mes, OpenMes.Connect.DureClaw, enabled: ...`
      (미설정 시 기본 false). 버스 주소는 env `BUS_URL`/`OAH_SECRET`.

  실제 화면은 `OpenMesWeb.Connect.DureClawLive`, 메타데이터는 `.Extension` 이 담당한다.
  """

  @timeout_ms 1500
  # 결과 폴링: fan-in 은 병렬(collect_all)이라 전체 대기 = 가장 느린 1개(합산 아님).
  # observer·원격 노드는 task.result 를 안 올리므로 *항상* 상한에 걸린다 → 상한 = 무대 대기시간.
  # 데모 안전: 15s(30×500ms) 상한. SUGGEST 는 결정론적(golden)이라 응답 없어도 항상 종합된다.
  @poll_max 30
  @poll_int 500

  @doc """
  확장 활성 여부. config 게이트.

      config :open_mes, OpenMes.Connect.DureClaw, enabled: true

  미설정 시 기본값 false (코어 비침투 — 명시적으로 켜야 라우트/카탈로그 노출).
  """
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  @doc """
  버스 라이브 스냅샷(읽기 전용): 연결여부 + health + 온라인 에이전트 + Work Key.
  BUS_URL 미설정/버스 다운이어도 connected:false 로 안전 반환한다.
  """
  def snapshot do
    case base() do
      {:ok, http, headers} ->
        %{
          connected: true,
          bus_url: http,
          health: get_json(http, "/api/health", headers) || %{},
          agents: (get_json(http, "/api/presence", headers) || %{})["agents"] || [],
          work_keys: (get_json(http, "/api/work-keys", headers) || %{})["work_keys"] || []
        }

      :disabled ->
        %{connected: false, bus_url: nil, health: %{}, agents: [], work_keys: []}
    end
  end

  @doc """
  분석 지시(Approval Flow `:executed`) — 온라인 에이전트에 task.assign fan-out 후
  결과를 fan-in 수집한다. REST 전용(버스 `POST /api/task` + `GET /api/task-result/:id`).

  코어 OMK 도메인 쓰기 0 — 외부 버스로의 지시·수집일 뿐(코어 비침투).
  주의: sim 에이전트는 ack("{role} completed")만 반환한다. rich 데이터(비전 점수·LOT 계보)는
  물리 에이전트(Pi 카메라·GPU)가 실작업하거나 시나리오가 emits 를 주입할 때 나온다.

  반환: `%{work_key, dispatched: [%{agent, role, caps, task_id, result}]}` | `{:error, :no_bus}`.
  """
  def dispatch_analysis(prompt) do
    instructions = String.trim(to_string(prompt))

    case base() do
      {:ok, http, headers} when instructions != "" ->
        wk = (get_json(http, "/api/work-keys/latest", headers) || %{})["work_key"]
        agents = (get_json(http, "/api/presence", headers) || %{})["agents"] || []

        dispatched =
          Enum.map(agents, fn a ->
            name = a["name"]
            tid = "mes-#{System.system_time(:millisecond)}-#{String.replace(name, ~r/\W/, "_")}"

            # 자유 프롬프트가 그대로 instructions 로 전달된다. 진짜 oah-agent(claude/codex/…)는
            # 이를 읽어 실행하고, sim 워커는 무시하고 ack 한다.
            assign(http, headers, %{
              "to" => name,
              "role" => a["role"],
              "work_key" => wk,
              "task_id" => tid,
              "instructions" => instructions
            })

            %{agent: name, role: a["role"], caps: a["capabilities"] || [], task_id: tid}
          end)

        %{
          work_key: wk,
          prompt: instructions,
          dispatched: collect_all(http, headers, dispatched)
        }

      {:ok, _http, _headers} ->
        {:error, :empty_prompt}

      :disabled ->
        {:error, :no_bus}
    end
  end

  @doc """
  불량 조사 (역할별 차등 지시 → fan-in → 종합) — RSI 루프의 1차 leg.

  각 엣지에 *자기 역할*의 관측을 지시(센싱)하고, 마스터로 fan-in 수집한 뒤, 골든 시나리오면
  결정론적 SUGGEST 로 종합한다. "센싱(엣지) → 종합(브레인) → 제안" 을 한 화면에 보인다.

  반환(미스): `%{mode: :llm, pattern, work_key, lot, observations, suggest, llm_ms}`
  반환(히트): `%{mode: :crystallized, pattern, lot, suggest, hit_us, llm_ms, frozen_at}` — LLM 0회.
  """
  alias OpenMes.Connect.DureClaw.SkillCache

  def dispatch_investigation(lot_no) do
    lot = String.trim(to_string(lot_no))
    key = defect_pattern(lot)

    # ── 결정화 캐시 우선 — 승인되어 동결된 룰이 있으면 LLM 디스패치 0회 ──
    case SkillCache.lookup(key) do
      {:hit, rule, hit_us} ->
        %{
          mode: :crystallized,
          pattern: key,
          lot: lot,
          suggest: rule.decision,
          hit_us: hit_us,
          llm_ms: rule.llm_ms,
          frozen_at: rule.frozen_at
        }

      :miss ->
        investigate_via_llm(lot, key)
    end
  end

  defp investigate_via_llm(lot, key) do
    case base() do
      {:ok, http, headers} ->
        t0 = System.monotonic_time(:millisecond)
        wk = (get_json(http, "/api/work-keys/latest", headers) || %{})["work_key"]
        agents = (get_json(http, "/api/presence", headers) || %{})["agents"] || []

        dispatched =
          Enum.map(agents, fn a ->
            name = a["name"]
            caps = a["capabilities"] || []
            {label, task} = role_task(caps, lot)

            tid =
              "mes-inv-#{System.system_time(:millisecond)}-#{String.replace(name, ~r/\W/, "_")}"

            assign(http, headers, %{
              "to" => name,
              "role" => a["role"],
              "work_key" => wk,
              "task_id" => tid,
              "instructions" => task
            })

            %{agent: name, role: a["role"], caps: caps, role_task: label, task_id: tid}
          end)

        observations = collect_all(http, headers, dispatched)

        %{
          mode: :llm,
          pattern: key,
          work_key: wk,
          lot: lot,
          observations: observations,
          suggest: golden_suggest(lot),
          llm_ms: System.monotonic_time(:millisecond) - t0
        }

      :disabled ->
        {:error, :no_bus}
    end
  end

  # 엣지 capability → (역할 라벨, 짧은 역할별 지시). 짧게 = 실 Claude 도 빠르게.
  defp role_task(caps, lot) do
    cond do
      caps_any?(caps, ["camera", "edge", "gpio", "led"]) ->
        {"엣지 검사", "LOT #{lot} 외관 검사: 스크래치 의심 여부와 감지 센서를 한 줄로 답해줘."}

      caps_any?(caps, ["vision", "nvidia-gpu"]) ->
        {"비전 분석", "LOT #{lot} 비전: 스크래치 점수(0~1)와 위치를 한 줄로 답해줘."}

      caps_any?(caps, ["genealogy", "mes"]) ->
        {"LOT 계보", "LOT #{lot} 계보 역추적: 공통 원자재 LOT과 영향 작업지시를 한 줄로 답해줘."}

      true ->
        {"보조 분석", "LOT #{lot} 불량 분석 보조: 핵심 한 줄."}
    end
  end

  defp caps_any?(caps, keys), do: Enum.any?(keys, &(&1 in caps))

  # 골든 시나리오 종합 (결정론적 — 무대 안정). 골든 LOT 이 아니면 nil.
  defp golden_suggest("A-2026-1031") do
    %{
      "defect_type" => "외관/스크래치",
      "root_cause" => "원자재 LOT R-882",
      "evidence" => "동일 자재 투입 3개 작업지시 불량률 상승 + 비전 edge-top 0.88",
      "confidence" => 0.82,
      "affected_work_orders" => ["WO-3301", "WO-3302", "WO-3307"],
      "action" => "quarantine"
    }
  end

  defp golden_suggest(_), do: nil

  # 불량 패턴 키 (룰 캐시 단위). 골든은 패턴 시그니처, 그 외는 lot 단위.
  defp defect_pattern("A-2026-1031"), do: "외관/스크래치@edge-top"
  defp defect_pattern(lot), do: "lot:#{lot}"

  @doc "승인 → 결정을 룰로 동결(결정화). 다음 같은 패턴 불량은 LLM 0회로 처리된다."
  def crystallize(lot_no, decision, opts \\ []) do
    SkillCache.crystallize(defect_pattern(to_string(lot_no)), decision, opts)
  end

  @doc "동결된 결정론적 룰 목록(대시보드용)."
  def frozen_rules, do: SkillCache.all()

  @doc "동결 룰 해제(데모 리셋용)."
  def forget(lot_no), do: SkillCache.forget(defect_pattern(to_string(lot_no)))

  defp assign(http, headers, body) do
    Req.post!("#{http}/api/task", headers: headers, json: body, receive_timeout: @timeout_ms)
  rescue
    _ -> :error
  end

  # fan-in 을 병렬로 — 전체 대기 = 가장 느린 1개(합산 아님). 죽은 에이전트(observer·원격)는
  # @poll_max 상한에서 nil 로 떨어지고 나머지를 막지 않는다. 타임아웃 태스크는 kill → nil.
  defp collect_all(http, headers, dispatched) do
    dispatched
    |> Task.async_stream(
      &collect(http, headers, &1),
      max_concurrency: max(length(dispatched), 1),
      timeout: @poll_max * @poll_int + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(dispatched)
    |> Enum.map(fn
      {{:ok, collected}, _item} -> collected
      {{:exit, _}, item} -> Map.put(item, :result, nil)
    end)
  end

  # task.result 가 StateStore 에 저장되므로 REST 로 폴링. 단일 에이전트 상한 @poll_max×@poll_int.
  defp collect(http, headers, %{task_id: tid} = item) do
    result =
      Enum.reduce_while(1..@poll_max, nil, fn _, _ ->
        case Req.get("#{http}/api/task-result/#{tid}",
               headers: headers,
               receive_timeout: @timeout_ms
             ) do
          {:ok, %{status: 200, body: body}} -> {:halt, body}
          _ -> Process.sleep(@poll_int) && {:cont, nil}
        end
      end)

    Map.put(item, :result, result)
  rescue
    _ -> Map.put(item, :result, nil)
  end

  defp base do
    case System.get_env("BUS_URL") do
      url when is_binary(url) and url != "" ->
        http = String.replace(url, ~r/^ws/, "http")
        secret = System.get_env("OAH_SECRET", "")
        {:ok, http, [{"authorization", "Bearer #{secret}"}]}

      _ ->
        :disabled
    end
  end

  defp get_json(http, path, headers) do
    case Req.get("#{http}#{path}", headers: headers, receive_timeout: @timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> body
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
