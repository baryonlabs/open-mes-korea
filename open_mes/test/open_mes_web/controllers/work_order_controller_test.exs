defmodule OpenMesWeb.WorkOrderControllerTest do
  @moduledoc """
  WorkOrder 컨트롤러 통합 테스트.

  검증 대상:
    - 생성 201 / 조회 200
    - 정상 전이 200
    - 불법 전이 422
    - actor_id(X-Actor-Id) 누락 쓰기 거부 422
    - 미존재 404
  """
  use OpenMesWeb.ConnCase, async: true

  alias OpenMes.Production

  @actor "ctrl-tester"

  defp valid_params do
    %{
      "work_order_no" => "WO-#{System.unique_integer([:positive])}",
      "item_id" => Ecto.UUID.generate(),
      "planned_quantity" => "100"
    }
  end

  defp with_actor(conn), do: put_req_header(conn, "x-actor-id", @actor)

  defp create_wo do
    {:ok, wo} = Production.create_work_order(valid_params(), @actor)
    wo
  end

  describe "POST /api/work_orders" do
    test "actor 헤더가 있으면 201 + draft 생성", %{conn: conn} do
      conn =
        conn
        |> with_actor()
        |> post(~p"/api/work_orders", work_order: valid_params())

      assert %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "draft"
      assert data["id"]
    end

    test "actor 헤더 누락 시 422 거부", %{conn: conn} do
      conn = post(conn, ~p"/api/work_orders", work_order: valid_params())
      assert %{"errors" => %{"actor" => _}} = json_response(conn, 422)
    end

    test "actor 헤더가 공백뿐이면 422 거부", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-actor-id", "   ")
        |> post(~p"/api/work_orders", work_order: valid_params())

      assert json_response(conn, 422)
    end
  end

  describe "GET /api/work_orders/:id" do
    test "단건 조회 200", %{conn: conn} do
      wo = create_wo()
      conn = get(conn, ~p"/api/work_orders/#{wo.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == wo.id
    end

    test "미존재 404", %{conn: conn} do
      conn = get(conn, ~p"/api/work_orders/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "조회에는 actor 헤더 불필요", %{conn: conn} do
      wo = create_wo()
      # 헤더 없이도 200
      conn = get(conn, ~p"/api/work_orders/#{wo.id}")
      assert json_response(conn, 200)
    end
  end

  describe "상태 전이 엔드포인트" do
    test "POST .../release 정상 200", %{conn: conn} do
      wo = create_wo()

      conn =
        conn |> with_actor() |> post(~p"/api/work_orders/#{wo.id}/release")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["status"] == "released"
      assert data["released_at"]
    end

    test "POST .../start (draft 에서) 불법 전이 422", %{conn: conn} do
      wo = create_wo()

      conn =
        conn |> with_actor() |> post(~p"/api/work_orders/#{wo.id}/start")

      assert %{"errors" => %{"status" => _}} = json_response(conn, 422)
    end

    test "전이 엔드포인트도 actor 누락 시 422", %{conn: conn} do
      wo = create_wo()
      conn = post(conn, ~p"/api/work_orders/#{wo.id}/release")
      assert %{"errors" => %{"actor" => _}} = json_response(conn, 422)
    end

    test "미존재 전이 404", %{conn: conn} do
      conn =
        conn |> with_actor() |> post(~p"/api/work_orders/#{Ecto.UUID.generate()}/release")

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/work_orders/:id" do
    test "draft 수정 200", %{conn: conn} do
      wo = create_wo()

      conn =
        conn
        |> with_actor()
        |> patch(~p"/api/work_orders/#{wo.id}", work_order: %{"planned_quantity" => "300"})

      assert %{"data" => data} = json_response(conn, 200)
      assert data["planned_quantity"] == "300"
    end

    test "released 상태 수정 거부 422", %{conn: conn} do
      wo = create_wo()
      {:ok, _} = Production.release_work_order(wo.id, @actor)

      conn =
        conn
        |> with_actor()
        |> patch(~p"/api/work_orders/#{wo.id}", work_order: %{"planned_quantity" => "300"})

      assert json_response(conn, 422)
    end
  end
end
