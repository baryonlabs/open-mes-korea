defmodule OpenMes.Extension.RouterMount do
  @moduledoc """
  확장 라우트를 컴파일 타임에 일괄 주입하는 매크로(설계 30 §2.1).

  호스트 Router 는 하드코딩 if 블록 대신 이 한 줄을 쓴다:

      defmodule OpenMesWeb.Router do
        use OpenMesWeb, :router
        require OpenMes.Extension.RouterMount
        # ...
        OpenMes.Extension.RouterMount.mount_extension_routes()
      end

  ## Phoenix 미의존(설계 30 §3.1)

  이 매크로는 **quote AST 만 생성**한다. 실제 `live/get/post` 매크로는 호스트 Router 의
  `use ...Web, :router` 컨텍스트에서 펼쳐지므로, 계약 패키지는 Phoenix 를 dep 로 끌지 않는다.

  ## 컴파일 타임 게이트

  `Discovery.route_specs/0` 가 `enabled? == true` 인 확장만 반환하므로, 비활성 확장은
  라우트 테이블에 흔적이 남지 않는다(현행 `if X.enabled?()` 와 동등). 이 매크로가
  **컴파일 타임에** `enabled?/0` 를 호출하므로(구 `if X.enabled?()` 와 같은 시점),
  off=라우트 흔적 0 게이트가 그대로 성립한다. `enabled?` 가 `Application.get_env`(현행
  애드온) 든 `compile_env`(EXT-1) 든 무관하게 매크로 호출 시점에 평가된다 — config
  변경을 라우트에 반영하려면 재컴파일이 필요하다(컴파일 타임 게이트의 본질).
  """

  @doc """
  컴파일 타임에 확장 라우트 스펙을 순회해 Phoenix 라우트로 펼친다.

  진입부에서 `ensure_apps_loaded/0`(deps 앱 load) 안전판을 호출해 자동 발견(`:auto`) 모드의
  컴파일 타임 정합성을 보장한다(설계 30 §2.4).
  """
  defmacro mount_extension_routes do
    ensure_apps_loaded()
    specs = OpenMes.Extension.Discovery.route_specs()

    for %{scope: scope, pipeline: pipe, routes: routes} <- specs do
      route_asts = Enum.map(routes, &route_ast/1)

      quote do
        scope unquote(scope) do
          pipe_through unquote(pipe)
          unquote_splicing(route_asts)
        end
      end
    end
  end

  @doc """
  mix.exs deps 의 app 들을 컴파일 타임에 load(자동 발견 스캔 대상 확정 — 설계 30 §2.4).

  Mix 미가용(릴리스 런타임 등)·load 실패 시 조용히 통과한다(견고성).
  """
  def ensure_apps_loaded do
    if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :deps_apps, 0) do
      Enum.each(Mix.Project.deps_apps(), &Application.load/1)
    end

    :ok
  rescue
    _ -> :ok
  end

  # 라우트 튜플 → Phoenix 라우트 매크로 호출 AST. 잘못된 형태는 컴파일 타임에 raise
  # (ext.verify C8 이 미리 잡는다 — 설계 30 §5).
  defp route_ast({:live, path, mod, action}),
    do: quote(do: live(unquote(path), unquote(mod), unquote(action)))

  defp route_ast({:get, path, ctrl, action}),
    do: quote(do: get(unquote(path), unquote(ctrl), unquote(action)))

  defp route_ast({:post, path, ctrl, action}),
    do: quote(do: post(unquote(path), unquote(ctrl), unquote(action)))

  defp route_ast(other),
    do:
      raise(
        ArgumentError,
        "잘못된 route_spec 라우트 튜플: #{inspect(other)} — " <>
          "{:live|:get|:post, path, module, action} 형태여야 합니다(설계 30 §2.1)."
      )
end
