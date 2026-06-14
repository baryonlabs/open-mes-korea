# 통합 검증 체크리스트 (통합 후 확인)

> 이 환경엔 elixir/mix 가 없어 자동 컴파일/실행 검증을 할 수 없다.
> 아래는 **사용자가 로컬에서** 통합 후 직접 확인할 항목이다.

## A. 정적/구조 (mix 없이도 사람이 확인 가능)

- [ ] `lib/open_mes/extensions/{extension,definition,registry}.ex` 배치됨
- [ ] `lib/open_mes_ingest/extension.ex`, `lib/open_mes_media/extension.ex` 배치됨(10 메타 모듈)
- [ ] `lib/open_mes_addons/` 아래 5개 애드온 디렉토리 존재
- [ ] `lib/open_mes_web/live/catalog_live.ex` + `lib/open_mes_web/live/addons/*` 존재
- [ ] `priv/repo/migrations/` 에 7개 마이그레이션, 번호 오름차순(MIGRATION_ORDER.md 와 일치)
- [ ] `priv/repo/migrations/` 에 애드온 test/support 스크립트가 **섞이지 않음**(운영 마이그레이션 7개뿐)
- [ ] mix.exs deps 에 broadway / ex_aws / ex_aws_s3 / sweet_xml / hackney / file_system / eqrcode 포함
- [ ] config.exs `:extensions` 리스트에 **7개 모듈 전부** 등록
- [ ] application.ex 에 `ingest_children()` / `media_children()` 배선, 애드온 child 없음
- [ ] router.ex 에 카탈로그(/ , /extensions) + 코어 /api + 애드온 5개 조건부 scope

## B. 컴파일 / deps

- [ ] `mix deps.get` 성공(eqrcode, broadway, ex_aws 계열 모두 받아짐)
- [ ] `mix compile` 경고/에러 없음(특히 `:extensions` 의 7개 모듈이 모두 컴파일 트리에 존재)
- [ ] `mix compile` 시 미정의 모듈(UndefinedFunctionError 컴파일 경고) 없음

## C. DB / 마이그레이션

- [ ] `docker compose up -d` 후 db/minio healthy
- [ ] `mix ecto.create` 성공
- [ ] `mix ecto.migrate` 성공 — 7개 전부 적용(TimescaleDB 이미지에서 5/6번 통과)
- [ ] `equipment_measurements` 가 hypertable 로 생성됨(`SELECT * FROM timescaledb_information.hypertables;`)

## D. 카탈로그 노출 (핵심 — 7개 확장)

- [ ] `mix phx.server` 후 `http://localhost:4000/` 접속 → 카탈로그 렌더
- [ ] 카드 **7개** 노출: 작업지시 CSV 내보내기 / 불량 통계 위젯 / LOT QR 라벨 생성 /
      설비 가동률 OEE / 일일 생산 요약 / (EXT-1)설비 수집 / (EXT-2)멀티미디어
- [ ] 카테고리 배지 확인: production / quality / traceability / analytics 등 분류 정상
- [ ] enabled 확장은 "열기" 링크, disabled 확장은 "비활성" 배지

## E. enabled/disabled 토글

- [ ] `INGEST_ENABLED=false`(기본) → EXT-1 카드 "비활성" 배지, `/ingest` 라우트 미등록
- [ ] `INGEST_ENABLED=true` + TimescaleDB → EXT-1 카드 "열기", `/ingest/health` 응답
- [ ] `MEDIA_ENABLED=true` + MinIO → EXT-2 활성(Scanner/Dispatcher/TransferSupervisor 기동)
- [ ] 애드온 게이트 토글(`ADDON_*_ENABLED`) 시 카탈로그 배지/링크와 라우트 등록이 함께 변함
- [ ] disabled 애드온의 LiveView 경로 직접 접근 시 404(라우트 미등록 — 컴파일 타임 게이트)

## F. 코어 단독 동작 (비침투 검증 — 가장 중요)

- [ ] 모든 확장 off(`INGEST_ENABLED=false MEDIA_ENABLED=false`, 애드온 전부 false)에서
      `mix phx.server` 기동 + WorkOrder API 정상 동작
- [ ] `grep -r "OpenMes.Extensions" lib/open_mes/production lib/open_mes/audit lib/open_mes/outbox`
      → **0건** (코어가 레지스트리/확장을 참조하지 않음)
- [ ] `grep -rE "Repo.(insert|update|delete)" lib/open_mes_addons` → **0건**(애드온 읽기 전용)
- [ ] `:extensions` 리스트를 `[]` 로 비워도 코어 WorkOrder API 가 그대로 동작(레지스트리 분리 가능)
- [ ] `mix test` — 코어 + 레지스트리/카탈로그 + 각 확장 테스트 통과

## G. degrade / 트러블슈팅 확인

- [ ] MinIO 미기동 상태에서 EXT-2 enabled → 앱이 크래시하지 않고 전송 실패만 기록(degrade)
- [ ] OEE/불량통계/일일요약 애드온: 전제 테이블(production_results 등) 부재 시 빈 표로 degrade
      (코어가 WorkOrder 만 구현한 현재 상태에서도 화면이 예외 없이 렌더)
