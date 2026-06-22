defmodule OpenMes.Addons.CadBom.Classifier do
  @moduledoc """
  부품 행 → **발주 공정(업체 유형)** 분류(순수 함수).

  CAD 도면의 분류(부품도/가공품/레이저/승인도…)와 도면명·재질을 보고, 그 부품을 어떤
  업체(공정)에 견적 의뢰할지 정한다. 견적 BOM 을 공정별로 묶는 기준이 된다.

  결과 공정:
    - `레이저절단`     — 판금 레이저 절단(분류에 "레이저")
    - `표준품구매`     — 볼트/너트/베어링 등 규격품(도면명 키워드)
    - `가공외주`       — 절삭/밀링 가공품(분류 "가공" 또는 재질 있는 가공 부품)
    - `부품제작/구매`  — 일반 부품도
    - `승인도(참고)`   — 승인도(견적 대상 아님, 참고)
    - `기타`           — 위 어디에도 안 맞음
  """

  @standard ~w(BOLT NUT WASHER SCREW BEARING SPRING O-RING ORING GASKET)

  @doc "한 부품 행의 발주 공정을 판정한다."
  @spec process(map()) :: String.t()
  def process(%{분류: cls, 품명: name, 재질: mat}) do
    c = to_string(cls)
    n = name |> to_string() |> String.upcase()
    m = to_string(mat)

    cond do
      String.contains?(c, "레이저") -> "레이저절단"
      String.contains?(c, ["커팅", "절단"]) -> "커팅"
      String.contains?(c, "절곡") -> "절곡"
      String.contains?(c, "용접") -> "용접"
      standard_part?(n) -> "표준품구매"
      String.contains?(c, "가공") -> "가공외주"
      String.contains?(c, "승인") -> "승인도(참고)"
      String.contains?(c, "부품") -> "부품제작/구매"
      m != "" -> "가공외주"
      true -> "기타"
    end
  end

  defp standard_part?(name), do: Enum.any?(@standard, &String.contains?(name, &1))
end
