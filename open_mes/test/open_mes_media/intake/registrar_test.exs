defmodule OpenMes.Media.Intake.RegistrarTest do
  @moduledoc """
  멱등 등록 검증(§7.5, §7.3 멱등성 명시 검증).
  EXT-1 WorkOrder 멱등 전이 버그 교훈 — 같은 파일 N회 스캔 → row 1개를 명시적으로 테스트.
  """
  use OpenMes.DataCase, async: true

  alias OpenMes.Media.Intake.Registrar
  alias OpenMes.Media.MediaAsset

  @root "/nas"
  @mtime ~U[2026-06-13 08:00:00.000000Z]

  defp file(path, size, mtime), do: %{path: path, size: size, mtime: mtime}

  test "안정화 파일 1건은 detected 로 등록된다" do
    f = file("/nas/EQP-01/video/2026-06-13/cam1.mp4", 1_000, @mtime)
    assert {:ok, :inserted, asset} = Registrar.register(f, root: @root)
    assert asset.state == "detected"
    assert asset.equipment_id == "EQP-01"
    assert asset.media_type == "video"
    # object_key 가 등록 시점에 확정되고 asset_id 를 포함(멱등 재업로드 보장)
    assert asset.object_key =~ asset.id
    assert Repo.aggregate(MediaAsset, :count) == 1
  end

  test "같은 (path,mtime,size) 를 N회 등록해도 row 는 1개 (멱등 — on_conflict:nothing)" do
    f = file("/nas/EQP-01/video/2026-06-13/cam1.mp4", 1_000, @mtime)

    assert {:ok, :inserted, _} = Registrar.register(f, root: @root)
    # 같은 파일을 다시 스캔한 상황 — 조용히 skip
    assert {:ok, :skipped} = Registrar.register(f, root: @root)
    assert {:ok, :skipped} = Registrar.register(f, root: @root)
    assert {:ok, :skipped} = Registrar.register(f, root: @root)

    assert Repo.aggregate(MediaAsset, :count) == 1
  end

  test "같은 path 라도 mtime 이 다르면(덮어쓰기) 새 row 로 등록된다" do
    path = "/nas/EQP-01/video/2026-06-13/cam1.mp4"
    assert {:ok, :inserted, _} = Registrar.register(file(path, 1_000, @mtime), root: @root)

    new_mtime = ~U[2026-06-13 09:00:00.000000Z]
    assert {:ok, :inserted, _} = Registrar.register(file(path, 2_000, new_mtime), root: @root)

    assert Repo.aggregate(MediaAsset, :count) == 2
  end

  test "비규약 경로도 버리지 않고 unknown 으로 등록된다" do
    f = file("/nas/weird/file.mp4", 500, @mtime)
    assert {:ok, :inserted, asset} = Registrar.register(f, root: @root)
    assert asset.equipment_id in ["weird", "unknown"]
    assert asset.meta["source_path"] == "/nas/weird/file.mp4"
  end
end
