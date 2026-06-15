defmodule OpenMes.Extension.Discovery do
  @moduledoc """
  확장 발견(계약 패키지 `open_mes_extension_api`). 두 경로(설계 30 §2.4):

    - `all/0`        : 런타임 발견 OK(카탈로그·메타데이터). 로드된 OTP 앱을 스캔.
    - `route_specs/0`: 컴파일 타임 확정 필요(라우트). `RouterMount` 매크로가 호출한다.

  **컴파일 타임 정합성**: 매크로 본문은 호스트(`:open_mes`) 컴파일 시점에 실행된다. 이때
  deps 는 이미 컴파일·로드되어 있으나, 일부 환경에서 dep 앱이 `:application.load` 안 됐을 수
  있으므로 `RouterMount` 가 `ensure_apps_loaded/0`(`Mix.Project.deps_apps` load)로 안전판을 둔다.

  **견고성**: 발견 중 한 모듈이 raise 해도 전체가 죽지 않도록 모든 경로를 rescue 한다
  (현행 `safe_enabled?` 정신 확장). 중복 id 는 `Enum.uniq` + ext.verify C5 가 잡는다.
  """

  @doc """
  로드된 모든 OTP 앱에서 `OpenMes.Extension` behaviour 구현 모듈을 수집한다.

  escape hatch:
    - `config :open_mes, :extra_extensions, [Mod, ...]`   — 발견 못 한 모듈 강제 등록.
    - `config :open_mes, :exclude_extensions, [Mod, ...]` — 발견됐지만 제외.
  """
  @spec all() :: [module()]
  def all do
    # 호스트 자체 in-tree 확장은 :extensions 명시 목록을 단일 진실로 쓴다. 컴파일 타임(라우트
    # 매크로)에는 호스트(:open_mes) 자신의 .app 모듈 목록이 아직 생성 전이라 `:application.
    # get_key` 로 introspection 할 수 없기 때문이다(설계 30 §2.4 컴파일 타임 정합성). 외부 dep
    # 확장은 이미 컴파일·로드되어 있으므로 discover_modules 가 앱 스캔으로 잡는다.
    self_declared = Application.get_env(:open_mes, :extensions, [])
    discovered = discover_modules()
    extra = Application.get_env(:open_mes, :extra_extensions, [])
    exclude = Application.get_env(:open_mes, :exclude_extensions, [])

    (self_declared ++ discovered ++ extra)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in exclude))
  end

  @doc """
  `enabled?` 이고 `route_spec/0` 을 가진 확장의 스펙 목록.

  `RouterMount.mount_extension_routes/0` 매크로가 컴파일 타임에 평가한다. `enabled? == false`
  인 확장은 제외되어 라우트 테이블에 흔적이 남지 않는다(현행 컴파일 타임 게이트와 동등).
  """
  @spec route_specs() :: [OpenMes.Extension.route_spec()]
  def route_specs do
    for mod <- modules(),
        safe_enabled?(mod),
        spec = safe_route_spec(mod),
        not is_nil(spec) do
      spec
    end
  end

  # 라우트 발견은 Registry.modules/0(모드 분기) 를 단일 진실로 따른다 — :manual 이면 명시 목록,
  # :auto 면 all/0. 카탈로그와 라우트가 동일한 확장 목록을 보게 하여 정합을 보장한다.
  defp modules, do: OpenMes.Extension.Registry.modules()

  # ── 내부: 로드된 앱 모듈 스캔 ─────────────────────────────────────────────

  defp discover_modules do
    for {app, _, _} <- Application.loaded_applications(),
        {:ok, mods} <- [:application.get_key(app, :modules)],
        mod <- mods,
        implements_extension?(mod) do
      mod
    end
  rescue
    _ -> []
  end

  # behaviour 채택 여부를 introspection 으로 판정(ext.verify C2 와 동일 로직).
  defp implements_extension?(mod) do
    Code.ensure_loaded?(mod) and
      function_exported?(mod, :id, 0) and
      OpenMes.Extension in (mod.module_info(:attributes)[:behaviour] || [])
  rescue
    _ -> false
  end

  defp safe_enabled?(mod) do
    mod.enabled?()
  rescue
    _ -> false
  end

  defp safe_route_spec(mod) do
    if function_exported?(mod, :route_spec, 0), do: mod.route_spec(), else: nil
  rescue
    _ -> nil
  end
end
