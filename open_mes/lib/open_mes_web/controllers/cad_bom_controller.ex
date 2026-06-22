defmodule OpenMesWeb.Addons.CadBomController do
  @moduledoc """
  CAD 견적 BOM 다운로드 컨트롤러.

  LiveView 화면(`CadBomLive`)의 다운로드 폼이 붙여넣은 CAD 인덱스 텍스트(`cad_index`)와
  대상(`kind`: "통합" 또는 공정명)을 POST 한다. 무상태 — 받은 텍스트를 그때 파싱해 CSV 로 돌려준다.

  POST 인 이유: 붙여넣은 인덱스가 길 수 있어 쿼리스트링(GET) 대신 본문으로 보낸다.
  `:browser` 파이프라인의 CSRF 보호를 받으므로 폼에 토큰이 포함된다(LiveView `<.form>` 자동).

  읽기/변환 전용: 도메인 쓰기 없음. AuditLog/Outbox 무관.
  """
  use OpenMesWeb, :controller

  alias OpenMes.Addons.CadBom

  def download(conn, params) do
    if CadBom.enabled?() do
      text = Map.get(params, "cad_index", "")
      kind = Map.get(params, "kind", "통합")

      csv =
        case kind do
          "통합" -> CadBom.to_integrated_csv(text)
          process -> CadBom.to_quote_csv(text, process)
        end

      conn
      |> send_download({:binary, IO.iodata_to_binary(csv)},
        filename: CadBom.filename(kind),
        charset: "utf-8"
      )
    else
      conn |> put_status(:not_found) |> text("CAD 견적 BOM 애드온이 비활성화되어 있습니다.")
    end
  end
end
