# 코어 접점 패치 (application.ex 1곳 + config + 옵션 router)

> EXT-2 의 **유일한 코어 접점**은 `application.ex` 의 조건부 child 추가 1곳이다(§7.2).
> 그 외 `lib/open_mes/` 하위는 절대 수정하지 않는다. 아래 패치를 코어에 적용한다.
> `enabled: false`(기본)면 어떤 child 도 뜨지 않으므로 코어 동작/테스트에 영향이 0이다.

---

## 1. `lib/open_mes/application.ex` — 조건부 child 추가 (유일한 코어 코드 변경)

`children` 리스트 끝에 `media_children()` 을 펼쳐 넣고, private 함수 1개를 추가한다.

```elixir
# lib/open_mes/application.ex
defmodule OpenMes.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        OpenMes.Repo,
        OpenMesWeb.Telemetry,
        {Phoenix.PubSub, name: OpenMes.PubSub},
        OpenMesWeb.Endpoint
        # ... 기존 코어 child ...
      ] ++ media_children()   # ← EXT-2: 이 한 줄만 추가

    opts = [strategy: :one_for_one, name: OpenMes.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ── EXT-2(멀티미디어 수집) 조건부 child — config :media 가 켜졌을 때만 기동 ──
  # enabled? == false(기본)면 빈 리스트 → watch/transfer 가 아예 안 뜬다. 코어 영향 0.
  defp media_children do
    if OpenMes.Media.enabled?() do
      [
        OpenMes.Media.Transfer.TransferSupervisor,  # 동시 이관 제한(백프레셔)
        OpenMes.Media.Watch.Scanner,                # NAS 폴링 감지
        OpenMes.Media.Transfer.Dispatcher           # detected→uploading 픽업·디스패치
      ]
    else
      []
    end
  end
end
```

> 기동 순서 주의: TransferSupervisor 가 Scanner/Dispatcher 보다 먼저 와야 한다
> (Dispatcher 가 제출할 슈퍼바이저가 살아 있어야 함).

---

## 2. `mix.exs` — deps 추가 (코어 의존성 목록에 추가, 코어 로직 변경 아님)

```elixir
# mix.exs deps/0 에 추가
{:ex_aws, "~> 2.5"},          # S3 호환 클라이언트 (MinIO 도 S3 API)
{:ex_aws_s3, "~> 2.5"},
{:sweet_xml, "~> 0.7"},       # ex_aws_s3 응답 파싱
{:hackney, "~> 1.20"}         # ex_aws HTTP 클라이언트
# (file_system 은 미사용 — §2.2 폴링 채택. deps 에서 제외)
```

---

## 3. config — 기본 비활성 + runtime 환경변수 (§6.1)

```elixir
# config/config.exs — 기본 비활성(코어는 false 여도 완전 동작)
config :open_mes, OpenMes.Media,
  enabled: false,
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink
```

```elixir
# config/runtime.exs — 환경변수로 켬 + object storage 설정
config :open_mes, OpenMes.Media,
  enabled: System.get_env("MEDIA_ENABLED", "false") == "true",
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink,
  bucket: System.get_env("MEDIA_BUCKET", "open-mes-media"),
  watch_roots: System.get_env("MEDIA_WATCH_ROOTS", "") |> String.split(",", trim: true),
  scan_interval_ms: 5_000,
  min_quiet_seconds: 10,
  dispatch_interval_ms: 2_000,
  max_concurrent_transfers: 3,
  max_retries: 5,
  stale_uploading_seconds: 1_800

# ex_aws (MinIO) — S3 호환 endpoint
config :ex_aws,
  access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
  secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin"),
  json_codec: Jason

config :ex_aws, :s3,
  scheme: System.get_env("MINIO_SCHEME", "http://"),
  host: System.get_env("MINIO_HOST", "localhost"),
  port: String.to_integer(System.get_env("MINIO_PORT", "9000")),
  region: "us-east-1"
```

---

## 4. (옵션) `lib/open_mes_web/router.ex` — 조건부 `/media` 조회 scope

읽기 전용 상태 조회만 노출(원본 바이너리 직접 서빙 금지 — presigned URL 은 후속).
**`enabled?` 가 false 면 등록하지 않는다.**

```elixir
# router.ex 끝부분 (옵션)
if OpenMes.Media.enabled?() do
  scope "/media", OpenMesWeb do
    pipe_through :api   # 코어 기존 read 파이프라인 재사용

    get "/health", MediaHealthController, :show
    get "/assets/:id", MediaAssetController, :show
  end
end
```

> 컨트롤러는 MVP 범위 밖(상태 조회는 `OpenMes.Media.get_asset/1` / `list_by_state/2` 로 충분).
> 노출이 필요해지면 얇은 컨트롤러를 추가한다. 본 산출물은 라우터 배선 예시만 제공.

---

## 5. docker-compose — MinIO 추가 (§7.4)

```yaml
services:
  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    ports: ["9000:9000", "9001:9001"]
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes: ["minio_data:/data"]
volumes:
  minio_data:
```

버킷 생성(최초 1회): `mc mb local/open-mes-media` 또는 콘솔(http://localhost:9001).
```
