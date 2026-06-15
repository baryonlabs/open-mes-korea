# 코어 패치 (1/2): `lib/open_mes/application.ex`

> 설계 §6.1, §7.2 — 코어-확장의 **유일한 배선 접점 중 하나**. config 게이트된 조건부 child 추가.
> 이 변경은 `enabled: false`(기본)면 Broadway child 를 띄우지 않으므로 코어 동작에 영향 0.

## 변경 전 (개념)

```elixir
defmodule OpenMes.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      OpenMes.Repo,
      OpenMesWeb.Endpoint
      # ... 기존 코어 children
    ]

    opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## 변경 후

```elixir
defmodule OpenMes.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        OpenMes.Repo,
        OpenMesWeb.Endpoint
        # ... 기존 코어 children
      ] ++ ingest_children()

    opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ── 확장 배선 접점 (설계 §6.1) ──────────────────────────────
  # config :enabled 가 true 일 때만 Broadway 파이프라인을 supervise.
  # Broadway 가 BufferProducer 까지 함께 supervise 하므로 child 는 Pipeline 하나뿐.
  # enabled:false(기본)면 빈 리스트 → 코어는 확장 없이 완전히 동작.
  defp ingest_children do
    if OpenMes.Ingest.enabled?() do
      [OpenMes.Ingest.Pipeline]
    else
      []
    end
  end
end
```

## diff 형태 (적용용)

```diff
     children =
-      [
-        OpenMes.Repo,
-        OpenMesWeb.Endpoint
-      ]
+      [
+        OpenMes.Repo,
+        OpenMesWeb.Endpoint
+      ] ++ ingest_children()

     opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
     Supervisor.start_link(children, opts)
   end
+
+  defp ingest_children do
+    if OpenMes.Ingest.enabled?() do
+      [OpenMes.Ingest.Pipeline]
+    else
+      []
+    end
+  end
 end
```

**qa-auditor 검증 포인트**: 이 파일 변경은 `ingest_children/0` 추가 + children 리스트에 `++ ingest_children()` 한 줄뿐이다. 그 외 코어 로직 변경 없음.
