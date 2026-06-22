defmodule OpenMesWeb.Addons.CadBomLive do
  @moduledoc """
  CAD 견적 BOM 화면(LiveView).

  동작:
    - CAD 도면 인덱스(도번·도면명·분류·수량·재질·규격 — `_index.csv`)를 붙여넣는다.
    - 실시간으로 ① 통합 BOM(품번 합산) ② 발주 공정별 분류 ③ 공정별 건수/수량 요약을 보여준다.
    - 공정(업체)별 견적 BOM, 통합 BOM 을 CSV 로 다운로드(컨트롤러 POST — 첨부 파일).

  다운로드를 컨트롤러로 위임하는 이유: LiveView 는 파일 첨부를 직접 못 보낸다. 붙여넣은 인덱스를
  hidden 필드로 폼 POST 하고 `CadBomController.download/2` 가 `send_download` 로 내려준다.

  읽기/변환 전용: 도메인 쓰기 없음(AuditLog/Outbox 무관). 새 DB 테이블 0.
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.CadBom

  @download_path "/extensions/cad-bom/download"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_text(socket, "") |> assign(page_title: "CAD 견적 BOM")}
  end

  @impl true
  def handle_event("change", %{"cad_index" => text}, socket) do
    {:noreply, assign_text(socket, text)}
  end

  def handle_event("sample", _params, socket) do
    {:noreply, assign_text(socket, CadBom.sample())}
  end

  def handle_event("clear", _params, socket) do
    {:noreply, assign_text(socket, "")}
  end

  defp assign_text(socket, text) do
    result = CadBom.analyze(text)

    socket
    |> assign(text: text)
    |> assign(result: result)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, download_path: @download_path)

    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">CAD 견적 BOM</h1>
        <p class="mt-1 text-sm text-zinc-500">
          CAD 도면 인덱스를 붙여넣으면 통합 BOM 을 만들고, 부품을 발주 공정별로 분류해 업체 견적용 BOM 을 내려받습니다.
        </p>
      </header>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-5">
        <!-- 입력 -->
        <section class="lg:col-span-2">
          <form phx-change="change">
            <label class="block text-sm font-medium text-zinc-700">
              CAD 도면 인덱스 (CSV/TSV 붙여넣기)
            </label>
            <p class="mt-1 text-xs text-zinc-400">
              헤더 예: 도번,도면명,분류,수량,재질,규격,발주처,모델
            </p>
            <textarea
              name="cad_index"
              rows="14"
              phx-debounce="300"
              placeholder="도번,도면명,분류,수량,재질,규격,발주처,모델&#10;DRNT-CNJG-003,BRACKET,가공품,2,SS400,,드림텍,CNC HAND"
              class="mt-2 block w-full rounded-md border-zinc-300 font-mono text-xs"
            >{@text}</textarea>
          </form>
          <div class="mt-3 flex gap-2">
            <button
              type="button"
              phx-click="sample"
              class="rounded-md bg-zinc-100 px-3 py-1.5 text-sm font-medium text-zinc-700 hover:bg-zinc-200"
            >
              샘플 불러오기
            </button>
            <button
              type="button"
              phx-click="clear"
              class="rounded-md px-3 py-1.5 text-sm text-zinc-500 hover:text-zinc-700"
            >
              지우기
            </button>
          </div>
        </section>
        
    <!-- 결과 -->
        <section class="lg:col-span-3">
          <%= if @result.total == 0 do %>
            <div class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-400">
              인덱스를 붙여넣으면 통합 BOM·분류·견적 BOM 이 여기에 표시됩니다. <br />「샘플 불러오기」로 드림텍 예시를 바로 볼 수 있습니다.
            </div>
          <% else %>
            <!-- 공정별 요약 + 견적 BOM 다운로드 -->
            <div class="mb-4 flex items-center justify-between">
              <h2 class="text-sm font-semibold text-zinc-800">
                통합 BOM <span class="text-zinc-400">· {@result.total}품번</span>
              </h2>
              <.form for={to_form(%{})} action={@download_path} method="post" class="inline">
                <input type="hidden" name="cad_index" value={@text} />
                <input type="hidden" name="kind" value="통합" />
                <button class="rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-indigo-700">
                  통합 BOM CSV
                </button>
              </.form>
            </div>

            <div class="mb-5 grid grid-cols-1 gap-2 sm:grid-cols-2">
              <div
                :for={g <- @result.by_process}
                class="flex items-center justify-between rounded-md border border-zinc-200 bg-white px-3 py-2"
              >
                <div class="text-sm">
                  <span class="font-medium text-zinc-800">{g.공정}</span>
                  <span class="text-xs text-zinc-400">· {g.건수}품번 / {g.수량}EA</span>
                </div>
                <.form for={to_form(%{})} action={@download_path} method="post" class="inline">
                  <input type="hidden" name="cad_index" value={@text} />
                  <input type="hidden" name="kind" value={g.공정} />
                  <button class="rounded border border-indigo-200 px-2 py-1 text-xs font-medium text-indigo-700 hover:bg-indigo-50">
                    견적 BOM ↓
                  </button>
                </.form>
              </div>
            </div>
            
    <!-- 통합 BOM 표 -->
            <div class="overflow-x-auto rounded-lg border border-zinc-200">
              <table class="min-w-full divide-y divide-zinc-200 text-xs">
                <thead class="bg-zinc-50 text-left text-zinc-500">
                  <tr>
                    <th class="px-3 py-2 font-medium">품번</th>
                    <th class="px-3 py-2 font-medium">품명</th>
                    <th class="px-3 py-2 font-medium">발주공정</th>
                    <th class="px-3 py-2 font-medium text-right">수량</th>
                    <th class="px-3 py-2 font-medium">재질</th>
                    <th class="px-3 py-2 font-medium">규격</th>
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
                    <td class="px-3 py-1.5 text-zinc-500">{r.규격}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      </div>
    </div>
    """
  end
end
