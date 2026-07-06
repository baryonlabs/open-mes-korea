defmodule OpenMes.Addons.WoCsvExport do
  @moduledoc """
  작업지시 CSV 내보내기 애드온 — 퍼사드(공개 진입점).

  목적:
    작업지시(WorkOrder) 목록을 CSV 로 내려받는다(현장 보고/엑셀 분석용).

  성격(설계 §2 애드온 ①):
    - **읽기 전용**: 코어 데이터는 `OpenMes.Production.list_work_orders/1`(공개 조회 함수)로
      읽기만 한다. 쓰기/DELETE/AuditLog 없음. 새 DB 테이블 0개.
    - **코어 비침투**: 코어 파일을 수정하지 않는다. 코어 의존은 Production 컨텍스트의
      공개 읽기 함수 1개뿐.
    - config on/off 게이트. 읽기 전용이므로 운영상 안전 → 기본 on 권장(config 가 관리).

  이 모듈은 게이트(`enabled?/0`)와 CSV 생성 위임만 담당한다. 실제 직렬화는
  `OpenMes.Addons.WoCsvExport.Csv` 가, behaviour 메타데이터는 `*.Extension` 이 담당한다.
  """

  alias OpenMes.Addons.WoCsvExport.Csv

  @doc """
  애드온 활성 여부(config 게이트).

      config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true

  값이 없으면 기본 false(비활성)로 본다. `*.Extension.enabled?/0` 가 이 함수에 위임한다.

  라우트 게이트 정합: `RouterMount` 매크로가 이 함수를 **컴파일 타임**에 호출하므로(현행
  `if X.enabled?()` 와 동일 시점), off 면 라우트 테이블에 흔적이 남지 않는다(설계 30 §2.1).
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
  주어진 필터로 작업지시를 조회해 CSV 본문(iodata)을 만든다.

  `filters` 는 `OpenMes.Production.list_work_orders/1` 와 동일한 문자열 키 맵이다
  (예: `%{"status" => "released", "due_date" => "2026-06-30"}`). 읽기 전용.

  반환: `iodata`(컨트롤러가 그대로 `send_download` / `Plug.Conn.send_resp` 에 넘긴다).
  """
  @spec to_csv(map()) :: iodata()
  def to_csv(filters \\ %{}) when is_map(filters) do
    filters
    |> sanitize_filters()
    |> OpenMes.Production.list_work_orders()
    |> Csv.encode_work_orders()
  end

  @doc "다운로드 파일명. 현재 시각 기준(예: work_orders_20260613_142530.csv)."
  @spec filename(DateTime.t()) :: String.t()
  def filename(now \\ DateTime.utc_now()) do
    stamp =
      now
      |> DateTime.truncate(:second)
      |> Calendar.strftime("%Y%m%d_%H%M%S")

    "work_orders_#{stamp}.csv"
  end

  # 화면/외부에서 들어온 필터를 안전한 화이트리스트로 제한한다.
  # (코어 조회 함수가 무시하긴 하지만, 의도를 명확히 하고 빈 문자열을 정리한다.)
  @allowed_filter_keys ~w(status item_id due_date limit offset)

  defp sanitize_filters(filters) do
    filters
    |> Enum.filter(fn {k, v} ->
      to_string(k) in @allowed_filter_keys and present?(v)
    end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
