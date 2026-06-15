defmodule Mix.Tasks.Ext.Verify do
  @shortdoc "확장 정적 검증 (introspection + grep, 서버/Repo 미기동)"

  @moduledoc """
  확장 모듈을 정적으로 검증한다 — `OpenMes.Extensions.Extension` behaviour 계약을
  introspection 으로, 코어 비침투를 grep 휴리스틱으로 점검한다.

  ## 사용법

      mix ext.verify OpenMes.Addons.WoCsvExport.Extension   # 단일 확장
      mix ext.verify                                          # :extensions 전체 스캔

  ## 검증 항목(체크 7종)

    - C1 필수 콜백 구현 — behaviour introspection 으로 유도(하드코딩 0)
    - C2 behaviour 채택 — `@behaviour OpenMes.Extensions.Extension`
    - C3 config :extensions 등록 — `Registry.modules()` 포함
    - C4 카탈로그 노출 가능 — `Registry.all()` 에서 raise 없이 엔트리화
    - C5 id 고유성 — 등록된 확장 간 id 중복 0 + atom
    - C6 category 유효성 — `Extension.categories()` 기준
    - C7 코어 비침투(휴리스틱) — 확장 소스의 명백한 Repo 직접 쓰기 grep

  ## 설계 원칙(pi)

    - 순수 정적 + 런타임 introspection + grep 만. dialyzer/AST 전수분석/외부 deps 0.
    - `Mix.Task.run("compile")` 로 **컴파일만 보장**하고 서버/Repo 는 기동하지 않는다.
    - 출력: 사람·LLM 모두 파싱 가능한 ✅/❌ 라인 + 실패 시 `→` 수정 안내 1줄.
      종료코드: 전체 통과 0, 위반 1.

  ## C7 한계(정직 표기)

    grep 은 매크로 우회 등을 잡지 못한다. C7 은 "명백한 코어 직접 쓰기"를 잡는 1차 가드다.
    **도메인 쓰기 확장은 C7 을 통과해도 qa-auditor `audit-verify` 스킬 검토가 필수**다.
  """
  use Mix.Task

  alias OpenMes.Extensions.{Extension, Registry}

  # C7 코어 직접 쓰기 위반 패턴(설계 §3.3). 단순 export/읽기 애드온은 0건이어야 한다.
  # 함수로 둔다(모듈 속성 X) — Elixir 1.18부터 컴파일된 ~r// 는 모듈 속성에 못 넣는다(Reference).
  defp write_patterns do
    [
      ~r/Repo\.(insert|update|delete|insert_all|update_all|delete_all)\b/,
      ~r/Ecto\.Multi\b/,
      ~r/OpenMes\.Repo\./
    ]
  end

  @impl Mix.Task
  def run(args) do
    # 서버/Repo 기동 없이 컴파일만 보장 → 빠르고 부작용 0.
    Mix.Task.run("compile")

    modules =
      case args do
        [] -> Registry.modules()
        [name | _] -> [resolve_module(name)]
      end

    results = Enum.map(modules, &verify_module/1)

    case args do
      [] -> report_scan(results)
      _ -> report_single(hd(results))
    end

    if Enum.all?(results, & &1.ok?) do
      :ok
    else
      exit({:shutdown, 1})
    end
  end

  # ── 모듈명 → 모듈 안전 변환 ───────────────────────────────────────────────

  defp resolve_module(name) do
    mod =
      name
      |> String.trim_leading("Elixir.")
      |> then(&Module.concat([&1]))

    if Code.ensure_loaded?(mod) do
      {:ok, mod}
    else
      {:error, mod, name}
    end
  end

  # ── 단일 모듈 검증 ───────────────────────────────────────────────────────

  # 로드 실패: C3부터 ❌로 명확히 보고(추측 금지).
  defp verify_module({:error, mod, name}) do
    %{
      module: mod,
      ok?: false,
      checks: [
        {:fail, "C0 모듈 로드", "모듈 #{name} 을 로드할 수 없음",
         "모듈명 오타 또는 미컴파일. 정확한 모듈명으로 재실행하거나 `mix compile` 확인"}
      ]
    }
  end

  defp verify_module({:ok, mod}), do: verify_module(mod)

  defp verify_module(mod) when is_atom(mod) do
    # introspection 전 모듈 적재 보장(function_exported?/3 는 미적재 시 false 반환).
    Code.ensure_loaded(mod)

    checks =
      [
        check_c1(mod),
        check_c2(mod),
        check_c3(mod),
        check_c4(mod),
        check_c5(mod),
        check_c6(mod),
        check_c7(mod)
      ]

    %{module: mod, ok?: Enum.all?(checks, &pass?/1), checks: checks}
  end

  defp pass?({:ok, _, _}), do: true
  defp pass?({:fail, _, _, _}), do: false

  # C1 — 필수 콜백 구현(behaviour introspection 으로 유도, 하드코딩 0)
  defp check_c1(mod) do
    required = required_callbacks()

    missing =
      Enum.reject(required, fn {name, arity} -> function_exported?(mod, name, arity) end)

    case missing do
      [] ->
        {:ok, "C1", "필수 콜백 #{length(required)}개 구현"}

      _ ->
        labels = Enum.map_join(missing, ", ", fn {n, a} -> "#{n}/#{a}" end)

        {:fail, "C1", "필수 콜백 누락: #{labels}",
         "extension.ex 에 `def #{elem(hd(missing), 0)}` 추가 (가이드 §2.3 (B) 템플릿)"}
    end
  end

  # C2 — behaviour 채택(@behaviour 선언)
  defp check_c2(mod) do
    behaviours =
      mod.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if Extension in behaviours do
      {:ok, "C2", "Extension behaviour 채택"}
    else
      {:fail, "C2", "Extension behaviour 미채택",
       "extension.ex 에 `use OpenMes.Extensions.Definition` 추가"}
    end
  end

  # C3 — config :extensions 등록
  defp check_c3(mod) do
    if mod in Registry.modules() do
      {:ok, "C3", "config :extensions 등록"}
    else
      {:fail, "C3", "config :extensions 미등록",
       "config :open_mes, :extensions 리스트에 모듈 한 줄 추가 (가이드 §2.3 D)"}
    end
  end

  # C4 — 카탈로그 노출 가능(to_entry 가 raise 없이 성공)
  defp check_c4(mod) do
    if Enum.any?(Registry.all(), &(&1.module == mod)) do
      {:ok, "C4", "카탈로그 노출 가능"}
    else
      {:fail, "C4", "카탈로그 노출 불가(콜백 raise 또는 미등록)", "id/name/category 등 콜백 반환값 점검 (또는 C3 먼저 해결)"}
    end
  rescue
    e ->
      {:fail, "C4", "카탈로그 엔트리화 중 예외: #{Exception.message(e)}",
       "콜백이 raise. id/name/category 반환값 점검"}
  end

  # C5 — id 고유성(등록된 확장 간 빈도 1 + atom)
  defp check_c5(mod) do
    id = safe_call(mod, :id)

    cond do
      not is_atom(id) or is_nil(id) ->
        {:fail, "C5", "id 가 atom 이 아님(#{inspect(id)})", "id/0 이 :addon_* 형태 atom 을 반환하도록 변경"}

      true ->
        freq =
          Registry.modules()
          |> Enum.map(&safe_call(&1, :id))
          |> Enum.count(&(&1 == id))

        if freq <= 1 do
          {:ok, "C5", "id 고유 (#{inspect(id)})"}
        else
          {:fail, "C5", "id 중복 (#{inspect(id)}, #{freq}회)",
           "다른 확장과 id 충돌. :addon_* 고유 atom 으로 변경"}
        end
    end
  end

  # C6 — category 유효성(Extension.categories/0 기준)
  defp check_c6(mod) do
    cat = safe_call(mod, :category)

    if cat in Extension.categories() do
      {:ok, "C6", "category 유효 (#{inspect(cat)})"}
    else
      valid = Enum.map_join(Extension.categories(), " · ", &inspect/1)

      {:fail, "C6", "category 무효 (#{inspect(cat)})",
       "유효 카테고리(#{valid}) 중 하나로. 새 분류면 Extension.categories/0 에 추가"}
    end
  end

  # C7 — 코어 비침투(grep 휴리스틱). 명백한 Repo 직접 쓰기만 경고.
  defp check_c7(mod) do
    files = addon_source_files(mod)

    hits =
      Enum.flat_map(files, fn path ->
        case File.read(path) do
          {:ok, content} -> scan_writes(path, content)
          _ -> []
        end
      end)

    case hits do
      [] ->
        {:ok, "C7", "코어 비침투 (직접 쓰기 0건; 도메인 쓰기 확장은 audit-verify 필수)"}

      _ ->
        detail = Enum.map_join(hits, ", ", fn {f, line, _} -> "#{Path.basename(f)}:#{line}" end)

        {:fail, "C7", "코어 직접 쓰기 의심 #{length(hits)}건 (#{detail})",
         "컨텍스트 공개 함수 경유로 변경. 도메인 쓰기면 audit-verify 필수(가이드 §2.4)"}
    end
  end

  defp scan_writes(path, content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      if Enum.any?(write_patterns(), &Regex.match?(&1, line)) do
        [{path, n, String.trim(line)}]
      else
        []
      end
    end)
  end

  # 모듈 → 확장 소스 파일 집합 추정(Macro.underscore 로 디렉토리 추정 + 글롭).
  # 예: OpenMes.Addons.WoCsvExport.Extension → open_mes_addons/wo_csv_export/
  defp addon_source_files(mod) do
    base = Macro.underscore(mod)

    # ".../extension" 의 마지막 한 단계(extension)를 떼어 디렉토리 루트를 얻는다.
    dir = Path.dirname(base)
    name = Path.basename(dir)

    globs = [
      "lib/#{dir}/**/*.ex",
      "lib/#{dir}.ex",
      "lib/open_mes_web/controllers/#{name}_controller.ex"
    ]

    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  # ── 안전 호출 ───────────────────────────────────────────────────────────

  defp safe_call(mod, fun) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: nil
  rescue
    _ -> nil
  end

  # 필수 콜백 = behaviour 전체 - optional. 단일 출처(하드코딩 금지).
  defp required_callbacks do
    optional = Extension.behaviour_info(:optional_callbacks)
    Extension.behaviour_info(:callbacks) -- optional
  end

  # ── 리포트 ──────────────────────────────────────────────────────────────

  defp report_single(%{module: mod, ok?: ok?, checks: checks}) do
    Mix.shell().info("ext.verify: #{inspect(mod)}")
    Enum.each(checks, &print_check/1)

    passed = Enum.count(checks, &pass?/1)
    total = length(checks)
    mark = if ok?, do: "✅", else: "❌"
    code = if ok?, do: 0, else: 1

    Mix.shell().info("")
    Mix.shell().info("결과: #{passed}/#{total} 통과 #{mark}  (종료코드 #{code})")

    unless ok? do
      Mix.shell().info("다음: 위 → 안내대로 수정 후 `mix ext.verify #{inspect(mod)}` 재실행")
    end
  end

  defp report_scan(results) do
    Mix.shell().info("ext.verify: 전체 스캔 (#{length(results)}개 확장)")

    Enum.each(results, fn %{module: mod, ok?: ok?, checks: checks} ->
      passed = Enum.count(checks, &pass?/1)
      total = length(checks)
      mark = if ok?, do: "✅", else: "❌"
      Mix.shell().info("  #{mark} #{inspect(mod)} (#{passed}/#{total})")

      unless ok? do
        checks
        |> Enum.filter(fn c -> not pass?(c) end)
        |> Enum.each(fn {:fail, id, msg, fix} ->
          Mix.shell().info("      ❌ #{id} #{msg}")
          Mix.shell().info("         → #{fix}")
        end)
      end
    end)

    ok_count = Enum.count(results, & &1.ok?)
    total = length(results)
    mark = if ok_count == total, do: "✅", else: "❌"
    code = if ok_count == total, do: 0, else: 1

    Mix.shell().info("")
    Mix.shell().info("합계: #{ok_count}/#{total} 확장 통과 #{mark}  (종료코드 #{code})")
  end

  defp print_check({:ok, id, msg}) do
    Mix.shell().info("  ✅ #{id} #{msg}")
  end

  defp print_check({:fail, id, msg, fix}) do
    Mix.shell().info("  ❌ #{id} #{msg}")
    Mix.shell().info("      → #{fix}")
  end
end
