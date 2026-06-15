defmodule OpenMesWeb.FallbackController do
  @moduledoc """
  컨텍스트가 반환한 {:error, ...} 를 HTTP 응답으로 변환하는 공통 fallback.

  매핑 규약:
    - {:error, :not_found}        → 404 {errors: {detail: "찾을 수 없습니다"}}
    - {:error, %Ecto.Changeset{}} → 422 {errors: {...}}  (잘못된 상태전이도 status 에러로 자연 흐름)
  """
  use OpenMesWeb, :controller

  # 미존재 리소스
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "찾을 수 없습니다"}})
  end

  # 검증 실패 / 잘못된 상태 전이(changeset 에러로 표현됨)
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: translate_errors(changeset)})
  end

  # changeset 의 에러를 {필드 => [메시지...]} 형태로 변환
  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
