# 05. Architect 설계: NAS Watch 기반 멀티미디어(소음/영상) 데이터 수집 확장 모듈 (EXT-2)

- **작성자**: architect
- **작성일**: 2026-06-13
- **대상**: 레거시 설비/CCTV가 NAS 공유폴더에 떨어뜨리는 대용량 바이너리(소음 녹음, 설비 영상, 이미지) 자동 감지·수집 → object storage 이관 → 메타데이터 인덱싱
- **수집 방식 (확정)**: NAS 공유폴더 watch (브로커리스, 디바이스 무수정)
- **기술 스택 (확정)**: Phoenix (Elixir) + Ecto + PostgreSQL **+ MinIO/S3(object storage)**. (Broadway는 §3.5 결정 참조 — 이번엔 미사용)
- **참고 문서**: CLAUDE.md, docs/extension-roadmap.md, `_workspace/04_architect_ingest_design.md`(EXT-1)
- **로드맵 위치**: EXT-2 멀티미디어 수집
- **수신자**: domain-engineer (구현), qa-auditor (검토)

---

## 0. 설계 원칙 요약 (이 설계가 지켜야 하는 불변 규칙)

EXT-1과 동일한 상위 제약을 승계하고, NAS watch / 대용량 바이너리에 특화된 제약을 추가한다.

### A. 확장 모듈의 코어 비침투 (pi 최소 코어) — EXT-1 승계

1. **코어 무의존**: 코어(`lib/open_mes/`)는 이 확장에 일절 의존하지 않는다. MinIO/NAS watch가 없어도 코어는 완전히 동작한다. 확장은 별도 네임스페이스 `lib/open_mes_media/`로 격리한다.
2. **확장 포인트는 behaviour 계약**: object storage 접근과 코어 도메인 연계는 behaviour로 계약화한다. 확장이 코어 내부 모듈을 직접 호출하지 않는다.
3. **선택적 활성화**: `application.ex`에서 config 플래그(`:media_enabled`)로 watch/이관 child를 켜고 끈다. 꺼져도 코어는 정상 동작하고, 어떤 코어 테스트도 깨지지 않는다.

### B. 데이터 성격별 저장 분리 (이 확장의 핵심)

4. **원본 바이너리는 DB/hypertable에 넣지 않는다.** 소음 원음·영상·이미지는 **object storage(MinIO/S3)**로만 보관. 메타데이터만 PostgreSQL `media_assets` 테이블에 인덱싱한다.
5. **추출 스칼라 특징(소음 dB, 주파수 피크 등)은 EXT-1의 `equipment_measurements`로 합류**한다. 단 **특징 추출 자체는 이번 범위 밖**(EXT-3 예지보전). 이번엔 합류 경로(behaviour 확장 포인트)만 예약한다.

### C. 텔레메트리 경계 일관성 (qa-auditor 오탐 방지)

6. **멀티미디어 메타데이터는 고빈도 텔레메트리에 준한다 → 건건 AuditLog를 달지 않는다.** `media_assets`는 append 후 처리상태(state)를 갱신하는 운영 인덱스이지 도메인 트랜잭션이 아니다.
   - 코어의 "모든 쓰기에 AuditLog" 원칙(CLAUDE.md L69-71)은 **도메인 트랜잭션 데이터에만 적용**된다(WorkOrder/Operation/LOT/불량).
   - `media_assets`의 INSERT 및 state 전이(detected→uploading→stored…)에는 **건건 AuditLog를 달지 않는다** — 명시적 경계 선언.
   - **qa-auditor 주의**: `media_assets` 경로에 AuditLog가 없는 것은 **정상**이다. 누락이 아니다. (§7.3에 검증 항목으로 명시)
7. **도메인 신호는 behaviour 경유로만 코어에 흘린다**(EXT-1 §0-B-6 승계). 멀티미디어 그 자체는 코어에 닿지 않는다. 도메인 의미 사건(예: 영상 수집 완료 → 검사 트리거)이 필요하면 sink behaviour → 코어 `Outbox.emit`. MVP는 인터페이스만 정의(`NoopSink` 기본).

### D. 기존 컨벤션 승계

8. OTP 앱 이름 `open_mes`, 코어 컨텍스트 `OpenMes`, 웹 `OpenMesWeb`. 확장은 `OpenMes.Media`.
9. `media_assets`는 코어 컨벤션대로 `binary_id` PK 사용(고빈도 시계열 hypertable이 아니라 저~중빈도 운영 인덱스이므로 UUID PK가 적절. EXT-1 hypertable과 다른 점).
10. 한국어 우선(주석/에러메시지), 영문 식별자. MVP 최소만, 확장 경로는 남긴다.

### E. EXT-2 고유 불변식 (대용량 바이너리 + NAS watch)

11. **원본 NAS 파일은 object storage 이관이 확정(stored)되기 전까지 삭제 금지.** 이관 실패는 재시도하고, 절대 데이터를 잃지 않는다(데이터 확보 우선 원칙).
12. **파일 안정성**: 쓰기 도중 파일을 잡지 않는다(§2.3 안정화 게이트 통과 후에만 수집).
13. **멱등성 명시 설계**: 같은 파일을 두 번 수집하지 않는다. `(nas_path, file_mtime, size)` 또는 콘텐츠 해시 기반 유니크 제약으로 보장한다(§2.4). EXT-1의 WorkOrder 멱등 전이 버그 교훈 — 멱등성은 암묵에 맡기지 않고 DB 제약으로 못 박는다.
14. **개별 스트리밍 이관 + 백프레셔**: 영상은 수백 MB~GB. 메모리에 통째로 적재하지 않고 스트리밍으로 이관한다. 동시 이관 수를 제한해 NAS/네트워크/MinIO 부하를 통제한다.

---

## 1. 확장 모듈 디렉토리 구조 (코어/EXT-1과 격리)

### 1.1 의존성 추가 (mix.exs)

```elixir
# mix.exs deps에 추가
{:ex_aws, "~> 2.5"},          # S3 호환 클라이언트 (MinIO도 S3 API)
{:ex_aws_s3, "~> 2.5"},
{:sweet_xml, "~> 0.7"},       # ex_aws_s3 응답 파싱
{:file_system, "~> 1.0"},     # (옵션) inotify 기반 watch — §2.2에서 폴링과 비교 후 선택
{:hackney, "~> 1.20"}         # ex_aws HTTP 클라이언트
```

> **결정**: 별도 Repo를 만들지 않는다. `media_assets`는 기존 `OpenMes.Repo`(동일 PostgreSQL)에 만든다. EXT-1과 같은 DB를 공유하되 **테이블 레벨로만 분리**된다(트랜잭션 결합 안 함). 별도 Repo/별도 DB는 MVP 과설계(YAGNI).

> **결정**: object storage 클라이언트는 `ex_aws_s3`(S3 호환)를 기본 구현으로 쓰되, **반드시 behaviour(`ObjectStore`) 뒤에 둔다**(§3). MinIO든 AWS S3든 NCP Object Storage든 endpoint config만 바꿔 교체 가능. 나중에 ex_aws를 통째로 갈아끼워도 behaviour 계약만 지키면 됨.

### 1.2 디렉토리 구조

```text
open_mes/
├── lib/
│   ├── open_mes/                          # ← 코어 (이 확장에 무의존, 변경 없음)
│   │   ├── application.ex                  #   ← child_spec 조건부 추가만 (§6.1, 유일한 코어 접점)
│   │   ├── repo.ex
│   │   └── outbox/outbox.ex                #   기존 emit 헬퍼 — sink 구현체에서만 재사용
│   │
│   ├── open_mes_ingest/                    # ← EXT-1 (별개 확장. EXT-2와 격리. §1.3 공유 지점만 연결)
│   │   └── ...                             #   equipment_measurements 등
│   │
│   ├── open_mes_media/                     # ← EXT-2 확장 네임스페이스 (격리)
│   │   ├── media.ex                        #   확장 퍼사드 (enabled?/0, 공개 진입점, 상태 조회)
│   │   │
│   │   ├── watch/                          #   ── 감지 계층 ──
│   │   │   ├── scanner.ex                  #     주기적 폴링 스캐너 (GenServer, §2.2 채택)
│   │   │   ├── stability.ex                #     쓰기 완료(안정화) 판정 — 순수 함수 (§2.3)
│   │   │   └── path_policy.ex              #     watch 루트/하위경로→equipment_id·media_type 매핑 (§2.5)
│   │   │
│   │   ├── intake/                         #   ── 멱등 등록 계층 ──
│   │   │   └── registrar.ex                #     안정화된 파일을 media_assets에 멱등 등록 (detected) (§2.4)
│   │   │
│   │   ├── transfer/                       #   ── 이관 계층 ──
│   │   │   ├── transfer_worker.ex          #     단일 asset 스트리밍 이관 워커 (Task, §4.2)
│   │   │   ├── transfer_supervisor.ex      #     동시 이관 수 제한 (Task.Supervisor + 큐, 백프레셔, §4.3)
│   │   │   └── transfer_dispatcher.ex      #     detected→uploading 픽업·디스패치 (GenServer poll, §4.1)
│   │   │
│   │   ├── object_store/                   #   ── object storage 추상화 ──
│   │   │   ├── object_store.ex             #     behaviour 정의 (@callback) (§3.1)
│   │   │   ├── s3_object_store.ex          #     MinIO/S3 기본 구현 (ex_aws, 멀티파트 스트리밍) (§3.2)
│   │   │   └── key_builder.ex              #     object key 생성 규칙 (§3.3)
│   │   │
│   │   ├── media_asset.ex                  #   Ecto 스키마 (media_assets) + state 전이 함수 (§5)
│   │   ├── state_machine.ex               #   처리상태 전이 규칙 (순수 함수, 허용 전이만) (§5.2)
│   │   │
│   │   └── sink/                           #   ── 코어/EXT-3 연계 behaviour 계약 ──
│   │       ├── media_sink.ex               #     behaviour 정의 (@callback) (§6.2)
│   │       └── noop_sink.ex                #     기본 구현 (MVP 기본값)
│   │
│   └── open_mes_web/
│       └── router.ex                       # ← (옵션) /media/health, /media/assets/:id 조회 scope (조건부)
│
├── priv/
│   └── repo/
│       └── migrations/
│           └── ..._create_media_assets.exs # 일반 PG 테이블 (+ 유니크 인덱스 = 멱등성)
└── test/
    ├── open_mes_media/watch/stability_test.exs
    ├── open_mes_media/watch/path_policy_test.exs
    ├── open_mes_media/state_machine_test.exs
    ├── open_mes_media/intake/registrar_test.exs       # 멱등 등록(중복 무시) 검증
    ├── open_mes_media/object_store/s3_object_store_test.exs
    └── open_mes_media/transfer/transfer_worker_test.exs
```

### 1.3 모듈 경계와 책임

| 모듈 | 책임 | 코어 의존 |
|------|------|----------|
| `OpenMes.Media` | 확장 퍼사드. `enabled?/0`, 상태 조회 진입점. | ❌ |
| `OpenMes.Media.Watch.Scanner` | 주기 폴링으로 watch 루트 트리 스캔. 후보 파일 발견. | Repo만 |
| `OpenMes.Media.Watch.Stability` | 쓰기 완료 판정(순수 함수: size+mtime 안정화, .tmp/.part 제외). | ❌ |
| `OpenMes.Media.Watch.PathPolicy` | NAS 경로 → `equipment_id`·`media_type` 매핑 규칙(순수 함수). | ❌ |
| `OpenMes.Media.Intake.Registrar` | 안정화 파일을 `media_assets`에 멱등 INSERT(detected). 중복은 무시. | Repo만 |
| `OpenMes.Media.Transfer.Dispatcher` | detected asset을 픽업해 이관 큐로 디스패치(GenServer poll). | Repo만 |
| `OpenMes.Media.Transfer.TransferSupervisor` | 동시 이관 수 제한 + 큐잉(백프레셔). | Repo만 |
| `OpenMes.Media.Transfer.TransferWorker` | 단일 asset: NAS→object storage 스트리밍 이관, state 전이, 검증. | Repo, ObjectStore |
| `OpenMes.Media.ObjectStore` | **behaviour 계약**. put_stream/head/delete. | ❌(계약만) |
| `OpenMes.Media.ObjectStore.S3ObjectStore` | MinIO/S3 기본 구현(멀티파트 스트리밍 업로드). | ❌ |
| `OpenMes.Media.MediaAsset` | `media_assets` Ecto 스키마 + changeset. | ❌ |
| `OpenMes.Media.StateMachine` | 허용 state 전이만 통과시키는 순수 함수. | ❌ |
| `OpenMes.Media.Sink.MediaSink` | **behaviour 계약**. stored 후처리(EXT-3 특징추출/도메인 신호). | ❌(계약만) |
| `OpenMes.Media.Sink.NoopSink` | 기본 구현. 아무 동작 안 함. MVP 기본값. | ❌ |

> **핵심 격리 규칙** (EXT-1 승계):
> - 코어(`lib/open_mes/`)는 `OpenMes.Media.*`를 import/alias/호출하지 않는다. 의존 방향은 **확장 → 코어** 단방향만.
> - EXT-2가 코어에 닿는 유일한 정당 경로: (a) `OpenMes.Repo`(같은 DB 인프라), (b) `Sink` 구현체에서 `OpenMes.Outbox.emit`(도메인 이벤트, 후속).
> - **EXT-2 ↔ EXT-1 공유 지점**: 코드 의존 없음. 의미적 연결만 — `media_assets.equipment_id`가 `equipment_measurements.equipment_id`와 동일 식별자 규약을 따른다. 특징 추출(EXT-3)이 `media_assets`에서 dB 등을 뽑아 `equipment_measurements`에 적재할 때 합류한다. 지금은 식별자 규약만 일치시킨다(§2.5 PathPolicy가 동일 equipment_id 체계 사용).
> - `application.ex` child_spec 조건부 추가가 코어-확장의 유일한 배선 접점이며 config 플래그로 게이트된다.

---

## 2. NAS Watch 메커니즘 (선택 + 근거, 파일 안정성·멱등성 해결)

### 2.1 감지 → 등록 → 이관 흐름 개요

```text
[NAS 공유폴더]  (레거시 설비/CCTV가 파일을 떨어뜨림, MES는 read-only 마운트)
      ↓ 주기 스캔 (Scanner, 예: 5초)
[후보 파일 목록]
      ↓ Stability 게이트 (쓰기 완료 판정 — size/mtime 안정화 + .tmp/.part 제외)
[안정화된 파일]
      ↓ Registrar: media_assets 멱등 INSERT (state=detected)  ← 유니크 제약이 중복 차단
[detected asset (DB)]
      ↓ Dispatcher 픽업 → TransferSupervisor 큐 (동시 N 제한 = 백프레셔)
      ↓ TransferWorker: detected→uploading, 스트리밍 이관, 검증
[object storage(MinIO)에 원본 저장 + stored]
      ↓ (state=stored) MediaSink.handle_stored (NoopSink 기본; EXT-3 확장 포인트)
      ↓ (원본 NAS 파일은 보존정책에 따라 — MVP는 삭제 안 함, §8.2)
```

### 2.2 감지 메커니즘: **주기적 폴링 스캐너 채택** (inotify/FileSystem 미채택)

> **결정 — FileSystem(inotify) watch 대신 주기적 폴링 스캐너를 채택한다.**

**근거:**
1. **NAS에서 inotify는 신뢰할 수 없다.** inotify/FSEvents는 **로컬 파일시스템 이벤트**다. NFS/SMB(CIFS)로 마운트된 NAS 공유폴더에 **다른 호스트(설비/CCTV)가 쓴 변경은 watch 호스트의 커널에 inotify 이벤트로 전달되지 않는다.** 이것은 라이브러리 한계가 아니라 네트워크 파일시스템의 근본 특성이다. → inotify 채택 시 "파일이 들어와도 이벤트가 안 오는" 치명적 데이터 유실.
2. **폴링은 NAS와 무관하게 동작한다.** 디렉토리 `readdir` + `stat`는 NFS/SMB에서 정상 동작한다. 약간의 지연(폴링 주기)을 감수하면 누락이 없다. **데이터 확보 우선 원칙**: 실시간성보다 "안 놓치는 것"이 먼저.
3. **파일 안정성 판정과 자연스럽게 결합**(§2.3): 폴링은 어차피 두 시점의 `stat`를 비교하므로 size/mtime 안정화 판정을 공짜로 얻는다. inotify는 "쓰기 완료" 이벤트를 주지 않으므로(IN_CLOSE_WRITE도 원격 쓰기엔 안 옴) 어차피 안정화 폴링이 추가로 필요하다.
4. **단순성(pi)**: GenServer 하나 + `:timer.send_interval`. 외부 OS 의존(inotify-tools) 없음.

> `file_system` 라이브러리는 **로컬 디스크에 스풀하는 변형 구성**(설비가 로컬에 쓰고 MES가 같은 호스트에서 watch)에서만 의미가 있다. NAS 공유폴더 시나리오에서는 부적합하므로 deps에 넣되 기본 비활성(또는 제외). MVP는 폴링만.

**Scanner 설계 (GenServer):**
- config `scan_interval_ms`(기본 5_000), `watch_roots`(디렉토리 목록).
- 매 주기: 각 root를 재귀 순회(`Path.wildcard` 또는 `File.ls` 재귀). 각 파일에 대해 `File.stat`로 `size`, `mtime` 취득.
- 후보를 Stability 게이트(§2.3)에 통과시킨 뒤, 통과분만 Registrar(§2.4)로 넘긴다.
- **대용량 디렉토리 대비**: 깊은 트리/수만 파일이면 매 스캔 full-walk가 비싸다. MVP 완화책 — (a) watch_roots를 날짜/설비 하위로 좁게 구성하도록 권고, (b) `media_assets`에 이미 등록된 경로는 stat 후 빠르게 skip(멱등 등록이 어차피 막지만 DB 왕복 절약 위해 in-memory `seen` 캐시 옵션). 인덱싱형 스캔 최적화(mtime 워터마크 등)는 후속(§8.5).

### 2.3 파일 안정성: 쓰기 완료 감지 (Stability 게이트, 순수 함수)

쓰기 도중 파일을 잡으면 손상본을 수집한다. 아래 **다중 게이트**를 모두 통과해야 "안정"으로 판정한다.

| 게이트 | 규칙 | 근거 |
|--------|------|------|
| **확장자/임시명 제외** | `.tmp`, `.part`, `.partial`, `.filepart`, `~`로 끝나거나 `.`로 시작하는 숨김파일은 제외. | 많은 쓰기 도구가 `.tmp`→`rename` 패턴을 쓴다. 최종 rename 후 이름만 잡는다. |
| **mtime 유예(quiet period)** | `now - mtime >= min_quiet_seconds`(기본 10초). 즉 마지막 수정 후 일정 시간이 지나야 함. | 쓰기가 진행 중이면 mtime이 계속 갱신된다. 유예 시간 동안 변화 없으면 쓰기 종료로 간주. |
| **size 안정화(2-스캔 비교)** | 직전 스캔의 `size`와 현재 `size`가 같아야 함. Scanner가 직전 스캔 결과를 보관(in-memory map: path→{size, mtime, first_seen})하고 비교. | rename 패턴을 안 쓰는 도구(직접 append) 대비. 두 시점 size 동일 = 쓰기 멈춤. |
| **(영상 옵션) 최소 안정 횟수** | 대용량 영상은 안정 판정을 N회 연속 만족해야 통과(기본 1, 영상은 2 권장). | GB 영상은 일시적으로 size가 멈춰 보일 수 있어 보수적으로. |

```elixir
defmodule OpenMes.Media.Watch.Stability do
  @moduledoc "쓰기 완료(안정화) 판정. 순수 함수. Scanner가 직전 관측치를 주입."

  @default_min_quiet_seconds 10
  @temp_suffixes ~w(.tmp .part .partial .filepart ~)

  @doc """
  prev: 직전 스캔 관측치 %{size, mtime} | nil
  curr: 현재 %{path, size, mtime}
  now:  현재 시각
  반환: :stable | {:pending, reason} | :ignore
  """
  def assess(prev, curr, now, opts \\ []) do
    cond do
      temp_name?(curr.path)            -> :ignore
      not quiet_elapsed?(curr, now, opts) -> {:pending, :mtime_quiet}
      is_nil(prev)                     -> {:pending, :first_seen}   # 최초 관측 — 다음 스캔에 비교
      prev.size != curr.size           -> {:pending, :size_changing}
      true                             -> :stable
    end
  end
  # temp_name?/quiet_elapsed? 구현은 domain-engineer.
end
```

> **핵심**: `:first_seen`은 절대 즉시 등록하지 않는다. 반드시 **최소 2회 스캔에 걸쳐 size 불변 + mtime 유예**를 확인한 뒤에만 `:stable`. 이것이 손상본 수집을 막는 1차 방어선. 콘텐츠 해시(§2.4)가 최종 방어선.

### 2.4 중복 수집 방지 (멱등성 — DB 유니크 제약으로 명시)

> **결정 — 멱등성을 암묵에 맡기지 않고 DB 유니크 제약으로 못 박는다.** (EXT-1 WorkOrder 멱등 전이 버그 교훈)

**멱등 키 설계 — 2단계:**

1. **1차(빠른) 키: `(nas_path, file_mtime, file_size)`** 유니크 제약.
   - Registrar는 안정화된 파일을 `media_assets`에 INSERT 시도. 동일 `(nas_path, file_mtime, file_size)`가 이미 있으면 **`on_conflict: :nothing`으로 조용히 무시**(이미 detected/이관됨).
   - mtime+size를 포함하는 이유: 같은 경로에 새 파일이 덮어써지면(같은 path, 다른 내용) mtime/size가 달라져 **새 asset으로 정상 등록**된다. path만 키로 쓰면 덮어쓰기를 놓친다.
   - 빠르다: 해시 계산 없이 stat 결과만으로 판정.

2. **2차(확정) 키: `content_hash`** 유니크 제약(이관 단계에서 채움).
   - TransferWorker가 스트리밍 이관 중 **SHA-256을 함께 계산**(스트림을 흘리며 해시 누적, 추가 read 없음). 이관 성공 시 `content_hash`를 기록.
   - 같은 내용 파일이 다른 경로/다른 mtime으로 두 번 들어오면 2차 키가 중복을 잡는다. 충돌 시 해당 asset을 `duplicate`로 표시하고 object storage 중복 업로드분은 정리(또는 동일 key면 멱등). 
   - **MVP 범위**: 2차 해시 유니크는 **부분 인덱스(`content_hash IS NOT NULL`)로 두되**, 충돌 처리는 "duplicate 마킹 + 로그"까지만. 정교한 dedup(이미 stored면 재이관 skip)은 1차 키로 대부분 해결되므로 충분.

**유니크 제약(마이그레이션):**
```elixir
create unique_index(:media_assets, [:nas_path, :file_mtime, :file_size],
         name: :media_assets_source_identity)
create unique_index(:media_assets, [:content_hash],
         where: "content_hash IS NOT NULL",
         name: :media_assets_content_hash)
```

> **멱등 등록 핵심 코드 패턴(Registrar):**
> ```elixir
> %MediaAsset{}
> |> MediaAsset.detect_changeset(attrs)
> |> Repo.insert(on_conflict: :nothing, conflict_target: :media_assets_source_identity)
> # {:ok, %{id: nil}} 또는 0 rows = 이미 존재 → skip (정상, 에러 아님)
> ```
> 이렇게 하면 Scanner가 같은 파일을 10번 봐도 row는 1개. **재시작·중복 스캔에 안전.**

### 2.5 경로 정책 (PathPolicy — equipment_id / media_type 도출)

NAS 디렉토리 구조에서 출처 설비와 미디어 종류를 도출한다. 디바이스 무수정이므로 **경로 규약으로 메타데이터를 얻는다.**

- 예시 규약: `/{root}/{equipment_id}/{media_type}/{yyyy-mm-dd}/{filename}`
  - `/nas/cctv/EQP-01/video/2026-06-13/cam1_080000.mp4` → `equipment_id="EQP-01"`, `media_type="video"`.
  - 매핑 불가 경로는 `equipment_id="unknown"`으로 등록하되 `meta`에 원본 경로 보존(데이터를 버리지 않음).
- **media_type 분류**: 확장자 기반 1차 분류(`.wav/.flac/.mp3`→`audio`, `.mp4/.avi/.mov`→`video`, `.jpg/.png`→`image`). 경로 규약과 불일치 시 경로 우선 + meta에 기록.
- **EXT-1 식별자 규약 일치**: 여기서 도출하는 `equipment_id`는 `equipment_measurements.equipment_id`와 **동일 체계**여야 EXT-3에서 특징을 합류시킬 수 있다. PathPolicy의 매핑 테이블/규칙을 EXT-1과 공유하는 설비 식별자 규약으로 맞춘다.
- 순수 함수. 단위 테스트로 매핑 규칙 고정.

---

## 3. Object Storage 추상화 (behaviour 계약 + MinIO 기본 구현)

### 3.1 behaviour 계약 — `ObjectStore`

```elixir
defmodule OpenMes.Media.ObjectStore do
  @moduledoc """
  object storage 접근 계약. MinIO/S3/NCP 등 S3 호환 백엔드를 교체 가능하게 추상화.
  대용량 바이너리를 메모리에 올리지 않도록 스트리밍 업로드를 계약에 명시한다.
  """

  @type key :: String.t()
  @type bucket :: String.t()

  @doc "로컬/NAS 파일 경로를 스트리밍으로 업로드. 메모리에 전체 적재 금지(멀티파트)."
  @callback put_file_stream(bucket, key, source_path :: String.t(), opts :: keyword) ::
              {:ok, %{etag: String.t(), size: non_neg_integer()}} | {:error, term()}

  @doc "객체 존재/메타 확인 (이관 검증용)."
  @callback head(bucket, key) ::
              {:ok, %{size: non_neg_integer(), etag: String.t()}} | {:error, :not_found | term()}

  @doc "객체 삭제 (실패 정리/duplicate 정리용)."
  @callback delete(bucket, key) :: :ok | {:error, term()}
end
```

- 구현체는 config로 선택:
  ```elixir
  config :open_mes, OpenMes.Media, object_store: OpenMes.Media.ObjectStore.S3ObjectStore
  ```
- 테스트는 in-memory fake store로 교체(behaviour 덕분에 MinIO 없이 단위 테스트 가능).

### 3.2 MinIO 기본 구현 — `S3ObjectStore`

- `ex_aws_s3` 사용. MinIO는 S3 API 호환이므로 endpoint/credential만 MinIO로 설정.
- **스트리밍 멀티파트 업로드**(대용량 핵심):
  ```elixir
  source_path
  |> ExAws.S3.Upload.stream_file()            # 파일을 청크 스트림으로 (메모리 적재 X)
  |> ExAws.S3.upload(bucket, key, opts)        # 멀티파트 업로드
  |> ExAws.request(config_overrides)
  ```
- **이관 검증**: 업로드 후 `head/2`로 size 비교(NAS 원본 size == object size). 불일치 시 `{:error, :size_mismatch}` → 재시도(§4.4).
- config(runtime):
  ```elixir
  config :ex_aws,
    access_key_id: System.get_env("MINIO_ACCESS_KEY"),
    secret_access_key: System.get_env("MINIO_SECRET_KEY")
  config :ex_aws, :s3,
    scheme: "http://", host: System.get_env("MINIO_HOST", "localhost"),
    port: String.to_integer(System.get_env("MINIO_PORT", "9000")),
    region: "us-east-1"   # MinIO 기본
  config :open_mes, OpenMes.Media,
    bucket: System.get_env("MEDIA_BUCKET", "open-mes-media")
  ```

### 3.3 Object Key 생성 규칙 — `KeyBuilder`

- 충돌 없고 추적 가능한 key:
  `{media_type}/{equipment_id}/{yyyy}/{mm}/{dd}/{asset_id}_{원본파일명}`
  - 예: `video/EQP-01/2026/06/13/{uuid}_cam1_080000.mp4`
- `asset_id`(media_asset PK UUID)를 포함해 **동일 파일명 충돌을 원천 차단**(같은 분에 두 cam1이 와도 다른 key).
- key는 등록 시점에 결정해 `media_assets.object_key`에 저장 → 이관 워커가 그대로 사용(재시도해도 같은 key = 멱등 업로드).

---

## 4. 처리 파이프라인 (감지→이관→인덱싱, 실패/재시도/dead-letter, 백프레셔)

### 4.1 Dispatcher (detected → uploading 픽업)

- GenServer. 주기(`dispatch_interval_ms`, 기본 2_000)마다 `media_assets`에서 `state IN (detected, transfer_failed)` 이고 재시도 가능 시점인 asset을 **소량(limit)** 조회.
- 각 asset을 `TransferSupervisor`에 제출. **동시 이관 상한이 백프레셔의 핵심**(§4.3): 큐가 차 있으면 더 픽업하지 않는다(detected는 DB에 그대로 남아 다음 주기에 처리 — 자연스러운 backlog).
- 픽업 시 낙관적 잠금: `detected → uploading` 전이를 **조건부 UPDATE**(`WHERE state='detected'`)로 수행. 영향 행 0이면 다른 워커가 가져간 것 → skip. (다중 노드/동시성 안전.)

### 4.2 TransferWorker (단일 asset 스트리밍 이관)

순서:
1. asset state 확인(`uploading` 선점 성공분만).
2. `ObjectStore.put_file_stream(bucket, object_key, nas_path)` — **스트리밍**(메모리에 전체 적재 안 함). 이 과정에서 **SHA-256 누적 계산**(스트림 tap)으로 `content_hash` 산출.
3. `ObjectStore.head`로 size 검증(NAS size == object size).
4. 성공: `uploading → stored` 전이 + `object_key`, `content_hash`, `file_size`, `stored_at`, `etag` 기록.
5. 실패: `uploading → transfer_failed` + `retry_count += 1`, `last_error` 기록. **원본 NAS 파일은 건드리지 않는다**(§4.4 보존).
6. `stored` 후 `MediaSink.handle_stored(asset)` 호출(NoopSink 기본; EXT-3 확장 포인트).

> **스트리밍 + 해시 동시 계산**: `ExAws.S3.Upload.stream_file`이 내는 청크 스트림에 `Stream.transform`으로 `:crypto.hash_update`를 끼워 해시를 누적한다. 별도 전체 재read 없이 한 번의 스트림으로 업로드+해시. (정확한 구현은 domain-engineer — ex_aws upload 파이프라인에 tap을 거는 형태.)

### 4.3 TransferSupervisor (동시 이관 제한 = 백프레셔)

- `Task.Supervisor` + 동시 실행 카운터(또는 `:poolboy`/간단한 토큰 세마포어). config `max_concurrent_transfers`(기본 3).
- **백프레셔 흐름**: 동시 이관이 상한이면 Dispatcher가 신규 픽업을 멈춘다 → detected asset이 DB에 backlog로 쌓임(메모리 아님, DB라 안전) → 상한 해제되면 다음 주기에 픽업. **NAS/네트워크/MinIO를 GB 영상 동시 다발로 포화시키지 않는다.**
- 이것이 EXT-1의 Broadway `max_demand` 백프레셔에 대응하는 EXT-2 버전. 단 단위가 "메시지"가 아니라 "동시 대용량 전송"이라 세마포어가 적합(§3.5 결정 참조).

### 4.4 실패 / 재시도 / dead-letter / 원본 보존

| 실패 유형 | 처리 | 재시도 | 원본 NAS 파일 |
|----------|------|--------|--------------|
| **이관 일시 오류**(MinIO 다운, 네트워크 끊김, size_mismatch) | `transfer_failed` + retry_count↑. 지수 백오프 후 Dispatcher가 재픽업. | ✅ (max_retries, 기본 5) | **보존(삭제 금지)** |
| **이관 영구 오류**(retry_count > max_retries) | `dead`(영구 실패) 전이 + 경보 로그. | ❌ | **보존(절대 삭제 금지)** — 수동 조치 대상 |
| **원본 손상/읽기 불가**(stat OK였으나 read 실패) | `transfer_failed` → 재시도; 지속되면 `dead`. | 제한적 | 보존 |
| **중복(content_hash 충돌)** | `duplicate` 표시. 이미 stored된 동일 내용 존재. | ❌ | 보존(원본은 정책에 따라) |

> **핵심 불변식(§0-E-11 재확인)**: object storage `stored` 확정 전까지 **원본 NAS 파일을 절대 삭제하지 않는다.** 이관 실패도, dead도 원본은 남긴다. 데이터 유실 0이 최우선. 원본 정리/수명주기는 별도 정책(§8.2)으로, 이번 범위는 "삭제 안 함"이 기본.

> **dead-letter 개념**: EXT-1은 별도 `ingest_dead_letters` 테이블을 뒀지만, EXT-2는 **`media_assets`의 `state=dead` + `last_error`로 충분**하다. 원본 메타가 이미 row에 있고, raw payload 같은 별도 보관이 불필요(파일 자체가 NAS에 남아 있음). 별도 dead-letter 테이블은 과설계(YAGNI). 운영자는 `WHERE state='dead'` 조회로 처리.

---

## 5. media_assets 메타데이터 스키마 + 처리상태 머신

### 5.1 컬럼 정의

| 필드 | 타입 | 제약 | 비고 |
|------|------|------|------|
| `id` | `binary_id` | PK | 코어 컨벤션(UUID). KeyBuilder가 object key에 사용. |
| `equipment_id` | `string` | NOT NULL | 출처 설비. EXT-1과 동일 식별자 규약(FK 없음). |
| `media_type` | `string` | NOT NULL | `audio`/`video`/`image`. CHECK 제약. |
| `nas_path` | `string` | NOT NULL | 원본 NAS 절대경로. 멱등 1차 키 구성. |
| `file_mtime` | `utc_datetime_usec` | NOT NULL | 원본 수정시각. 멱등 1차 키 구성. |
| `file_size` | `bigint` | NOT NULL | 바이트 크기(GB 영상 대비 bigint). 멱등 1차 키 + 이관 검증. |
| `content_hash` | `string` | NULL | SHA-256(이관 중 계산). 멱등 2차 키(부분 유니크). |
| `object_key` | `string` | NULL | object storage key(등록 시 결정, 이관에 사용). |
| `etag` | `string` | NULL | object storage가 반환한 etag(이관 확인). |
| `state` | `string` | NOT NULL, DEFAULT `'detected'` | 처리상태(§5.2). CHECK 제약. |
| `retry_count` | `integer` | NOT NULL, DEFAULT 0 | 이관 재시도 횟수. |
| `last_error` | `string` | NULL | 마지막 실패 사유. |
| `captured_at` | `utc_datetime_usec` | NULL | (옵션) 미디어 촬영/녹음 시각. 경로/파일명에서 파싱되면 채움. |
| `stored_at` | `utc_datetime_usec` | NULL | object storage 이관 확정 시각. |
| `meta` | `map`(jsonb) | NULL | 원본 경로, 분류 부가정보 등. |
| `inserted_at` / `updated_at` | `utc_datetime_usec` | NOT NULL | Ecto timestamps(운영 인덱스이므로 사용). |

> **AuditLog 컬럼 없음 / actor_id 없음** — §0-C 경계. `media_assets`는 도메인 트랜잭션이 아니라 수집 운영 인덱스. 출처는 `equipment_id`+`nas_path`. (qa-auditor 오탐 방지)

### 5.2 처리상태 머신 (state machine)

```text
detected ──→ uploading ──→ stored ──→ (예약) feature_extracted
   │             │
   │             ├──→ transfer_failed ──(재시도)──→ uploading
   │             │            └──(max_retries 초과)──→ dead
   │             └──→ (content_hash 충돌) duplicate
   └──→ duplicate (1차 키는 on_conflict로 애초에 INSERT 안 됨; duplicate는 2차 해시 충돌 경로)
```

| state | 의미 | 진입 |
|-------|------|------|
| `detected` | 안정화 파일이 멱등 등록됨. 이관 대기. | Registrar |
| `uploading` | 이관 진행 중(선점됨). | Dispatcher(조건부 UPDATE) |
| `stored` | object storage 이관 확정(size/etag 검증 완료). **원본 보존 종료 가능 시점(정책)**. | TransferWorker |
| `transfer_failed` | 이관 실패, 재시도 대상. | TransferWorker |
| `dead` | 재시도 소진. 영구 실패. 수동 조치. 원본 보존. | TransferWorker |
| `duplicate` | content_hash 중복(동일 내용 이미 stored). | TransferWorker |
| `feature_extracted` | **(예약, EXT-3)** 특징 추출 완료. 이번 범위에서 전이 미구현, state 값만 예약. | (EXT-3) |

> **허용 전이만 통과**: `StateMachine.transition(from, to)` 순수 함수로 허용 전이 화이트리스트를 강제(코어 상태머신 패턴과 동일 철학). 임의 전이 금지. `feature_extracted`는 화이트리스트에 **자리만 예약**(stored→feature_extracted)하되 이번 범위에서 호출 경로는 없음.

> **EXT-1 멱등 전이 버그 교훈 적용**: 모든 전이는 **조건부 UPDATE(`WHERE state = <expected_from>`)**로 수행. "이미 그 상태면 no-op, 다른 워커가 선점했으면 skip". 같은 전이를 두 번 시도해도 안전. (Dispatcher 동시성·재시작 안전.)

### 5.3 마이그레이션 관점

```elixir
def change do
  create table(:media_assets, primary_key: false) do
    add :id, :binary_id, primary_key: true
    add :equipment_id, :string, null: false
    add :media_type, :string, null: false
    add :nas_path, :string, null: false
    add :file_mtime, :utc_datetime_usec, null: false
    add :file_size, :bigint, null: false
    add :content_hash, :string
    add :object_key, :string
    add :etag, :string
    add :state, :string, null: false, default: "detected"
    add :retry_count, :integer, null: false, default: 0
    add :last_error, :string
    add :captured_at, :utc_datetime_usec
    add :stored_at, :utc_datetime_usec
    add :meta, :map
    timestamps(type: :utc_datetime_usec)
  end

  # 멱등성(§2.4) — 명시적 DB 제약
  create unique_index(:media_assets, [:nas_path, :file_mtime, :file_size],
           name: :media_assets_source_identity)
  create unique_index(:media_assets, [:content_hash],
           where: "content_hash IS NOT NULL",
           name: :media_assets_content_hash)

  # 픽업 쿼리 인덱스(Dispatcher: state별 조회)
  create index(:media_assets, [:state, :inserted_at])
  create index(:media_assets, [:equipment_id, :media_type, :captured_at])

  # 방어선 CHECK
  create constraint(:media_assets, :media_assets_media_type_check,
           check: "media_type IN ('audio','video','image')")
  create constraint(:media_assets, :media_assets_state_check,
           check: "state IN ('detected','uploading','stored','transfer_failed','dead','duplicate','feature_extracted')")
end
```

> 일반 PostgreSQL 테이블(hypertable 아님). 저~중빈도. retention/파티셔닝은 데이터 누적 후 후속(§8.2).

---

## 6. config on/off + behaviour 확장 포인트, EXT-1/EXT-3 연계

### 6.1 선택적 활성화 (application.ex — 코어-확장 유일 배선 접점)

```elixir
# config/config.exs (기본 비활성 — 코어는 false여도 완전 동작)
config :open_mes, OpenMes.Media,
  enabled: false,
  object_store: OpenMes.Media.ObjectStore.S3ObjectStore,
  sink: OpenMes.Media.Sink.NoopSink

# config/runtime.exs — 환경변수로 켬
config :open_mes, OpenMes.Media,
  enabled: System.get_env("MEDIA_ENABLED", "false") == "true",
  watch_roots: System.get_env("MEDIA_WATCH_ROOTS", "") |> String.split(",", trim: true),
  scan_interval_ms: 5_000,
  max_concurrent_transfers: 3,
  max_retries: 5
```

```elixir
# application.ex
defp media_children do
  if OpenMes.Media.enabled?() do
    [
      OpenMes.Media.Transfer.TransferSupervisor,   # Task.Supervisor
      OpenMes.Media.Watch.Scanner,                 # 폴링 감지
      OpenMes.Media.Transfer.Dispatcher            # 이관 디스패치
    ]
  else
    []
  end
end
```

- `enabled? == false`면 watch/transfer child가 아예 안 뜬다. 라우터 `/media` scope도 조건부 미등록. 코어 영향 0.
- **검증 포인트(qa-auditor)**: config를 끄고 `mix test` 전체 통과. 확장이 코어에 필수 아님 증명.

### 6.2 behaviour 계약 — `MediaSink` (EXT-3 확장 포인트)

```elixir
defmodule OpenMes.Media.Sink.MediaSink do
  @moduledoc """
  stored 후처리 계약. EXT-2가 코어/EXT-3와 만나는 추상 경계.
  - 기본(NoopSink): 아무 동작 안 함.
  - 후속(EXT-3): 특징 추출(소음 dB/주파수 피크) → equipment_measurements 합류,
    또는 도메인 신호(영상 수집완료→검사 트리거)를 코어 Outbox.emit으로 발행.
  """
  @callback handle_stored(asset :: map()) :: :ok
end
```

- TransferWorker가 `stored` 전이 직후 `configured_sink().handle_stored(asset)` 호출.
- **MVP 기본 `NoopSink`**: `def handle_stored(_), do: :ok`. 멀티미디어는 object storage 적재 + 인덱싱만 되고 코어/EXT-3로 아무것도 안 흘러간다. §0-C 경계를 코드로 보장.

### 6.3 EXT-1 / EXT-3 연계 지점 정리

| 연계 | 방식 | 이번 범위 |
|------|------|----------|
| **EXT-2 → EXT-1** (특징 합류) | EXT-3가 `media_assets`(stored)에서 특징 추출 → `equipment_measurements`(동일 equipment_id)에 적재. | **미구현**. 식별자 규약 일치(§2.5) + `feature_extracted` state 예약 + `MediaSink` 확장 포인트만 남김. |
| **EXT-2 → 코어** (도메인 신호) | `MediaSink` 구현체에서 `OpenMes.Outbox.emit`. (예: 영상 수집완료 이벤트) | **미구현**. 이벤트 타입이 `system-architecture.md`에 정의돼야 활성화(EXT-1 §6.3 결정 승계 — 임의 이벤트 추가 금지). `NoopSink` 기본. |
| **EXT-2 ↔ EXT-1 코드 의존** | 없음. 각자 독립 child/네임스페이스. | 의미적 식별자 규약만 공유. |

> **핵심**: 멀티미디어→특징→시계열 합류와 도메인 신호 연계가 모두 **`MediaSink` 한 점**으로 추상화된다. 코어는 이 behaviour의 존재조차 모른다(의존 방향 확장→코어 유지). EXT-3 도입 시 `NoopSink`를 `FeatureExtractSink`로 교체하면 됨.

---

## 7. domain-engineer 구현 지침 + qa-auditor 검증 포인트

### 7.1 마이그레이션 의존성 / 구현 순서

```text
[전제] MinIO 컨테이너를 docker-compose에 추가 (§7.4) — 코드 전 인프라 확인
       NAS 공유폴더는 read-only로 마운트(컨테이너/호스트). 로컬 개발은 로컬 디렉토리로 대체.
  1. 마이그레이션: create_media_assets (+ 유니크 인덱스 = 멱등성, CHECK)
  2. OpenMes.Media.MediaAsset 스키마 + detect_changeset
  3. OpenMes.Media.StateMachine (순수 함수, 허용 전이 화이트리스트) + 단위 테스트 (TDD)
  4. OpenMes.Media.Watch.Stability (순수 함수) + 단위 테스트 (TDD)
  5. OpenMes.Media.Watch.PathPolicy (순수 함수) + 단위 테스트 (TDD)
  6. OpenMes.Media.ObjectStore behaviour + S3ObjectStore(ex_aws 스트리밍) + in-memory fake
  7. OpenMes.Media.ObjectStore.KeyBuilder
  8. OpenMes.Media.Intake.Registrar (멱등 INSERT on_conflict:nothing) + 테스트(중복 무시)
  9. OpenMes.Media.Watch.Scanner (GenServer 폴링 + 직전 관측치 캐시 + Stability 결합)
 10. OpenMes.Media.Sink.MediaSink behaviour + NoopSink (기본값)
 11. OpenMes.Media.Transfer.TransferSupervisor (동시 제한 세마포어)
 12. OpenMes.Media.Transfer.TransferWorker (스트리밍 이관 + 해시 + size 검증 + 상태전이)
 13. OpenMes.Media.Transfer.Dispatcher (GenServer poll + 조건부 UPDATE 선점)
 14. OpenMes.Media 퍼사드(enabled?) + application.ex 조건부 child + config
 15. (옵션) /media/health, /media/assets/:id 조회 라우터 조건부 scope
 16. 테스트: Stability/PathPolicy/StateMachine 단위, Registrar 멱등, TransferWorker(fake store), 코어 비침투 회귀
```

### 7.2 구현 세부 규칙

- **코어 비침투 절대 규칙**: `lib/open_mes/` 하위 수정 금지. **유일한 예외는 `application.ex`의 `media_children/0` 추가**(+ 옵션 `router.ex` 조건부 `/media` scope). 그 외 코어 변경 금지.
- **의존 방향**: `OpenMes.Media.*`는 `OpenMes.Repo`와 (MediaSink 한정)`OpenMes.Outbox`만 코어에서 참조. 그 외 코어 모듈 alias 금지. **EXT-1(`OpenMes.Ingest.*`)도 직접 참조 금지**(EXT-2는 EXT-1과 코드 의존 없음).
- **스트리밍 절대 규칙**: 이관 시 `File.read/1`로 전체를 메모리에 올리지 않는다. 반드시 `ExAws.S3.Upload.stream_file` 류 스트리밍. GB 영상에서 OOM 방지.
- **원본 보존 절대 규칙**: TransferWorker/Dispatcher/실패 경로 어디서도 `File.rm`(NAS 원본)을 호출하지 않는다. 원본 삭제는 이번 범위에 **없음**(§8.2 후속 정책 전까지 금지).
- **멱등 INSERT**: Registrar는 `Repo.insert(on_conflict: :nothing, conflict_target: :media_assets_source_identity)`. 충돌(이미 존재)은 **에러가 아니라 정상 skip**으로 처리.
- **조건부 전이 선점**: detected→uploading은 `from(a in MediaAsset, where: a.id == ^id and a.state == "detected") |> Repo.update_all(set: [...])` 영향 행 1일 때만 진행. 0이면 다른 워커 선점 → skip. (다중 워커/재시작 안전.)
- **해시 스트리밍**: 업로드 스트림에 SHA-256 누적을 끼워 단일 패스로 처리. 별도 전체 재read 금지.
- **size 검증**: 업로드 후 `head`로 object size == nas file_size 확인 후에만 stored. 불일치는 transfer_failed.
- **append + state 갱신만**: media_assets는 INSERT 후 state/이관 메타 UPDATE만. 물리 삭제 함수 미작성(원본·인덱스 모두 보존).
- **언어**: 주석/에러 한국어, 식별자 영문.

### 7.3 qa-auditor 검증 포인트

**코어 감사 원칙이 이 확장 텔레메트리 경로에는 그대로 적용되지 않는다.** EXT-1 §7.3과 동일 철학.

정상(결함 아님 — 오탐 금지):
- ✅ **`media_assets` INSERT/state 전이에 AuditLog 없음** — §0-C 경계. 멀티미디어 메타데이터는 고빈도 텔레메트리에 준하는 수집 운영 인덱스. 누락이 아니라 설계 결정.
- ✅ **`media_assets`에 actor_id 컬럼 없음** — 설비 출처(`equipment_id`+`nas_path`)가 곧 출처. 사람 actor 모델 적용 대상 아님.
- ✅ **`media_assets`가 코어 테이블을 FK 참조하지 않음** — 수집/도메인 분리 의도(EXT-1과 동일).
- ✅ **별도 dead-letter 테이블 없음** — `state=dead`로 대체. 원본이 NAS에 보존되므로 raw 별도 보관 불필요.

검증(위반 시 보고):
- ⛔ **코어 비침투**: `lib/open_mes/` 변경이 `application.ex`(+옵션 `router.ex`) 외에 있으면 위반.
- ⛔ **선택적 활성화**: `enabled: false`로 코어 `mix test` 전체 통과. child 미기동 확인.
- ⛔ **의존 방향 단방향**: 코어 모듈이 `OpenMes.Media.*`를 참조하지 않는지. EXT-2가 `OpenMes.Ingest.*`(EXT-1)를 참조하지 않는지(grep).
- ⛔ **멱등성(명시 검증)**: `(nas_path, file_mtime, file_size)` 유니크 제약 존재 + Registrar가 `on_conflict:nothing`인지. 같은 파일 N회 스캔 → row 1개인지 테스트 존재 확인. (EXT-1 멱등 버그 교훈 — 반드시 본다.)
- ⛔ **상태 머신 화이트리스트**: 임의 전이 추가 없는지. 모든 전이가 조건부 UPDATE(선점)인지.
- ⛔ **원본 보존**: 코드 어디에도 NAS 원본 `File.rm`/`File.rm_rf`가 없는지(grep). stored 전 삭제는 절대 금지.
- ⛔ **스트리밍 이관**: 대용량 파일을 `File.read`로 통째 메모리 적재하지 않는지(grep `File.read` 이관 경로).
- ⛔ **도메인 이벤트 Outbox 경유**: MediaSink가 도메인 이벤트를 발행한다면 `OpenMes.Outbox.emit`(동일 트랜잭션 패턴)으로만. 직접 outbox_events insert 금지. (MVP는 NoopSink라 해당 없음.)

> 즉 **audit-verify 스킬의 "모든 쓰기에 AuditLog" 룰은 media_assets 경로에 적용 제외**. AuditLog/LOT/상태머신(코어) 룰은 코어 도메인 트랜잭션에만 유효. 단 EXT-2 고유 룰(멱등성/원본보존/스트리밍/상태머신 선점)은 엄격히 검증.

### 7.4 MinIO 로컬 개발 셋업

docker-compose에 MinIO 추가:
```yaml
services:
  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    ports: ["9000:9000", "9001:9001"]   # 9000 API, 9001 콘솔
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes: ["minio_data:/data"]
volumes:
  minio_data:
```
- 버킷 생성(최초 1회): `mc mb local/open-mes-media` 또는 콘솔(http://localhost:9001).
- 로컬 개발은 NAS 대신 로컬 디렉토리(`MEDIA_WATCH_ROOTS=./tmp/nas_watch`)로 감지 동작 확인. 테스트 파일을 디렉토리에 떨궈 detected→stored 흐름 확인.
- 환경변수: `MEDIA_ENABLED=true`, `MINIO_HOST=localhost MINIO_PORT=9000 MINIO_ACCESS_KEY=minioadmin MINIO_SECRET_KEY=minioadmin MEDIA_BUCKET=open-mes-media`.

### 7.5 테스트 필수 케이스

- `Stability`: temp 확장자 제외, mtime 유예 미경과 → pending, first_seen → pending, size 변동 → pending, 안정 → stable.
- `PathPolicy`: 규약 경로 → equipment_id/media_type 도출, 비규약 → unknown + meta 보존.
- `StateMachine`: 허용 전이 통과, 비허용 전이 거부, 동일 상태 재전이 안전.
- `Registrar`(멱등): 같은 (path,mtime,size) 2회 등록 → row 1개. 같은 path 다른 mtime → 새 row 2개.
- `TransferWorker`(fake ObjectStore): 정상 → stored + content_hash + object_key. 업로드 실패 → transfer_failed + retry_count↑ + 원본 보존. size 불일치 → transfer_failed.
- **코어 비침투 회귀**: `enabled:false`에서 코어 WorkOrder 테스트 전체 통과.

---

## 8. 미해결 / 후속 항목

### 8.1 인프라 전제 (착수 전 확인)
- **MinIO 컨테이너 추가 승인**(§7.4) — docker-compose 변경. (없어도 코어/EXT-1 무영향, `media_enabled:false`면 정상.)
- **NAS 마운트 방식**: 운영에서 NFS/SMB read-only 마운트 경로 확정 필요. watch 호스트가 해당 경로를 읽을 수 있어야 함. 권한/마운트 안정성은 인프라 영역.

### 8.2 파일 보존 정책 / 수명주기 (이번 범위 밖)
- 원본 NAS 파일: 현재 **삭제 안 함**(데이터 유실 0 우선). stored 후 일정 기간 뒤 정리할지, 영구 보존할지 **정책 미정** → 사용자 확정 필요.
- object storage 수명주기(lifecycle/retention/tiering): MinIO/S3 lifecycle rule 또는 후속 잡. 대용량 영상 장기 보관 비용 고려.
- `media_assets` retention/파티셔닝: 데이터 누적 후 후속(EXT-1 §8.3과 동일 철학).

### 8.3 특징 추출 (EXT-3 연계) — 확장 포인트만 남김
- 소음 dB/주파수 피크, 영상 프레임 분석 등은 EXT-3. `stored → feature_extracted` 전이 + `MediaSink` 확장 포인트 예약. 추출 결과는 `equipment_measurements`(EXT-1, 동일 equipment_id)로 합류. 추출 엔진(라이브러리/외부 서비스) 선택은 EXT-3에서.

### 8.4 대용량 영상 스트리밍 한계
- 매우 큰 영상(수~수십 GB)은 멀티파트 업로드 타임아웃/파트 수 한계 고려. ex_aws upload chunk size 튜닝(기본 5MB → 영상은 더 크게). 동시 이관 수(`max_concurrent_transfers`)와 NAS read 대역폭 균형. 부하 테스트로 조정.
- 이관 중 중단(노드 재시작): `uploading` 상태로 남은 asset은 멀티파트 미완료 → Dispatcher가 `uploading`을 일정 시간 후 `transfer_failed`로 회수(stale 회수 로직)하고 재이관. (object key 동일 = 멱등 재업로드.) 이 stale 회수는 MVP에 포함 권장(§4.1 Dispatcher에 타임아웃 회수 추가).

### 8.5 watch 스캔 최적화 (대규모 디렉토리)
- 수만~수십만 파일 트리에서 full-walk 폴링은 비싸다. 후속: mtime 워터마크(직전 스캔 이후 변경분만), 디렉토리별 분산 스캔, 또는 설비가 "오늘 날짜" 하위에만 쓰도록 watch_roots를 날짜 하위로 좁힘. MVP는 단순 full-walk + seen 캐시.

### 8.6 보안 / 접근권한
- object storage 접근: MVP는 root credential. 운영은 버킷별 IAM 정책 + 최소권한 access key. presigned URL로 조회 제공 시 만료/권한 설계 필요.
- NAS 마운트: read-only 강제(MES가 원본을 변경/삭제 못 하게 — 보존 불변식의 인프라 차원 보강).
- `media_assets` 조회 API(`/media/assets/:id`) 노출 시: 원본 바이너리는 직접 서빙하지 않고 presigned URL 발급 + 코어 인증/권한 연계. AI 접근은 코어 AI Context API 경유 원칙(직접 object storage 접근 금지) — EXT-3 단계에서 설계.

### 8.7 사용자 확인 필요 요약
1. **MinIO 컨테이너 추가 승인**(§8.1) — 착수 전 필수.
2. **NAS 마운트 경로/방식 + 경로 규약**(§2.5 PathPolicy) — equipment_id 도출 규칙 확정.
3. **원본 NAS 파일 보존 정책**(§8.2) — MVP는 "삭제 안 함". 정리 시점 필요 시 확정.
4. **멱등 키 방식**: `(nas_path, file_mtime, file_size)` 1차 + content_hash 2차로 진행. 충돌 처리 수준(duplicate 마킹) 승인.
5. **EXT-3 연계 시점**: MVP는 NoopSink(적재+인덱싱만). 특징추출/도메인신호는 EXT-3로 미룸.
