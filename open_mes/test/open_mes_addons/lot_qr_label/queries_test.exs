defmodule OpenMes.Addons.LotQrLabel.QueriesTest do
  @moduledoc """
  애드온③ LOT 조회(읽기 전용) + **LOT 쓰기 없음** 검증 (DB 필요).

  설계 §0-B-7 강조: 이 애드온은 MVP 읽기 전용이다. 본 테스트는
    1. LOT 조회(get/search/필터)가 정확히 동작하는지,
    2. (중요) 어떤 조회/라벨 생성 경로도 material_lots 를 **변경하지 않는지**
       (행 수/상태 불변)를 검증한다.

  주의: 이 테스트는 `material_lots` 테이블이 존재한다고 가정한다(코어 LOT 마이그레이션).
  코어에 해당 테이블이 아직 없다면 이 파일은 통합 후 활성화한다(애드온은 새 테이블 0).
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Addons.LotQrLabel
  alias OpenMes.Addons.LotQrLabel.MaterialLot
  alias OpenMes.Repo

  import Ecto.Query

  # 테스트 설정 전용 LOT 삽입(애드온 코드가 아니라 테스트가 직접 씨앗을 만든다).
  defp seed_lot(attrs) do
    now = DateTime.utc_now()

    id = Ecto.UUID.generate()

    base = %{
      id: id,
      item_id: Ecto.UUID.generate(),
      lot_type: "material",
      quantity: Decimal.new("100"),
      status: "available",
      inserted_at: now,
      updated_at: now
    }

    row = Map.merge(base, attrs)

    # 스키마리스 insert_all 은 컬럼 타입을 모르므로 binary_id(uuid) 컬럼에는
    # 덤프된 16바이트 바이너리를 넣어야 한다(daily_summary 테스트와 동일 패턴).
    dumped =
      row
      |> Map.update!(:id, &Ecto.UUID.dump!/1)
      |> Map.update!(:item_id, &Ecto.UUID.dump!/1)

    {1, _} = Repo.insert_all("material_lots", [dumped])
    Repo.get!(MaterialLot, id)
  end

  defp lot_count, do: Repo.aggregate(MaterialLot, :count, :id)

  describe "get_lot/1 · get_lot_by_no/1" do
    test "id 로 단건 조회" do
      lot = seed_lot(%{lot_no: "LOT-A"})
      assert %MaterialLot{lot_no: "LOT-A"} = LotQrLabel.get_lot(lot.id)
    end

    test "없는 id 는 nil" do
      assert LotQrLabel.get_lot(Ecto.UUID.generate()) == nil
    end

    test "lot_no 정확 일치 단건 조회" do
      seed_lot(%{lot_no: "LOT-EXACT"})
      assert %MaterialLot{lot_no: "LOT-EXACT"} = LotQrLabel.get_lot_by_no("LOT-EXACT")
      assert LotQrLabel.get_lot_by_no("LOT-NONE") == nil
    end
  end

  describe "search_lots/1" do
    test "lot_no 부분 일치(ILIKE) 필터" do
      seed_lot(%{lot_no: "LOT-2026-0001"})
      seed_lot(%{lot_no: "LOT-2026-0002"})
      seed_lot(%{lot_no: "OTHER-9"})

      results = LotQrLabel.search_lots(q: "2026")
      lot_nos = Enum.map(results, & &1.lot_no)

      assert "LOT-2026-0001" in lot_nos
      assert "LOT-2026-0002" in lot_nos
      refute "OTHER-9" in lot_nos
    end

    test "status 필터" do
      seed_lot(%{lot_no: "S-AVAIL", status: "available"})
      seed_lot(%{lot_no: "S-SCRAP", status: "scrapped"})

      results = LotQrLabel.search_lots(status: "scrapped")
      assert Enum.map(results, & &1.lot_no) == ["S-SCRAP"]
    end

    test "빈 q/status 는 필터 미적용" do
      seed_lot(%{lot_no: "ANY-1"})
      results = LotQrLabel.search_lots(q: "", status: "")
      assert Enum.any?(results, &(&1.lot_no == "ANY-1"))
    end

    test "limit 적용" do
      for i <- 1..5, do: seed_lot(%{lot_no: "LIM-#{i}"})
      assert length(LotQrLabel.search_lots(q: "LIM-", limit: 2)) == 2
    end

    test "ILIKE 메타문자는 이스케이프되어 와일드카드로 동작하지 않는다" do
      seed_lot(%{lot_no: "LOT_X"})
      seed_lot(%{lot_no: "LOTZX"})

      # "LOT_X" 검색은 '_' 를 리터럴로 취급해야 한다 → "LOTZX" 가 매칭되면 안 됨.
      results = LotQrLabel.search_lots(q: "LOT_X")
      lot_nos = Enum.map(results, & &1.lot_no)
      assert "LOT_X" in lot_nos
      refute "LOTZX" in lot_nos
    end
  end

  describe "읽기 전용 불변식 — LOT 쓰기 없음(중요, 설계 §0-B-7)" do
    test "조회/검색/라벨 생성 어느 경로도 material_lots 행 수를 바꾸지 않는다" do
      lot = seed_lot(%{lot_no: "RO-1", status: "available"})
      before_count = lot_count()

      # 모든 읽기 경로를 호출한다.
      _ = LotQrLabel.get_lot(lot.id)
      _ = LotQrLabel.get_lot_by_no("RO-1")
      _ = LotQrLabel.search_lots(q: "RO", status: "available")
      _ = LotQrLabel.build_label(lot)

      assert lot_count() == before_count
    end

    test "라벨 생성 후 LOT 상태가 변하지 않는다(available 유지)" do
      lot = seed_lot(%{lot_no: "RO-2", status: "available"})

      _label = LotQrLabel.build_label(lot)
      _ = LotQrLabel.get_lot(lot.id)

      reloaded = Repo.one(from l in MaterialLot, where: l.id == ^lot.id)
      assert reloaded.status == "available"
      assert reloaded.updated_at == lot.updated_at
    end
  end
end
