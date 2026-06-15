defmodule OpenMesWeb.IngestControllerTest do
  @moduledoc """
  IngestController HTTP 통합 테스트(설계 §7.4): 202 / 401 / 429.

  주의(샌드박스): 컨트롤러는 즉시 202 를 반환하고 적재는 Broadway 프로세스가
  비동기로 처리하므로, DB 커넥션 공유를 위해 공유 샌드박스(async:false)를 쓴다.

  전제: test 환경에서 ingest 활성(enabled: true) + device_tokens: ["test-token"]
  (patches/config.snippets.md 참조). 라우터의 /ingest scope 가 컴파일 타임에 등록됨.
  """
  use OpenMesWeb.ConnCase, async: false

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(OpenMes.Repo, {:shared, self()})
    :ok
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer test-token")

  describe "POST /ingest/equipment — 인증" do
    test "토큰이 없으면 401", %{conn: conn} do
      body = %{"equipment_id" => "EQP-01", "metric_key" => "t", "value" => 1.0, "measured_at" => now_iso()}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/ingest/equipment", body)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "잘못된 토큰이면 401", %{conn: conn} do
      body = %{"equipment_id" => "EQP-01", "metric_key" => "t", "value" => 1.0, "measured_at" => now_iso()}

      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> post("/ingest/equipment", body)

      assert json_response(conn, 401)
    end
  end

  describe "POST /ingest/equipment — 202 비동기 수집" do
    test "유효 토큰 + 단건 → 202 accepted:1", %{conn: conn} do
      body = %{
        "equipment_id" => "EQP-01",
        "metric_key" => "temperature",
        "value" => 72.4,
        "measured_at" => now_iso()
      }

      conn = conn |> auth() |> post("/ingest/equipment", body)
      assert json_response(conn, 202) == %{"accepted" => 1}
    end

    test "유효 토큰 + 배열 → 202 accepted:N", %{conn: conn} do
      body = [
        %{"equipment_id" => "EQP-01", "metric_key" => "temperature", "value" => 72.4, "measured_at" => now_iso()},
        %{"equipment_id" => "EQP-01", "metric_key" => "state", "string_value" => "running", "measured_at" => now_iso()}
      ]

      # 최상위 JSON 배열은 raw 본문으로 보내 Phoenix JSON 파서가 params["_json"] 에
      # 담도록 한다(Plug.Test 는 리스트를 params 로 직접 변환하지 못한다).
      conn =
        conn
        |> auth()
        |> put_req_header("content-type", "application/json")
        |> post("/ingest/equipment", Jason.encode!(body))

      assert json_response(conn, 202) == %{"accepted" => 2}
    end

    test "오염 메시지도 일단 202(접수)된다 — 검증은 비동기, dead-letter 격리", %{conn: conn} do
      # 컨트롤러는 큐 적재만 확인(202). 검증 실패는 파이프라인에서 dead-letter 로 격리.
      body = %{"metric_key" => "temperature", "value" => 1.0, "measured_at" => now_iso()}

      conn = conn |> auth() |> post("/ingest/equipment", body)
      assert json_response(conn, 202) == %{"accepted" => 1}
    end
  end

  describe "GET /ingest/health" do
    test "활성 상태와 큐 깊이를 반환한다", %{conn: conn} do
      conn = conn |> auth() |> get("/ingest/health")
      body = json_response(conn, 200)
      assert body["enabled"] == true
      assert is_integer(body["queue_depth"])
    end
  end
end
