# 애드온 ④ 설비 가동률 OEE — config / router 병합 스니펫

설계 `09_architect_registry_catalog_design.md` §5, `10_.../README.md` §4 슬롯에 꽂는다.
**3곳만** 건드린다(코어 비침투). 모두 명시적 병합 — 통째 교체 아님.

---

## 1. `config/config.exs` — `:extensions` 리스트 + 게이트

```elixir
# :extensions 리스트에 한 줄 추가(이미 10 기반작업에서 슬롯 표시됨)
config :open_mes, :extensions, [
  # ... 기존 EXT-1/EXT-2/다른 애드온 ...
  OpenMes.Addons.EquipmentOee.Extension          # ← 애드온 ④
]

# 게이트 한 줄. 읽기 전용이라 기본 on 도 안전하나, EXT 컨벤션상 기본 off.
config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
```

## 2. `config/test.exs` — 테스트에서 라우트 필요 시 on

```elixir
config :open_mes, OpenMes.Addons.EquipmentOee, enabled: true
```

## 3. `lib/open_mes_web/router.ex` — 조건부 LiveView scope

`skel/router.ex` 하단 애드온 슬롯에 추가(EXT-1 패턴 — 컴파일 타임 enabled? 게이트):

```elixir
if OpenMes.Addons.EquipmentOee.Extension.enabled?() do
  scope "/extensions", OpenMesWeb.Addons do
    pipe_through :browser
    live "/equipment-oee", EquipmentOeeLive, :index
  end
end
```

> `home_path/0` = `"/extensions/equipment-oee"` 와 일치해야 카탈로그 "열기" 링크가 동작한다.

## 4. (선택) Repo 주입 — 테스트/멀티 Repo

`Oee` 는 기본 `OpenMes.Repo` 를 읽는다. 다른 Repo 를 쓰면:

```elixir
config :open_mes, OpenMes.Addons.EquipmentOee.Oee, repo: MyApp.Repo
```

---

## 카탈로그 노출(자동)

`config :open_mes, :extensions` 리스트에 `OpenMes.Addons.EquipmentOee.Extension` 를 넣으면
`OpenMes.Extensions.Registry.all/0` 이 이를 읽어 **카탈로그에 카드가 자동 추가**된다
(카탈로그 코드 변경 0). enabled=false 면 "비활성" 배지로 표시, true 면 "열기" 링크 노출.

- 카드 표시: 이름 "설비 가동률 OEE" / 카테고리 "분석"(`:analytics`) / v0.1.0 / 설명.
```

## 마이그레이션

**없음(0개).** 새 테이블을 만들지 않는다. 코어 테이블(`production_results`, `operations`,
`routings`)을 읽기 전용 투영(`EquipmentOee.ReadModels`)으로 읽기만 한다.

> 단 OEE 읽기 쿼리가 동작하려면 코어가 `production_results`/`operations`/`routings`
> 테이블을 제공해야 한다(docs/domain-model.md 정의). 현재 `_workspace` 코어는 WorkOrder 만
> 구현됨 → 해당 테이블이 마이그레이션될 때까지 OEE 화면은 빈 표로 안전하게 degrade 한다
> (`EquipmentOeeLive` 가 예외를 rescue). 코어가 정식 스키마를 구현하면 ReadModels 를
> 코어 alias 로 교체 가능(후속).
