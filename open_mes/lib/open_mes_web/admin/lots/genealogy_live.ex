defmodule OpenMesWeb.Admin.Lots.GenealogyLive do
  @moduledoc """
  LOT 계보(genealogy) 조회 LiveView (설계 §3.3 G3).

  제품 LOT → source_operation_id → 그 공정에 투입된 LotConsumption → 원자재 LOT 계보를
  트리/목록으로 표시한다. `OpenMes.Lots.genealogy/1` 결과를 재귀적으로 펼친다.

  읽기 전용(쓰기 없음). genealogy 는 Lots 컨텍스트가 LotConsumption 경유로 산출한다.
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Lots
  alias OpenMes.MasterData

  @max_depth 5

  @impl true
  def mount(%{"id" => lot_id}, _session, socket) do
    case Lots.fetch_lot(lot_id) do
      {:ok, lot} ->
        tree = build_tree(lot_id, @max_depth)

        {:ok,
         assign(socket,
           page_title: "LOT 계보",
           lot: lot,
           item: MasterData.get_item(lot.item_id),
           tree: tree
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "존재하지 않는 LOT 입니다")
         |> push_navigate(to: ~p"/admin/lots")}
    end
  end

  # 재귀적으로 1단계 genealogy 를 펼쳐 트리 노드를 구성한다.
  # 노드: %{lot: lot, source_operation_id: id, inputs: [child_node]}
  defp build_tree(_lot_id, 0), do: nil

  defp build_tree(lot_id, depth) do
    case Lots.genealogy(lot_id) do
      {:ok, %{lot: lot, source_operation_id: op_id, inputs: inputs}} ->
        children =
          Enum.map(inputs, fn %{consumption: c, lot: input_lot} ->
            %{
              consumption: c,
              node: build_tree(input_lot.id, depth - 1) || leaf(input_lot)
            }
          end)

        %{lot: lot, source_operation_id: op_id, children: children}

      {:error, :not_found} ->
        nil
    end
  end

  defp leaf(lot), do: %{lot: lot, source_operation_id: lot.source_operation_id, children: []}

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell current_path={@current_path} current_actor={@current_actor} current_role={@current_role} flash={@flash}>
      <.page_header
        title={"LOT 계보 — #{@lot.lot_no}"}
        subtitle={"품목: #{if @item, do: "#{@item.item_code} · #{@item.name}", else: @lot.item_id} · 상태: #{@lot.status}"}
      >
        <:actions>
          <.link patch={~p"/admin/lots"}>
            <.button class="bg-zinc-100 text-zinc-700 hover:bg-zinc-200">LOT 목록</.button>
          </.link>
        </:actions>
      </.page_header>

      <div class="rounded-lg border border-zinc-200 p-5">
        <h2 class="mb-3 text-sm font-semibold text-zinc-900">계보 트리</h2>
        <p :if={@tree == nil} class="text-sm text-zinc-500">계보 정보를 찾을 수 없습니다.</p>
        <.tree_node :if={@tree} node={@tree} consumption={nil} root={true} />
      </div>
    </.admin_shell>
    """
  end

  # 트리 노드(재귀 컴포넌트). consumption 가 있으면 투입 수량을 함께 표시.
  attr :node, :map, required: true
  attr :consumption, :any, default: nil
  attr :root, :boolean, default: false

  defp tree_node(assigns) do
    ~H"""
    <div class={[!@root && "ml-5 border-l-2 border-zinc-200 pl-4 pt-2"]}>
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-mono text-sm font-semibold text-zinc-900">{@node.lot.lot_no}</span>
        <span class="rounded bg-zinc-100 px-2 py-0.5 text-xs text-zinc-600">{lot_type_text(@node.lot.lot_type)}</span>
        <span :if={@consumption} class="text-xs text-indigo-700">투입 {@consumption.quantity}</span>
        <span :if={@node.source_operation_id} class="text-xs text-zinc-400">
          ← 공정 {String.slice(to_string(@node.source_operation_id), 0, 8)}
        </span>
      </div>
      <div :if={@node.children != []}>
        <.tree_node :for={child <- @node.children} node={child.node} consumption={child.consumption} />
      </div>
      <p :if={@root and @node.children == []} class="mt-2 text-sm text-zinc-400">
        이 LOT 에 투입된 하위 LOT 이 없습니다(원자재 또는 미투입).
      </p>
    </div>
    """
  end

  defp lot_type_text("raw"), do: "원자재"
  defp lot_type_text("semi"), do: "반제품"
  defp lot_type_text("product"), do: "제품"
  defp lot_type_text(other), do: other
end
