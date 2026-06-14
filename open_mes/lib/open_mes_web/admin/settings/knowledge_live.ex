defmodule OpenMesWeb.Admin.Settings.KnowledgeLive do
  @moduledoc """
  설정 — 지식베이스(OKF 문서) 목록/상세/생성/수정 LiveView — 설계 27번 §3.2.

  AI 조사가 읽는 OKF 지식 문서(표준작업서·설비매뉴얼·트러블슈팅 등)를 사람이 편집한다.
  모든 쓰기는 `OpenMes.Knowledge` 컨텍스트 경유(AuditLog 내장). LiveView 는 Repo 직접 호출 안 함.

  live_action: :index(목록·필터), :show(상세·변경이력), :new/:edit(폼·마크다운 미리보기).
  삭제 대신 active=false(이력 보존). OKF export/import 는 컨트롤러(파일 다운로드/업로드).
  """
  use OpenMesWeb.Admin.AdminLive

  alias OpenMes.Knowledge
  alias OpenMes.Knowledge.KnowledgeDocument

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "지식베이스", preview: false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filters = take_filters(params)

    socket
    |> assign(:form, nil)
    |> assign(:document, nil)
    |> assign(:filters, filters)
    |> assign(:okf_types, Knowledge.list_okf_types())
    |> load_documents(filters)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:editing_id, nil)
    |> assign(:document, %KnowledgeDocument{active: true, tags: []})
    |> assign(:form, to_form(Knowledge.change_document(%KnowledgeDocument{active: true})))
    |> assign(:preview, false)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Knowledge.fetch_document(id) do
      {:ok, doc} ->
        socket
        |> assign(:editing_id, id)
        |> assign(:document, doc)
        |> assign(:form, to_form(Knowledge.change_document(doc)))
        |> assign(:preview, false)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "존재하지 않는 문서입니다")
        |> push_patch(to: ~p"/admin/settings/knowledge")
    end
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Knowledge.fetch_document(id) do
      {:ok, doc} ->
        socket
        |> assign(:form, nil)
        |> assign(:document, doc)
        |> assign(:audit_logs, Knowledge.document_audit_logs(id))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "존재하지 않는 문서입니다")
        |> push_patch(to: ~p"/admin/settings/knowledge")
    end
  end

  @impl true
  def handle_event("validate", %{"knowledge_document" => params}, socket) do
    changeset =
      socket.assigns.document
      |> Knowledge.change_document(normalize(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("toggle_preview", _params, socket) do
    {:noreply, assign(socket, :preview, !socket.assigns.preview)}
  end

  def handle_event("save", %{"knowledge_document" => params}, socket) do
    actor = socket.assigns.current_actor
    save_document(socket, socket.assigns.editing_id, normalize(params), actor)
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    actor = socket.assigns.current_actor

    with {:ok, doc} <- Knowledge.fetch_document(id),
         {:ok, _} <- Knowledge.update_document(id, %{"active" => !doc.active}, actor) do
      {:noreply,
       socket
       |> put_flash(:info, if(doc.active, do: "비활성화했습니다", else: "활성화했습니다"))
       |> load_documents(socket.assigns.filters)}
    else
      _ -> {:noreply, put_flash(socket, :error, "상태 변경에 실패했습니다")}
    end
  end

  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/settings/knowledge?#{take_filters(params)}")}
  end

  defp save_document(socket, nil, params, actor) do
    case Knowledge.create_document(params, actor) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> put_flash(:info, "문서를 생성했습니다")
         |> push_patch(to: ~p"/admin/settings/knowledge")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}
    end
  end

  defp save_document(socket, id, params, actor) do
    case Knowledge.update_document(id, params, actor) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> put_flash(:info, "문서를 수정했습니다")
         |> push_patch(to: ~p"/admin/settings/knowledge")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "존재하지 않는 문서입니다")
         |> push_patch(to: ~p"/admin/settings/knowledge")}
    end
  end

  defp load_documents(socket, filters) do
    assign(socket, :documents, Knowledge.list_documents(filters))
  end

  defp take_filters(params) do
    params
    |> Map.take(["okf_type", "tag", "active"])
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  # tags 폼 입력(쉼표/줄바꿈 구분 문자열) → 리스트. 빈 값 정리.
  defp normalize(params) do
    case Map.get(params, "tags") do
      tags when is_binary(tags) ->
        list =
          tags
          |> String.split(~r/[,\n]/u, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "tags", list)

      _ ->
        params
    end
  end

  defp tags_value(%{tags: tags}) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags_value(_), do: ""

  defp expired?(%{valid_until: %Date{} = d}), do: Date.compare(d, Date.utc_today()) == :lt
  defp expired?(_), do: false

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header title={@document.title || @document.okf_type} subtitle={"OKF 유형: #{@document.okf_type}"}>
        <:actions>
          <.link navigate={~p"/admin/settings/knowledge/#{@document.id}/export"} target="_blank">
            <.button>.md 다운로드</.button>
          </.link>
          <.link patch={~p"/admin/settings/knowledge/#{@document.id}/edit"}>
            <.button>수정</.button>
          </.link>
          <.link navigate={~p"/admin/settings/knowledge"} class="text-sm text-zinc-500">← 목록</.link>
        </:actions>
      </.page_header>

      <div class="grid gap-6 lg:grid-cols-3">
        <div class="lg:col-span-2 space-y-4">
          <div class="rounded-lg border border-zinc-200 p-4">
            <h2 class="mb-2 text-sm font-semibold text-zinc-700">본문 (마크다운)</h2>
            <pre class="whitespace-pre-wrap text-sm text-zinc-800">{@document.body}</pre>
          </div>
        </div>
        <div class="space-y-4">
          <div class="rounded-lg border border-zinc-200 p-4 text-sm">
            <h2 class="mb-2 font-semibold text-zinc-700">메타데이터</h2>
            <dl class="space-y-1 text-zinc-600">
              <div><dt class="inline font-medium">설명:</dt> {@document.description || "—"}</div>
              <div><dt class="inline font-medium">resource:</dt> <code>{@document.resource || "—"}</code></div>
              <div><dt class="inline font-medium">버전:</dt> {@document.version || "—"}</div>
              <div><dt class="inline font-medium">유효기간:</dt> {@document.valid_until || "—"}</div>
              <div><dt class="inline font-medium">작성자:</dt> {@document.uploaded_by}</div>
              <div class="flex flex-wrap gap-1 pt-1">
                <span :for={tag <- @document.tags} class="rounded bg-indigo-50 px-1.5 py-0.5 text-xs text-indigo-700">{tag}</span>
              </div>
            </dl>
          </div>

          <div class="rounded-lg border border-zinc-200 p-4 text-sm">
            <h2 class="mb-2 font-semibold text-zinc-700">변경 이력 (OKF log.md)</h2>
            <.empty_state :if={@audit_logs == []} message="변경 이력이 없습니다." />
            <ul :if={@audit_logs != []} class="space-y-1 text-xs text-zinc-600">
              <li :for={log <- @audit_logs}>
                <span class="font-mono">{log.action}</span> · {log.actor_id} ·
                {Calendar.strftime(log.inserted_at, "%Y-%m-%d %H:%M")}
              </li>
            </ul>
          </div>
        </div>
      </div>
    </.admin_shell>
    """
  end

  def render(assigns) do
    ~H"""
    <.admin_shell
      current_path={@current_path}
      current_actor={@current_actor}
      current_role={@current_role}
      flash={@flash}
    >
      <.page_header title="지식베이스 (OKF)" subtitle="AI 조사가 인용하는 표준작업서·설비매뉴얼·트러블슈팅 등">
        <:actions>
          <.link patch={~p"/admin/settings/knowledge/new"}>
            <.button>신규 문서</.button>
          </.link>
          <.link navigate={~p"/admin/settings/knowledge/export"} target="_blank">
            <.button>OKF 내보내기</.button>
          </.link>
        </:actions>
      </.page_header>

      <form phx-change="filter" class="mb-4 flex flex-wrap items-end gap-3">
        <div>
          <label class="block text-xs text-zinc-500">OKF 유형</label>
          <select name="okf_type" class="rounded border-zinc-300 text-sm">
            <option value="">전체</option>
            <option :for={t <- @okf_types} value={t} selected={@filters["okf_type"] == t}>{t}</option>
          </select>
        </div>
        <div>
          <label class="block text-xs text-zinc-500">태그(설비/공정)</label>
          <input
            type="text"
            name="tag"
            value={@filters["tag"] || ""}
            placeholder="예: EQ-P03"
            class="rounded border-zinc-300 text-sm"
          />
        </div>
      </form>

      <div class="mb-4 rounded-lg border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-600">
        OKF 번들 가져오기: zip 파일 업로드 (관용적 소비 — 미지 필드/깨진 링크/type 누락도 거부하지 않고 경고만 표시)
        <form
          action={~p"/admin/settings/knowledge/import"}
          method="post"
          enctype="multipart/form-data"
          class="mt-2 flex items-center gap-2"
        >
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="actor_id" value={@current_actor} />
          <input type="file" name="bundle" accept=".zip" class="text-xs" />
          <.button type="submit">가져오기</.button>
        </form>
      </div>

      <.empty_state
        :if={@documents == []}
        message="등록된 지식 문서가 없습니다. '신규 문서' 또는 seed 로 추가하세요."
      />

      <.table :if={@documents != []} id="knowledge-docs" rows={@documents}>
        <:col :let={doc} label="유형">{doc.okf_type}</:col>
        <:col :let={doc} label="제목">
          <.link navigate={~p"/admin/settings/knowledge/#{doc.id}"} class="text-indigo-600 hover:underline">
            {doc.title || "(제목 없음)"}
          </.link>
        </:col>
        <:col :let={doc} label="태그">
          <span class="flex flex-wrap gap-1">
            <span :for={tag <- doc.tags} class="rounded bg-zinc-100 px-1.5 py-0.5 text-xs text-zinc-600">{tag}</span>
          </span>
        </:col>
        <:col :let={doc} label="유효">
          <span :if={expired?(doc)} class="rounded-full bg-red-100 px-2 py-0.5 text-xs text-red-700">만료</span>
          <span :if={!expired?(doc)} class="text-xs text-zinc-400">{doc.valid_until || "—"}</span>
        </:col>
        <:col :let={doc} label="상태"><.active_badge active={doc.active} /></:col>
        <:action :let={doc}>
          <.link patch={~p"/admin/settings/knowledge/#{doc.id}/edit"} class="text-indigo-600 hover:underline">수정</.link>
        </:action>
        <:action :let={doc}>
          <button
            type="button"
            phx-click="toggle_active"
            phx-value-id={doc.id}
            data-confirm={if doc.active, do: "비활성화하시겠습니까?", else: "활성화하시겠습니까?"}
            class="text-zinc-500 hover:underline"
          >
            {if doc.active, do: "비활성", else: "활성"}
          </button>
        </:action>
      </.table>

      <.modal :if={@form} id="doc-modal" show on_cancel={JS.patch(~p"/admin/settings/knowledge")}>
        <.header>{if @live_action == :new, do: "신규 OKF 문서", else: "문서 수정"}</.header>
        <.simple_form for={@form} phx-change="validate" phx-submit="save">
          <.input field={@form[:okf_type]} label="OKF 유형 (예: 표준작업서, 설비매뉴얼, 트러블슈팅)" />
          <.input field={@form[:title]} label="제목" />
          <.input field={@form[:description]} label="한 줄 요약" />
          <.input field={@form[:resource]} label="resource URI (선택 — 예: mes://knowledge/manual/eq-p03)" />
          <.input name="knowledge_document[tags]" value={tags_value(@document)} label="태그 (쉼표 구분 — 설비/공정 코드 포함)" />
          <.input field={@form[:version]} label="버전 (선택)" />
          <.input field={@form[:valid_until]} type="date" label="유효기간 (선택)" />

          <div class="flex items-center justify-between">
            <span class="text-sm font-medium text-zinc-700">본문 (마크다운)</span>
            <button type="button" phx-click="toggle_preview" class="text-xs text-indigo-600 hover:underline">
              {if @preview, do: "편집", else: "미리보기"}
            </button>
          </div>
          <.input :if={!@preview} field={@form[:body]} type="textarea" rows="14" />
          <pre :if={@preview} class="max-h-80 overflow-auto whitespace-pre-wrap rounded border border-zinc-200 bg-zinc-50 p-3 text-sm">{@form[:body].value}</pre>

          <.input field={@form[:active]} type="checkbox" label="활성" />
          <:actions>
            <.button phx-disable-with="저장 중...">저장</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </.admin_shell>
    """
  end
end
