# 08. QA 감사: EXT-2 멀티미디어 NAS Watch 수집 확장 모듈

- **감사자**: qa-auditor
- **감사일**: 2026-06-13
- **대상**: `_workspace/07_domain_engineer_media_impl/` 전체
- **설계 기준**: `_workspace/05_architect_media_ingest_design.md` (EXT-2)
- **원칙**: `CLAUDE.md` (pi 최소, 데이터 확보 우선, 확장 모듈 구조)
- **검증 방법**: 정적 코드 검토 + grep 불변식 검증 + 테스트 커버리지 확인. (mix 미실행 — 격리 워크스페이스에 코어 트리 부재. 정적 검증으로 한정.)

---

## 최종 판정: ✅ APPROVED

EXT-2 구현은 설계 7개 검증 항목과 EXT-2 고유 불변식(원본 보존·멱등성·스트리밍·상태머신 선점·코어 비침투)을 모두 충족한다. 차단/수정 필요 위반 없음. 아래 ⚠️ 1건(해시 청크 순서)은 운영 강건성 권고이며, 데이터 유실·멱등성 불변식을 깨지 않으므로 승인을 막지 않는다. 후속 개선 권장으로 기록한다.

---

## 항목별 결과

### 1. 코어 비침투 — ✅ PASS (가장 중요)

- ✅ **코어 직접 수정 없음**: 확장 코드 전부 `lib/open_mes_media/`로 격리. 코어(`lib/open_mes/`) 파일은 이 워크스페이스에 포함되지 않으며, 코어 접점은 `CORE_PATCH.md`로만 명시(application.ex 조건부 child 1곳 + config + 옵션 router). 설계 §7.2 "유일한 코어 접점" 준수.
- ✅ **확장→코어 단방향 의존(Repo 한정)**: `grep -rhoE "OpenMes\.[A-Za-z.]+"` 결과 코어 참조는 `OpenMes.Repo`(6회, 실제 호출) + `OpenMes.Outbox`(2회, **주석/문서만** — `media.ex:13`, `sink/media_sink.ex:11`). NoopSink는 Outbox 무의존. 의존 방향 단방향 확인.
- ✅ **EXT-1 무참조**: `grep "OpenMes.Ingest|open_mes_ingest"` → 실제 코드 0건. `invariants_test.exs:44` 가 이를 정적으로 강제.
- ✅ **config off 시 코어 정상**: `media.ex:27 enabled?/0` 기본 false. `CORE_PATCH.md` §1 `media_children/0` 가 false면 빈 리스트. `invariants_test.exs:54` 가 테스트 환경 `enabled?==false`를 강제.

### 2. 원본 보존 불변식 — ✅ PASS (가장 중요)

- ✅ **`File.rm`/`File.rm_rf` 실제 호출 0건**: `grep -rn "File.rm" lib` → 유일 매치 `transfer_worker.ex:18`은 **주석**(불변식 선언문)이다. 실제 호출 없음. `File.stream/File.copy/IO.binread/File.write`도 0건.
- ✅ **transfer_failed/dead 경로에서도 원본 보존**:
  - `transfer_worker.ex:127 fail/2` — transfer_failed 전이 + retry_count↑만, 원본 미터치.
  - `dispatcher.ex:104 bury_exhausted/1` — dead 전이만(`retry_count > max_retries`), 원본 미터치.
  - `dispatcher.ex:88 recover_stale_uploading/1` — stale uploading을 transfer_failed로 회수만, 원본 미터치.
  - 예외 경로(`transfer_worker.ex:75 rescue`)도 transfer_failed 회수만, 원본 미터치.
- ✅ **정적 검증 존재**: `invariants_test.exs:18-27` 가 `lib/open_mes_media/**/*.ex` 전체를 정규식 `File\.rm(_rf)?[!\s(]`로 스캔해 위반 시 fail. 설계 §0-E-11 / §7.3 ⛔원본 보존 충족.

### 3. 멱등성 (EXT-1 버그 교훈) — ✅ PASS

- ✅ **DB 유니크 2단계**: 마이그레이션 `20260613000010_create_media_assets.exs`
  - L65 1차 키 `unique_index([:nas_path,:file_mtime,:file_size], name: :media_assets_source_identity)`.
  - L70 2차 키 `unique_index([:content_hash], where: "content_hash IS NOT NULL", name: :media_assets_content_hash)` (부분 유니크).
- ✅ **`on_conflict: :nothing` 적용**: `registrar.ex:68-71` `Repo.insert(on_conflict: :nothing, conflict_target: [:nas_path,:file_mtime,:file_size])`. 충돌 시 `{:ok, %MediaAsset{id: nil}}` → `{:ok, :skipped}` 정상 처리(에러 아님). 설계 §2.4 패턴 정확 일치.
- ✅ **같은 파일 N회 스캔 → row 1개 테스트**: `registrar_test.exs:27-37` (N회 등록 후 `count == 1`), L39-47 (다른 mtime → row 2개), L16-25 (정상 1건).
- ✅ **조건부 UPDATE 선점(다중 워커 안전)**:
  - `media_asset.ex:95 claim_query/3` — `WHERE id=^id AND state=^from` + StateMachine 화이트리스트 게이트.
  - `dispatcher.ex:153 claim/1` — 영향 행 1이면 선점, 0이면 `:skip`.
  - `transfer_worker.ex:148 transition/3` — `{1,_}→:ok`, `{0,_}→:stale`.
  - 2차 키 충돌(`media_assets_content_hash`)은 `transfer_worker.ex:159-180`에서 Postgrex/Ecto 제약 에러를 `:content_hash_conflict`로 매핑 → duplicate 전이. 정확.

### 4. 파일 안정성 — ✅ PASS

- ✅ **temp/숨김 제외**: `stability.ex:75 temp_name?/1` — `.`시작 또는 `.tmp/.part/.partial/.filepart/~` 접미. `assess/4` 첫 게이트에서 `:ignore`.
- ✅ **mtime 유예**: `stability.ex:88 quiet_elapsed?/3` — `now - mtime >= min_quiet_seconds`(기본 10초). 미경과 시 `{:pending,:mtime_quiet}`.
- ✅ **2-스캔 size 비교**: `assess/4` L60 `prev.size != curr.size → {:pending,:size_changing}`. Scanner가 `seen` map(path→{size,mtime})로 직전 관측치 주입(`scanner.ex:111`).
- ✅ **first_seen 즉시 등록 금지**: `stability.ex:56 is_nil(prev) → {:pending,:first_seen}`. 최소 2회 스캔 강제. Scanner는 `:stable`일 때만 `maybe_register` 호출(`scanner.ex:100-101`). 손상본 수집 1차 방어선 정상.
- ✅ Scanner는 `:ignore/:pending`도 현재 관측치를 `seen`에 누적(`scanner.ex:110-111`)해 안정화 진행 보장.

### 5. 스트리밍 이관 — ✅ PASS

- ✅ **`File.read` 실제 호출 0건**: `grep -rn "File.read" lib` → 유일 매치 `s3_object_store.ex:10`은 **주석**(스트리밍 규칙 선언). 실제 호출 없음. `invariants_test.exs:29-42`가 이관 경로(`/transfer/`,`/object_store/`)에 `File.read` 없음을 정적 강제.
- ✅ **stream_file 멀티파트**: `s3_object_store.ex:33` `ExAws.S3.Upload.stream_file(chunk_size: @chunk_bytes=16MB)` → L36 `ExAws.S3.upload`. GB 영상 메모리 미적재.
- ✅ **단일 패스 SHA-256**: `s3_object_store.ex:35` `Stream.each`로 업로드 청크를 `on_chunk` 콜백 노출. `transfer_worker.ex:47-68` `:crypto.hash_init/update/final`로 누적, `Base.encode16(:lower)`. 별도 재read 없음.
- ✅ **size 검증 후에만 stored**: `transfer_worker.ex:82 verify_and_store/7` — `head/2` size == file_size 불일치 시 transfer_failed(L91-95). 일치 시에만 `commit_stored`.

### 6. 텔레메트리 경계 — ✅ PASS (오탐 없음)

설계 §0-C / §7.3 명시대로 `media_assets`에 AuditLog/actor_id/코어 FK가 **없는 것은 의도된 설계**. 위반으로 지적하지 않음.
- ✅ AuditLog 미생성 — 수집 운영 인덱스(고빈도 텔레메트리 준함). 정상.
- ✅ actor_id 컬럼 없음 — 출처는 `equipment_id`+`nas_path`. 정상.
- ✅ 코어 테이블 FK 없음 (`equipment_id`는 string, FK 아님). 정상.
- ✅ 별도 dead-letter 테이블 없음 — `state=dead`+`last_error`로 대체. 정상.
- 마이그레이션 L7-11, `media_asset.ex:12-15` 주석에 경계가 명시되어 의도 확인됨.

### 7. pi 최소 원칙 — ✅ PASS

- ✅ **특징추출/소음분석 코드 없음**: `grep "특징|소음분석|dB|주파수|FFT|extract_feature"` 매치는 전부 **moduledoc 주석**(`media_sink.ex:10` 등). 실행 코드 0.
- ✅ **`feature_extracted` state만 예약, 호출 경로 0**: `state_machine.ex:29` `"stored"=>["feature_extracted"]` 화이트리스트 자리만. `feature_extracted` 매치 전부 state_machine 정의/주석. 전이를 트리거하는 호출처 없음.
- ✅ **MediaSink 확장점만 예약**: `MediaSink` behaviour + `NoopSink.handle_stored/1 → :ok`(`noop_sink.ex:14`)가 유일 구현. TransferWorker가 stored 직후 호출(`transfer_worker.ex:184`), 실패 격리(`safe_sink`). EXT-3 교체점 보존, 현재는 무동작.
- ✅ **YAGNI**: 별도 Repo/dead-letter 테이블/특징 파이프라인 없음. config off 시 코어 정상(항목1). 호출처 0 선제 추상화 없음.

---

## ⚠️ 후속 개선 권고 (승인 차단 아님)

### W-1. 스트리밍 해시 청크 순서 의존성 — ⚠️ MINOR
- **위치**: `s3_object_store.ex:35-36` + `transfer_worker.ex:50-51`
- **내용**: `on_chunk` 콜백이 `ExAws.S3.upload` 멀티파트 파이프라인의 `Stream.each` 단계에서 호출된다. `ex_aws_s3`의 멀티파트 업로드는 기본적으로 파트를 **동시(concurrent) 처리**할 수 있어, 청크가 파일 바이트 순서와 다르게 `on_chunk`에 도달하면 `:crypto.hash_update` 누적 순서가 어긋나 `content_hash`가 원본 SHA-256과 불일치할 수 있다.
- **영향 평가**: 데이터 유실 불변식(원본 보존)·1차 멱등 키(`nas_path,mtime,size`)·size 검증에는 **영향 없음**. content_hash는 2차(보조) 멱등 키이고, 설계 §2.4가 "정교한 dedup은 1차 키로 충분"으로 한정했으므로 기능 정확성을 깨지 않는다. 따라서 BLOCKED/NEEDS_FIX 아님.
- **권고 수정**: (a) `stream_file` 청크를 업로드 전에 순차 `Stream.transform`으로 해시 누적(업로드 직전 단일 스레드 tap 보장), 또는 (b) ex_aws upload 옵션에서 파트 동시성을 1로 두거나 순서 보장 경로 사용, 또는 (c) content_hash를 "참고용 메타"로 명시하고 2차 유니크 충돌 분기를 best-effort로 문서화. 부하/정합 테스트로 실제 순서 보장 여부를 검증 후 택1.

### W-2. (참고) stale 회수 후 retry_count 미증가 — 정상 설계
- `dispatcher.ex:88` stale uploading 회수 시 `retry_count`를 올리지 않는다(이관 시도 실패가 아니라 중단이므로). `release_back/1`(L178)도 동일. 의도된 동작으로 확인. 위반 아님.

---

## 검증 근거 grep 요약

```
File.rm  (lib)        → transfer_worker.ex:18 (주석만)        ✅ 실호출 0
File.read (lib)       → s3_object_store.ex:10 (주석만)        ✅ 실호출 0
OpenMes.Ingest (lib)  → 0건                                    ✅
코어 참조 (media lib) → OpenMes.Repo ×6(실), OpenMes.Outbox ×2(주석) ✅ 단방향
on_conflict :nothing  → registrar.ex:69                        ✅
유니크 2단계          → migration L65, L70                     ✅
조건부 UPDATE 선점    → media_asset.ex:111, dispatcher.ex:154, transfer_worker.ex:152 ✅
stream_file           → s3_object_store.ex:33                  ✅
feature_extracted 호출처 → 0 (state_machine 정의만)            ✅
특징추출 실행코드     → 0 (주석만)                             ✅
```

## 판정 근거 종합

| 항목 | 결과 |
|------|------|
| 1. 코어 비침투 | ✅ PASS |
| 2. 원본 보존 불변식 | ✅ PASS |
| 3. 멱등성 (2단계 유니크 + on_conflict + 조건부 선점) | ✅ PASS |
| 4. 파일 안정성 (temp/mtime/2-scan/first_seen) | ✅ PASS |
| 5. 스트리밍 이관 (stream_file + 단일패스 해시) | ✅ PASS / ⚠️ W-1 |
| 6. 텔레메트리 경계 | ✅ PASS (오탐 없음) |
| 7. pi 최소 (확장점만 예약, YAGNI) | ✅ PASS |

**최종: ✅ APPROVED** (W-1은 후속 개선 권고로 domain-engineer에 전달, 승인 차단 아님)
