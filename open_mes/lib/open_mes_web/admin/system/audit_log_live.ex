defmodule OpenMesWeb.Admin.System.AuditLogLive do
  @moduledoc """
  G6 관리자 — 감사 로그 조회(읽기 전용).

  AuditLog 목록을 resource_type / action / actor / 기간 필터로 조회한다.
  각 행은 before/after 스냅샷(jsonb)을 펼쳐 볼 수 있다(details/summary).

  쓰기 없음(AuditLog 자체는 append-only — 여기서는 조회만). 목록은 `OpenMes.Audit.list_audit_logs/1` 경유.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Audit

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "감사 로그",
       resource_type: "",
       actor: "",
       from: nil,
       to: nil,
       resource_types: Audit.list_resource_types()
     )
     |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(
       resource_type: Map.get(params, "resource_type", ""),
       actor: Map.get(params, "actor", ""),
       from: parse_date(Map.get(params, "from", "")),
       to: parse_date(Map.get(params, "to", ""))
     )
     |> load()}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(resource_type: "", actor: "", from: nil, to: nil)
     |> load()}
  end

  defp load(socket) do
    filters = %{
      "resource_type" => socket.assigns.resource_type,
      "actor_id" => socket.assigns.actor,
      "from" => date_to_iso(socket.assigns.from),
      "to" => date_to_iso(socket.assigns.to),
      "limit" => "100"
    }

    assign(socket, logs: Audit.list_audit_logs(filters))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header title="감사 로그" subtitle="모든 도메인 쓰기의 변경 이력(읽기 전용, 최근 100건)" />

      <form phx-submit="filter" class="mb-4 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs font-medium text-zinc-500">리소스 유형</label>
          <select name="resource_type" class="mt-1 rounded-lg border-zinc-300 text-sm">
            <option value="" selected={@resource_type == ""}>전체</option>
            <option :for={rt <- @resource_types} value={rt} selected={@resource_type == rt}>{rt}</option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">작업자(actor)</label>
          <input type="text" name="actor" value={@actor} placeholder="actor 부분일치"
            class="mt-1 rounded-lg border-zinc-300 text-sm" />
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">시작일</label>
          <input type="date" name="from" value={to_input(@from)} class="mt-1 rounded-lg border-zinc-300 text-sm" />
        </div>
        <div>
          <label class="block text-xs font-medium text-zinc-500">종료일</label>
          <input type="date" name="to" value={to_input(@to)} class="mt-1 rounded-lg border-zinc-300 text-sm" />
        </div>
        <.button type="submit">조회</.button>
        <button type="button" phx-click="reset"
          class="rounded-lg border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50">
          초기화
        </button>
      </form>

      <.empty_state :if={@logs == []} message="조회된 감사 로그가 없습니다." />

      <table :if={@logs != []} class="w-full text-sm" id="audit-log-table">
        <thead>
          <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500">
            <th class="py-2 pr-4">시각</th>
            <th class="py-2 pr-4">작업자</th>
            <th class="py-2 pr-4">액션</th>
            <th class="py-2 pr-4">리소스</th>
            <th class="py-2">변경 내역</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={log <- @logs} class="border-b border-zinc-100 align-top" id={"audit-#{log.id}"}>
            <td class="py-2 pr-4 whitespace-nowrap text-zinc-600">{format_at(log.inserted_at)}</td>
            <td class="py-2 pr-4 text-zinc-800">{log.actor_id}</td>
            <td class="py-2 pr-4 font-medium text-zinc-900">{log.action}</td>
            <td class="py-2 pr-4 text-zinc-600">
              {log.resource_type}
              <span class="block font-mono text-[11px] text-zinc-400">{short_id(log.resource_id)}</span>
            </td>
            <td class="py-2">
              <details>
                <summary class="cursor-pointer text-indigo-600">before/after 보기</summary>
                <div class="mt-2 grid gap-2 sm:grid-cols-2">
                  <div>
                    <p class="text-[11px] font-semibold text-zinc-400">BEFORE</p>
                    <pre class="overflow-x-auto rounded bg-zinc-50 p-2 text-[11px] text-zinc-700">{format_snapshot(log.before)}</pre>
                  </div>
                  <div>
                    <p class="text-[11px] font-semibold text-zinc-400">AFTER</p>
                    <pre class="overflow-x-auto rounded bg-zinc-50 p-2 text-[11px] text-zinc-700">{format_snapshot(log.after)}</pre>
                  </div>
                </div>
              </details>
            </td>
          </tr>
        </tbody>
      </table>
    </.admin_shell>
    """
  end

  defp format_at(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_at(_), do: "—"

  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp format_snapshot(nil), do: "—"

  defp format_snapshot(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join("\n")
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_input(nil), do: ""
  defp to_input(%Date{} = d), do: Date.to_iso8601(d)

  defp date_to_iso(nil), do: ""
  defp date_to_iso(%Date{} = d), do: Date.to_iso8601(d)
end
