defmodule OpenMes.Addons.CadBom.Csv do
  @moduledoc """
  통합 BOM / 공정별 견적 BOM → CSV 직렬화(순수 함수, deps 0).

  - RFC 4180 이스케이프(쉼표/따옴표/개행 → 따옴표 감싸기, 내부 `"` 이중화), 행구분 CRLF.
  - 엑셀 한글 호환을 위해 선두에 UTF-8 BOM(`\\uFEFF`)을 붙인다.
  - 견적 BOM 은 `단가`·`금액` 컬럼을 비워 보내 업체가 채워 회신하도록 한다.
  """

  # 엑셀이 UTF-8 을 자동 인식하도록 BOM
  @bom "﻿"

  @integrated_headers ~w(품번 품명 분류 발주공정 수량 재질 규격 발주처 모델)
  @quote_headers ~w(품번 품명 규격 재질 수량 단가 금액 비고)

  @doc "통합 BOM 전체를 CSV(iodata)로."
  @spec integrated([map()]) :: iodata()
  def integrated(rows) do
    body =
      Enum.map(rows, fn r ->
        encode_row([
          r.품번,
          r.품명,
          r.분류,
          r.공정,
          r.수량,
          r.재질,
          r.규격,
          r.발주처,
          r.모델
        ])
      end)

    [@bom, encode_row(@integrated_headers) | body]
  end

  @doc "한 공정(업체)용 견적 BOM 을 CSV(iodata)로. 단가/금액은 빈칸."
  @spec quote_group([map()], String.t()) :: iodata()
  def quote_group(rows, _process) do
    body =
      Enum.map(rows, fn r ->
        encode_row([r.품번, r.품명, r.규격, r.재질, r.수량, "", "", ""])
      end)

    [@bom, encode_row(@quote_headers) | body]
  end

  # ── RFC 4180 ────────────────────────────────────────────────
  defp encode_row(fields), do: [Enum.map_join(fields, ",", &escape/1), "\r\n"]

  defp escape(value) do
    s = to_string(value)

    if String.contains?(s, [",", "\"", "\r", "\n"]) do
      "\"" <> String.replace(s, "\"", "\"\"") <> "\""
    else
      s
    end
  end
end
