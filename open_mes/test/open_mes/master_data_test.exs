defmodule OpenMes.MasterDataTest do
  @moduledoc """
  기준정보(MasterData) 컨텍스트 테스트 — CRUD + AuditLog 동반 검증.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Audit.AuditLog
  alias OpenMes.MasterData
  alias OpenMes.MasterData.Item

  @actor "actor-test"

  defp item_attrs(overrides \\ %{}) do
    Map.merge(
      %{"item_code" => "ITM-#{System.unique_integer([:positive])}", "name" => "테스트 품목",
        "item_type" => "product", "unit" => "EA"},
      overrides
    )
  end

  describe "품목 생성 / AuditLog" do
    test "유효한 품목을 생성하고 item.create AuditLog 1건을 남긴다" do
      assert {:ok, %Item{} = item} = MasterData.create_item(item_attrs(), @actor)
      assert item.active == true

      logs = Repo.all(AuditLog)
      assert [%AuditLog{action: "item.create", resource_type: "item"} = log] = logs
      assert log.resource_id == item.id
      assert log.before == nil
      assert log.after["item_type"] == "product"
      assert log.actor_id == @actor
    end

    test "잘못된 item_type 은 거부된다" do
      assert {:error, cs} = MasterData.create_item(item_attrs(%{"item_type" => "invalid"}), @actor)
      assert "허용되지 않은 품목 유형입니다" in errors_on(cs).item_type
      # 실패 시 AuditLog 도 롤백되어 0건
      assert Repo.all(AuditLog) == []
    end

    test "item_code 중복은 거부된다" do
      attrs = item_attrs(%{"item_code" => "DUP-1"})
      assert {:ok, _} = MasterData.create_item(attrs, @actor)
      assert {:error, cs} = MasterData.create_item(attrs, @actor)
      assert "이미 존재하는 품목 코드입니다" in errors_on(cs).item_code
    end
  end

  describe "품목 수정 / AuditLog before·after" do
    test "수정 시 before/after 스냅샷을 담은 item.update AuditLog 를 남긴다" do
      {:ok, item} = MasterData.create_item(item_attrs(%{"name" => "원래이름"}), @actor)

      assert {:ok, updated} = MasterData.update_item(item.id, %{"name" => "변경이름"}, @actor)
      assert updated.name == "변경이름"

      [update_log] = Repo.all(from l in AuditLog, where: l.action == "item.update")
      assert update_log.before["name"] == "원래이름"
      assert update_log.after["name"] == "변경이름"
    end

    test "비활성화(active=false)도 update 경로로 AuditLog 를 남긴다" do
      {:ok, item} = MasterData.create_item(item_attrs(), @actor)
      assert {:ok, updated} = MasterData.update_item(item.id, %{"active" => false}, @actor)
      assert updated.active == false
      assert Repo.exists?(from l in AuditLog, where: l.action == "item.update")
    end

    test "존재하지 않는 품목 수정은 not_found" do
      assert {:error, :not_found} = MasterData.update_item(Ecto.UUID.generate(), %{}, @actor)
    end
  end

  describe "BOM / Routing FK 및 제약" do
    test "BOM 은 부모-자식 동일 품목을 거부한다" do
      {:ok, item} = MasterData.create_item(item_attrs(), @actor)

      assert {:error, cs} =
               MasterData.create_bom(
                 %{"parent_item_id" => item.id, "child_item_id" => item.id, "quantity" => 1},
                 @actor
               )

      assert errors_on(cs).child_item_id != []
    end

    test "정상 BOM 생성 + bill_of_material.create AuditLog" do
      {:ok, parent} = MasterData.create_item(item_attrs(%{"item_type" => "product"}), @actor)
      {:ok, child} = MasterData.create_item(item_attrs(%{"item_type" => "raw"}), @actor)

      assert {:ok, bom} =
               MasterData.create_bom(
                 %{"parent_item_id" => parent.id, "child_item_id" => child.id,
                   "quantity" => 2, "loss_rate" => "0.1"},
                 @actor
               )

      assert bom.id
      assert Repo.exists?(from l in AuditLog, where: l.action == "bill_of_material.create")
    end
  end
end
