defmodule OpenMesWeb.Addons.EquipmentOeeLive do
  @moduledoc """
  애드온 ④ 설비 가동률 OEE — LiveView 화면(설계 §2 애드온④, §7-b).

  설비/기간 선택 → 설비별 OEE 3요소(가용성·성능·품질) + 종합 OEE 표시.
  데이터 소스는 `OpenMes.Addons.EquipmentOee.Oee` 읽기 집계뿐(쓰기 0). 한국어 UI.

  ## 견고성
    - 잘못된 기간(to <= from), 데이터 결측 → 빈 표/"—" 로 안전 표시(크래시 없음).
    - 비율 nil(계산 불가)은 `Calculator.to_percent/1` 이 "—" 로 렌더.
  """
  use OpenMesWeb, :live_view

  alias OpenMes.Addons.EquipmentOee.Calculator
  alias OpenMes.Addons.EquipmentOee.Oee

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()
    from = Date.add(today, -7)

    socket =
      socket
      |> assign(page_title: "설비 가동률 OEE")
      |> assign(from_date: from, to_date: today)
      |> load_rows()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"from" => from, "to" => to}, socket) do
    socket =
      socket
      |> assign(from_date: parse_date(from, socket.assigns.from_date))
      |> assign(to_date: parse_date(to, socket.assigns.to_date))
      |> load_rows()

    {:noreply, socket}
  end

  # 기간 [from 00:00, to+1일 00:00) 으로 읽어 설비별 OEE 행을 적재.
  defp load_rows(socket) do
    %{from_date: from_date, to_date: to_date} = socket.assigns

    rows =
      with {:ok, from_dt} <- start_of_day(from_date),
           {:ok, to_dt} <- start_of_day(Date.add(to_date, 1)) do
        safe_rows(from_dt, to_dt)
      else
        _ -> []
      end

    assign(socket, rows: rows, invalid_period: invalid_period?(from_date, to_date))
  end

  # Repo 미가용 등 어떤 예외에도 화면이 죽지 않도록 방어(읽기 전용이므로 빈 목록으로 degrade).
  defp safe_rows(from_dt, to_dt) do
    Oee.by_equipment(from_dt, to_dt)
  rescue
    _ -> []
  end

  defp invalid_period?(from_date, to_date), do: Date.compare(from_date, to_date) == :gt

  defp start_of_day(%Date{} = d), do: DateTime.new(d, ~T[00:00:00], "Etc/UTC")

  defp parse_date(str, fallback) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> fallback
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-8">
      <header class="mb-6">
        <h1 class="text-2xl font-bold text-zinc-900">설비 가동률 OEE</h1>
        <p class="mt-1 text-sm text-zinc-500">
          OEE = 가용성(Availability) × 성능(Performance) × 품질(Quality). 코어 생산 실적 기반 읽기 전용.
        </p>
      </header>

      <form phx-change="filter" phx-submit="filter" class="mb-6 flex flex-wrap items-end gap-4">
        <label class="flex flex-col text-sm text-zinc-700">
          시작일
          <input
            type="date"
            name="from"
            value={Date.to_iso8601(@from_date)}
            class="mt-1 rounded border border-zinc-300 px-2 py-1"
          />
        </label>
        <label class="flex flex-col text-sm text-zinc-700">
          종료일
          <input
            type="date"
            name="to"
            value={Date.to_iso8601(@to_date)}
            class="mt-1 rounded border border-zinc-300 px-2 py-1"
          />
        </label>
      </form>

      <div
        :if={@invalid_period}
        class="mb-4 rounded border border-amber-300 bg-amber-50 px-4 py-2 text-sm text-amber-700"
      >
        종료일이 시작일보다 빠릅니다. 기간을 확인하세요.
      </div>

      <div
        :if={@rows == [] and not @invalid_period}
        class="rounded-lg border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500"
      >
        해당 기간에 집계할 설비 실적이 없습니다.
      </div>

      <table :if={@rows != []} class="w-full border-collapse text-sm">
        <thead>
          <tr class="border-b border-zinc-300 text-left text-zinc-500">
            <th class="py-2 pr-4">설비</th>
            <th class="py-2 pr-4 text-right">가용성</th>
            <th class="py-2 pr-4 text-right">성능</th>
            <th class="py-2 pr-4 text-right">품질</th>
            <th class="py-2 pr-4 text-right">종합 OEE</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="border-b border-zinc-100">
            <td class="py-2 pr-4 font-mono text-xs text-zinc-700">
              {equipment_label(row.equipment_id)}
            </td>
            <td class="py-2 pr-4 text-right">{Calculator.to_percent(row.result.availability)}</td>
            <td class="py-2 pr-4 text-right">{Calculator.to_percent(row.result.performance)}</td>
            <td class="py-2 pr-4 text-right">{Calculator.to_percent(row.result.quality)}</td>
            <td class="py-2 pr-4 text-right font-semibold text-indigo-700">
              {Calculator.to_percent(row.result.oee)}
            </td>
          </tr>
        </tbody>
      </table>

      <p class="mt-4 text-xs text-zinc-400">
        "—" 는 계산 불가(계획시간 0, 생산수량 0, 시간 결측 등)를 의미합니다. 0% 와 다릅니다.
      </p>
    </div>
    """
  end

  defp equipment_label(nil), do: "(미지정)"
  defp equipment_label(id) when is_binary(id), do: id
end
