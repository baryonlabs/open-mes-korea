# mix.exs — deps 병합 기준본 (통합 최종)
#
# 이 파일은 실행용이 아니라 병합 가이드다. phx.new 가 생성한 mix.exs 의 `defp deps do [...] end`
# 안에, 아래 "확장 deps" 블록을 추가한다. phx.new 기본 deps 는 절대 지우지 말 것.
#
# 출처:
#   - phx.new 기본          : phx.new 1.7 산출
#   - Broadway              : 06 (EXT-1) skel/mix.deps.exs
#   - ex_aws/ex_aws_s3/...  : 07 (EXT-2) CORE_PATCH.md L58-61
#   - eqrcode               : 11_addon_lot_qr_label (애드온③, ~> 0.2)
#   - nimble_csv            : 미사용(애드온① 은 직접 인코딩 — 추가하지 않음)

defp deps do
  [
    # ── phx.new 1.7 기본 (그대로 둔다) ──────────────────────────────────
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
     github: "tailwindlabs/heroicons",
     tag: "v2.1.1",
     sparse: "optimized",
     app: false,
     compile: false,
     depth: 1},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_poller, "~> 1.0"},

    # ── EXT-1 설비 수집 (06) ────────────────────────────────────────────
    {:broadway, "~> 1.1"},

    # ── EXT-2 멀티미디어 (07) — MinIO(S3 호환) ─────────────────────────
    {:ex_aws, "~> 2.5"},
    {:ex_aws_s3, "~> 2.5"},
    {:sweet_xml, "~> 0.7"},
    {:hackney, "~> 1.20"},
    {:file_system, "~> 1.0"},

    # ── 애드온 ──────────────────────────────────────────────────────────
    {:eqrcode, "~> 0.2"}
    # 애드온① CSV 는 직접 인코딩 → nimble_csv 추가하지 않음.
    # 애드온②④⑤ 는 추가 deps 없음(순수 Ecto 쿼리).
    # 레지스트리/카탈로그(10)는 추가 deps 없음(순수 Elixir + LiveView 스택).
  ]
end
