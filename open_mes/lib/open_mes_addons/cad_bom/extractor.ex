defmodule OpenMes.Addons.CadBom.Extractor do
  @moduledoc """
  업로드된 CAD(DXF/DWG) 파일 → 도면별 부품 행 추출(Python 어댑터 호출).

  실제 DXF 파싱은 Elixir 가 못 하므로, `priv/cad_bom/cad_extract.py`(ezdxf 기반, ara_big_cad
  파이프라인의 표제란 추출 로직 재사용)를 `System.cmd/3` 로 호출하고 JSON 출력을 파싱한다.

  파이썬 실행기 경로는 config 로 지정한다(ezdxf 설치된 환경 필요):

      config :open_mes, OpenMes.Addons.CadBom,
        python: "/path/to/.venv/bin/python"   # 또는 env CAD_PYTHON

  반환: `{:ok, %{rows: [row], files: [...], errors: [...]}}` | `{:error, reason}`
  row: %{품번, 품명, 분류, 수량, 재질, 규격, 발주처, 모델} (Parser/Classifier 와 동일 키)
  """

  @doc "CAD 파일 경로 리스트를 추출해 부품 행으로 변환한다."
  @spec extract([Path.t()]) :: {:ok, map()} | {:error, String.t()}
  def extract([]), do: {:ok, %{rows: [], files: [], errors: []}}

  def extract(paths) when is_list(paths) do
    py = python()
    script = script_path()

    if not File.exists?(script) do
      {:error, "추출 스크립트를 찾을 수 없습니다: #{script}"}
    else
      case System.cmd(py, [script | paths], stderr_to_stdout: false) do
        {out, 0} -> parse_output(out)
        {out, code} -> {:error, "추출기 실패(exit #{code}): #{String.slice(out, 0, 300)}"}
      end
    end
  rescue
    e in ErlangError ->
      {:error, "파이썬 실행 실패(#{python()} 확인 — ezdxf 설치 필요): #{inspect(e.original)}"}
  end

  defp parse_output(out) do
    with {:ok, %{"rows" => rows} = data} <- Jason.decode(String.trim(out)) do
      {:ok,
       %{
         rows: Enum.map(rows, &to_row/1),
         files: Map.get(data, "files", []),
         errors: Map.get(data, "errors", [])
       }}
    else
      _ -> {:error, "추출기 출력 파싱 실패: #{String.slice(out, 0, 200)}"}
    end
  end

  # 추출 JSON 행 → Parser/Classifier 호환 행. 도번/도면명/작업분류만 신뢰, 수량 기본 1.
  defp to_row(m) do
    %{
      품번: get(m, "dwg_no"),
      품명: get(m, "title"),
      분류: get(m, "work_category"),
      수량: 1,
      재질: "",
      규격: "",
      발주처: get(m, "client"),
      모델: get(m, "model")
    }
  end

  defp get(m, k), do: m |> Map.get(k, "") |> to_string() |> String.trim()

  defp python do
    cfg = Application.get_env(:open_mes, OpenMes.Addons.CadBom, [])
    System.get_env("CAD_PYTHON") || Keyword.get(cfg, :python) || "python3"
  end

  defp script_path do
    Application.app_dir(:open_mes, "priv/cad_bom/cad_extract.py")
  end
end
