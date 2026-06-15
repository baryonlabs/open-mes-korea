# 코어 패치 (2/2): `lib/open_mes_web/router.ex`

> 설계 §4.1, §6.1, §7.2 — 코어-확장의 **유일한 배선 접점 중 하나**. config 게이트된 조건부 `/ingest` scope 추가.
> `OpenMes.Ingest.enabled?()` 가 false 면 scope 자체가 등록되지 않는다(코어 `/api` 영향 0).

## 추가할 내용

기존 라우터(work_order `/api` scope 들)는 **그대로 둔다**. 아래 파이프라인과 조건부 scope 만 추가한다.

```elixir
defmodule OpenMesWeb.Router do
  use OpenMesWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_actor do
    plug OpenMesWeb.Plugs.RequireActor
  end

  # ── 추가: 설비 수집 디바이스 토큰 파이프라인 (설계 §4.2) ──────
  pipeline :require_device_token do
    plug OpenMesWeb.Plugs.RequireDeviceToken
  end

  # ... 기존 /api scope 들 (work_orders) 그대로 ...

  # ── 추가: 설비 수집 scope (확장 활성 시에만 등록, 설계 §6.1) ──
  # 라우터 컴파일 시점에 enabled? 로 게이트. off 면 /ingest 라우트가 아예 없다.
  if OpenMes.Ingest.enabled?() do
    scope "/ingest", OpenMesWeb do
      pipe_through [:api, :require_device_token]

      post "/equipment", IngestController, :create
      get "/health", IngestController, :health
    end
  end
end
```

## diff 형태 (적용용)

```diff
   pipeline :require_actor do
     plug OpenMesWeb.Plugs.RequireActor
   end
+
+  pipeline :require_device_token do
+    plug OpenMesWeb.Plugs.RequireDeviceToken
+  end

   # ... 기존 /api scope 들 ...
+
+  if OpenMes.Ingest.enabled?() do
+    scope "/ingest", OpenMesWeb do
+      pipe_through [:api, :require_device_token]
+
+      post "/equipment", IngestController, :create
+      get "/health", IngestController, :health
+    end
+  end
 end
```

## 주의: 컴파일 타임 게이트와 테스트

`if OpenMes.Ingest.enabled?()` 는 **라우터 컴파일 시점**에 평가된다(모듈 본문). 따라서
컨트롤러 테스트에서 `/ingest` 라우트가 필요하면 테스트 환경 config 에서 `enabled: true` 여야 한다.

- `config/test.exs` 에 `config :open_mes, OpenMes.Ingest, enabled: true, device_tokens: ["test-token"]` 추가(아래 `config/config.exs.snippet.md` 참조).
- 반대로 "코어 비침투 회귀 테스트"(설계 §7.4)는 `enabled: false` 빌드에서 코어 work_order 테스트가 전부 통과함을 확인한다 — 이 경우 `/ingest` scope 가 등록되지 않아도 코어는 정상.

> **대안(런타임 게이트)**: 컴파일 타임 분기가 부담이면 scope 를 항상 등록하되 `require_device_token` plug 앞에 "확장 비활성 시 404" plug 를 두는 방식도 가능하다. MVP 는 설계 §6.1 의 컴파일 타임 조건부 등록을 따른다(코어 라우트 테이블에 흔적조차 안 남김).

**qa-auditor 검증 포인트**: 이 파일 변경은 (1) `require_device_token` 파이프라인 추가, (2) 조건부 `/ingest` scope 추가 두 가지뿐. 기존 `/api` work_order 라우트는 손대지 않음.
