defmodule OpenMes.Addons.CadBom do
  @moduledoc """
  CAD 견적 BOM 애드온 — 퍼사드(공개 진입점).

  목적:
    CAD 도면 인덱스(도번·도면명·분류·수량·재질·규격 — 도면 분리 파이프라인의 `_index.csv`)를 받아
      ① **통합 BOM**: 도면들에 흩어진 부품을 도번 기준으로 합치고 수량을 합산
      ② **부품 분류**: 각 부품의 발주 공정(가공외주/레이저절단/표준품구매/부품제작/승인도)을 판정
      ③ **업체(공정)별 견적 BOM**: 공정별로 묶어 견적 의뢰용 CSV(단가/금액 빈칸) 생성

  성격(코어 비침투, pi 원칙):
    - **새 DB 테이블 0**: 입력 텍스트를 그때그때 파싱하는 무상태(stateless) 처리. 쓰기/AuditLog 없음.
    - 코어 컨텍스트 수정 0. 순수 함수 모듈(`Parser`/`Classifier`/`Csv`)로만 구성.
    - config on/off 게이트. 읽기/변환 전용이라 운영상 안전.
  """

  alias OpenMes.Addons.CadBom.{Parser, Classifier, Csv}

  @doc """
  애드온 활성 여부(config 게이트).

      config :open_mes, OpenMes.Addons.CadBom, enabled: true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :open_mes
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, false)
    |> case do
      true -> true
      _ -> false
    end
  end

  @doc """
  CAD 인덱스 텍스트를 분석한다.

  반환:
      %{
        rows: [통합 BOM 행(공정 포함)],
        by_process: [%{공정, 건수, 수량}],   # 공정별 집계
        total: 통합 BOM 품번 수
      }
  """
  @spec analyze(String.t()) :: %{rows: [map()], by_process: [map()], total: non_neg_integer()}
  def analyze(text) when is_binary(text) do
    rows =
      text
      |> Parser.parse()
      |> Enum.map(&Map.put(&1, :공정, Classifier.process(&1)))
      |> integrate()

    %{rows: rows, by_process: group_summary(rows), total: length(rows)}
  end

  @doc "통합 BOM 전체 CSV(iodata)."
  @spec to_integrated_csv(String.t()) :: iodata()
  def to_integrated_csv(text), do: text |> analyze() |> Map.fetch!(:rows) |> Csv.integrated()

  @doc "특정 공정(업체) 견적 BOM CSV(iodata)."
  @spec to_quote_csv(String.t(), String.t()) :: iodata()
  def to_quote_csv(text, process) do
    text
    |> analyze()
    |> Map.fetch!(:rows)
    |> Enum.filter(&(&1.공정 == process))
    |> Csv.quote_group(process)
  end

  @doc "다운로드 파일명. kind 는 \"통합\" 또는 공정명."
  @spec filename(String.t(), DateTime.t()) :: String.t()
  def filename(kind, now \\ DateTime.utc_now()) do
    stamp = now |> DateTime.truncate(:second) |> Calendar.strftime("%Y%m%d_%H%M%S")
    safe = kind |> String.replace(~r/[^\p{L}\p{N}]+/u, "_") |> String.trim("_")
    "BOM_#{safe}_#{stamp}.csv"
  end

  @doc "데모용 샘플 CAD 인덱스(드림텍 CNC HAND 개조 일부)."
  @spec sample() :: String.t()
  def sample do
    """
    도번,도면명,분류,수량,재질,규격,발주처,모델
    CMK-DRS1-STND-000,SHAFT HAND ASSY,승인도,1,,,드림텍,CNC HAND
    DRNT-CNJG-003,BRACKET,가공품,2,SS400,,드림텍,CNC HAND
    DRNT-MCH-021,GUIDE BLOCK,가공품,2,AL6061,,드림텍,CNC HAND
    DRNT-LSR-010,BASE PLATE,레이저,1,SPCC,t3.0 300x200,드림텍,CNC HAND
    DRNT-LSR-011,COVER,추가 레이저,1,SPCC,t2.0 250x180,드림텍,CNC HAND
    ATC-DAI-PIN-1,PIN-1,부품도,4,SUS304,Ø8x40,드림텍,CNC HAND
    ATC-DAI-PIN-2,PIN-2,부품도,4,SUS304,Ø10x50,드림텍,CNC HAND
    STD-BOLT-M6,HEX BOLT M6x20,부품도,20,,M6x20,드림텍,CNC HAND
    """
  end

  # ── 통합 BOM: 품번 기준 중복 합치고 수량 합산 ──────────────────
  defp integrate(rows) do
    rows
    |> Enum.group_by(&dedup_key/1)
    |> Enum.map(fn {_key, group} ->
      base = hd(group)
      %{base | 수량: group |> Enum.map(& &1.수량) |> Enum.sum()}
    end)
    |> Enum.sort_by(&{process_order(&1.공정), &1.공정, &1.품번})
  end

  # 품번이 있으면 품번으로, 없으면 품명으로 묶는다(공란 품번끼리 잘못 합쳐지지 않게).
  defp dedup_key(%{품번: "", 품명: name}), do: {:name, name}
  defp dedup_key(%{품번: pn}), do: {:pn, pn}

  defp group_summary(rows) do
    rows
    |> Enum.group_by(& &1.공정)
    |> Enum.map(fn {proc, g} ->
      %{공정: proc, 건수: length(g), 수량: g |> Enum.map(& &1.수량) |> Enum.sum()}
    end)
    |> Enum.sort_by(&{process_order(&1.공정), &1.공정})
  end

  # 표시·정렬 순서(견적 대상 공정 먼저, 참고는 뒤로).
  @order %{
    "가공외주" => 0,
    "레이저절단" => 1,
    "부품제작/구매" => 2,
    "표준품구매" => 3,
    "기타" => 8,
    "승인도(참고)" => 9
  }
  defp process_order(proc), do: Map.get(@order, proc, 5)
end
