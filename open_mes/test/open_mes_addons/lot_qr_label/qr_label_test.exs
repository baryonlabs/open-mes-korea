defmodule OpenMes.Addons.LotQrLabel.QrLabelTest do
  @moduledoc """
  애드온③ QR 페이로드/SVG/라벨 조립 순수 로직 테스트 (DB 불필요, async).

  검증 포인트:
    - QR 페이로드 정확성(접두사 + lot_no, 상태/수량 비포함 → LOT 식별자만)
    - SVG QR 인코딩 동작
    - build_label 이 LOT 읽기 데이터를 그대로 라벨로 옮긴다
  """
  use ExUnit.Case, async: true

  alias OpenMes.Addons.LotQrLabel
  alias OpenMes.Addons.LotQrLabel.MaterialLot

  describe "qr_payload/1 — 페이로드 정확성" do
    test "MaterialLot → \"OPENMES:LOT:<lot_no>\"" do
      lot = %MaterialLot{lot_no: "LOT-2026-0001"}
      assert LotQrLabel.qr_payload(lot) == "OPENMES:LOT:LOT-2026-0001"
    end

    test "문자열 lot_no 입력도 동일 형식" do
      assert LotQrLabel.qr_payload("ABC123") == "OPENMES:LOT:ABC123"
    end

    test "페이로드는 lot_no 만 담는다(상태/수량은 인코딩하지 않음)" do
      # 라벨 인쇄 후 LOT 상태가 바뀌어도 QR 식별자는 항상 유효해야 한다.
      lot = %MaterialLot{lot_no: "L-9", status: "available", quantity: Decimal.new("10")}
      payload = LotQrLabel.qr_payload(lot)

      assert payload == "OPENMES:LOT:L-9"
      refute payload =~ "available"
      refute payload =~ "10"
    end

    test "nil lot_no 는 빈 식별자" do
      assert LotQrLabel.qr_payload(nil) == "OPENMES:LOT:"
    end
  end

  describe "qr_svg/1 — SVG 인코딩" do
    test "페이로드를 SVG 문자열로 인코딩한다" do
      svg = LotQrLabel.qr_svg("OPENMES:LOT:LOT-1")
      assert is_binary(svg)
      assert svg =~ "<svg"
      assert svg =~ "</svg>"
    end

    test "서로 다른 페이로드는 일반적으로 다른 SVG 를 만든다" do
      a = LotQrLabel.qr_svg("OPENMES:LOT:AAA")
      b = LotQrLabel.qr_svg("OPENMES:LOT:BBB")
      assert a != b
    end
  end

  describe "build_label/1 — 라벨 조립" do
    test "LOT 읽기 데이터를 라벨 필드로 옮기고 QR 을 채운다" do
      now = ~U[2026-06-13 09:00:00.000000Z]

      lot = %MaterialLot{
        id: "11111111-1111-1111-1111-111111111111",
        lot_no: "LOT-2026-0007",
        item_id: "22222222-2222-2222-2222-222222222222",
        lot_type: "material",
        quantity: Decimal.new("42"),
        status: "available",
        inserted_at: now
      }

      label = LotQrLabel.build_label(lot)

      assert label.lot_id == lot.id
      assert label.lot_no == "LOT-2026-0007"
      assert label.item_id == lot.item_id
      assert label.lot_type == "material"
      assert label.quantity == Decimal.new("42")
      assert label.status == "available"
      assert label.status_label == "가용"
      assert label.created_at == now
      assert label.qr_payload == "OPENMES:LOT:LOT-2026-0007"
      assert label.qr_svg =~ "<svg"
    end
  end

  describe "MaterialLot.status_label/1 — 한국어 표시" do
    test "정의된 상태 6개는 한국어 라벨로 매핑" do
      assert MaterialLot.status_label("available") == "가용"
      assert MaterialLot.status_label("reserved") == "예약"
      assert MaterialLot.status_label("consumed") == "소비"
      assert MaterialLot.status_label("produced") == "생산"
      assert MaterialLot.status_label("quarantined") == "격리"
      assert MaterialLot.status_label("scrapped") == "폐기"
    end

    test "nil 은 \"-\"" do
      assert MaterialLot.status_label(nil) == "-"
    end
  end

  describe "읽기 전용 불변식 — 쓰기 함수 부재" do
    test "MaterialLot 은 changeset 을 노출하지 않는다(Repo 쓰기 경로 차단)" do
      refute function_exported?(MaterialLot, :changeset, 2)
      refute function_exported?(MaterialLot, :create_changeset, 2)
      refute function_exported?(MaterialLot, :update_changeset, 2)
    end

    test "LotQrLabel 컨텍스트는 쓰기 함수를 노출하지 않는다" do
      exported = LotQrLabel.__info__(:functions)
      names = Enum.map(exported, fn {name, _arity} -> name end)

      refute :create_lot in names
      refute :update_lot in names
      refute :delete_lot in names
      refute :insert in names
      refute :issue_label in names
    end
  end
end
