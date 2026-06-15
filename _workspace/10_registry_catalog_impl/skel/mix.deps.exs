# mix.exs deps 병합 참조 (설계 §4.5)
#
# 이 파일은 실행용이 아니라 **병합 가이드**다. phx.new 가 생성한 mix.exs 의 `deps/0`
# 함수에, 아래 "확장 deps" 블록을 추가한다. phx.new 기본 deps 는 그대로 둔다.
#
# 적용법:
#   1) mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer
#   2) 생성된 mix.exs 의 defp deps do [...] end 안 끝부분에 아래 확장 deps 를 추가
#   3) mix deps.get

defp deps do
  [
    # ── phx.new 기본(생략 표기 — 그대로 둔다) ──
    {:phoenix, "~> 1.7"},
    {:phoenix_ecto, "~> 4.4"},
    {:ecto_sql, "~> 3.10"},
    {:postgrex, ">= 0.0.0"},
    {:phoenix_html, "~> 4.0"},
    {:phoenix_live_view, "~> 0.20"},
    {:phoenix_live_dashboard, "~> 0.8"},
    {:jason, "~> 1.2"},
    {:bandit, "~> 1.0"},
    {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
    {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
    {:heroicons,
     github: "tailwindlabs/heroicons", tag: "v2.1.1", sparse: "optimized", app: false, compile: false, depth: 1},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},

    # ── EXT-1 설비 수집(06) ──
    {:broadway, "~> 1.1"},

    # ── EXT-2 멀티미디어(07) ──
    {:ex_aws, "~> 2.5"},
    {:ex_aws_s3, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},
    {:hackney, "~> 1.20"},
    {:file_system, "~> 1.0"},

    # ── 애드온(애드온 통합 시 활성화 — 이 기반 작업 범위 밖) ──
    # {:eqrcode, "~> 0.2"}      # 애드온③ LOT QR (SVG QR 생성)
    # {:nimble_csv, "~> 1.2"}   # 애드온① (선택 — 수동 인코딩 시 불필요)

    # 레지스트리/카탈로그(이 기반 작업)는 추가 deps 가 없다.
    # Extension/Definition/Registry 는 순수 Elixir, CatalogLive 는 phx.new LiveView 스택만 사용.
  ]
end
