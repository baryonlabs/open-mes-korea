defmodule OpenMes.Addons.CadBom.Xlsx do
  @moduledoc """
  최소 XLSX(엑셀) 생성기 — 외부 deps 0(Erlang `:zip` + 수기 XML, pi 원칙).

  XLSX 는 정해진 XML 파일들의 zip 이다. 문자열은 inline string(`t="inlineStr"`)으로 넣어
  sharedStrings 를 생략한다(단순·정확). 정수 셀은 숫자로, 그 외는 문자열로 출력한다.

  사용: `OpenMes.Addons.CadBom.Xlsx.build("BOM", ["품번","품명",...], [["A","B",1], ...])` → xlsx 바이너리.
  """

  @doc "헤더 + 행(2차원 리스트)으로 단일 시트 xlsx 바이너리를 만든다."
  @spec build(String.t(), [String.t()], [[term()]]) :: binary()
  def build(sheet_name, headers, rows) do
    all = [headers | rows]
    sheet = sheet_xml(all)

    files = [
      {~c"[Content_Types].xml", content_types()},
      {~c"_rels/.rels", root_rels()},
      {~c"xl/workbook.xml", workbook(sheet_name)},
      {~c"xl/_rels/workbook.xml.rels", workbook_rels()},
      {~c"xl/worksheets/sheet1.xml", sheet}
    ]

    {:ok, {_name, bin}} = :zip.create(~c"bom.xlsx", files, [:memory])
    bin
  end

  defp sheet_xml(rows) do
    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {cells, r} -> row_xml(cells, r) end)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <sheetData>#{body}</sheetData></worksheet>
    """
  end

  defp row_xml(cells, r) do
    cs =
      cells
      |> Enum.with_index()
      |> Enum.map_join("", fn {v, c} -> cell_xml(v, ref(c, r)) end)

    "<row r=\"#{r}\">#{cs}</row>"
  end

  defp cell_xml(v, ref) when is_integer(v), do: "<c r=\"#{ref}\"><v>#{v}</v></c>"

  defp cell_xml(v, ref) do
    text = v |> to_string() |> esc()
    "<c r=\"#{ref}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">#{text}</t></is></c>"
  end

  # 0-based col, 1-based row → A1 참조
  defp ref(col, row), do: col_letter(col) <> Integer.to_string(row)

  defp col_letter(n) do
    # 0→A, 25→Z, 26→AA …
    do_col(n, [])
  end

  defp do_col(n, acc) do
    rem = rem(n, 26)
    acc = [<<?A + rem>> | acc]
    div = div(n, 26) - 1
    if div < 0, do: IO.iodata_to_binary(acc), else: do_col(div, acc)
  end

  defp esc(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp content_types do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
    """
  end

  defp root_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
    """
  end

  defp workbook(name) do
    safe = name |> esc() |> String.slice(0, 31)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
    <sheets><sheet name="#{safe}" sheetId="1" r:id="rId1"/></sheets></workbook>
    """
  end

  defp workbook_rels do
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
    """
  end
end
