defmodule OpenMes.Media.Watch.PathPolicy do
  @moduledoc """
  NAS 경로 → equipment_id / media_type 도출 — 순수 함수 모듈.

  설계 근거: `_workspace/05_architect_media_ingest_design.md` §2.5.

  디바이스 무수정이므로 경로 규약으로 메타데이터를 얻는다.

  규약(예시): `/{root}/{equipment_id}/{media_type}/{yyyy-mm-dd}/{filename}`
    예) `/nas/cctv/EQP-01/video/2026-06-13/cam1_080000.mp4`
        → equipment_id="EQP-01", media_type="video"

  핵심 원칙(데이터를 버리지 않음):
    - 매핑 불가 경로도 버리지 않는다. equipment_id="unknown" 으로 등록하고
      meta 에 원본 경로/사유를 보존한다(나중에 수동 재매핑 가능).
    - media_type 은 확장자 1차 분류 + 경로 규약 보강. 불일치 시 경로 우선 + meta 기록.
    - EXT-1 equipment_measurements.equipment_id 와 동일 식별자 규약을 따른다(§2.5).
  """

  @audio_exts ~w(.wav .flac .mp3 .aac .ogg .m4a)
  @video_exts ~w(.mp4 .avi .mov .mkv .webm .mpg .mpeg)
  @image_exts ~w(.jpg .jpeg .png .bmp .tiff .tif .gif)

  @media_types ~w(audio video image)

  @doc """
  watch root 기준 상대경로(또는 절대경로)에서 메타데이터를 도출한다.

    * `nas_path` — 파일 절대경로
    * `root`     — 이 파일이 속한 watch root(상대경로 추출용). 빈 문자열이면 전체 경로로 추론.

  반환: `%{equipment_id, media_type, captured_at, meta}`
    - `captured_at` 은 경로의 날짜 세그먼트에서 파싱되면 채우고, 안 되면 nil.
    - `meta` 는 원본 경로, 분류 근거, 비규약 여부 등 보존 정보.
  """
  def derive(nas_path, root \\ "") when is_binary(nas_path) do
    rel = relative(nas_path, root)
    segments = rel |> Path.split() |> Enum.reject(&(&1 in ["", "/", "."]))
    ext_type = classify_by_ext(nas_path)

    {equipment_id, path_type, date_seg, conforms?} = parse_segments(segments)

    # media_type 결정: 경로 규약 우선, 없으면 확장자 분류, 둘 다 없으면 확장자.
    media_type = path_type || ext_type || "image"

    meta =
      %{
        "source_path" => nas_path,
        "ext_media_type" => ext_type,
        "path_media_type" => path_type,
        "conforms_to_convention" => conforms?
      }
      |> maybe_put_mismatch(path_type, ext_type)

    %{
      equipment_id: equipment_id,
      media_type: media_type,
      captured_at: parse_date(date_seg),
      meta: meta
    }
  end

  @doc "확장자 기반 media_type 1차 분류. 미분류 시 nil."
  def classify_by_ext(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext in @audio_exts -> "audio"
      ext in @video_exts -> "video"
      ext in @image_exts -> "image"
      true -> nil
    end
  end

  # 규약 `{equipment_id}/{media_type}/{yyyy-mm-dd}/{filename}` 파싱.
  # 세그먼트가 규약을 만족하면 {equipment_id, media_type, date, true},
  # 아니면 가능한 만큼 추론하되 conforms?=false.
  defp parse_segments([eqp, mtype, date, _file | _rest]) when mtype in @media_types do
    {eqp, mtype, date, true}
  end

  defp parse_segments([eqp, mtype, _file]) when mtype in @media_types do
    {eqp, mtype, nil, true}
  end

  defp parse_segments([eqp | _rest]) when is_binary(eqp) and eqp != "" do
    # 첫 세그먼트를 설비로 추정하되 규약 미충족(media_type 세그먼트 누락/불일치).
    {eqp, nil, nil, false}
  end

  defp parse_segments(_), do: {"unknown", nil, nil, false}

  # 경로 규약 media_type 과 확장자 분류가 다르면 meta 에 명시(데이터 진단용).
  defp maybe_put_mismatch(meta, path_type, ext_type)
       when is_binary(path_type) and is_binary(ext_type) and path_type != ext_type do
    Map.put(meta, "media_type_mismatch", true)
  end

  defp maybe_put_mismatch(meta, _, _), do: meta

  # root 기준 상대경로 추출. root 가 비었거나 접두가 아니면 원본 경로 그대로.
  defp relative(nas_path, root) when root in [nil, ""], do: nas_path

  defp relative(nas_path, root) do
    if String.starts_with?(nas_path, root) do
      nas_path
      |> String.replace_prefix(root, "")
      |> String.trim_leading("/")
    else
      nas_path
    end
  end

  # "2026-06-13" → ~U[2026-06-13 00:00:00.000000Z]. 파싱 실패 시 nil(데이터 버리지 않고 nil).
  defp parse_date(nil), do: nil

  defp parse_date(seg) when is_binary(seg) do
    case Date.from_iso8601(seg) do
      {:ok, date} -> DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
      _ -> nil
    end
  end
end
