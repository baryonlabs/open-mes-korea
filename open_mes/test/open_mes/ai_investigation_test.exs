defmodule OpenMes.AiInvestigationTest do
  @moduledoc """
  AI 종합 조사(Level 1 Read-only) 테스트 — 설계 25번.

  검증:
    - 권한 role 필터(미인가 거부, 허용 role 통과).
    - 집계+다운샘플(raw 전량 금지 — sample ≤ 60, 통계 요약).
    - 키 브리지(equipment_code → equipment).
    - investigate(mock) → AiInteraction(intent="query", answered) + AuditLog(ai_interaction.query).
    - 쓰기 0(조사 전후 생산 데이터/Outbox 불변), proposed_action=nil.
    - 추세/이상치 판정 순수 함수.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Ai.{AiInteraction, Investigation}
  alias OpenMes.Audit.AuditLog
  alias OpenMes.MasterData
  alias OpenMes.Outbox.Event
  alias OpenMes.Repo

  import Ecto.Query

  @actor "tester"
  @admin %{actor_id: @actor, role: "system_admin"}
  @quality %{actor_id: @actor, role: "quality_manager"}
  @operator %{actor_id: @actor, role: "operator"}

  setup do
    {:ok, equipment} =
      MasterData.create_equipment(%{equipment_code: "EQ-TST", name: "테스트설비"}, @actor)

    %{equipment: equipment}
  end

  # 시계열 측정값 시딩(읽기 전용 스키마 — insert_all). value 추세는 증가(rising) 유도.
  defp seed_measurements(equipment_code, metric_key, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for i <- 1..count do
        %{
          equipment_id: equipment_code,
          metric_key: metric_key,
          value: i * 1.0,
          unit: "mm/s",
          quality: "good",
          measured_at: DateTime.add(now, -(count - i) * 60, :second),
          ingested_at: now,
          meta: %{}
        }
      end

    Repo.insert_all("equipment_measurements", rows)
  end

  defp seed_media(equipment_code, media_type, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for i <- 1..count do
        %{
          id: Ecto.UUID.bingenerate(),
          equipment_id: equipment_code,
          media_type: media_type,
          nas_path: "/nas/#{equipment_code}/#{media_type}_#{i}.dat",
          file_mtime: now,
          file_size: 1_048_576,
          state: "stored",
          retry_count: 0,
          object_key: "media/#{equipment_code}/#{media_type}_#{i}",
          captured_at: DateTime.add(now, -i * 60, :second),
          meta: %{},
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("media_assets", rows)
  end

  describe "권한 role 필터" do
    test "허용 role(admin/품질)은 컨텍스트를 받는다", %{equipment: eq} do
      assert {:ok, ctx} = Investigation.build_context(eq.equipment_code, [], @admin)
      assert ctx.subject.equipment_code == "EQ-TST"
      assert {:ok, _} = Investigation.build_context(eq.equipment_code, [], @quality)
    end

    test "미인가 role(operator)은 거부된다", %{equipment: eq} do
      assert {:error, :unauthorized} = Investigation.build_context(eq.equipment_code, [], @operator)
    end

    test "investigate 도 미인가 role 을 거부한다", %{equipment: eq} do
      assert {:error, :unauthorized} =
               Investigation.investigate(eq.equipment_code, "조사", @operator)
    end

    test "없는 설비 코드는 not_found", %{equipment: _eq} do
      assert {:error, :equipment_not_found} =
               Investigation.build_context("EQ-NOPE", [], @admin)
    end
  end

  describe "집계 + 다운샘플 (raw 전량 금지)" do
    test "시계열은 통계 요약 + 다운샘플(≤60)로만 노출된다", %{equipment: eq} do
      seed_measurements(eq.equipment_code, "vibration", 200)

      assert {:ok, ctx} = Investigation.build_context(eq.equipment_code, [], @admin)
      [metric] = ctx.timeseries.metrics

      assert metric.metric_key == "vibration"
      assert metric.count == 200
      assert metric.avg > 0
      # raw 전량(200) 이 아니라 다운샘플(≤60)만 컨텍스트에 들어간다.
      assert length(metric.sample) <= 60
      assert ctx.timeseries.total_points == 200
      assert metric.trend == "rising"
    end

    test "미디어는 메타 + 타입별 개수만(바이너리 0)", %{equipment: eq} do
      seed_media(eq.equipment_code, "video", 3)
      seed_media(eq.equipment_code, "image", 5)

      assert {:ok, ctx} = Investigation.build_context(eq.equipment_code, [], @admin)
      assert ctx.media.counts_by_type["video"] == 3
      assert ctx.media.counts_by_type["image"] == 5
      assert ctx.media.total == 8
      # asset 맵에 바이너리 필드 없음 — 메타/링크만.
      asset = List.first(ctx.media.assets)
      assert asset.reference =~ "media/EQ-TST"
      refute Map.has_key?(asset, :binary)
    end

    test "데이터 없으면 빈 상태로 무붕괴", %{equipment: eq} do
      assert {:ok, ctx} = Investigation.build_context(eq.equipment_code, [], @admin)
      assert ctx.timeseries.metrics == []
      assert ctx.media.assets == []
      assert ctx.media.total == 0
    end
  end

  describe "investigate (mock) — 감사 + 쓰기 0" do
    test "AiInteraction(query, answered) + AuditLog 기록, proposed_action=nil", %{equipment: eq} do
      seed_measurements(eq.equipment_code, "vibration", 100)
      seed_media(eq.equipment_code, "video", 2)

      audit_before = Repo.aggregate(AuditLog, :count)
      outbox_before = Repo.aggregate(Event, :count)

      assert {:ok, %{interaction: interaction, context: ctx, result: result}} =
               Investigation.investigate(eq.equipment_code, "진동 추세 조사", @admin, period: "24h")

      # AiInteraction: intent=query, answered(터미널), proposed_action 없음(읽기 전용).
      assert interaction.intent == "query"
      assert interaction.approval_status == "answered"
      assert interaction.proposed_action == nil
      assert interaction.provider == "mock"
      assert interaction.referenced_resources["role"] == "system_admin"
      assert is_binary(result.analysis)
      assert result.referenced == ctx.referenced

      # AuditLog 1건 추가(ai_interaction.query).
      assert Repo.aggregate(AuditLog, :count) == audit_before + 1

      assert Repo.one(
               from a in AuditLog,
                 where: a.action == "ai_interaction.query",
                 select: count(a.id)
             ) == 1

      # Outbox 불변(읽기는 이벤트 없음).
      assert Repo.aggregate(Event, :count) == outbox_before
    end

    test "조사는 AiInteraction(query) 외 도메인 쓰기 0 (생산/측정 불변)", %{equipment: eq} do
      seed_measurements(eq.equipment_code, "temperature", 50)

      meas_before = Repo.aggregate(from(m in "equipment_measurements"), :count)
      interactions_before = Repo.aggregate(AiInteraction, :count)

      assert {:ok, _} = Investigation.investigate(eq.equipment_code, "조사", @admin)

      # 측정값(시계열)은 한 건도 변하지 않는다(읽기 전용).
      assert Repo.aggregate(from(m in "equipment_measurements"), :count) == meas_before
      # AiInteraction 은 정확히 1건만 추가(감사 레코드).
      assert Repo.aggregate(AiInteraction, :count) == interactions_before + 1
    end

    test "조사 이력 조회", %{equipment: eq} do
      assert {:ok, _} = Investigation.investigate(eq.equipment_code, "첫 조사", @admin)
      assert {:ok, _} = Investigation.investigate(eq.equipment_code, "둘째 조사", @quality)

      history = Investigation.list_query_interactions(eq.equipment_code)
      assert length(history) == 2
      assert Enum.all?(history, &(&1.intent == "query"))
    end
  end

  describe "추세/이상치 판정 (순수 함수)" do
    test "증가 시리즈는 rising" do
      assert Investigation.trend_of([1.0, 2.0, 3.0, 4.0, 5.0]) == "rising"
    end

    test "감소 시리즈는 falling" do
      assert Investigation.trend_of([5.0, 4.0, 3.0, 2.0, 1.0]) == "falling"
    end

    test "평탄 시리즈는 flat" do
      assert Investigation.trend_of([3.0, 3.0, 3.0, 3.0]) == "flat"
      assert Investigation.trend_of([]) == "flat"
    end

    test "이상치 개수(평균±3σ 초과)" do
      # 안정 baseline(다수) + 단일 outlier — 3σ 초과 1건 검출.
      baseline = List.duplicate(1.0, 40)
      assert Investigation.anomaly_count(baseline ++ [100.0]) >= 1
      # 균일 시리즈는 이상치 0(σ=0 방어).
      assert Investigation.anomaly_count([2.0, 2.0, 2.0, 2.0]) == 0
    end
  end

  describe "AiInteraction changeset 확장" do
    test "intent=query + answered 상태 허용" do
      cs =
        AiInteraction.changeset(%AiInteraction{}, %{
          actor_id: @actor,
          intent: "query",
          prompt: "조사",
          approval_status: "answered"
        })

      assert cs.valid?
    end

    test "answered 는 23번 propose 상태머신 전이 그래프에 없다(평행 경로)" do
      refute AiInteraction.allowed_transition?("proposed", "answered")
      refute AiInteraction.allowed_transition?("answered", "executed")
    end
  end
end
