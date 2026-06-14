defmodule OpenMesWeb.KnowledgeImportController do
  @moduledoc """
  OKF 지식베이스 가져오기 컨트롤러 — 설계 27번 §3.1.

  업로드한 OKF 번들(zip)을 언패킹(`:zip`, 외부 dep 0)해 파일맵으로 만들고
  `Bundle.import_bundle` → `Knowledge.import_documents`(AuditLog 동반)로 저장한다.

  **관용적 소비**: 미지 필드/깨진 링크/type 누락/누락 index 를 거부하지 않고 경고만
  flash 로 표시한다. import 는 항상 진행(절대 reject 0).
  """
  use OpenMesWeb, :controller

  alias OpenMes.Knowledge
  alias OpenMes.Okf.Bundle

  def import(conn, %{"bundle" => %Plug.Upload{path: path}} = params) do
    actor_id = Map.get(params, "actor_id") || "admin"

    with {:ok, file_map} <- unzip(path) do
      attrs_with_warnings = Bundle.import_bundle(file_map, actor_id)
      result = Knowledge.import_documents(attrs_with_warnings, actor_id)

      conn
      |> put_flash_result(result)
      |> redirect(to: ~p"/admin/settings/knowledge")
    else
      {:error, reason} ->
        conn
        |> put_flash(:error, "번들 압축 해제 실패: #{inspect(reason)}")
        |> redirect(to: ~p"/admin/settings/knowledge")
    end
  end

  def import(conn, _params) do
    conn
    |> put_flash(:error, "zip 번들 파일을 선택하세요.")
    |> redirect(to: ~p"/admin/settings/knowledge")
  end

  # zip → %{경로 => 내용}. :zip.unzip 인메모리. md 외 파일은 import_bundle 가 거른다.
  defp unzip(path) do
    case :zip.unzip(String.to_charlist(path), [:memory]) do
      {:ok, entries} ->
        file_map =
          Map.new(entries, fn {name, content} -> {to_string(name), content} end)

        {:ok, file_map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_flash_result(conn, %{imported: n, errors: errors, warnings: warnings}) do
    info = "OKF 문서 #{n}건을 가져왔습니다."

    info =
      if warnings == [],
        do: info,
        else: info <> " 경고 #{length(warnings)}건: " <> Enum.join(Enum.take(warnings, 5), " / ")

    conn = put_flash(conn, :info, info)

    if errors == [],
      do: conn,
      else: put_flash(conn, :error, "오류 #{length(errors)}건: " <> Enum.join(Enum.take(errors, 3), " / "))
  end
end
