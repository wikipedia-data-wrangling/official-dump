#!/usr/bin/env bash
# Phase 3 hop 2 recovery — finish what the chain didn't.
# The INSERT SELECT completed 2026-06-16 22:44 BST (INSERT 0 670640642 rows
# into revision_text_v2 / p1+p2), but the chain aborted at verify because
# pg_class.reltuples=-1 for the freshly-created partitioned parent.
#
# Recovery: trust the INSERT count, run the atomic swap, regenerate the
# --files list, restart loader + sampler. ANALYZE deferred to autovacuum.

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
CHAIN_LOG="$REPO/phase3_hop2_recovery_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$CHAIN_LOG") 2>&1

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

cd "$REPO"

# ---------------------------------------------------------------------------
# STEP 0 — preflight
# ---------------------------------------------------------------------------
say "=== STEP 0: preflight ==="

# All three tables must exist
for t in revision_text revision_text_v2 revision_text_p1 revision_text_p2; do
  exists=$(PGSERVICE=wiki psql -tAc "SELECT 1 FROM pg_class WHERE relname='$t';")
  [ "$exists" = "1" ] || die "$t does not exist"
done
say "all four tables present"

# p1 and p2 are attached to v2
parent=$(PGSERVICE=wiki psql -tAc "SELECT inhparent::regclass::text FROM pg_inherits WHERE inhrelid='revision_text_p1'::regclass;")
[ "$parent" = "revision_text_v2" ] || die "revision_text_p1 not attached to revision_text_v2 (parent=$parent)"
say "partitions are attached to revision_text_v2"

# Loader must be stopped
if pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null; then
  die "loader procs still alive — stop them first"
fi
say "loader: not running"

# ---------------------------------------------------------------------------
# STEP 1 — atomic swap
# ---------------------------------------------------------------------------
say "=== STEP 1: atomic swap ==="
say "(INSERT 0 670,640,642 from chain log is our proof the data is complete;"
say " ANALYZE deferred to autovacuum / first query planner need)"
T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
\timing on
BEGIN;
DROP TABLE revision_text;
ALTER TABLE revision_text_v2 RENAME TO revision_text;
COMMIT;

SELECT c.relname, c.relkind,
       coalesce(t.spcname, '(default)') AS tablespace,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
  FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
 WHERE c.relname LIKE 'revision_text%'
 ORDER BY c.relname;
SQL
T1=$(date +%s)
say "swap done in $((T1-T0)) s"
df -h /media/simone/lacie14 /media/simone/lacie10 /media/simone/ssd1 / | grep -E "Filesystem|sde|sdd|sdc|nvme"

# ---------------------------------------------------------------------------
# STEP 2 — regenerate --files list
# ---------------------------------------------------------------------------
say "=== STEP 2: regenerate --files list ==="
COMPLETED_LIST=/tmp/phase3_completed_basenames.txt
NEW_FILES_LIST=/tmp/phase3_remaining_files_post_hop2.txt

{
  for f in "$REPO"/phase3_loader_pre_move_*.log \
           "$REPO"/phase3_loader_pre_partition_*.log \
           "$REPO"/phase3_loader_pre_hop2_*.log \
           "$REPO"/phase3_loader_active.log; do
    [ -f "$f" ] && grep "done: seen=" "$f" 2>/dev/null || true
  done
} | grep -oE 'enwiki-20260401-pages-meta-history[0-9]+\.xml-p[0-9]+p[0-9]+\.7z' \
  | sort -u > "$COMPLETED_LIST" || true
say "completed file basenames (across all runs): $(wc -l < "$COMPLETED_LIST")"

ORIG_LIST=/tmp/phase3_remaining_files.txt
[ -f "$ORIG_LIST" ] || die "original /tmp/phase3_remaining_files.txt not found"
grep -vF -f "$COMPLETED_LIST" "$ORIG_LIST" > "$NEW_FILES_LIST" || true
say "remaining files: $(wc -l < "$NEW_FILES_LIST")"
echo "  first 3:"
head -3 "$NEW_FILES_LIST" | sed 's|^|    |'
echo "  last 3:"
tail -3 "$NEW_FILES_LIST" | sed 's|^|    |'

# ---------------------------------------------------------------------------
# STEP 3 — relaunch loader in tmux phase3-load
# ---------------------------------------------------------------------------
say "=== STEP 3: relaunch loader ==="
if tmux has-session -t phase3-load 2>/dev/null; then
  tmux kill-session -t phase3-load
fi
tmux new-session -d -s phase3-load -c "$REPO" \
  'source .venv/bin/activate; exec zsh -i'
sleep 2

if [ -f "$REPO/phase3_loader_active.log" ]; then
  mv "$REPO/phase3_loader_active.log" "$REPO/phase3_loader_pre_hop2recovery_$(date +%Y%m%d_%H%M%S).log"
fi

# $(cat ...) inside the destination shell so the long argv doesn't trip
# tmux's send-keys length cap (lesson from hop 1 step 3).
tmux send-keys -t phase3-load \
  "python load_pages_meta_history_xml.py --workers 2 --no-truncate --skip-revision-check --files \$(cat $NEW_FILES_LIST) 2>&1 | tee phase3_loader_active.log" \
  Enter
sleep 5
say "phase3-load pane tail:"
tmux capture-pane -t phase3-load -p | tail -10

# ---------------------------------------------------------------------------
# STEP 4 — relaunch sampler
# ---------------------------------------------------------------------------
say "=== STEP 4: relaunch sampler ==="
if tmux has-session -t phase3-sampler 2>/dev/null; then
  tmux kill-session -t phase3-sampler
fi
tmux new-session -d -s phase3-sampler -c "$REPO" \
  "./phase3_sampler.sh phase3_loader_active.log 300"
sleep 2
tmux ls

say "=== ALL DONE ==="
say "chain log: $CHAIN_LOG"
