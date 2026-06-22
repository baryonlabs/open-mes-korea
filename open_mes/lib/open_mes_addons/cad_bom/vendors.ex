defmodule OpenMes.Addons.CadBom.Vendors do
  @moduledoc """
  발주 공정 → **업체 후보** 시드(과거데이터 대체 전 시작점).

  사용자가 과거 거래처 데이터를 넣기 전까지, 공정별로 견적 의뢰할 만한 후보를 제시한다.
  실재하는 외주 플랫폼·표준품 유통을 앵커로 두고, 나머지는 사용자가 실거래처로 교체/추가한다.
  (설계: 시드로 시작 → 추후 과거 BOM·거래 이력으로 학습 교체)

  반환 후보: %{name, note, url}. 화면에서 칩으로 보여주고 다중 선택 + 직접 입력을 허용한다.
  """

  # 모든 가공/판금 공정에 공통 후보(임가공 매칭 플랫폼)
  @platform %{name: "CAPA", note: "임가공 매칭 플랫폼(가공·판금·레이저)", url: "https://capa.ai"}

  @seed %{
    "가공외주" => [
      %{name: "사내 가공실", note: "내부 CNC/머시닝", url: ""},
      %{name: "정밀가공 거래처 A", note: "시드 — 실거래처로 교체", url: ""}
    ],
    "레이저절단" => [
      %{name: "레이저절단 거래처 A", note: "판금 레이저(시드)", url: ""}
    ],
    "커팅" => [
      %{name: "판금 커팅 거래처 A", note: "시드", url: ""}
    ],
    "절곡" => [
      %{name: "절곡 거래처 A", note: "시드", url: ""}
    ],
    "용접" => [
      %{name: "용접 외주 A", note: "시드", url: ""}
    ],
    "부품제작/구매" => [
      %{name: "부품제작 거래처 A", note: "시드", url: ""}
    ],
    "표준품구매" => [
      %{name: "MISUMI Korea", note: "표준부품(볼트·베어링 등) 통판", url: "https://kr.misumi-ec.com"},
      %{name: "볼트/체결 유통 A", note: "시드", url: ""}
    ],
    "승인도(참고)" => [],
    "기타" => []
  }

  @doc "공정명 → 업체 후보 리스트(공통 플랫폼 포함). 견적 대상 공정만 플랫폼 추가."
  @spec candidates(String.t()) :: [map()]
  def candidates(process) do
    base = Map.get(@seed, process, [])

    if process in ["승인도(참고)", "기타"] do
      base
    else
      base ++ [@platform]
    end
  end

  @doc "전체 공정의 후보 맵(공정 => [후보])."
  @spec all([String.t()]) :: %{optional(String.t()) => [map()]}
  def all(processes) do
    Map.new(processes, fn p -> {p, candidates(p)} end)
  end
end
