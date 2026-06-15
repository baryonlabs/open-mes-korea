# config 스니펫 (설계 §4.2, §6.1)

코어 config 파일에 **추가**할 내용. 기존 코어 config 는 변경하지 않는다.
ingest 확장은 기본 비활성(`enabled: false`)이므로 이 추가만으로 코어 동작에 영향이 없다.

## `config/config.exs` — 기본값(비활성)

```elixir
# 설비 수집 확장 — 기본 비활성. 코어는 이게 false 여도 완전히 동작한다.
config :open_mes, OpenMes.Ingest,
  enabled: false,
  # DomainSink 구현체. 기본 NoopSink = 텔레메트리 적재만, 코어 무연계(설계 §6.3).
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: []
```

## `config/runtime.exs` — 환경변수로 켜기 (설계 §4.2)

```elixir
# 운영/스테이징에서 환경변수로 활성화. TimescaleDB 가 설치된 DB 여야 한다(§8.1).
config :open_mes, OpenMes.Ingest,
  enabled: System.get_env("INGEST_ENABLED", "false") == "true",
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens:
    System.get_env("INGEST_DEVICE_TOKENS", "") |> String.split(",", trim: true)
```

## `config/test.exs` — 컨트롤러/파이프라인 테스트용

라우터의 `/ingest` scope 는 컴파일 타임에 `enabled?` 로 게이트되므로(router 패치 참조),
컨트롤러 테스트를 돌리려면 테스트 환경에서 활성화해야 한다.

```elixir
# Broadway 파이프라인 child 는 test helper 에서 개별 기동/정지하거나
# Broadway.test_message/2 로 직접 메시지를 흘려 검증한다(설계 §7.4).
config :open_mes, OpenMes.Ingest,
  enabled: true,
  sink: OpenMes.Ingest.Sink.NoopSink,
  device_tokens: ["test-token"]
```

> **코어 비침투 회귀 검증(설계 §7.3)**: 별도로 `enabled: false` 빌드에서 `mix test`(코어 work_order 테스트) 전체가 통과해야 한다. 이때 `/ingest` scope 는 등록되지 않으며 Broadway child 도 안 뜬다.

## `mix.exs` — 의존성 추가 (설계 §1.1)

```elixir
defp deps do
  [
    # ... 기존 코어 deps ...
    {:broadway, "~> 1.1"}
    # TimescaleDB 는 PostgreSQL 확장이라 라이브러리 deps 추가 없음.
    # 마이그레이션에서 CREATE EXTENSION + create_hypertable 로 활성화.
  ]
end
```

## Docker (설계 §8.1) — 인프라 전제

`CREATE EXTENSION timescaledb` 가 동작하려면 PostgreSQL 이미지를 TimescaleDB 포함
이미지로 교체해야 한다.

```yaml
# docker-compose.yml (db 서비스 image 만 교체)
services:
  db:
    image: timescale/timescaledb:latest-pg16   # ← postgres:16 등에서 교체
    # ... 나머지 동일 ...
```

> 교체하지 않으면 ingest 마이그레이션(enable_timescaledb)이 실패한다. 단 코어는 영향 없음
> (`enabled: false` 면 코어 정상). **사용자 승인 필요 항목**(설계 §8.6-1).
