defmodule OpenMesWeb.Addons.WoCsvExportController do
  @moduledoc """
  작업지시 CSV 다운로드 컨트롤러(읽기 전용).

  LiveView 화면(`WoCsvExportLive`)의 "CSV 다운로드" 링크가 이 액션으로 GET 한다.
  쿼리스트링의 필터(status/due_date 등)를 그대로 퍼사드에 넘겨 CSV 를 만들고
  `send_download` 로 첨부 파일로 응답한다.

  성격:
    - **읽기 전용**: 퍼사드(`OpenMes.Addons.WoCsvExport`)가 코어 조회 함수로 읽기만 한다.
      쓰기/AuditLog 없음. 단순 export 는 감사 대상이 아니다(설계 §2 애드온 ①).
    - **게이트**: 애드온이 비활성이면 404 로 응답한다(라우터에서도 컴파일 타임 게이트하지만,
      방어적으로 한 번 더 확인).
  """
  use OpenMesWeb, :controller

  alias OpenMes.Addons.WoCsvExport

  @doc """
  필터에 맞는 작업지시를 CSV 로 다운로드한다.

  쿼리 파라미터(모두 선택): `status`, `due_date`, `item_id`, `limit`, `offset`.
  퍼사드가 화이트리스트 + 빈 값 정리를 처리하므로 params 를 그대로 넘긴다.
  """
  def download(conn, params) do
    if WoCsvExport.enabled?() do
      csv = WoCsvExport.to_csv(params)

      conn
      |> put_resp_content_type("text/csv")
      |> send_download({:binary, IO.iodata_to_binary(csv)},
        filename: WoCsvExport.filename(),
        charset: "utf-8"
      )
    else
      conn
      |> put_status(:not_found)
      |> text("작업지시 CSV 내보내기 애드온이 비활성화되어 있습니다.")
    end
  end
end
