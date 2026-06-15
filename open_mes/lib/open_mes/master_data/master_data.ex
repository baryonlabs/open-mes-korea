defmodule OpenMes.MasterData do
  @moduledoc """
  기준정보(MasterData) 바운디드 컨텍스트 — Item/BOM/Process/Routing/Equipment/Worker.

  핵심 불변식:
    - 모든 쓰기(생성/수정)는 단일 `Ecto.Multi` 안에서 AuditLog 1건을 동반한다.
      (CLAUDE.md "모든 쓰기" 원칙 — 기준정보 변경도 감사 대상.)
    - 모든 쓰기 함수는 actor_id 를 명시적으로 받는다(actor 없는 쓰기 금지).
    - 삭제는 제공하지 않는다(이력 보존). 비활성화는 active=false 수정으로 처리한다.

  6개 엔티티의 CRUD 반복을 제거하기 위해 제네릭 헬퍼(create/2, update/2)를 둔다.
  resource_type / audit action 접두어는 스키마 모듈별 매핑(@resources)으로 결정한다.
  """
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias OpenMes.Audit
  alias OpenMes.MasterData.{BillOfMaterial, Equipment, Item, Process, Routing, Worker}
  alias OpenMes.Repo

  # 스키마 모듈 → {resource_type 문자열}. AuditLog action 은 "#{resource_type}.create/update".
  @resources %{
    Item => "item",
    BillOfMaterial => "bill_of_material",
    Process => "process",
    Routing => "routing",
    Equipment => "equipment",
    Worker => "worker"
  }

  # ──────────────────────────────────────────────────────────────────
  # 조회 (읽기 — AuditLog 불필요)
  # ──────────────────────────────────────────────────────────────────

  @doc "품목 목록. active 필터/페이지네이션 지원."
  def list_items(filters \\ %{}), do: list(Item, filters)
  def get_item(id), do: Repo.get(Item, id)
  def fetch_item(id), do: fetch(Item, id)

  def list_processes(filters \\ %{}), do: list(Process, filters)
  def get_process(id), do: Repo.get(Process, id)

  def list_equipment(filters \\ %{}), do: list(Equipment, filters)
  def get_equipment(id), do: Repo.get(Equipment, id)

  @doc "설비 코드로 단건 조회(AI 조사 키 브리지용 — equipment_code 문자열 ↔ equipment.id binary_id). nil 가능."
  def get_equipment_by_code(equipment_code) when is_binary(equipment_code),
    do: Repo.get_by(Equipment, equipment_code: equipment_code)

  def get_equipment_by_code(_), do: nil

  def list_workers(filters \\ %{}), do: list(Worker, filters)
  def get_worker(id), do: Repo.get(Worker, id)

  def list_boms(filters \\ %{}), do: list(BillOfMaterial, filters)
  def get_bom(id), do: Repo.get(BillOfMaterial, id)

  def list_routings(filters \\ %{}), do: list(Routing, filters)
  def get_routing(id), do: Repo.get(Routing, id)

  @doc """
  품목 id → 품목 라벨 맵(조회 화면 라벨 해석용, N+1 방지).
  `ids` 가 주어지면 해당 품목만, 없으면 전체 품목을 대상으로 한다.
  반환: %{item_id => %{item_code, name, item_type, unit}}.
  """
  def items_map(ids \\ nil) do
    query =
      case ids do
        nil -> Item
        ids when is_list(ids) -> from(i in Item, where: i.id in ^Enum.uniq(ids))
      end

    query
    |> Repo.all()
    |> Map.new(fn i ->
      {i.id, %{item_code: i.item_code, name: i.name, item_type: i.item_type, unit: i.unit}}
    end)
  end

  @doc "공정 id → 공정 라벨 맵. 반환: %{process_id => %{process_code, name}}."
  def processes_map(ids \\ nil) do
    query =
      case ids do
        nil -> Process
        ids when is_list(ids) -> from(p in Process, where: p.id in ^Enum.uniq(ids))
      end

    query
    |> Repo.all()
    |> Map.new(fn p -> {p.id, %{process_code: p.process_code, name: p.name}} end)
  end

  # ──────────────────────────────────────────────────────────────────
  # 폼용 changeset 빌더 (쓰기 아님 — UI 폼 렌더/검증용. AuditLog 무관)
  # ──────────────────────────────────────────────────────────────────

  def change_item(%Item{} = item, attrs \\ %{}), do: Item.changeset(item, attrs)
  def change_process(%Process{} = p, attrs \\ %{}), do: Process.changeset(p, attrs)
  def change_equipment(%Equipment{} = e, attrs \\ %{}), do: Equipment.changeset(e, attrs)
  def change_worker(%Worker{} = w, attrs \\ %{}), do: Worker.changeset(w, attrs)
  def change_bom(%BillOfMaterial{} = b, attrs \\ %{}), do: BillOfMaterial.changeset(b, attrs)
  def change_routing(%Routing{} = r, attrs \\ %{}), do: Routing.changeset(r, attrs)

  # ──────────────────────────────────────────────────────────────────
  # 생성 / 수정 (AuditLog 동반 — 제네릭)
  # ──────────────────────────────────────────────────────────────────

  @doc "품목 생성(AuditLog: item.create)."
  def create_item(attrs, actor_id), do: create(Item, attrs, actor_id)
  @doc "품목 수정(AuditLog: item.update). 비활성화도 이 경로(active=false)."
  def update_item(id, attrs, actor_id), do: update(Item, id, attrs, actor_id)

  def create_process(attrs, actor_id), do: create(Process, attrs, actor_id)
  def update_process(id, attrs, actor_id), do: update(Process, id, attrs, actor_id)

  def create_equipment(attrs, actor_id), do: create(Equipment, attrs, actor_id)
  def update_equipment(id, attrs, actor_id), do: update(Equipment, id, attrs, actor_id)

  def create_worker(attrs, actor_id), do: create(Worker, attrs, actor_id)
  def update_worker(id, attrs, actor_id), do: update(Worker, id, attrs, actor_id)

  def create_bom(attrs, actor_id), do: create(BillOfMaterial, attrs, actor_id)
  def update_bom(id, attrs, actor_id), do: update(BillOfMaterial, id, attrs, actor_id)

  def create_routing(attrs, actor_id), do: create(Routing, attrs, actor_id)
  def update_routing(id, attrs, actor_id), do: update(Routing, id, attrs, actor_id)

  @doc ~S"""
  제네릭 생성. 동일 트랜잭션에서 AuditLog("#{resource}.create") 1건을 남긴다.
  """
  def create(schema_mod, attrs, actor_id) do
    resource_type = Map.fetch!(@resources, schema_mod)

    Multi.new()
    |> Multi.insert(:record, schema_mod.changeset(struct(schema_mod), attrs))
    |> Audit.put_log(:audit, fn %{record: record} ->
      %{
        actor_id: actor_id,
        action: "#{resource_type}.create",
        resource_type: resource_type,
        resource_id: record.id,
        before: nil,
        after: snapshot(record)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:record)
  end

  @doc ~S"""
  제네릭 수정. 동일 트랜잭션에서 AuditLog("#{resource}.update") 1건을 남긴다.
  before/after 스냅샷을 모두 기록한다.
  """
  def update(schema_mod, id, attrs, actor_id) do
    resource_type = Map.fetch!(@resources, schema_mod)

    Multi.new()
    |> Multi.run(:load, fn repo, _ -> load(repo, schema_mod, id) end)
    |> Multi.update(:record, fn %{load: record} -> schema_mod.changeset(record, attrs) end)
    |> Audit.put_log(:audit, fn %{load: before_rec, record: after_rec} ->
      %{
        actor_id: actor_id,
        action: "#{resource_type}.update",
        resource_type: resource_type,
        resource_id: after_rec.id,
        before: snapshot(before_rec),
        after: snapshot(after_rec)
      }
    end)
    |> Repo.transaction()
    |> normalize_result(:record)
  end

  # ──────────────────────────────────────────────────────────────────
  # 내부 헬퍼
  # ──────────────────────────────────────────────────────────────────

  defp list(schema_mod, filters) do
    schema_mod
    |> filter_active(filters)
    |> order_recent()
    |> paginate(filters)
    |> Repo.all()
  end

  defp fetch(schema_mod, id) do
    case Repo.get(schema_mod, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp load(repo, schema_mod, id) do
    case repo.get(schema_mod, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp filter_active(query, %{"active" => active}) when active in [true, "true"],
    do: from(r in query, where: r.active == true)

  defp filter_active(query, %{"active" => active}) when active in [false, "false"],
    do: from(r in query, where: r.active == false)

  defp filter_active(query, _), do: query

  defp order_recent(query), do: from(r in query, order_by: [desc: r.inserted_at])

  defp paginate(query, filters) do
    limit = parse_int(Map.get(filters, "limit"), 50) |> min(200) |> max(1)
    offset = parse_int(Map.get(filters, "offset"), 0) |> max(0)
    from(r in query, limit: ^limit, offset: ^offset)
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  # 결과 정규화: {:ok, %{step => rec}} → {:ok, rec}.
  defp normalize_result({:ok, changes}, key), do: {:ok, Map.fetch!(changes, key)}
  defp normalize_result({:error, :load, :not_found, _}, _key), do: {:error, :not_found}

  defp normalize_result({:error, _step, %Ecto.Changeset{} = cs, _}, _key), do: {:error, cs}
  defp normalize_result({:error, _step, reason, _}, _key), do: {:error, reason}

  # 감사 스냅샷: 메타 필드 제외한 도메인 필드만(decimal 은 문자열로 직렬화).
  defp snapshot(%mod{} = record) do
    mod.__schema__(:fields)
    |> Enum.reject(&(&1 in [:id, :inserted_at, :updated_at]))
    |> Map.new(fn field -> {field, serialize(Map.get(record, field))} end)
  end

  defp serialize(%Decimal{} = d), do: Decimal.to_string(d)
  defp serialize(other), do: other
end
