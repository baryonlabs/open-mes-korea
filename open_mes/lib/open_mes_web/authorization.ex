defmodule OpenMesWeb.Authorization do
  @moduledoc """
  공장 역할(role) 기반 화면 가시성·인가의 단일 원천(설계 §2.2).

  순수 함수 모듈(상태 없음). web 계층에만 존재하며 코어 도메인은 손대지 않는다.

  매핑 원천:
    - 관리자 화면(/admin/*)의 role 매핑은 `AdminComponents.menu/0` 트리의 각 항목 `:roles` 필드.
    - 트리에 없는 영역(/shopfloor, /extensions)은 `@area_roles` 맵으로 보강.

  핵심 규칙:
    - `system_admin` 은 모든 화면을 보고 접근한다(항상 true). 메뉴/매핑에 명시 불필요.
    - 그 외 role 은 자기에게 허용된 경로만 — 가시성(사이드바)과 인가(직접 URL) 모두.
    - 경로 인가는 prefix 매칭(예: /admin/work-orders 허용 → /admin/work-orders/123 도 허용).
  """

  alias OpenMesWeb.AdminComponents

  # role 메타 — 식별자(영문) / 한국어명 / 배지 색(Tailwind) / 점 색.
  # 순서 보존(상단바 드롭다운/배지 나열 순서). 설계 §1.1.
  @roles [
    %{
      key: "system_admin",
      label: "시스템 관리자",
      badge_class: "bg-slate-100 text-slate-700",
      dot_class: "bg-slate-500"
    },
    %{
      key: "production_manager",
      label: "생산관리자",
      badge_class: "bg-blue-100 text-blue-700",
      dot_class: "bg-blue-500"
    },
    %{
      key: "quality_manager",
      label: "품질관리자",
      badge_class: "bg-green-100 text-green-700",
      dot_class: "bg-green-500"
    },
    %{
      key: "material_manager",
      label: "자재·창고 담당자",
      badge_class: "bg-amber-100 text-amber-700",
      dot_class: "bg-amber-500"
    },
    %{
      key: "operator",
      label: "현장 작업자",
      badge_class: "bg-purple-100 text-purple-700",
      dot_class: "bg-purple-500"
    }
  ]

  @fallback_role %{
    key: "unknown",
    label: "미지정",
    badge_class: "bg-zinc-100 text-zinc-600",
    dot_class: "bg-zinc-400"
  }

  @default_role "system_admin"

  # 메뉴 트리에 없는 영역의 role 규칙(설계 §2.2). system_admin 은 코드에서 항상 추가.
  @area_roles %{
    "/shopfloor" => ["operator"],
    "/extensions" => []
  }

  @doc "role 메타 리스트(순서 보존)."
  def roles, do: @roles

  @doc "단건 role 메타. 미지 role 은 fallback."
  def role(key), do: Enum.find(@roles, @fallback_role, &(&1.key == key))

  @doc "role 식별자 목록."
  def role_keys, do: Enum.map(@roles, & &1.key)

  @doc "데모 기본 role(세션 없을 때) — 전체 보임."
  def default_role, do: @default_role

  @doc "role 한국어명."
  def role_label(key), do: role(key).label

  @doc "role 배지 색 클래스."
  def role_badge_class(key), do: role(key).badge_class

  @doc "role 점 색 클래스."
  def role_dot_class(key), do: role(key).dot_class

  @doc "유효 role 식별자인가."
  def valid_role?(key), do: key in role_keys()

  @doc """
  경로 인가 판정. system_admin 은 항상 true.
  그 외는 메뉴 트리/area_roles 의 허용 role 에 포함되어야 한다(prefix 매칭).
  """
  def allowed?("system_admin", _path), do: true

  def allowed?(role, path) when is_binary(path) do
    role in roles_for_path(path)
  end

  def allowed?(_role, _path), do: false

  @doc """
  해당 경로를 볼 수 있는 role key 리스트(배지 렌더용). system_admin 항상 포함.
  매칭 실패(미정의 경로)면 system_admin 만(관리자 전용으로 간주).
  """
  def roles_for_path(path) when is_binary(path) do
    roles =
      menu_roles_for_path(path) || area_roles_for_path(path) || []

    Enum.uniq(["system_admin" | roles])
  end

  def roles_for_path(_), do: ["system_admin"]

  @doc """
  해당 role 에게 보이는 메뉴 트리(그룹/항목 필터). system_admin 은 전체.
  빈 그룹(항목 0)은 제거한다.
  """
  def visible_menu(role) do
    AdminComponents.menu()
    |> Enum.map(fn group ->
      items = Enum.filter(group.items, fn item -> allowed_for_item?(role, item) end)
      %{group | items: items}
    end)
    |> Enum.reject(fn group -> group.items == [] end)
  end

  @doc """
  role 의 랜딩 경로(인가 거부 시 리다이렉트 대상).
  visible_menu 의 첫 활성 항목. operator 는 /shopfloor, 없으면 / 로.
  """
  def landing(role) do
    cond do
      role == "operator" ->
        "/shopfloor"

      true ->
        role
        |> visible_menu()
        |> Enum.flat_map(& &1.items)
        |> Enum.find(& &1.enabled)
        |> case do
          nil -> "/"
          item -> item.path
        end
    end
  end

  # ── 내부 ────────────────────────────────────────────────────────────

  # 메뉴 항목의 roles(없으면 그룹 컨텍스트 없이 항목 단위로만 본다 — menu/0 가 항목에 roles 주입).
  defp allowed_for_item?("system_admin", _item), do: true

  defp allowed_for_item?(role, item) do
    role in (Map.get(item, :roles) || [])
  end

  # 메뉴 트리에서 path 와 prefix 매칭되는 항목의 roles. 가장 긴(구체적) 매칭 우선.
  defp menu_roles_for_path(path) do
    AdminComponents.menu()
    |> Enum.flat_map(& &1.items)
    |> Enum.filter(fn item -> path_match?(path, item.path) end)
    |> Enum.sort_by(fn item -> -String.length(item.path) end)
    |> case do
      [] -> nil
      [item | _] -> Map.get(item, :roles) || []
    end
  end

  defp area_roles_for_path(path) do
    @area_roles
    |> Enum.filter(fn {prefix, _} -> path_match?(path, prefix) end)
    |> Enum.sort_by(fn {prefix, _} -> -String.length(prefix) end)
    |> case do
      [] -> nil
      [{_prefix, roles} | _] -> roles
    end
  end

  defp path_match?(current, prefix) when is_binary(current),
    do: current == prefix or String.starts_with?(current, prefix <> "/")

  defp path_match?(_current, _prefix), do: false
end
