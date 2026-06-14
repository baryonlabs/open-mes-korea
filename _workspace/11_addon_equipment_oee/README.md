# 애드온 ④ 설비 가동률 OEE 계산 (EquipmentOee)

설계 `09_architect_registry_catalog_design.md` §2 애드온④, §7-b 의 구현물.
**작고 독립적인 읽기 전용 분석 확장.** OEE = 가용성 × 성능 × 품질.

---

## 한 줄 요약

코어 생산 실적(`ProductionResult`/`Operation`/`Routing`)을 **읽기만** 해서 설비별·기간별
OEE 3요소와 종합 OEE 를 계산·표시한다. 쓰기 0, AuditLog 0, Outbox 0, **새 테이블 0**, 코어 수정 0.

## OEE 정의

| 요소 | 공식 | 출처 |
|------|------|------|
| 가용성 Availability | 실가동시간 / 계획시간 | ProductionResult `started_at`~`ended_at`(실가동), 조회 기간 길이(계획 근사) |
| 성능 Performance | (표준 cycle time × 총생산) / 실가동시간 | Routing `standard_cycle_time`, ProductionResult 수량/시간 |
| 품질 Quality | 양품 / (양품 + 불량) | ProductionResult `good_quantity`/`defect_quantity` |
| **종합 OEE** | 가용성 × 성능 × 품질 | 위 셋의 곱 |

> 계획시간은 코어에 별도 모델이 없어 **조회 기간 길이로 근사**(MVP). 정밀 계획정지 모델은 후속.

## 파일 구조

```text
11_addon_equipment_oee/
├── lib/
│   ├── open_mes_addons/
│   │   ├── equipment_oee.ex                     # 퍼사드 — enabled?/0 게이트만
│   │   └── equipment_oee/
│   │       ├── extension.ex                     # ★ Extension behaviour 구현(메타데이터)
│   │       ├── calculator.ex                    # ★ 순수 계산(OEE 3요소, Repo 무관, 테스트 용이)
│   │       ├── oee.ex                           # 읽기 집계(Repo 읽기 → Calculator)
│   │       └── read_models.ex                   # 코어 테이블 읽기 전용 투영 스키마
│   └── open_mes_web/live/addons/
│       └── equipment_oee_live.ex                # LiveView(설비/기간 선택 + OEE 표, 한국어)
├── config/
│   └── addon_equipment_oee.snippets.md          # config/router 병합 스니펫 + 카탈로그 노출
├── test/open_mes_addons/equipment_oee/
│   ├── calculator_test.exs                      # OEE 정확성 + 0나눗셈/결측 방어
│   ├── oee_test.exs                             # 집계→Calculator 연결(스텁 Repo)
│   └── extension_test.exs                       # behaviour 준수 + enabled? 토글
└── README.md
```

## 모듈 책임

- **`EquipmentOee`** — on/off 게이트(`enabled?/0`). config 미설정 시 기본 false.
- **`EquipmentOee.Calculator`** — 순수 함수. 입력은 숫자뿐, 부수효과 0. 0 나눗셈/결측은
  `nil`(계산 불가, 0% 와 구분)로 방어하고 비율은 0.0~1.0 클램프. 가정이 바뀌어도 테스트로 고정.
- **`EquipmentOee.Oee`** — Repo 읽기 집계. `production_results` ⨝ `operations` ⨝ `routings`
  로 설비별 실가동시간/수량/cycle time 을 모아 Calculator 에 위임. `opts[:repo]` 주입 가능(테스트).
- **`EquipmentOee.ReadModels`** — `production_results`/`operations`/`routings` 읽기 전용 투영
  (changeset 없음 → 쓰기 불가). 코어 비침투를 위해 애드온 네임스페이스에 둠(설계 §2 허용).
- **`OpenMesWeb.Addons.EquipmentOeeLive`** — 기간 선택 → 설비별 OEE 3요소 + 종합 OEE 표.

## 엣지케이스 방어 (설계 필수)

| 상황 | 처리 |
|------|------|
| 계획시간 0/음수 | 가용성 `nil` → 종합 `nil` |
| 실가동시간 0/음수 | 성능 `nil` → 종합 `nil` |
| 생산수량(양품+불량) 0 | 품질 `nil` → 종합 `nil` |
| `started_at`/`ended_at` 결측 | 해당 행 실가동 0 기여(쿼리 CASE 방어) |
| `standard_cycle_time` 결측 | 성능 `nil` |
| 잘못된 기간(to ≤ from) | 빈 목록(쿼리 미실행) |
| Repo/테이블 미가용 | LiveView rescue → 빈 표 degrade(크래시 없음) |

`nil` = "계산 불가"를 명확히 표시("—"), **0% 와 구분**. 어떤 경우에도 크래시하지 않는다.

## 카탈로그 노출

`config :open_mes, :extensions` 에 `OpenMes.Addons.EquipmentOee.Extension` 추가 →
`Registry.all/0` 이 읽어 카탈로그에 카드 자동 추가(카탈로그 코드 변경 0).
카드: 이름 "설비 가동률 OEE" / 카테고리 "분석"(`:analytics`) / v0.1.0 / "열기" → `/extensions/equipment-oee`.
상세 병합 스니펫은 `config/addon_equipment_oee.snippets.md` 참조.

## 비침투 / pi 체크

- 읽기 전용: Repo 읽기만. 쓰기/AuditLog/Outbox/마이그레이션 0.
- 코어 수정 0: `lib/open_mes_addons/equipment_oee/` 격리. 코어는 이 애드온을 모름.
- pi: 계산은 순수 함수로 분리, 무거운 BI/차트 라이브러리 0(표 + 백분율 텍스트).
- 영문 식별자(`:addon_equipment_oee`), 한국어 UI/주석.

## 의존성

추가 deps **없음**. Ecto(읽기 쿼리) + Phoenix LiveView(화면)만 사용 — 둘 다 코어/기반에 이미 존재.
