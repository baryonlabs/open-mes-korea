#!/usr/bin/env bash
#
# integrate.sh — Open MES Korea 통합 스크립트
#
# _workspace 의 각 산출물(02/06/07/10/11_addon_*)의 lib/·priv/·test/ 소스를
# phx.new 가 생성한 open_mes 앱 트리로 복사한다.
#
# 이 스크립트가 하는 일: **파일 배치만** 한다.
# 이 스크립트가 하지 않는 일: config/mix.exs/application.ex/router.ex **병합**.
#   → 병합 기준본은 13_integration_package/merge_files/ 에 있고, INTEGRATION_GUIDE.md
#     Step 3 의 안내대로 수동으로 병합/덮어쓴다(코어 비침투 검증을 사람이 확인해야 하므로).
#
# 특성:
#   - 멱등(idempotent): 여러 번 실행해도 안전. rsync 로 동일 파일은 변경 없음.
#   - patches/ skel/ snippet/ *.md / config/ 는 복사 대상에서 제외(수동 병합 안내 대상).
#   - 덮어쓰기 전 확인(--yes 로 건너뜀), 복사 결과 요약 출력.
#
# 사용법:
#   ./integrate.sh                 # 대화형(덮어쓰기 확인)
#   ./integrate.sh --yes           # 확인 없이 진행
#   WORKSPACE=/path TARGET=/path ./integrate.sh
#
set -euo pipefail

# ── 경로 변수 ──────────────────────────────────────────────────────────────
# WORKSPACE: 산출물 디렉토리들이 있는 _workspace 경로
# TARGET   : phx.new 로 생성한 open_mes 앱 루트(mix.exs 가 있는 곳)
WORKSPACE="${WORKSPACE:-/Users/hongsw/dev/open-mes-korea/_workspace}"
TARGET="${TARGET:-/Users/hongsw/dev/open-mes-korea}"

ASSUME_YES="no"
[ "${1:-}" = "--yes" ] && ASSUME_YES="yes"

# ── rsync 옵션: 디렉토리 구조 보존, 제외 패턴 적용 ─────────────────────────
# 제외: 마크다운(가이드), patches/, skel/, config/(병합 기준 — 자동 복사 금지), snippet
RSYNC="rsync -a"
EXCLUDES=(
  --exclude='*.md'
  --exclude='patches/'
  --exclude='skel/'
  --exclude='config/'
  --exclude='*.snippets.md'
  --exclude='CORE_PATCH.md'
  --exclude='INTEGRATION.md'
)

COPIED=0
SKIPPED_MISSING=0

log()  { printf '  %s\n' "$*"; }
head() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# copy_tree <src_dir> <dst_dir>
# src_dir 가 존재할 때만 rsync. 디렉토리 내용물(trailing slash)을 dst 로 합친다.
copy_tree() {
  local src="$1" dst="$2"
  if [ ! -d "$src" ]; then
    log "SKIP (없음): $src"
    SKIPPED_MISSING=$((SKIPPED_MISSING+1))
    return 0
  fi
  mkdir -p "$dst"
  # shellcheck disable=SC2086
  $RSYNC "${EXCLUDES[@]}" "$src"/ "$dst"/
  log "COPY: $src/  ->  $dst/"
  COPIED=$((COPIED+1))
}

# ── 사전 점검 ──────────────────────────────────────────────────────────────
head "사전 점검"
log "WORKSPACE = $WORKSPACE"
log "TARGET    = $TARGET"
if [ ! -f "$TARGET/mix.exs" ]; then
  echo "ERROR: $TARGET/mix.exs 가 없습니다. 먼저 phx.new 를 실행하세요:" >&2
  echo "  cd $TARGET && mix phx.new . --app open_mes --module OpenMes --binary-id --no-mailer" >&2
  exit 1
fi
if [ ! -d "$WORKSPACE/10_registry_catalog_impl" ]; then
  echo "ERROR: $WORKSPACE 에 산출물이 없습니다." >&2
  exit 1
fi

if [ "$ASSUME_YES" != "yes" ]; then
  echo
  echo "위 TARGET 트리에 _workspace 소스를 복사(덮어쓰기 가능)합니다. 계속? [y/N]"
  read -r ans
  case "$ans" in y|Y|yes) ;; *) echo "중단."; exit 0 ;; esac
fi

# ─────────────────────────────────────────────────────────────────────────
# [1] 코어 02 — WorkOrder (audit / outbox / production / web 컨트롤러/플러그 / 마이그레이션)
#     주의: 02 의 router.ex 는 복사하지 않는다(merge_files/router.ex 가 흡수).
#     EXCLUDES 가 .md 만 거르므로 router.ex 는 개별 제외한다.
# ─────────────────────────────────────────────────────────────────────────
head "[1] 코어 02 (WorkOrder)"
S="$WORKSPACE/02_domain_engineer_workorder_impl"
copy_tree "$S/lib/open_mes/audit"            "$TARGET/lib/open_mes/audit"
copy_tree "$S/lib/open_mes/outbox"           "$TARGET/lib/open_mes/outbox"
copy_tree "$S/lib/open_mes/production"        "$TARGET/lib/open_mes/production"
copy_tree "$S/lib/open_mes_web/controllers"  "$TARGET/lib/open_mes_web/controllers"
copy_tree "$S/lib/open_mes_web/plugs"        "$TARGET/lib/open_mes_web/plugs"
copy_tree "$S/priv/repo/migrations"          "$TARGET/priv/repo/migrations"
copy_tree "$S/test/open_mes"                 "$TARGET/test/open_mes"
copy_tree "$S/test/open_mes_web"             "$TARGET/test/open_mes_web"
copy_tree "$S/test/support"                  "$TARGET/test/support"
# 02/lib/open_mes_web/router.ex 는 의도적으로 미복사(merge_files/router.ex 사용)
log "NOTE: 02 router.ex 는 미복사 — merge_files/router.ex 를 수동 배치(Step 3)"

# ─────────────────────────────────────────────────────────────────────────
# [2] 기반 작업 10 — 레지스트리 / 카탈로그 / EXT 메타데이터 모듈
#     config/ 와 skel/ 은 EXCLUDES 로 제외됨(병합 기준 → 수동).
# ─────────────────────────────────────────────────────────────────────────
head "[2] 기반 작업 10 (레지스트리/카탈로그/EXT 메타)"
S="$WORKSPACE/10_registry_catalog_impl"
copy_tree "$S/lib/open_mes/extensions"       "$TARGET/lib/open_mes/extensions"
copy_tree "$S/lib/open_mes_web/live"         "$TARGET/lib/open_mes_web/live"
copy_tree "$S/lib/open_mes_ingest"           "$TARGET/lib/open_mes_ingest"   # EXT-1 메타데이터 extension.ex
copy_tree "$S/lib/open_mes_media"            "$TARGET/lib/open_mes_media"    # EXT-2 메타데이터 extension.ex
copy_tree "$S/test/open_mes/extensions"      "$TARGET/test/open_mes/extensions"
copy_tree "$S/test/open_mes_web/live"        "$TARGET/test/open_mes_web/live"
copy_tree "$S/test/support"                  "$TARGET/test/support"

# ─────────────────────────────────────────────────────────────────────────
# [3] EXT-1 06 — Ingest (Broadway 파이프라인 / 컨트롤러 / 플러그 / 마이그레이션)
#     주의: 06 의 extension.ex 는 10 것을 쓰므로, 10 을 [2]에서 먼저 복사했다.
#     rsync 가 동일 경로의 extension.ex 를 06 버전으로 덮어쓰지 않도록 제외.
# ─────────────────────────────────────────────────────────────────────────
head "[3] EXT-1 06 (Ingest)"
S="$WORKSPACE/06_domain_engineer_ingest_impl"
# 06 에는 extension.ex 가 없음(10 이 제공). lib/open_mes_ingest 전체 복사 안전.
copy_tree "$S/lib/open_mes_ingest"           "$TARGET/lib/open_mes_ingest"
copy_tree "$S/lib/open_mes_web/controllers"  "$TARGET/lib/open_mes_web/controllers"
copy_tree "$S/lib/open_mes_web/plugs"        "$TARGET/lib/open_mes_web/plugs"
copy_tree "$S/priv/repo/migrations"          "$TARGET/priv/repo/migrations"
copy_tree "$S/test/open_mes_ingest"          "$TARGET/test/open_mes_ingest"
copy_tree "$S/test/open_mes_web"             "$TARGET/test/open_mes_web"
copy_tree "$S/test/support"                  "$TARGET/test/support"

# ─────────────────────────────────────────────────────────────────────────
# [4] EXT-2 07 — Media (object_store / transfer / watch / 마이그레이션)
#     extension.ex 는 10 것을 사용(07 에는 없음).
# ─────────────────────────────────────────────────────────────────────────
head "[4] EXT-2 07 (Media)"
S="$WORKSPACE/07_domain_engineer_media_impl"
copy_tree "$S/lib/open_mes_media"            "$TARGET/lib/open_mes_media"
copy_tree "$S/priv/repo/migrations"          "$TARGET/priv/repo/migrations"
copy_tree "$S/test/open_mes_media"           "$TARGET/test/open_mes_media"
copy_tree "$S/test/support"                  "$TARGET/test/support"

# ─────────────────────────────────────────────────────────────────────────
# [5] 애드온 5개 — open_mes_addons/* + web/live/addons/* (+ wo_csv 컨트롤러)
#     모두 읽기 전용, 마이그레이션 0(테스트 임시 테이블은 test/support 로 복사).
# ─────────────────────────────────────────────────────────────────────────
head "[5] 애드온 5개"
for A in \
  11_addon_wo_csv_export \
  11_addon_defect_stats \
  11_addon_lot_qr_label \
  11_addon_equipment_oee \
  11_addon_daily_summary ; do
  S="$WORKSPACE/$A"
  log "--- $A ---"
  copy_tree "$S/lib/open_mes_addons"          "$TARGET/lib/open_mes_addons"
  copy_tree "$S/lib/open_mes_web/live/addons"  "$TARGET/lib/open_mes_web/live/addons"
  copy_tree "$S/lib/open_mes_web/controllers"  "$TARGET/lib/open_mes_web/controllers"  # wo_csv 만 존재
  copy_tree "$S/test/open_mes_addons"          "$TARGET/test/open_mes_addons"
  copy_tree "$S/test/support"                  "$TARGET/test/support"
done

# ─────────────────────────────────────────────────────────────────────────
# 요약
# ─────────────────────────────────────────────────────────────────────────
head "복사 요약"
log "복사한 트리 수: $COPIED"
log "없어서 건너뜀 : $SKIPPED_MISSING"
echo
echo "다음 단계(수동 병합 — INTEGRATION_GUIDE.md Step 3):"
echo "  1) merge_files/mix.deps.exs   -> mix.exs 의 defp deps 에 병합"
echo "  2) merge_files/config.exs     -> config/config.exs 끝(import_config 위)에 병합"
echo "  3) merge_files/dev.exs        -> config/dev.exs 에 병합"
echo "  4) merge_files/runtime.exs    -> config/runtime.exs 에 병합"
echo "  5) merge_files/application.ex -> lib/open_mes/application.ex 덮어쓰기(또는 병합)"
echo "  6) merge_files/router.ex      -> lib/open_mes_web/router.ex 덮어쓰기"
echo
echo "주의: 이 환경엔 elixir/mix 가 없어 컴파일 검증 불가."
echo "      경로/모듈명/버전/순서의 정적 정확성만 보장됩니다(가이드 Step 0 참조)."
