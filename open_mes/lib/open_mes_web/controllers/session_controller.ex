defmodule OpenMesWeb.SessionController do
  @moduledoc """
  세션 로그인/로그아웃 + 역할(role) 전환 컨트롤러 — 데모용(설계 §4.4).

  공개 데모라 실제 비밀번호 저장/검증은 없다. 데모 계정 6종(역할별)과 **공용 데모 비밀번호**를
  로그인 페이지에 그대로 노출하고, 로그인 시 세션에 actor_id(worker_code)+current_role 을 기록한다.
  이후 모든 쓰기는 이 actor_id 로 AuditLog 에 남아 "누가 무엇을" 추적된다(SSOT).

  LiveView 는 세션을 직접 못 쓰므로 로그인/역할전환은 일반 컨트롤러를 경유한다.
  """
  use OpenMesWeb, :controller

  alias OpenMesWeb.Authorization

  # 데모 공용 비밀번호(로그인 페이지에 표시). 실제 인증 아님.
  @demo_password "demo1234"

  # 역할별 데모 계정(seeds.exs 와 동일). {worker_code, 표시이름, role}
  @accounts [
    {"W-ADMIN", "관리자 김", "system_admin"},
    {"W-PROD1", "생산관리 이", "production_manager"},
    {"W-QC1", "품질관리 박", "quality_manager"},
    {"W-MAT1", "자재창고 최", "material_manager"},
    {"W-OP1", "현장작업 정", "operator"}
  ]

  def accounts, do: @accounts
  def demo_password, do: @demo_password

  @doc "로그인 페이지(큰 이미지 + 우측 로그인 패널). app 레이아웃 없이 전체 화면."
  def login_page(conn, _params) do
    render(conn, :login,
      layout: false,
      accounts: @accounts,
      demo_password: @demo_password
    )
  end

  @doc "로그인: worker_code + 데모 비밀번호 확인 → 세션에 actor_id/role 기록 → landing 이동."
  def login(conn, %{"worker_code" => code, "password" => pw}) do
    account = Enum.find(@accounts, fn {c, _, _} -> c == code end)

    cond do
      pw != @demo_password ->
        conn |> put_flash(:error, "비밀번호가 올바르지 않습니다.") |> redirect(to: ~p"/login")

      is_nil(account) ->
        conn |> put_flash(:error, "존재하지 않는 계정입니다.") |> redirect(to: ~p"/login")

      true ->
        {_code, name, role} = account

        conn
        |> configure_session(renew: true)
        |> put_session(:actor_id, code)
        |> put_session(:current_role, role)
        |> put_flash(:info, "#{name}(#{Authorization.role_label(role)})으로 로그인했습니다.")
        |> redirect(to: Authorization.landing(role))
    end
  end

  def login(conn, _params),
    do: conn |> put_flash(:error, "계정을 선택하세요.") |> redirect(to: ~p"/login")

  @doc "로그아웃: 세션 폐기 후 로그인 페이지로."
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  @doc "역할 전환: 유효하면 세션에 기록. 그 후 해당 role landing 으로 redirect."
  def set_role(conn, %{"role" => role}) do
    conn =
      if Authorization.valid_role?(role) do
        conn
        |> put_session(:current_role, role)
        |> put_flash(:info, "역할을 전환했습니다: #{Authorization.role_label(role)}")
      else
        put_flash(conn, :error, "알 수 없는 역할입니다.")
      end

    redirect(conn, to: back_path(conn, role))
  end

  defp back_path(_conn, role) do
    if Authorization.valid_role?(role), do: Authorization.landing(role), else: "/admin/items"
  end
end
