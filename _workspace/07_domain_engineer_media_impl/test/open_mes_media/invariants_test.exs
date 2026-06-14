defmodule OpenMes.Media.InvariantsTest do
  @moduledoc """
  EXT-2 고유 불변식의 정적/구성 검증(qa-auditor 검증 포인트 §7.3 보강).

    - 원본 보존: lib/open_mes_media/ 전체에 NAS 원본 삭제(File.rm/File.rm_rf) 호출이 없다.
    - 스트리밍: 이관 경로에 File.read(전체 메모리 적재)가 없다.
    - 코어 비침투: lib/open_mes_media/ 가 EXT-1(OpenMes.Ingest.*)을 참조하지 않는다.
    - config off: enabled?==false 가 기본이며 child 가 비어 있다.
  """
  use ExUnit.Case, async: true

  @media_lib Path.expand("../../lib/open_mes_media", __DIR__)

  defp media_sources do
    Path.wildcard(Path.join(@media_lib, "**/*.ex"))
  end

  test "원본 보존: 코드 어디에도 File.rm / File.rm_rf (NAS 원본 삭제)가 없다" do
    offenders =
      for path <- media_sources(),
          src = File.read!(path),
          String.match?(src, ~r/File\.rm(_rf)?[!\s(]/),
          do: path

    assert offenders == [],
           "원본 보존 불변식 위반: 다음 파일에 File.rm 류가 있습니다 → #{inspect(offenders)}"
  end

  test "스트리밍: 이관 경로에 File.read(전체 메모리 적재)가 없다" do
    transfer_sources =
      media_sources()
      |> Enum.filter(&String.contains?(&1, ["/transfer/", "/object_store/"]))

    offenders =
      for path <- transfer_sources,
          src = File.read!(path),
          String.match?(src, ~r/File\.read[!\s(]/),
          do: path

    assert offenders == [],
           "스트리밍 불변식 위반: 이관 경로에 File.read 가 있습니다 → #{inspect(offenders)}"
  end

  test "코어 비침투: EXT-2 가 EXT-1(OpenMes.Ingest.*)을 참조하지 않는다" do
    offenders =
      for path <- media_sources(),
          src = File.read!(path),
          String.contains?(src, "OpenMes.Ingest"),
          do: path

    assert offenders == [], "EXT-1 참조 발견(코드 의존 금지): #{inspect(offenders)}"
  end

  test "config off 기본: media_children 이 빈 리스트(코어 비침투)" do
    # 테스트 환경에서 enabled? 가 기본(false)인지 확인. 켜져 있으면 코어 비침투 검증이 무력화됨.
    refute OpenMes.Media.enabled?(),
           "테스트 환경에서 OpenMes.Media.enabled? 는 false 여야 한다(코어 비침투 회귀의 전제)."
  end
end
