defmodule OpenMesWeb.Addons.CadBomLive do
  @moduledoc """
  CAD 견적 BOM 화면(LiveView) — 업로드 흐름.

  흐름: CAD(DXF/DWG) 업로드 → MES 가 추출(ezdxf 어댑터) → 통합 BOM →
        부품 발주 공정 분류 → 공정별 업체 후보 선택 → 업체별 견적 BOM(CSV/엑셀) 다운로드.

  추출된 행은 인덱스 CSV 로 직렬화(`rows_to_index`)해 화면/다운로드의 기존 분석·CSV·엑셀
  기계를 그대로 재사용한다. 다운로드는 컨트롤러 POST(`<.form>` CSRF) 로 첨부 파일을 내린다.

  읽기/변환 전용: 도메인 쓰기 없음(AuditLog/Outbox 무관). 새 DB 테이블 0.
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.CadBom
  alias OpenMes.Addons.CadBom.Vendors

  @download_path "/extensions/cad-bom/download"
  @no_vendor_proc ["승인도(참고)", "기타"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "CAD 견적 BOM")
     |> assign(extract_files: [], extract_errors: [], extract_error: nil, selected: %{})
     |> assign_text("")
     |> allow_upload(:cad, accept: ~w(.dxf .dwg), max_entries: 30, max_file_size: 60_000_000)}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :cad, ref)}
  end

  def handle_event("extract", _params, socket) do
    dir = Path.join(System.tmp_dir!(), "cadbom_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    paths =
      consume_uploaded_entries(socket, :cad, fn %{path: path}, entry ->
        dest = Path.join(dir, entry.client_name)
        File.cp!(path, dest)
        {:ok, dest}
      end)

    result = CadBom.extract_files(paths)
    File.rm_rf(dir)

    case result do
      {:ok, %{rows: rows, files: files, errors: errors}} ->
        {:noreply,
         socket
         |> assign_text(CadBom.rows_to_index(rows))
         |> assign(
           extract_files: files,
           extract_errors: errors,
           extract_error: nil,
           selected: %{}
         )}

      {:error, msg} ->
        {:noreply, assign(socket, extract_error: msg, extract_files: [], extract_errors: [])}
    end
  end

  def handle_event("sample", _params, socket) do
    {:noreply, reset_with(socket, CadBom.sample())}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, reset_with(socket, "")}
  end

  def handle_event("change", %{"cad_index" => text}, socket) do
    {:noreply, assign_text(socket, text)}
  end

  def handle_event("toggle_vendor", %{"process" => p, "vendor" => v}, socket) do
    cur = Map.get(socket.assigns.selected, p, [])
    next = if v in cur, do: List.delete(cur, v), else: [v | cur]
    {:noreply, assign(socket, selected: Map.put(socket.assigns.selected, p, next))}
  end

  defp reset_with(socket, text) do
    socket
    |> assign_text(text)
    |> assign(extract_files: [], extract_errors: [], extract_error: nil, selected: %{})
  end

  defp assign_text(socket, text) do
    assign(socket, text: text, result: CadBom.analyze(text))
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, download_path: @download_path, no_vendor_proc: @no_vendor_proc)

    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">CAD 견적 BOM</h1>
        <p class="mt-1 text-sm text-zinc-500">
          CAD 도면을 업로드하면 BOM 을 추출하고, 도면마다 필요한 작업(레이저·가공·커팅 등)으로 분류해
          공정별 업체 후보를 고르고 견적용 BOM(CSV·엑셀)을 내려받습니다.
        </p>
      </header>

      <section class="mb-6 rounded-lg border border-zinc-200 bg-white p-5">
        <form phx-change="validate" phx-submit="extract">
          <div
            class="flex flex-col items-center justify-center rounded-md border-2 border-dashed border-zinc-300 px-4 py-8 text-center"
            phx-drop-target={@uploads.cad.ref}
          >
            <p class="text-sm text-zinc-600">CAD 파일(.dxf · .dwg)을 끌어다 놓거나 선택하세요</p>
            <p class="mt-1 text-xs text-zinc-400">.dwg 는 서버에 ODA File Converter 필요 · .dxf 는 즉시 추출</p>
            <.live_file_input upload={@uploads.cad} class="mt-3 text-sm" />
          </div>

          <div :if={@uploads.cad.entries != []} class="mt-3 space-y-1">
            <div
              :for={entry <- @uploads.cad.entries}
              class="flex items-center justify-between text-xs text-zinc-600"
            >
              <span>{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-zinc-400 hover:text-red-500"
              >
                ✕
              </button>
            </div>
          </div>

          <div class="mt-4 flex items-center gap-2">
            <button
              type="submit"
              disabled={@uploads.cad.entries == []}
              class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-700 disabled:opacity-40"
            >
              BOM 추출
            </button>
            <button
              type="button"
              phx-click="sample"
              class="rounded-md bg-zinc-100 px-3 py-2 text-sm text-zinc-700 hover:bg-zinc-200"
            >
              샘플(드림텍)
            </button>
            <button
              :if={@result.total > 0}
              type="button"
              phx-click="clear"
              class="px-2 py-2 text-sm text-zinc-400 hover:text-zinc-700"
            >
              지우기
            </button>
          </div>
        </form>

        <p :if={@extract_error} class="mt-3 rounded bg-red-50 px-3 py-2 text-xs text-red-700">
          {@extract_error}
        </p>
        <div :if={@extract_files != []} class="mt-3 text-xs text-zinc-500">
          추출: <span :for={f <- @extract_files} class="mr-2">{f["file"]} → {f["parts"]}부품</span>
        </div>
        <div :if={@extract_errors != []} class="mt-1 text-xs text-amber-600">
          <span :for={e <- @extract_errors} class="mr-2">{e["file"]}: {e["error"]}</span>
        </div>
      </section>

      <%= if @result.total == 0 do %>
        <div class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-400">
          CAD 를 업로드해 「BOM 추출」하거나 「샘플(드림텍)」로 결과 형태를 확인하세요.
        </div>
      <% else %>
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-sm font-semibold text-zinc-800">
            통합 BOM <span class="text-zinc-400">· {@result.total}품번</span>
          </h2>
          <div class="flex gap-2">
            <.dl_btn path={@download_path} text={@text} kind="통합" fmt="csv" label="통합 CSV" />
            <.dl_btn
              path={@download_path}
              text={@text}
              kind="통합"
              fmt="xlsx"
              label="통합 엑셀"
              primary
            />
          </div>
        </div>

        <div class="mb-5 space-y-3">
          <div :for={g <- @result.by_process} class="rounded-md border border-zinc-200 bg-white p-3">
            <div class="flex items-center justify-between">
              <div class="text-sm">
                <span class="font-medium text-zinc-800">{g.공정}</span>
                <span class="text-xs text-zinc-400">· {g.건수}품번 / {g.수량}EA</span>
              </div>
              <div :if={g.공정 not in @no_vendor_proc} class="flex gap-2">
                <.dl_btn
                  path={@download_path}
                  text={@text}
                  kind={g.공정}
                  fmt="csv"
                  label="견적 CSV"
                  small
                />
                <.dl_btn
                  path={@download_path}
                  text={@text}
                  kind={g.공정}
                  fmt="xlsx"
                  label="견적 엑셀"
                  small
                />
              </div>
            </div>

            <div :if={g.공정 not in @no_vendor_proc} class="mt-2 flex flex-wrap items-center gap-1.5">
              <span class="text-xs text-zinc-400">업체 후보:</span>
              <button
                :for={v <- Vendors.candidates(g.공정)}
                type="button"
                phx-click="toggle_vendor"
                phx-value-process={g.공정}
                phx-value-vendor={v.name}
                title={v.note}
                class={[
                  "rounded-full border px-2.5 py-0.5 text-xs",
                  (v.name in Map.get(@selected, g.공정, []) &&
                     "border-indigo-500 bg-indigo-50 text-indigo-700") ||
                    "border-zinc-200 text-zinc-600 hover:bg-zinc-50"
                ]}
              >
                {v.name}
              </button>
              <span :if={Map.get(@selected, g.공정, []) != []} class="ml-1 text-xs text-indigo-600">
                → 선택: {Enum.join(Map.get(@selected, g.공정, []), ", ")}
              </span>
            </div>
          </div>
        </div>

        <div class="overflow-x-auto rounded-lg border border-zinc-200">
          <table class="min-w-full divide-y divide-zinc-200 text-xs">
            <thead class="bg-zinc-50 text-left text-zinc-500">
              <tr>
                <th class="px-3 py-2 font-medium">품번</th>
                <th class="px-3 py-2 font-medium">품명</th>
                <th class="px-3 py-2 font-medium">발주공정</th>
                <th class="px-3 py-2 font-medium text-right">수량</th>
                <th class="px-3 py-2 font-medium">재질</th>
                <th class="px-3 py-2 font-medium">발주처</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100">
              <tr :for={r <- @result.rows} class="hover:bg-zinc-50">
                <td class="whitespace-nowrap px-3 py-1.5 font-mono text-zinc-700">{r.품번}</td>
                <td class="px-3 py-1.5 text-zinc-800">{r.품명}</td>
                <td class="px-3 py-1.5">
                  <span class="rounded bg-zinc-100 px-1.5 py-0.5 text-zinc-600">{r.공정}</span>
                </td>
                <td class="px-3 py-1.5 text-right tabular-nums text-zinc-700">{r.수량}</td>
                <td class="px-3 py-1.5 text-zinc-500">{r.재질}</td>
                <td class="px-3 py-1.5 text-zinc-500">{r.발주처}</td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :text, :string, required: true
  attr :kind, :string, required: true
  attr :fmt, :string, required: true
  attr :label, :string, required: true
  attr :primary, :boolean, default: false
  attr :small, :boolean, default: false

  defp dl_btn(assigns) do
    ~H"""
    <.form for={to_form(%{})} action={@path} method="post" class="inline">
      <input type="hidden" name="cad_index" value={@text} />
      <input type="hidden" name="kind" value={@kind} />
      <input type="hidden" name="fmt" value={@fmt} />
      <button class={[
        (@small && "px-2 py-1 text-xs") || "px-3 py-1.5 text-sm",
        (@primary && "rounded-md bg-indigo-600 font-semibold text-white hover:bg-indigo-700") ||
          "rounded border border-indigo-200 font-medium text-indigo-700 hover:bg-indigo-50"
      ]}>
        {@label}
      </button>
    </.form>
    """
  end
end
