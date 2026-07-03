#!/usr/bin/env bash
# Phase 3 hop 1 — move revision_text from lacie14 (full, 0 free) to lacie10
# (newly cleared, 8.56 TiB free). Single ALTER TABLE; small Phase 1+2 tables
# stay on lacie14 (they're read-only during Phase 3 so the full disk is fine
# for them). Loader patched separately to SET temp_tablespaces = wiki_ts_sys.
#
# Designed to run inside its own tmux session (e.g. `tmux new -s phase3-move`)
# and complete autonomously. Wall time: ~16-22 h dominated by the ALTER TABLE.
#
# Pre-conditions (script verifies and aborts if missing):
#   * Loader is stopped (script will verify, won't auto-kill — should already be dead since Jun 9 21:05)
#   * Tablespace wiki_ts_lacie10 exists and simone has CREATE on it
#   * lacie10 has >= 8.5 TiB free

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
TS_NEW=wiki_ts_lacie10
TS_SYS=wiki_ts_sys
CHAIN_LOG="$REPO/phase3_move_to_lacie10_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$CHAIN_LOG") 2>&1

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

cd "$REPO"

# ---------------------------------------------------------------------------
# STEP 0 — preflight
# ---------------------------------------------------------------------------
say "=== STEP 0: preflight ==="

# Loader must be stopped
if pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null; then
  die "loader procs still alive — stop them first"
fi
say "loader: not running (good)"

# Tablespace must exist
spc_loc=$(PGSERVICE=wiki psql -tAc "SELECT pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname='$TS_NEW';" 2>/dev/null || true)
[ -n "$spc_loc" ] || die "tablespace $TS_NEW not found"
say "tablespace $TS_NEW at $spc_loc"

# GRANT must be in place
grant_ok=$(PGSERVICE=wiki psql -tAc "SELECT has_tablespace_privilege('simone','$TS_NEW','CREATE');")
[ "$grant_ok" = "t" ] || die "simone lacks CREATE on $TS_NEW"
say "GRANT verified"

# revision_text must be a regular (non-partitioned) table
relkind=$(PGSERVICE=wiki psql -tAc "SELECT relkind FROM pg_class WHERE relname='revision_text';")
[ "$relkind" = "r" ] || die "revision_text is not a regular table (relkind=$relkind)"
say "revision_text is a regular table"

# Verify current tablespace
cur_ts=$(PGSERVICE=wiki psql -tAc "
  SELECT coalesce(t.spcname,(SELECT spcname FROM pg_tablespace WHERE oid=(SELECT dattablespace FROM pg_database WHERE datname=current_database())))
    FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
   WHERE c.relname='revision_text';")
say "revision_text currently on tablespace: $cur_ts"
[ "$cur_ts" != "$TS_NEW" ] || die "revision_text is already on $TS_NEW"

# lacie10 free space check (need at least 8.5 TiB; pad with 200 GiB headroom)
lacie10_free_bytes=$(df -B1 --output=avail /media/simone/lacie10 | tail -1)
lacie10_free_tib=$(awk "BEGIN {printf \"%.2f\", $lacie10_free_bytes / 1024 / 1024 / 1024 / 1024}")
say "lacie10 free: $lacie10_free_tib TiB"
if [ "$lacie10_free_bytes" -lt 9200000000000 ]; then  # 8.36 TiB minimum + 200 GiB margin = 8.55 TiB
  die "lacie10 free is too tight ($lacie10_free_tib TiB); want >= 8.55 TiB"
fi

# Loader patch must be in place (SET temp_tablespaces)
grep -q "SET temp_tablespaces = 'wiki_ts_sys'" load_pages_meta_history_xml.py \
  || die "loader patch missing — add SET temp_tablespaces = 'wiki_ts_sys' to per-session setup"
say "loader patch present"

# Stop sampler
if tmux has-session -t phase3-sampler 2>/dev/null; then
  tmux kill-session -t phase3-sampler
  say "phase3-sampler killed"
fi
pkill -u simone -f phase3_sampler.sh || true

# Kill stray PG backends on wiki20260401 (none expected, but defensive)
backends=$(PGSERVICE=wiki psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='wiki20260401' AND pid <> pg_backend_pid();")
say "wiki20260401 backends: $backends"

# Note current sizes for after-comparison
PGSERVICE=wiki psql -c "
SELECT 'revision_text heap+TOAST+idx' AS what,
       pg_size_pretty(pg_total_relation_size('revision_text'));
SELECT 'reltuples' AS what,
       reltuples::bigint FROM pg_class WHERE relname='revision_text';"

# ---------------------------------------------------------------------------
# STEP 1 — ALTER TABLE revision_text SET TABLESPACE (THE BIG ONE: ~16-22 h)
# ---------------------------------------------------------------------------
say "=== STEP 1: ALTER TABLE revision_text SET TABLESPACE $TS_NEW (~16-22 h) ==="
say "reads ~8.35 TiB from lacie14, writes ~8.35 TiB to lacie10"
ALTER_T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
SET temp_tablespaces = '$TS_SYS';
SET maintenance_work_mem = '4GB';
\timing on
ALTER TABLE revision_text SET TABLESPACE $TS_NEW;

-- Confirm
SELECT c.relname,
       t.spcname AS new_tablespace,
       pg_size_pretty(pg_total_relation_size(c.oid))
  FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
 WHERE c.relname='revision_text';
SQL
ALTER_T1=$(date +%s)
say "ALTER TABLE completed in $((ALTER_T1 - ALTER_T0)) s ($(( (ALTER_T1 - ALTER_T0) / 3600 )) h)"

df -h /media/simone/lacie14 /media/simone/lacie10 /

# ---------------------------------------------------------------------------
# STEP 2 — regenerate --files list (skip files completed since SKIP=350 cut)
# ---------------------------------------------------------------------------
say "=== STEP 2: regenerate --files list ==="
COMPLETED_LIST=/tmp/phase3_completed_basenames.txt
NEW_FILES_LIST=/tmp/phase3_remaining_files_post_move.txt
grep "done: seen=" "$REPO/phase3_loader_active.log" 2>/dev/null \
  | grep -oE 'enwiki-20260401-pages-meta-history[0-9]+\.xml-p[0-9]+p[0-9]+\.7z' \
  | sort -u > "$COMPLETED_LIST" || true
say "completed file basenames extracted: $(wc -l < "$COMPLETED_LIST")"

ORIG_LIST=/tmp/phase3_remaining_files.txt
[ -f "$ORIG_LIST" ] || die "original /tmp/phase3_remaining_files.txt not found"
grep -vF -f "$COMPLETED_LIST" "$ORIG_LIST" > "$NEW_FILES_LIST" || true
say "remaining files after subtracting completed: $(wc -l < "$NEW_FILES_LIST")"
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

# Archive the old log
if [ -f "$REPO/phase3_loader_active.log" ]; then
  mv "$REPO/phase3_loader_active.log" "$REPO/phase3_loader_pre_move_$(date +%Y%m%d_%H%M%S).log"
fi

# Build the file-list arg in source bash; tmux just sends the resolved literal.
FILE_ARGS=$(tr '\n' ' ' < "$NEW_FILES_LIST")
tmux send-keys -t phase3-load \
  "python load_pages_meta_history_xml.py --workers 2 --no-truncate --skip-revision-check --files $FILE_ARGS 2>&1 | tee phase3_loader_active.log" \
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

# ---------------------------------------------------------------------------
say "=== ALL DONE ==="
say "chain log: $CHAIN_LOG"
say "new loader log: $REPO/phase3_loader_active.log"
say "lacie14 should now have ~10 TB free; lacie10 should have ~200 GiB free"
say "next hourly cron at :07 will show first post-move file rates"
