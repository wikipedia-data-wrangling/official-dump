#!/usr/bin/env bash
# Bulk-load orchestrator for the wiki20260401 pipeline.
#
# Usage:
#   ./run_pipeline.sh phase1            # download + load Phase 1a SQL + Phase 1b logging XML (~13 GB, hours)
#   ./run_pipeline.sh phase2            # download + load Phase 2 stub-meta-history (~225 GB, multi-hour)
#   ./run_pipeline.sh freeze2           # snapshot + key_figures + manifest + git tag phase2-frozen
#   ./run_pipeline.sh through_phase2    # phase1 + phase2 + freeze2  (end at phase2-frozen)
#   ./run_pipeline.sh phase3            # download + load Phase 3 pages-meta-history (~270 GiB, multi-day)
#   ./run_pipeline.sh freeze3           # snapshot + key_figures + manifest + API spot-check + git tag phase3-frozen
#   ./run_pipeline.sh through_phase3    # phase3 + freeze3  (end at phase3-frozen; assumes through_phase2 already ran)
#   ./run_pipeline.sh all               # phase1 -> phase2 -> freeze2 -> phase3 -> freeze3
#
# Pre-conditions (from setup_postgres18.sh, already done):
#   - PG18 running on port 5434
#   - Database wiki20260401, role simone, schema applied
#   - service=wiki entry in ~/.pg_service.conf
#   - jq installed (needed by freeze_phase3.sh): sudo apt-get install -y jq
#
# Long-running tip: run inside tmux/screen so a disconnect doesn't kill it:
#   tmux new -s wiki  ;  ./run_pipeline.sh all  ;  Ctrl-b d
#
# Idempotency: the downloader skips files matching their manifest sha1; loaders
# TRUNCATE their target tables before loading. Re-running a phase is safe.

set -euo pipefail

REPO_DIR="/home/simone/githubRepos/wikipediaData/official-dump"
cd "$REPO_DIR"
# shellcheck disable=SC1091
source "$REPO_DIR/.venv/bin/activate"

log()  { echo; echo "==> [$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

git_freeze_tag() {
  local tag="$1" msg="$2"
  log "Committing and tagging '$tag'"
  git add -A
  if git diff --cached --quiet; then
    echo "(no changes to commit)"
  else
    git commit -m "$msg"
  fi
  git tag -f "$tag"
}

run_phase1() {
  log "Phase 1a/1b — downloading SQL + logging XML"
  python download_dumps.py
  log "Phase 1a — loading SQL dumps (page, page_restrictions, protected_titles, user_groups, user_former_groups, change_tag, change_tag_def)"
  python load_sql_dumps.py
  log "Phase 1b — loading protection log XML"
  python load_logging_xml.py
  log "Phase 1 done."
}

run_phase2() {
  log "Phase 2 — downloading stub-meta-history XML (~225 GB compressed)"
  python download_dumps.py --phase 2
  log "Phase 2 — loading revision metadata into revision + actor"
  python load_stub_history_xml.py --workers 2
  log "Phase 2 done."
}

run_freeze2() {
  log "Phase 4a — freezing post-Phase-2 state"
  bash freeze_phase2.sh
  git_freeze_tag phase2-frozen "Phase 2 frozen"
  log "Phase 4a done."
}

run_phase3() {
  log "Phase 3 — downloading pages-meta-history (~270 GiB compressed; expect multi-day)"
  python download_dumps.py --phase 3
  log "Phase 3 — loading wikitext into revision_text"
  python load_pages_meta_history_xml.py --workers 2
  log "Phase 3 done."
}

run_freeze3() {
  log "Phase 4b — freezing post-Phase-3 state (includes API spot-check)"
  bash freeze_phase3.sh
  git_freeze_tag phase3-frozen "Phase 3 frozen"
  log "Phase 4b done."
}

case "${1:-}" in
  phase1)  run_phase1 ;;
  phase2)  run_phase2 ;;
  freeze2) run_freeze2 ;;
  through_phase2)
    run_phase1
    run_phase2
    run_freeze2
    ;;
  phase3)  run_phase3 ;;
  freeze3) run_freeze3 ;;
  through_phase3)
    run_phase3
    run_freeze3
    ;;
  all)
    run_phase1
    run_phase2
    run_freeze2
    run_phase3
    run_freeze3
    ;;
  ""|-h|--help)
    sed -n '2,27p' "$0"
    exit 0
    ;;
  *)
    fail "unknown subcommand: $1 (run with --help for usage)"
    ;;
esac

log "Pipeline run complete."
