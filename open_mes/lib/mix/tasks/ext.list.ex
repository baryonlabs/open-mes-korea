defmodule Mix.Tasks.Ext.List do
  @shortdoc "발견된 확장 목록 가시화 (출처 앱·enabled·라우트·외부 여부)"

  @moduledoc """
  발견된 확장을 한눈에 보여준다(설계 30 §2.4-1). 자동 발견(`:auto`)의 불투명성을 해소하는
  가시화 도구다 — `mix ext.verify`(검증)와 분리된 목록 task(검증 ≠ 목록).

      mix ext.list

      발견된 확장 (8) · 모드 :auto
        ✅ :ext_ingest            (app: open_mes)         enabled=false  route=/ingest
        ✅ :addon_wo_csv_export   (app: open_mes)         enabled=true   route=/extensions/wo-csv-export
        ...
      override(extra): []   제외(exclude): []

  열: id · 출처 OTP 앱 · enabled · route_spec scope · [외부] 표시(open_mes 가 아니면).
  """
  use Mix.Task

  alias OpenMes.Extension.Registry

  @impl Mix.Task
  def run(_args) do
    # 발견 대상 모듈이 로드되도록 컴파일 + deps 앱 load 안전판(설계 30 §2.4).
    Mix.Task.run("compile")
    OpenMes.Extension.RouterMount.ensure_apps_loaded()

    mode = Application.get_env(:open_mes, :extension_discovery, :manual)
    modules = Registry.modules()

    Mix.shell().info("발견된 확장 (#{length(modules)}) · 모드 #{inspect(mode)}")

    modules
    |> Enum.map(&row/1)
    |> Enum.sort_by(& &1.id)
    |> Enum.each(&print_row/1)

    extra = Application.get_env(:open_mes, :extra_extensions, [])
    exclude = Application.get_env(:open_mes, :exclude_extensions, [])
    Mix.shell().info("override(extra): #{inspect(extra)}   제외(exclude): #{inspect(exclude)}")
  end

  defp row(mod) do
    %{
      id: safe(mod, :id),
      app: source_app(mod),
      enabled: safe_enabled?(mod),
      route: route_scope(mod),
      external: source_app(mod) != :open_mes
    }
  end

  defp print_row(%{id: id, app: app, enabled: enabled, route: route, external: external}) do
    mark = if enabled, do: "✅", else: "⊘"
    ext_tag = if external, do: "  [외부]", else: ""

    Mix.shell().info(
      "  #{mark} #{inspect(id)}  (app: #{app})  enabled=#{enabled}  route=#{route}#{ext_tag}"
    )
  end

  # 모듈이 속한 OTP 앱(출처) — 외부 dep 확장 식별용.
  defp source_app(mod) do
    case :application.get_application(mod) do
      {:ok, app} -> app
      _ -> :unknown
    end
  end

  defp route_scope(mod) do
    if function_exported?(mod, :route_spec, 0) do
      case safe(mod, :route_spec) do
        %{scope: scope} -> scope
        _ -> "-"
      end
    else
      "-"
    end
  end

  defp safe_enabled?(mod) do
    mod.enabled?()
  rescue
    _ -> false
  end

  defp safe(mod, fun) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: nil
  rescue
    _ -> nil
  end
end
