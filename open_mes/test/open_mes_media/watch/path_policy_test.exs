defmodule OpenMes.Media.Watch.PathPolicyTest do
  use ExUnit.Case, async: true

  alias OpenMes.Media.Watch.PathPolicy

  describe "규약 경로 도출" do
    test "{root}/{eqp}/{type}/{date}/{file} 에서 equipment_id/media_type/captured_at 도출" do
      result =
        PathPolicy.derive("/nas/cctv/EQP-01/video/2026-06-13/cam1_080000.mp4", "/nas/cctv")

      assert result.equipment_id == "EQP-01"
      assert result.media_type == "video"
      assert result.captured_at == ~U[2026-06-13 00:00:00.000000Z]
      assert result.meta["conforms_to_convention"] == true
    end

    test "audio 규약 경로" do
      result = PathPolicy.derive("/nas/EQP-02/audio/2026-06-13/noise.wav", "/nas")
      assert result.equipment_id == "EQP-02"
      assert result.media_type == "audio"
    end
  end

  describe "확장자 분류" do
    test "확장자로 media_type 1차 분류" do
      assert PathPolicy.classify_by_ext("/x/a.wav") == "audio"
      assert PathPolicy.classify_by_ext("/x/a.mp4") == "video"
      assert PathPolicy.classify_by_ext("/x/a.png") == "image"
      assert PathPolicy.classify_by_ext("/x/a.unknown") == nil
    end
  end

  describe "비규약 경로 — 데이터 버리지 않음" do
    test "media_type 세그먼트가 없으면 첫 세그먼트를 설비로 추정 + conforms=false + 확장자로 type 폴백" do
      result = PathPolicy.derive("/nas/EQP-99/randomdir/file.mp4", "/nas")
      assert result.equipment_id == "EQP-99"
      # 경로 type 누락 → 확장자(mp4)로 폴백
      assert result.media_type == "video"
      assert result.meta["conforms_to_convention"] == false
      assert result.meta["source_path"] == "/nas/EQP-99/randomdir/file.mp4"
    end

    test "완전 비규약(세그먼트 없음)은 unknown 으로 등록 + 원본 경로 meta 보존" do
      result = PathPolicy.derive("file.mp4", "")
      assert result.equipment_id == "unknown"
      assert result.meta["source_path"] == "file.mp4"
    end

    test "경로 type 과 확장자 불일치는 경로 우선 + meta 에 mismatch 기록" do
      # 경로상 audio 인데 파일은 .mp4(video)
      result = PathPolicy.derive("/nas/EQP-01/audio/2026-06-13/clip.mp4", "/nas")
      assert result.media_type == "audio"
      assert result.meta["media_type_mismatch"] == true
    end
  end
end
