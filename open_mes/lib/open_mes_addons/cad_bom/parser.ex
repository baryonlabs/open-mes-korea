defmodule OpenMes.Addons.CadBom.Parser do
  @moduledoc """
  CAD 도면 인덱스 텍스트(CSV/TSV) → 부품 행 리스트(순수 함수).

  입력은 CAD 분리 파이프라인이 만든 `_index.csv` 같은 형식이다(도번·도면명·분류·수량·재질·규격·발주처·모델).
  헤더가 있으면 별칭으로 매핑하고, 없으면 기본 컬럼 순서로 읽는다. 외부 CSV deps 0(pi 원칙).

  - 구분자: 행에 탭이 있으면 TSV, 아니면 CSV(쉼표).
  - 따옴표로 감싼 필드는 단순 처리(앞뒤 따옴표 제거 + `""` → `"`).
  """

  @canonical ~w(품번 품명 분류 수량 재질 규격 발주처 모델)a

  @aliases %{
    "도번" => :품번,
    "품번" => :품번,
    "도면번호" => :품번,
    "drawing_no" => :품번,
    "도면명" => :품명,
    "품명" => :품명,
    "name" => :품명,
    "title" => :품명,
    "분류" => :분류,
    "구분" => :분류,
    "소스" => :분류,
    "type" => :분류,
    "category" => :분류,
    "수량" => :수량,
    "qty" => :수량,
    "q'ty" => :수량,
    "quantity" => :수량,
    "재질" => :재질,
    "material" => :재질,
    "matl" => :재질,
    "규격" => :규격,
    "spec" => :규격,
    "size" => :규격,
    "dimension" => :규격,
    "발주처" => :발주처,
    "고객" => :발주처,
    "customer" => :발주처,
    "모델" => :모델,
    "model" => :모델,
    "machine" => :모델
  }

  @type row :: %{
          품번: String.t(),
          품명: String.t(),
          분류: String.t(),
          수량: pos_integer(),
          재질: String.t(),
          규격: String.t(),
          발주처: String.t(),
          모델: String.t()
        }

  @doc "CAD 인덱스 텍스트를 부품 행 리스트로 파싱한다."
  @spec parse(String.t()) :: [row()]
  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.split(~r/\r\n|\r|\n/, trim: true)
      |> Enum.map(&split_cols/1)
      |> Enum.reject(&(&1 == [] or &1 == [""]))

    rows =
      case lines do
        [] ->
          []

        [first | rest] ->
          if header?(first) do
            keys = Enum.map(first, &header_key/1)
            Enum.map(rest, &row_to_map(&1, keys))
          else
            Enum.map(lines, &row_to_map(&1, @canonical))
          end
      end

    Enum.reject(rows, &blank_row?/1)
  end

  defp split_cols(line) do
    sep = if String.contains?(line, "\t"), do: "\t", else: ","

    line
    |> String.split(sep)
    |> Enum.map(&unquote_field/1)
  end

  defp unquote_field(field) do
    f = String.trim(field)

    if String.starts_with?(f, "\"") and String.ends_with?(f, "\"") and String.length(f) >= 2 do
      f |> String.slice(1..-2//1) |> String.replace("\"\"", "\"")
    else
      f
    end
  end

  defp header?(cols), do: Enum.any?(cols, &Map.has_key?(@aliases, normalize(&1)))
  defp header_key(col), do: Map.get(@aliases, normalize(col), :_ignore)
  defp normalize(s), do: s |> String.trim() |> String.downcase()

  defp row_to_map(cols, keys) do
    keys
    |> Enum.zip(cols)
    |> Enum.reduce(%{}, fn
      {:_ignore, _v}, acc -> acc
      {k, v}, acc -> Map.put(acc, k, v)
    end)
    |> normalize_row()
  end

  defp normalize_row(m) do
    %{
      품번: get(m, :품번),
      품명: get(m, :품명),
      분류: get(m, :분류),
      수량: qty(get(m, :수량)),
      재질: get(m, :재질),
      규격: get(m, :규격),
      발주처: get(m, :발주처),
      모델: get(m, :모델)
    }
  end

  defp get(m, k), do: m |> Map.get(k, "") |> to_string() |> String.trim()

  defp qty(""), do: 1

  defp qty(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp blank_row?(%{품번: "", 품명: ""}), do: true
  defp blank_row?(_), do: false
end
