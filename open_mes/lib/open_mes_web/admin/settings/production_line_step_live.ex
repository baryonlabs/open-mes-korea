defmodule OpenMesWeb.Admin.Settings.ProductionLineStepLive do
  @moduledoc """
  설정 — 생산라인 공정 단계 편집 LiveView(설계 22번 §3.2 B).

  라인 1개의 공정 단계 컬렉션 편집(추가/수정/위·아래 순서변경/삭제). 모든 쓰기는
  `OpenMes.ProductionLine` 컨텍스트 경유(AuditLog 내장). 순서변경은 버튼 swap(외부 JS 0,
  드래그앤드롭 없음 — pi). 공정·설비 드롭다운은 활성 기준정보에서 선택한다.

  live_action: :index(단계 표), :new(추가 모달), :edit(수정 모달).
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.MasterData
  alias OpenMes.ProductionLine
  alias OpenMes.ProductionLine.LineStep

  @impl true
  def mount(%{"id" => line_id}, _session, socket) do
    case ProductionLine.fetch_line(line_id) do
      {:ok, line} ->
        {:ok, assign(socket, line: line, page_title: "라인 단계 — #{line.name}")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "존재하지 않는 라인입니다")
         |> push_navigate(to: ~p"/admin/settings/lines")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:form, nil)
    |> load_steps()
  end

  defp apply_action(socket, :new, _params) do
    next_seq = next_sequence(socket)

    socket
    |> assign(
      :form,
      to_form(ProductionLine.change_step(%LineStep{line_id: socket.assigns.line.id, sequence: next_seq}))
    )
    |> assign(:editing_id, nil)
    |> load_steps()
  end

  defp apply_action(socket, :edit, %{"step_id" => step_id}) do
    case ProductionLine.fetch_step(step_id) do
      {:ok, step} ->
        socket
        |> assign(:form, to_form(ProductionLine.change_step(step)))
        |> assign(:editing_id, step_id)
        |> load_steps()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "존재하지 않는 단계입니다")
        |> push_patch(to: ~p"/admin/settings/lines/#{socket.assigns.line.id}/steps")
    end
  end

  @impl true
  def handle_event("validate", %{"line_step" => params}, socket) do
    changeset =
      %LineStep{line_id: socket.assigns.line.id}
      |> LineStep.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"line_step" => params}, socket) do
    actor = socket.assigns.current_actor
    params = Map.put(params, "line_id", socket.assigns.line.id) |> normalize_equipment()
    save_step(socket, socket.assigns.editing_id, params, actor)
  end

  def handle_event("reorder", %{"id" => step_id, "dir" => dir}, socket) do
    actor = socket.assigns.current_actor
    direction = if dir == "up", do: :up, else: :down

    case ProductionLine.reorder_step(step_id, direction, actor) do
      {:ok, _} -> {:noreply, load_steps(socket)}
      _ -> {:noreply, put_flash(socket, :error, "순서 변경에 실패했습니다")}
    end
  end

  def handle_event("delete", %{"id" => step_id}, socket) do
    actor = socket.assigns.current_actor

    case ProductionLine.delete_step(step_id, actor) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "단계를 삭제했습니다") |> load_steps()}
      _ -> {:noreply, put_flash(socket, :error, "삭제에 실패했습니다")}
    end
  end

  # 설비 "미지정"(빈 문자열) → nil.
  defp normalize_equipment(%{"equipment_id" => ""} = params), do: Map.put(params, "equipment_id", nil)
  defp normalize_equipment(params), do: params

  defp save_step(socket, nil, params, actor) do
    case ProductionLine.create_step(params, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "단계를 추가했습니다")
         |> push_patch(to: ~p"/admin/settings/lines/#{socket.assigns.line.id}/steps")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_step(socket, id, params, actor) do
    case ProductionLine.update_step(id, params, actor) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "단계를 수정했습니다")
         |> push_patch(to: ~p"/admin/settings/lines/#{socket.assigns.line.id}/steps")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "존재하지 않는 단계입니다")
         |> push_patch(to: ~p"/admin/settings/lines/#{socket.assigns.line.id}/steps")}
    end
  end

  defp load_steps(socket) do
    steps = ProductionLine.list_steps(socket.assigns.line.id)
    processes = MasterData.list_processes(%{"active" => "true"})
    equipment = MasterData.list_equipment(%{"active" => "true"})

    process_labels = Map.new(processes, &{&1.id, "#{&1.process_code} · #{&1.name}"})
    equipment_labels = Map.new(equipment, &{&1.id, "#{&1.equipment_code} · #{&1.name}"})

    socket
    |> assign(steps: steps, processes: processes, equipment: equipment)
    |> assign(process_labels: process_labels, equipment_labels: equipment_labels)
  end

  defp next_sequence(socket) do
    case ProductionLine.list_steps(socket.assigns.line.id) do
      [] -> 1
      steps -> (steps |> Enum.map(& &1.sequence) |> Enum.max()) + 1
    end
  end

  defp process_options(processes), do: Enum.map(processes, &{"#{&1.process_code} · #{&1.name}", &1.id})

  defp equipment_options(equipment),
    do: [{"미지정", ""} | Enum.map(equipment, &{"#{&1.equipment_code} · #{&1.name}", &1.id})]

  @impl true
  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header title={"라인 단계 — #{@line.name}"} subtitle={"라인코드 #{@line.line_code}"}>
        <:actions>
          <.link
            navigate={~p"/admin/reports/production?line=#{@line.line_code}"}
            class="text-sm text-indigo-600 hover:underline"
          >
            모니터 미리보기 →
          </.link>
          <.link patch={~p"/admin/settings/lines/#{@line.id}/steps/new"}>
            <.button>단계 추가</.button>
          </.link>
          <.link navigate={~p"/admin/settings/lines"} class="text-sm text-zinc-500 hover:underline">
            목록으로
          </.link>
        </:actions>
      </.page_header>

      <.empty_state
        :if={@steps == []}
        message="공정 단계가 없습니다. '단계 추가' 로 구성하세요."
      />

      <.table :if={@steps != []} id="steps" rows={@steps}>
        <:col :let={step} label="순서">{step.sequence}</:col>
        <:col :let={step} label="공정">{Map.get(@process_labels, step.process_id, "-")}</:col>
        <:col :let={step} label="설비">
          {Map.get(@equipment_labels, step.equipment_id, "미지정")}
        </:col>
        <:action :let={step}>
          <button
            type="button"
            phx-click="reorder"
            phx-value-id={step.id}
            phx-value-dir="up"
            class="text-zinc-500 hover:underline"
          >
            위로
          </button>
        </:action>
        <:action :let={step}>
          <button
            type="button"
            phx-click="reorder"
            phx-value-id={step.id}
            phx-value-dir="down"
            class="text-zinc-500 hover:underline"
          >
            아래로
          </button>
        </:action>
        <:action :let={step}>
          <.link
            patch={~p"/admin/settings/lines/#{@line.id}/steps/#{step.id}/edit"}
            class="text-indigo-600 hover:underline"
          >
            수정
          </.link>
        </:action>
        <:action :let={step}>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={step.id}
            data-confirm="이 단계를 삭제하시겠습니까?"
            class="text-red-600 hover:underline"
          >
            삭제
          </button>
        </:action>
      </.table>

      <.modal
        :if={@form}
        id="step-modal"
        show
        on_cancel={JS.patch(~p"/admin/settings/lines/#{@line.id}/steps")}
      >
        <.header>{if @live_action == :new, do: "단계 추가", else: "단계 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input
            field={@form[:process_id]}
            type="select"
            label="공정"
            prompt="공정 선택"
            options={process_options(@processes)}
          />
          <.input
            field={@form[:equipment_id]}
            type="select"
            label="설비 (미지정 가능)"
            options={equipment_options(@equipment)}
          />
          <.input field={@form[:sequence]} type="number" label="순서" />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end
end
