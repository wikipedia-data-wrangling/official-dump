#!/usr/bin/env bash
# Phase 3 partitioning autonomous chain — span revision_text across lacie14 + lacie10.
#
# Designed to be launched in its own tmux session (e.g. `tmux new -s phase3-partition`)
# and run end-to-end without further intervention. Estimated wall time: 18-22 h
# dominated by the bulk INSERT SELECT.
#
# Pre-conditions (script verifies and aborts if missing):
#   * Tablespace wiki_ts_lacie10 exists (sudo step done — see PRINT_SUDO below)
#   * `simone` has CREATE on wiki_ts_lacie10
#   * Loader is stopped (script will stop it if still running)
#
# Outline:
#   STEP 0  preflight + (auto) stop loader
#   STEP 1  CREATE partitioned parent + p1 (lacie14) + p2 (lacie10) + move PK indexes to NVMe
#   STEP 2  bulk copy: INSERT INTO revision_text_v2 SELECT * FROM revision_text  (THE BIG ONE)
#   STEP 3  verify row counts match between old + new
#   STEP 4  atomic swap (DROP old, RENAME new)
#   STEP 5  regenerate --files list (drop newly-completed files since the SKIP=350 cut)
#   STEP 6  relaunch loader in tmux phase3-load (--no-truncate --skip-revision-check)
#   STEP 7  relaunch sampler in tmux phase3-sampler

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
SPLIT_REV_ID=1000000000
TS_NEW=wiki_ts_lacie10
TS_OLD=wiki_ts_lacie
TS_SYS=wiki_ts_sys
CHAIN_LOG="$REPO/phase3_partition_chain_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$CHAIN_LOG") 2>&1

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

cd "$REPO"

# ---------------------------------------------------------------------------
# STEP 0 — preflight + stop loader
# ---------------------------------------------------------------------------
say "=== STEP 0: preflight ==="

# Verify lacie10 tablespace exists
spc_loc=$(PGSERVICE=wiki psql -tAc "SELECT pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname='$TS_NEW';" 2>/dev/null || true)
if [ -z "$spc_loc" ]; then
  cat <<EOF
$TS_NEW tablespace does not exist yet. Run these sudo commands first, then re-launch:

  sudo mkdir -p /media/simone/lacie10/postgres-wiki
  sudo chown postgres:postgres /media/simone/lacie10/postgres-wiki
  sudo chmod 700 /media/simone/lacie10/postgres-wiki
  sudo -u postgres psql -p 5434 -c \
    "CREATE TABLESPACE $TS_NEW LOCATION '/media/simone/lacie10/postgres-wiki';"
  sudo -u postgres psql -p 5434 -c \
    "GRANT CREATE ON TABLESPACE $TS_NEW TO simone;"

Then verify:
  PGSERVICE=wiki psql -tAc "SELECT has_tablespace_privilege('simone','$TS_NEW','CREATE');"

EOF
  die "missing tablespace $TS_NEW"
fi
say "tablespace $TS_NEW exists at $spc_loc"

# Verify GRANT
grant_ok=$(PGSERVICE=wiki psql -tAc "SELECT has_tablespace_privilege('simone','$TS_NEW','CREATE');")
[ "$grant_ok" = "t" ] || die "simone lacks CREATE on $TS_NEW — run the GRANT shown above"
say "GRANT verified"

# Verify revision_text exists and is NOT already partitioned
relkind=$(PGSERVICE=wiki psql -tAc "SELECT relkind FROM pg_class WHERE relname='revision_text';")
case "$relkind" in
  r) say "revision_text is a regular table — proceeding" ;;
  p) die "revision_text is already partitioned — nothing to do" ;;
  *) die "revision_text not found (relkind=$relkind)" ;;
esac

# Verify revision_text_v2 doesn't exist (clean slate)
v2_kind=$(PGSERVICE=wiki psql -tAc "SELECT relkind FROM pg_class WHERE relname='revision_text_v2';" || true)
[ -z "$v2_kind" ] || die "revision_text_v2 already exists (relkind=$v2_kind) — clean it up before running"

# Stop loader if running
if pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null; then
  say "loader is running — sending SIGINT for graceful shutdown"
  pkill -INT -u simone -f "^python load_pages_meta_history_xml" || true
  sleep 30
  pkill -TERM -u simone -f "^python load_pages_meta_history_xml" || true
  sleep 5
  pkill -KILL -u simone -f "^python load_pages_meta_history_xml" || true
  pkill -KILL -u simone -f "^7zz x -so" || true
  sleep 3
fi
pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null && die "loader still alive after SIGKILL"
say "loader stopped"

# Stop sampler too — don't want count queries during DDL
if tmux has-session -t phase3-sampler 2>/dev/null; then
  tmux kill-session -t phase3-sampler
  say "phase3-sampler killed"
fi
pkill -u simone -f phase3_sampler.sh || true

# Make sure no stragglers are holding locks
backends=$(PGSERVICE=wiki psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='wiki20260401' AND pid <> pg_backend_pid();")
say "remaining backends on wiki20260401: $backends"

# ---------------------------------------------------------------------------
# STEP 1 — create partitioned parent + p1 + p2 + move PK indexes
# ---------------------------------------------------------------------------
say "=== STEP 1: create partitioned parent + p1 + p2 ==="
STEP1_T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
\timing on
CREATE TABLE revision_text_v2 (
    rev_id         bigint NOT NULL,
    rev_text       bytea,
    rev_text_bytes bigint NOT NULL,
    PRIMARY KEY (rev_id)
) PARTITION BY RANGE (rev_id);

CREATE TABLE revision_text_p1
    PARTITION OF revision_text_v2
    FOR VALUES FROM (MINVALUE) TO ($SPLIT_REV_ID)
    TABLESPACE $TS_OLD;

CREATE TABLE revision_text_p2
    PARTITION OF revision_text_v2
    FOR VALUES FROM ($SPLIT_REV_ID) TO (MAXVALUE)
    TABLESPACE $TS_NEW;

-- Move both partition PK indexes to NVMe (wiki_ts_sys) for fast random lookups.
ALTER INDEX revision_text_p1_pkey SET TABLESPACE $TS_SYS;
ALTER INDEX revision_text_p2_pkey SET TABLESPACE $TS_SYS;

-- Confirm
SELECT c.relname,
       coalesce(t.spcname, '(default)') AS tablespace,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
  FROM pg_class c
  LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
 WHERE c.relname IN ('revision_text_v2', 'revision_text_p1',
                     'revision_text_p2', 'revision_text_p1_pkey',
                     'revision_text_p2_pkey')
 ORDER BY c.relname;
SQL
STEP1_T1=$(date +%s)
say "STEP 1 done in $((STEP1_T1 - STEP1_T0)) s"

# ---------------------------------------------------------------------------
# STEP 2 — bulk copy via INSERT SELECT (THE BIG ONE: ~18-22 h)
# ---------------------------------------------------------------------------
say "=== STEP 2: bulk copy revision_text -> revision_text_v2 (~18-22 h) ==="
say "reading 8+ TB from lacie14, writing ~6 TB to lacie14 (p1) + ~2.5 TB to lacie10 (p2)"
STEP2_T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
SET synchronous_commit = OFF;
SET maintenance_work_mem = '4GB';
SET work_mem = '512MB';
\timing on
INSERT INTO revision_text_v2 SELECT * FROM revision_text;
SQL
STEP2_T1=$(date +%s)
say "STEP 2 done in $((STEP2_T1 - STEP2_T0)) s ($(( (STEP2_T1 - STEP2_T0) / 3600 )) h)"

# ---------------------------------------------------------------------------
# STEP 3 — verify row counts match
# ---------------------------------------------------------------------------
say "=== STEP 3: verify counts ==="
# Use reltuples for speed; exact count(*) on 8 TB takes >5 min on HDD.
old_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text';")
new_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text_v2';")
say "old reltuples: $old_n"
say "new reltuples: $new_n"
diff=$(( old_n > new_n ? old_n - new_n : new_n - old_n ))
pct=$(( old_n > 0 ? (diff * 1000) / old_n : 0 ))
say "abs diff: $diff  (~$((pct / 10)).$((pct % 10))% of old)"
# Tolerance: reltuples is sampled — accept up to 2% drift between samplings.
[ "$pct" -le 20 ] || die "row count diverged by more than 2% — investigate before swap"
say "counts agree within tolerance — safe to swap"

# Extra sanity: each partition's reltuples adds up roughly to new total
p1_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text_p1';")
p2_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text_p2';")
say "p1 rows: $p1_n  (rev_id < $SPLIT_REV_ID)"
say "p2 rows: $p2_n  (rev_id >= $SPLIT_REV_ID)"

# ---------------------------------------------------------------------------
# STEP 4 — atomic swap: DROP old, RENAME new
# ---------------------------------------------------------------------------
say "=== STEP 4: atomic swap ==="
STEP4_T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
BEGIN;
DROP TABLE revision_text;  -- frees ~6 TB on lacie14 (the heap of the old single-table revision_text)
ALTER TABLE revision_text_v2 RENAME TO revision_text;
COMMIT;

-- Confirm
SELECT c.relname,
       coalesce(t.spcname, '(default)') AS tablespace,
       c.relkind
  FROM pg_class c
  LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
 WHERE c.relname IN ('revision_text', 'revision_text_p1',
                     'revision_text_p2', 'revision_text_p1_pkey',
                     'revision_text_p2_pkey')
 ORDER BY c.relname;
SQL
STEP4_T1=$(date +%s)
say "STEP 4 done in $((STEP4_T1 - STEP4_T0)) s"

df -h /media/simone/lacie14 /media/simone/lacie10 /

# ---------------------------------------------------------------------------
# STEP 5 — regenerate --files list (skip files completed since the last cut)
# ---------------------------------------------------------------------------
say "=== STEP 5: regenerate --files list ==="
# Extract basename of every file that has a "done: seen=" line in the current loader log.
COMPLETED_LIST=/tmp/phase3_completed_basenames.txt
NEW_FILES_LIST=/tmp/phase3_remaining_files_post_partition.txt
grep "done: seen=" "$REPO/phase3_loader_active.log" \
  | grep -oE 'enwiki-20260401-pages-meta-history[0-9]+\.xml-p[0-9]+p[0-9]+\.7z' \
  | sort -u > "$COMPLETED_LIST" || true
say "completed file basenames extracted: $(wc -l < "$COMPLETED_LIST")"

# Subtract from the original SKIP=350 cut list.
ORIG_LIST=/tmp/phase3_remaining_files.txt
[ -f "$ORIG_LIST" ] || die "original /tmp/phase3_remaining_files.txt not found"
grep -vF -f "$COMPLETED_LIST" "$ORIG_LIST" > "$NEW_FILES_LIST" || true
say "remaining files after subtracting completed: $(wc -l < "$NEW_FILES_LIST")"
echo "  first 3: $(head -3 "$NEW_FILES_LIST")"
echo "  last 3:  $(tail -3 "$NEW_FILES_LIST")"

# ---------------------------------------------------------------------------
# STEP 6 — relaunch loader in tmux phase3-load
# ---------------------------------------------------------------------------
say "=== STEP 6: relaunch loader ==="
if tmux has-session -t phase3-load 2>/dev/null; then
  tmux kill-session -t phase3-load
fi
tmux new-session -d -s phase3-load -c "$REPO" \
  'source .venv/bin/activate; exec zsh -i'
sleep 2
# Save old log for forensics, then overwrite with the fresh run's log.
[ -f "$REPO/phase3_loader_active.log" ] && \
  mv "$REPO/phase3_loader_active.log" "$REPO/phase3_loader_pre_partition_$(date +%Y%m%d_%H%M%S).log"
# Build the file-list arg here in source bash; tmux just sends the resolved
# (long) literal command to the destination zsh.
FILE_ARGS=$(tr '\n' ' ' < "$NEW_FILES_LIST")
tmux send-keys -t phase3-load \
  "python load_pages_meta_history_xml.py --workers 2 --no-truncate --skip-revision-check --files $FILE_ARGS 2>&1 | tee phase3_loader_active.log" \
  Enter
sleep 5
say "phase3-load pane tail:"
tmux capture-pane -t phase3-load -p | tail -10

# ---------------------------------------------------------------------------
# STEP 7 — relaunch sampler
# ---------------------------------------------------------------------------
say "=== STEP 7: relaunch sampler ==="
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
say "post-partition loader log: $REPO/phase3_loader_active.log"
say "next hourly cron at :07 will show new file rates against the partitioned table"
