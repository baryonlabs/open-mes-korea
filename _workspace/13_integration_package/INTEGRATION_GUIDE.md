# Open MES Korea — 통합 가이드 (INTEGRATION_GUIDE.md)

`_workspace` 의 모든 산출물(코어 02 / EXT-1 06 / EXT-2 07 / 기반작업 10 / 애드온 5개)을
하나의 동작하는 Phoenix 앱으로 통합하는 단계별 가이드다.

> ## 이 환경의 한계 (반드시 인지)
> 이 패키지가 만들어진 환경에는 **elixir/mix 가 설치되어 있지 않다.** 따라서
> 컴파일/마이그레이션/실행 검증은 **수행되지 않았다.** 이 패키지는 **정적 정확성**
> (경로 매핑, 모듈명, deps 버전, 마이그레이션 순서)만 보장한다.
> 실제 컴파일/실행은 **사용자가 로컬에서** Step 1~6 을 따라 직접 수행해야 한다.

---

## 패키지 구성

```text
13_integration_package/
├── INTEGRATION_GUIDE.md          # 이 문서
├── integrate.sh                  # 소스 파일 배치 스크립트(멱등)
├── docker-compose.yml            # TimescaleDB + MinIO + 버킷 생성
├── MIGRATION_ORDER.md            # 마이그레이션 7개 순서/의존성
├── VERIFICATION_CHECKLIST.md     # 통합 후 검증 항목
└── merge_files/                  # phx.new 산출물에 병합/덮어쓸 기준본
    ├── mix.deps.exs              # mix.exs deps 블록(병합)
    ├── config.exs                # config/config.exs 추가분(병합)
    ├── dev.exs                   # config/dev.exs 추가분(병합)
    ├── runtime.exs               # config/runtime.exs 추가분(병합)
    ├── application.ex            # lib/open_mes/application.ex(덮어쓰기/병합)
    └── router.ex                 # lib/open_mes_web/router.ex(덮어쓰기)
```

---

## Step 0 — 사전 요구

| 항목 | 권장 버전 | 비고 |
|------|----------|------|
| Erlang/OTP | 26+ | |
| Elixir | 1.16+ | |
| Phoenix(installer) | 1.7.x | `mix archive.install hex phx_new` |
| Node.js | 18+ | esbuild/tailwind assets |
| Docker / Docker Compose | 최신 | TimescaleDB + MinIO 기동용 |

```bash
elixir --version          # OTP 26 / Elixir 1.16+ 확인
mix local.hex --force
mix archive.install hex phx_new --force
docker --version
```

---

## Step 1 — Phoenix 앱 생성

프로젝트 루트(`/Users/hongsw/dev/open-mes-korea`)에서 현재 디렉토리에 생성한다.
카탈로그가 LiveView 라 LiveView 스택을 살린다(`--no-dashboard` 금지).

```bash
cd /Users/hongsw/dev/open-mes-korea
mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer
# 기존 파일(_workspace 등)과 충돌하면 phx.new 가 물어본다 → 덮어쓰지 말고 보류(N).
# phx.new 가 mix.exs / config/* / lib/open_mes/application.ex / lib/open_mes_web/router.ex 를 만든다.
```

> 과제 프롬프트의 `--database postgres` 는 phx.new 기본값이라 명시 안 해도 동일하다.
> 위 옵션은 10/09 설계가 합의한 `--app open_mes --module OpenMes --binary-id --no-mailer` 를 따른다.

---

## Step 2 — 소스 코드 배치 (integrate.sh)

`_workspace` 산출물의 `lib/·priv/·test/` 를 앱 트리로 복사한다. **파일 배치만** 하며
config/mix.exs/application.ex/router.ex 병합은 하지 않는다(Step 3 수동).

```bash
cd /Users/hongsw/dev/open-mes-korea/_workspace/13_integration_package
./integrate.sh
# 또는 확인 없이:  ./integrate.sh --yes
# 경로 변경 시:    WORKSPACE=/path/_workspace TARGET=/path/open_mes ./integrate.sh
```

스크립트는 멱등(여러 번 실행 안전)하고, `*.md / patches/ / skel/ / config/ / *.snippets.md`
는 제외한다(이들은 병합 기준 → Step 3). 복사 결과 요약을 출력한다.

**경로 매핑 요약**(스크립트가 수행):

| 출처 | 대상 |
|------|------|
| `02/lib/open_mes/{audit,outbox,production}/*` | `lib/open_mes/{audit,outbox,production}/*` |
| `02/lib/open_mes_web/{controllers,plugs}/*` | `lib/open_mes_web/{controllers,plugs}/*` |
| `02/priv/repo/migrations/000001~3` | `priv/repo/migrations/` |
| `10/lib/open_mes/extensions/*` | `lib/open_mes/extensions/*` |
| `10/lib/open_mes_web/live/catalog_live.ex` | `lib/open_mes_web/live/` |
| `10/lib/open_mes_ingest/extension.ex` | `lib/open_mes_ingest/extension.ex` |
| `10/lib/open_mes_media/extension.ex` | `lib/open_mes_media/extension.ex` |
| `06/lib/open_mes_ingest/*` | `lib/open_mes_ingest/*` |
| `06/lib/open_mes_web/{controllers,plugs}/*` | `lib/open_mes_web/{controllers,plugs}/*` |
| `06/priv/repo/migrations/100001~3` | `priv/repo/migrations/` |
| `07/lib/open_mes_media/*` | `lib/open_mes_media/*` |
| `07/priv/repo/migrations/000010` | `priv/repo/migrations/` |
| `11_addon_*/lib/open_mes_addons/*` | `lib/open_mes_addons/*` |
| `11_addon_*/lib/open_mes_web/live/addons/*` | `lib/open_mes_web/live/addons/*` |
| `11_addon_wo_csv_export/lib/open_mes_web/controllers/*` | `lib/open_mes_web/controllers/` |

> **router.ex 주의**: 02 의 router.ex 는 복사하지 않는다(Step 3 의 merge_files/router.ex 가 흡수).
> **extension.ex 주의**: EXT-1/EXT-2 의 메타데이터 `extension.ex` 는 10 것을 쓴다(06/07 에는 없음).

---

## Step 3 — config / mix.exs / application.ex / router.ex 병합

`merge_files/` 의 6개 파일을 phx.new 산출물에 반영한다.
**병합(부분 추가)** 과 **덮어쓰기(통째 교체)** 를 정확히 구분한다.

| merge_files 파일 | 대상 | 방식 |
|------------------|------|------|
| `mix.deps.exs` | `mix.exs` 의 `defp deps do [...] end` | **병합** — 확장 deps 블록을 deps 리스트에 추가(phx 기본 deps 유지) |
| `config.exs` | `config/config.exs` | **병합** — `:extensions` + 게이트 + ex_aws 블록을 추가(맨 끝 `import_config` 위). phx 기본 설정 유지 |
| `dev.exs` | `config/dev.exs` | **병합** — Repo 접속값 확인 + EXT/애드온 dev 게이트 추가 |
| `runtime.exs` | `config/runtime.exs` | **병합** — 환경변수 게이트 블록 추가(prod 블록 유지) |
| `application.ex` | `lib/open_mes/application.ex` | **덮어쓰기** 권장 — phx 기본 child(Repo/Telemetry/PubSub/Endpoint)를 포함한 통합본. phx 가 DNSCluster/Finch 등을 넣었다면 children 리스트에 다시 추가 |
| `router.ex` | `lib/open_mes_web/router.ex` | **덮어쓰기** — 카탈로그+코어+확장 scope 통합본 |

### :extensions 등록 목록 (7개 — 정확히 이대로)

```elixir
config :open_mes, :extensions, [
  OpenMes.Ingest.Extension,                       # EXT-1 (10/lib/open_mes_ingest/extension.ex)
  OpenMes.Media.Extension,                        # EXT-2 (10/lib/open_mes_media/extension.ex)
  OpenMes.Addons.WoCsvExport.Extension,           # 애드온① id :addon_wo_csv_export / :production
  OpenMes.Addons.DefectStats.Extension,           # 애드온② id :addon_defect_stats / :quality
  OpenMes.Addons.LotQrLabel.Extension,            # 애드온③ id :addon_lot_qr_label / :traceability
  OpenMes.Addons.EquipmentOee.Extension,          # 애드온④ id :addon_equipment_oee / :analytics
  OpenMes.Addons.DailyProductionSummary.Extension # 애드온⑤ id :addon_daily_production_summary / :production
]
```

> 컴파일 에러 회피 팁: Step 2 로 7개 확장 소스를 이미 배치했으므로 7개 전부 한 번에 넣어도 된다.
> 단계적으로 올리고 싶으면 `:extensions` 를 `[]` 로 시작해 확장별로 한 줄씩 추가해도 된다.

---

## Step 4 — 인프라 기동 (docker-compose)

```bash
cd /Users/hongsw/dev/open-mes-korea/_workspace/13_integration_package
docker compose up -d
docker compose ps            # db / minio healthy 확인
# MinIO 콘솔: http://localhost:9001 (minioadmin/minioadmin), 버킷 open-mes-media 자동 생성됨
```

- `db` 는 `timescale/timescaledb:latest-pg16` — EXT-1 의 `CREATE EXTENSION timescaledb` 가 동작한다.
- EXT-1/EXT-2 를 안 쓸 거면 docker 없이 일반 PostgreSQL 로도 코어는 동작한다(MIGRATION_ORDER.md 참조).

---

## Step 5 — deps / DB / 서버

```bash
cd /Users/hongsw/dev/open-mes-korea
mix deps.get                 # broadway, ex_aws*, sweet_xml, hackney, file_system, eqrcode 포함
mix compile                  # 경고/에러 없는지 확인
mix ecto.create
mix ecto.migrate             # 7개 마이그레이션 순서대로(MIGRATION_ORDER.md)
# (선택) mix run priv/repo/seeds.exs
mix test                     # 코어+레지스트리+확장 테스트
mix phx.server               # http://localhost:4000
```

확장을 켜고 서버를 띄우려면(개발 dev.exs 가 EXT 를 켜둠), 인프라가 떠 있어야 한다.
런타임 환경변수로 제어하려면:

```bash
INGEST_ENABLED=true MEDIA_ENABLED=true \
INGEST_DEVICE_TOKENS=dev-device-token \
MEDIA_BUCKET=open-mes-media \
mix phx.server
```

---

## Step 6 — 카탈로그 + 확장 동작 확인

1. `http://localhost:4000/` → 확장 카탈로그. 카드 **7개** 노출 확인.
   - 작업지시 CSV 내보내기 / 불량 통계 위젯 / LOT QR 라벨 생성 / 설비 가동률 OEE /
     일일 생산 요약 / 설비 수집(EXT-1) / 멀티미디어(EXT-2)
2. 각 카드 카테고리 배지(생산/품질/추적성/분석) 확인.
3. enabled 확장은 "열기" 링크로 LiveView 이동:
   - `/extensions/wo-csv-export`, `/extensions/defect-stats`, `/extensions/lot-qr-label`,
     `/extensions/equipment-oee`, `/extensions/daily-production-summary`
4. EXT-1 활성 시: `curl localhost:4000/ingest/health` (디바이스 토큰 헤더 필요).
5. 코어 API: `POST /api/work_orders` (actor 헤더 필요 — RequireActor 플러그).

세부 항목은 `VERIFICATION_CHECKLIST.md` 참조.

---

## 트러블슈팅

### TimescaleDB 확장이 없을 때 (`CREATE EXTENSION timescaledb` 실패)
- 원인: 일반 `postgres` 이미지를 쓰거나 DB 가 TimescaleDB 빌드가 아님.
- 해결: docker-compose.yml 의 `timescale/timescaledb:latest-pg16` 사용.
- EXT-1 을 안 쓸 거면: `INGEST_ENABLED=false` 로 두고, `priv/repo/migrations/` 에서
  `20260613100001~100003` 3개 파일을 제외(복사하지 않거나 삭제) → 일반 PG 로 마이그레이션 통과.

### MinIO 미기동 시 EXT-2 degrade
- EXT-2 enabled + MinIO 미접속이면 watch/transfer 파이프라인이 전송 실패를 기록할 뿐 앱은 살아 있다.
- 정상화: `docker compose up -d minio createbuckets` 후 버킷(open-mes-media) 확인.
- 끄려면: `MEDIA_ENABLED=false`(application.ex 의 media_children 가 빈 리스트가 되어 child 미기동).

### 카탈로그에 카드가 일부만 보임
- `:extensions` 리스트에 7개 모듈이 모두 들어갔는지 확인(merge_files/config.exs).
- 등록(리스트 포함)과 활성(enabled?)은 별개 — disabled 도 "비활성" 배지로 보여야 정상.
  안 보이면 리스트 누락, 비활성 배지면 정상(게이트 off).

### 컴파일 에러: `:extensions` 의 모듈을 못 찾음
- 해당 확장 소스가 lib 에 배치되지 않음 → integrate.sh 재실행 또는 해당 모듈을 리스트에서 임시 제거.

### 애드온 화면이 빈 표(OEE/불량통계/일일요약)
- 정상 degrade. 이 애드온들은 `production_results / defect_records / operations / routings`
  같은 코어 테이블을 읽는데, 현재 코어는 WorkOrder 만 구현됨 → 해당 테이블이 생기기 전까지 빈 표.
- 코어가 해당 스키마를 마이그레이션하면 자동으로 채워진다.

### WorkOrder API 401/422
- `RequireActor` 플러그가 actor 식별 정보를 요구한다(설계상 모든 쓰기 API 에 actor 필수).
  요청 헤더에 actor 정보를 넣어야 한다(02 컨트롤러/플러그 구현 참조).
