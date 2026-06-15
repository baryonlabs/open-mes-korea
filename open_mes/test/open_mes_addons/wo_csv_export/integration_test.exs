defmodule OpenMes.Addons.WoCsvExport.IntegrationTest do
  @moduledoc """
  통합 테스트 — 코어 Repo(work_orders) 가 있는 앱 트리에서만 실행.

  검증 포인트:
    - to_csv/1 이 코어 `list_work_orders/1` 로 읽어 CSV 를 만든다(필터 status/due_date 적용).
    - 다운로드 컨트롤러가 text/csv + attachment 로 응답한다.
    - 읽기 전용: 어떤 쓰기/AuditLog 도 발생하지 않는다.

  ## 활성화 방법(앱 통합 후)
    - `use OpenMes.DataCase` 가 동작하도록 이 파일을 앱의 test/ 트리에 둔다.
    - 본 워크스페이스에는 DataCase/work_orders 테이블이 없으므로 `@moduletag :integration`
      으로 묶고 기본 실행에서 제외한다. 통합 후 `mix test --include integration` 로 켠다.
    - 통합 후 아래 주석 처리된 `use OpenMes.DataCase` 와 픽스처를 활성화한다.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  # 앱 통합 후 아래로 교체:
  #   use OpenMes.DataCase
  #   alias OpenMes.Addons.WoCsvExport
  #   alias OpenMes.Production

  @actor_id "00000000-0000-0000-0000-0000000000aa"

  @doc false
  def create_wo(attrs) do
    # 통합 후:
    #   {:ok, wo} = Production.create_work_order(attrs, @actor_id)
    #   wo
    _ = {attrs, @actor_id}
    :skipped
  end

  describe "to_csv/1 — 필터 적용(통합)" do
    @tag :skip
    test "status 필터로 해당 상태 작업지시만 CSV 에 포함된다" do
      # create_wo(%{"work_order_no" => "WO-D", "item_id" => uuid(), "planned_quantity" => "10"})
      # released = create_wo(%{...}) |> release(...)
      #
      # csv = WoCsvExport.to_csv(%{"status" => "released"}) |> IO.iodata_to_binary()
      # assert csv =~ "WO-R"
      # refute csv =~ "WO-D"
      assert true
    end

    @tag :skip
    test "필터 없이 호출하면 모든 작업지시를 내보낸다(헤더 + N행)" do
      assert true
    end
  end

  describe "다운로드 컨트롤러(통합, ConnCase)" do
    @tag :skip
    test "GET /extensions/wo-csv-export/download → text/csv + attachment" do
      # conn = get(conn, "/extensions/wo-csv-export/download?status=released")
      # assert response_content_type(conn, :csv) =~ "text/csv"
      # assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment"
      assert true
    end

    @tag :skip
    test "애드온 비활성이면 404" do
      assert true
    end
  end
end
