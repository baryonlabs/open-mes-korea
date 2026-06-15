# 애드온 ① 작업지시 CSV 내보내기 — config / router 병합 스니펫

이 애드온은 **읽기 전용 + 새 테이블 0개**다. 통합 시 **코어 파일 3곳**(config / router)만
건드린다. 실제 config/router 파일은 기반작업(10)이 관리하므로, 아래 블록을 병합한다.

---

## 1. `config/config.exs` — `:extensions` 리스트 + 게이트

`:extensions` 명시 목록(설계 §1.2)에 한 줄, 게이트 한 줄을 추가한다.

```elixir
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,
  OpenMes.Media.Extension,
  OpenMes.Addons.WoCsvExport.Extension,   # ← 애드온 ① 추가(카탈로그 자동 노출)
  # ... 나머지 애드온 ...
]

# 읽기 전용이라 운영상 안전 → 기본 on 권장(원하면 false 로 시작 가능).
config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true
```

> `:extensions` 리스트에 추가하면 `Registry.all/0` 이 자동으로 읽어 카탈로그가 코드 변경 없이
> 카드를 그린다. 켜고/끄기는 리스트 포함 여부가 아니라 위 `enabled:` 게이트가 결정한다.

---

## 2. `config/test.exs` — 테스트 게이트

라우트/컨트롤러 테스트가 활성 상태를 전제하므로 테스트 환경에서 켠다.

```elixir
config :open_mes, OpenMes.Addons.WoCsvExport, enabled: true
```

---

## 3. `lib/open_mes_web/router.ex` — 조건부 scope (애드온 enabled 시에만 등록)

기반작업(10) `skel/router.ex` 하단의 애드온 슬롯에 아래 블록을 추가한다(EXT-1 패턴 승계 —
컴파일 타임 게이트). LiveView 화면 + 다운로드 컨트롤러 라우트 2개.

```elixir
if OpenMes.Addons.WoCsvExport.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser

    live "/wo-csv-export", WoCsvExportLive, :index
    get "/wo-csv-export/download", WoCsvExportController, :download
  end
end
```

- `live "/wo-csv-export"` → 필터 선택 화면(`home_path/0` 가 가리키는 경로와 일치).
- `get ".../download"` → CSV 첨부 다운로드(`send_download`). LiveView 가 파일을 직접 못 보내므로
  일반 HTTP GET 으로 분리한다.

---

## 4. `mix.exs` — deps 변경 없음

외부 CSV 라이브러리를 쓰지 않는다(직접 인코딩, pi). **추가 deps 0**. `nimble_csv` 도입하지 않음.
