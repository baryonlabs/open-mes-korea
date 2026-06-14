defmodule OpenMes.Media.ObjectStore.KeyBuilder do
  @moduledoc """
  object storage object key 생성 규칙 — 순수 함수. (EXT-2 §3.3)

  key 규약: `{media_type}/{equipment_id}/{yyyy}/{mm}/{dd}/{asset_id}_{원본파일명}`
    예) `video/EQP-01/2026/06/13/3f2a..._cam1_080000.mp4`

  핵심:
    - `asset_id`(media_asset PK UUID)를 포함해 **동일 파일명 충돌을 원천 차단**한다
      (같은 분에 두 cam1 이 와도 다른 key).
    - 날짜 세그먼트는 captured_at(있으면) 우선, 없으면 inserted_at/now 로 폴백.
    - key 는 등록 시점에 결정해 `media_assets.object_key` 에 저장 → 이관 워커가
      그대로 사용한다. 재시도해도 같은 key = **멱등 업로드**.
  """

  @doc """
  asset 메타로 object key 를 만든다.

    * `asset_id`     — media_asset PK(UUID 문자열)
    * `media_type`   — audio/video/image
    * `equipment_id` — 출처 설비
    * `nas_path`     — 원본 경로(파일명 추출용)
    * `at`           — 날짜 세그먼트 기준 시각(보통 captured_at 또는 now)
  """
  def build(asset_id, media_type, equipment_id, nas_path, %DateTime{} = at) do
    filename = nas_path |> Path.basename() |> sanitize()
    yyyy = pad(at.year, 4)
    mm = pad(at.month, 2)
    dd = pad(at.day, 2)

    "#{media_type}/#{equipment_id}/#{yyyy}/#{mm}/#{dd}/#{asset_id}_#{filename}"
  end

  # object key 에 안전하지 않은 문자를 보수적으로 치환(공백/제어문자 등).
  defp sanitize(name) do
    name
    |> String.replace(~r/\s+/u, "_")
    |> String.replace(~r/[^\w.\-가-힣]/u, "_")
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")
end
