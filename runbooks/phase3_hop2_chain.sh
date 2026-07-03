#!/usr/bin/env bash
# Phase 3 hop 2 — partition revision_text across lacie14 + ssd1 to free
# the lacie10 source entirely.
#
# Designed to run in its own tmux session (e.g. `tmux new -s phase3-hop2`)
# and complete autonomously. Wall time: ~16-20 h dominated by INSERT SELECT.
#
# Source: revision_text on wiki_ts_lacie10 (8.79 TB, lacie10 — 100% full)
# Targets:
#   p1 [MINVALUE, 1B)   on wiki_ts_lacie (lacie14, 9.5 TB free)
#   p2 [1B, MAXVALUE)   on wiki_ts       (ssd1, 5.3 TB free — internal SSD)
# PK indexes for both partitions land on wiki_ts_sys (NVMe).
# After swap: lacie10 fully freed (~8.6 TB).

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
SPLIT_REV_ID=1000000000
TS_P1=wiki_ts_lacie     # lacie14, 9.5 TB free
TS_P2=wiki_ts           # ssd1, 5.3 TB free (existing tablespace)
TS_SYS=wiki_ts_sys      # NVMe for PK indexes
TS_TEMP=wiki_ts_sys     # NVMe for temp spills
CHAIN_LOG="$REPO/phase3_hop2_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$CHAIN_LOG") 2>&1

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

cd "$REPO"

# ---------------------------------------------------------------------------
# STEP 0 — preflight
# ---------------------------------------------------------------------------
say "=== STEP 0: preflight ==="

# Loader must be stopped (it died on ENOSPC, so should be)
if pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null; then
  die "loader procs still alive — stop them first"
fi
say "loader: not running (good)"

# Verify grants
for ts in "$TS_P1" "$TS_P2" "$TS_SYS"; do
  g=$(PGSERVICE=wiki psql -tAc "SELECT has_tablespace_privilege('simone','$ts','CREATE');")
  [ "$g" = "t" ] || die "simone lacks CREATE on $ts"
done
say "GRANTs verified on $TS_P1, $TS_P2, $TS_SYS"

# revision_text must be a regular (non-partitioned) table
relkind=$(PGSERVICE=wiki psql -tAc "SELECT relkind FROM pg_class WHERE relname='revision_text';")
[ "$relkind" = "r" ] || die "revision_text is not a regular table (relkind=$relkind)"
say "revision_text is a regular table on wiki_ts_lacie10"

# revision_text_v2 must NOT exist (cleanup must be done)
v2=$(PGSERVICE=wiki psql -tAc "SELECT count(*) FROM pg_class WHERE relname IN ('revision_text_v2','revision_text_p1','revision_text_p2');")
[ "$v2" = "0" ] || die "leftover revision_text_v2/p1/p2 exists — DROP them first"
say "no leftover partition tables"

# Capacity check on destinations
say "destination capacity:"
df -h /media/simone/lacie14 /media/simone/ssd1 /media/simone/lacie10 | grep -E "Filesystem|sde|sdc|sdd"

# Stop sampler (may be holding a connection)
if tmux has-session -t phase3-sampler 2>/dev/null; then
  tmux kill-session -t phase3-sampler
  say "phase3-sampler killed"
fi
pkill -u simone -f phase3_sampler.sh || true

# Confirm no other client backends (autovacuum workers are fine, they don't
# hold ACCESS EXCLUSIVE locks that block our DDL — and we can't terminate
# them as simone anyway).
backends=$(PGSERVICE=wiki psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='wiki20260401' AND pid <> pg_backend_pid() AND backend_type='client backend';")
say "wiki20260401 client backends: $backends (should be 0)"
[ "$backends" = "0" ] || die "client backends connected — terminate them first"
# Show any autovacuum activity for awareness
av=$(PGSERVICE=wiki psql -tAc "SELECT count(*) FROM pg_stat_activity WHERE datname='wiki20260401' AND backend_type='autovacuum worker';")
say "wiki20260401 autovacuum workers: $av (harmless)"

# Capture pre-state for after-comparison
PGSERVICE=wiki psql -c "
SELECT 'revision_text size before move' AS what, pg_size_pretty(pg_total_relation_size('revision_text'));
SELECT 'reltuples' AS what, reltuples::bigint FROM pg_class WHERE relname='revision_text';
SELECT MIN(rev_id) AS min_rev, MAX(rev_id) AS max_rev FROM revision_text;"

# ---------------------------------------------------------------------------
# STEP 1 — create partitioned parent + p1 + p2 + move PK indexes to NVMe
# ---------------------------------------------------------------------------
say "=== STEP 1: create partitioned parent + p1 (lacie14) + p2 (ssd1) ==="
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
    TABLESPACE $TS_P1;

CREATE TABLE revision_text_p2
    PARTITION OF revision_text_v2
    FOR VALUES FROM ($SPLIT_REV_ID) TO (MAXVALUE)
    TABLESPACE $TS_P2;

ALTER INDEX revision_text_p1_pkey SET TABLESPACE $TS_SYS;
ALTER INDEX revision_text_p2_pkey SET TABLESPACE $TS_SYS;

SELECT c.relname,
       coalesce(t.spcname, '(default)') AS tablespace,
       c.relkind
  FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
 WHERE c.relname IN ('revision_text_v2','revision_text_p1','revision_text_p2',
                     'revision_text_p1_pkey','revision_text_p2_pkey')
 ORDER BY c.relname;
SQL
STEP1_T1=$(date +%s)
say "STEP 1 done in $((STEP1_T1 - STEP1_T0)) s"

# ---------------------------------------------------------------------------
# STEP 2 — bulk copy revision_text -> revision_text_v2 (~16-20 h)
# ---------------------------------------------------------------------------
say "=== STEP 2: bulk copy (~16-20 h) ==="
say "reading ~8.79 TB from lacie10, writing ~6.5 TB to lacie14 + ~2.3 TB to ssd1"
STEP2_T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
SET temp_tablespaces = '$TS_TEMP';
SET synchronous_commit = OFF;
SET maintenance_work_mem = '4GB';
SET work_mem = '512MB';
\timing on
INSERT INTO revision_text_v2 SELECT * FROM revision_text;
SQL
STEP2_T1=$(date +%s)
say "STEP 2 done in $((STEP2_T1 - STEP2_T0)) s ($(( (STEP2_T1 - STEP2_T0) / 3600 )) h)"

# ---------------------------------------------------------------------------
# STEP 3 — verify counts (reltuples-based for speed)
# ---------------------------------------------------------------------------
say "=== STEP 3: verify counts ==="
old_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text';")
new_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text_v2';")
p1_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text_p1';")
p2_n=$(PGSERVICE=wiki psql -tAc "SELECT reltuples::bigint FROM pg_class WHERE relname='revision_text_p2';")
say "old reltuples: $old_n"
say "new reltuples: $new_n"
say "p1:  $p1_n  (rev_id < $SPLIT_REV_ID)"
say "p2:  $p2_n  (rev_id >= $SPLIT_REV_ID)"
diff=$(( old_n > new_n ? old_n - new_n : new_n - old_n ))
pct=$(( old_n > 0 ? (diff * 1000) / old_n : 0 ))
say "abs diff: $diff  (~$((pct / 10)).$((pct % 10))% of old)"
[ "$pct" -le 30 ] || die "row count diverged by more than 3% — investigate before swap"
say "counts agree within reltuples-sampling tolerance"

# ---------------------------------------------------------------------------
# STEP 4 — atomic swap
# ---------------------------------------------------------------------------
say "=== STEP 4: atomic swap ==="
STEP4_T0=$(date +%s)
PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
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
STEP4_T1=$(date +%s)
say "STEP 4 done in $((STEP4_T1 - STEP4_T0)) s"
df -h /media/simone/lacie14 /media/simone/lacie10 /media/simone/ssd1 / | grep -E "Filesystem|sde|sdd|sdc|nvme"

# ---------------------------------------------------------------------------
# STEP 5 — regenerate --files list (skip files completed since SKIP=350 cut)
# ---------------------------------------------------------------------------
say "=== STEP 5: regenerate --files list ==="
COMPLETED_LIST=/tmp/phase3_completed_basenames.txt
NEW_FILES_LIST=/tmp/phase3_remaining_files_post_hop2.txt

# Collect completed basenames from ALL archived loader logs + the current one.
{
  for f in "$REPO"/phase3_loader_pre_move_*.log "$REPO"/phase3_loader_pre_partition_*.log "$REPO"/phase3_loader_active.log; do
    [ -f "$f" ] && grep "done: seen=" "$f" 2>/dev/null
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
# STEP 6 — relaunch loader in tmux phase3-load
# (use $(cat ...) inside the destination shell to avoid tmux send-keys
# command-too-long error — lesson from hop 1's step 3 failure)
# ---------------------------------------------------------------------------
say "=== STEP 6: relaunch loader ==="
if tmux has-session -t phase3-load 2>/dev/null; then
  tmux kill-session -t phase3-load
fi
tmux new-session -d -s phase3-load -c "$REPO" \
  'source .venv/bin/activate; exec zsh -i'
sleep 2

# Archive old log
if [ -f "$REPO/phase3_loader_active.log" ]; then
  mv "$REPO/phase3_loader_active.log" "$REPO/phase3_loader_pre_hop2_$(date +%Y%m%d_%H%M%S).log"
fi

# Send a SHORT command; let destination shell expand $(cat ...).
tmux send-keys -t phase3-load \
  "python load_pages_meta_history_xml.py --workers 2 --no-truncate --skip-revision-check --files \$(cat $NEW_FILES_LIST) 2>&1 | tee phase3_loader_active.log" \
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
say "post-hop-2 loader log: $REPO/phase3_loader_active.log"
say "lacie10 should now have ~8.6 TB free; lacie14 has ~3 TB free; ssd1 has ~4 TB free"
