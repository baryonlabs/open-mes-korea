defmodule OpenMes.Addons.WoCsvExport.CsvTest do
  @moduledoc """
  CSV 직렬화 정확성 테스트(순수 함수 — DB 불필요).

  검증 포인트:
    - 헤더 행이 항상 포함되고 컬럼 순서가 명세와 일치한다.
    - 데이터 행이 필드 순서대로 매핑된다(상태 한국어 라벨, decimal/date/datetime 포맷).
    - RFC 4180 이스케이프: 쉼표/따옴표/개행 포함 필드는 따옴표로 감싸고 내부 따옴표는 이중화.
    - 빈 목록도 헤더 행은 출력한다.
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.WoCsvExport.Csv
  alias OpenMes.Production.WorkOrder

  defp to_string_csv(work_orders), do: work_orders |> Csv.encode_work_orders() |> IO.iodata_to_binary()

  defp lines(csv), do: csv |> String.trim_trailing("\r\n") |> String.split("\r\n")

  describe "encode_work_orders/1 — 헤더" do
    test "빈 목록이어도 헤더 행은 항상 포함된다" do
      csv = to_string_csv([])
      assert lines(csv) == ["작업지시번호,품목,계획수량,납기일,상태,생성일"]
    end

    test "헤더 컬럼 순서가 명세(작업지시번호/품목/계획수량/납기일/상태/생성일)와 일치한다" do
      assert Csv.headers() == ["작업지시번호", "품목", "계획수량", "납기일", "상태", "생성일"]
    end

    test "행 구분자는 CRLF 이고 마지막 행 뒤에도 CRLF 가 붙는다" do
      csv = to_string_csv([])
      assert String.ends_with?(csv, "\r\n")
      refute String.contains?(csv, "\n\r")
    end
  end

  describe "encode_work_orders/1 — 데이터 행 매핑" do
    test "필드가 컬럼 순서대로 매핑되고 상태는 한국어 라벨, decimal/date 가 포맷된다" do
      wo = %WorkOrder{
        work_order_no: "WO-001",
        item_id: "ITEM-AAA",
        planned_quantity: Decimal.new("100.5"),
        due_date: ~D[2026-06-30],
        status: "released",
        inserted_at: ~U[2026-06-13 09:00:00Z]
      }

      [_header, row] = lines(to_string_csv([wo]))

      assert row == "WO-001,ITEM-AAA,100.5,2026-06-30,확정,2026-06-13T09:00:00Z"
    end

    test "nil 필드는 빈 셀로 출력된다" do
      wo = %WorkOrder{
        work_order_no: "WO-002",
        item_id: nil,
        planned_quantity: nil,
        due_date: nil,
        status: "draft",
        inserted_at: nil
      }

      [_header, row] = lines(to_string_csv([wo]))
      assert row == "WO-002,,,,초안,"
    end

    test "미정의 상태값은 원문 그대로 출력된다" do
      wo = %WorkOrder{work_order_no: "WO-003", status: "unknown_status"}
      [_h, row] = lines(to_string_csv([wo]))
      assert row =~ "unknown_status"
    end

    test "여러 행을 순서대로 인코딩한다" do
      wos = [
        %WorkOrder{work_order_no: "A", status: "draft"},
        %WorkOrder{work_order_no: "B", status: "completed"}
      ]

      [_h, r1, r2] = lines(to_string_csv(wos))
      assert r1 =~ "A,"
      assert r1 =~ "초안"
      assert r2 =~ "B,"
      assert r2 =~ "완료"
    end
  end

  describe "escape_field/1 — RFC 4180 이스케이프" do
    test "특수문자 없는 필드는 그대로 둔다" do
      assert Csv.escape_field("WO-001") == "WO-001"
      assert Csv.escape_field("") == ""
    end

    test "쉼표가 있으면 따옴표로 감싼다" do
      assert Csv.escape_field("A,B") == "\"A,B\""
    end

    test "따옴표가 있으면 감싸고 내부 따옴표를 이중화한다" do
      assert Csv.escape_field("12\"인치") == "\"12\"\"인치\""
    end

    test "개행(LF/CRLF)이 있으면 따옴표로 감싼다" do
      assert Csv.escape_field("line1\nline2") == "\"line1\nline2\""
      assert Csv.escape_field("line1\r\nline2") == "\"line1\r\nline2\""
    end
  end

  describe "encode_work_orders/1 — 이스케이프 통합" do
    test "쉼표/따옴표를 포함한 작업지시번호가 올바르게 이스케이프된다" do
      wo = %WorkOrder{
        work_order_no: "WO,\"특수\"",
        item_id: "품목, A",
        planned_quantity: Decimal.new("1"),
        status: "draft"
      }

      [_h, row] = lines(to_string_csv([wo]))
      # work_order_no: WO,"특수"  → "WO,""특수"""
      assert row =~ "\"WO,\"\"특수\"\"\""
      # item_id: 품목, A → "품목, A"
      assert row =~ "\"품목, A\""
    end
  end
end
