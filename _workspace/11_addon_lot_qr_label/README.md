# 11. 애드온③ — LOT QR 라벨 생성 (LotQrLabel)

설계 `09_architect_registry_catalog_design.md` **§2 애드온③ + §7-b** 의 구현물이다.
MaterialLot 의 `lot_no` 를 QR 코드 라벨(인쇄용)로 생성하는 **작고 독립적인 읽기 전용 확장**.

> **읽기 전용으로 못 박음(설계 §0-B-7 강조)**: LOT 상태(available → ...)를 절대 변경하지 않는다.
> Repo 읽기만, 쓰기/AuditLog/Outbox/LotConsumption 0, 새 테이블 0, 코어 수정 0.

---

## 파일 구조

```text
11_addon_lot_qr_label/
├── lib/open_mes_addons/lot_qr_label/
│   ├── extension.ex                  # OpenMes.Addons.LotQrLabel.Extension — behaviour(메타데이터)
│   ├── material_lot.ex               # 읽기 전용 MaterialLot 스키마(changeset 없음 → 쓰기 차단)
│   └── live/
│       └── lot_qr_label_live.ex      # OpenMesWeb.Addons.LotQrLabelLive — 검색/미리보기/인쇄
├── lib/open_mes_addons/lot_qr_label.ex   # OpenMes.Addons.LotQrLabel — 퍼사드(읽기 조회 + QR + 라벨 조립 + enabled?)
└── test/open_mes_addons/lot_qr_label/
    ├── extension_test.exs            # behaviour 준수, enabled? 게이트(DB 불필요)
    ├── qr_label_test.exs             # QR 페이로드 정확성, SVG, 라벨 조립, 쓰기 함수 부재(DB 불필요)
    └── queries_test.exs             # LOT 조회/필터 + (중요)LOT 쓰기 없음 검증(DB 필요)
```

### 핵심 역할

| 모듈 | 역할 |
|------|------|
| `OpenMes.Addons.LotQrLabel.Extension` | 카탈로그 메타데이터. id `:addon_lot_qr_label`, category `:traceability`, home_path `/extensions/lot-qr-label`. `enabled?` 위임. |
| `OpenMes.Addons.LotQrLabel.MaterialLot` | `material_lots` 읽기 전용 Ecto 스키마. **changeset 미제공** → Repo 쓰기 입력 불가. status 한국어 라벨 헬퍼. |
| `OpenMes.Addons.LotQrLabel` | 퍼사드. `get_lot/1`, `get_lot_by_no/1`, `search_lots/1`(읽기), `qr_payload/1`·`qr_svg/1`(순수), `build_label/1`, `enabled?/0`. |
| `OpenMesWeb.Addons.LotQrLabelLive` | LiveView: LOT 검색/필터 → QR 라벨 미리보기(SVG) → 인쇄용 레이아웃(`window.print()`). 쓰기 이벤트 없음. |

---

## 의존성 (경량 1개)

`eqrcode` — 순수 Elixir QR 생성기(외부 바이너리/네트워크 불필요). SVG 렌더. 과한 라벨 디자인 시스템 없음.

```elixir
# mix.exs deps/0 — 설계 §4.5 에서 이미 애드온③ 슬롯으로 표기됨
{:eqrcode, "~> 0.2"}
```

---

## 카탈로그 노출 스니펫 (통합 시 3곳만 건드림 — 설계 §7-b 슬롯)

### 1) `config/config.exs` — `:extensions` 리스트 + 게이트

```elixir
config :open_mes, :extensions, [
  # ... 기존 EXT-1/EXT-2/다른 애드온 ...
  OpenMes.Addons.LotQrLabel.Extension      # ← 애드온③ 등록(카탈로그 노출)
]

# 읽기 전용이라 기본 on 안전(원하면 false 로 시작 가능)
config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
```

> 등록(`:extensions` 포함)되면 `Registry.all/0` 이 읽어 카탈로그에 **카드로 자동 노출**된다.
> enabled=false 여도 "비활성" 배지로 보인다(설계 §3.3). 카탈로그 코드 변경 0.

### 2) `config/test.exs` — 테스트에서 라우트/게이트 활성

```elixir
config :open_mes, OpenMes.Addons.LotQrLabel, enabled: true
```

### 3) `lib/open_mes_web/router.ex` — 조건부 LiveView scope (`skel/router.ex` 슬롯 해제)

```elixir
if OpenMes.Addons.LotQrLabel.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/lot-qr-label", LotQrLabelLive, :index
  end
end
```

> `application.ex` 는 **건드리지 않는다**(애드온은 백그라운드 프로세스 0, supervised child 불필요).

---

## QR 페이로드 형식

```text
OPENMES:LOT:<lot_no>
```

- 접두사 `OPENMES:LOT:` 로 스캐너/연동 시스템이 LOT 라벨임을 식별.
- **lot_no(식별자)만** 인코딩. 상태/수량 같은 가변 값은 넣지 않는다 — 라벨 인쇄 후 LOT 상태가
  바뀌어도 QR 은 LOT 식별자로 항상 유효해야 하므로. (`qr_label_test.exs` 로 고정.)

---

## 비침투 / 읽기 전용 준수 메모 (qa-auditor 대비)

- **읽기 전용**: 퍼사드는 `Repo.get/one/all` 만 호출. insert/update/delete 0. `build_label`·`qr_payload`·`qr_svg` 는 순수 함수.
- **쓰기 경로 부재(구조적)**: `MaterialLot` 에 changeset 이 없어 Repo 쓰기의 입력이 될 수 없다.
  `queries_test.exs` 가 모든 읽기 경로 호출 후 `material_lots` 행 수/상태/updated_at 불변을 검증.
- **AuditLog/Outbox/LotConsumption 무관**: 도메인 쓰기 0 → 감사 룰 적용 대상 아님(설계 §2 말미 — 오탐 금지).
- **새 테이블 0**: 마이그레이션 없음. 코어 `material_lots` 를 읽기로만 매핑.
- **코어 비침투**: `lib/open_mes_addons/lot_qr_label/` 격리. 코어 스키마/컨텍스트 수정 0.
- **config on/off**: `enabled?/0` 게이트(기본 false). 꺼지면 카탈로그에 비활성 배지, 라우트 미등록.

> 전제: `material_lots` 테이블은 코어 LOT 마이그레이션 산출물이다(MVP 미구현 시 통합 후
> `queries_test.exs` 활성화). 애드온은 테이블을 만들지 않는다(읽기 전용).
```
