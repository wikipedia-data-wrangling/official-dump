#!/usr/bin/env bash
# Phase 3 partitioning runbook — span revision_text across lacie14 + lacie10.
#
# Read phase3_partition_plan.md first. This script implements the
# "Plan B" full-rewrite approach: cleaner SQL, slightly more wall-clock
# than the ATTACH-trick variant, but more predictable.
#
# NOTHING auto-fires. Each subcommand is intended to be reviewed,
# invoked separately, and verified before the next step.
#
# Pre-conditions:
#   * lacie10 has >= 2 TB free
#   * Phase 3 loader is currently stopped
#   * No other sessions writing to revision_text
#   * Tablespace wiki_ts_lacie10 will be created in step 3 (needs sudo)

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
TS_LACIE_DIR=/media/simone/lacie10/postgres-wiki
TS_NAME=wiki_ts_lacie10
SPLIT_REV_ID=1000000000  # boundary between p1 (lacie14) and p2 (lacie10)

# =============================================================================
# STEP 0 — Preflight: confirm we're in the right state to start
# =============================================================================
preflight() {
  echo "== loader procs ==" ; ps -u simone -o pid,etime,cmd | grep -E "load_pages_meta|7zz x -so" | grep -v grep || echo "(none — good)"
  echo "== lacie10 free ==" ; df -h /media/simone/lacie10
  echo "== lacie14 free ==" ; df -h /media/simone/lacie14
  echo "== pg health ==" ; pg_isready -p 5434
  echo "== revision_text size ==" ; PGSERVICE=wiki psql -tAc "SELECT pg_size_pretty(pg_total_relation_size('revision_text'));"
  echo "== revision_text rev_id range ==" ; PGSERVICE=wiki psql -tAc "SELECT MIN(rev_id), MAX(rev_id) FROM revision_text;"
  echo "== existing tablespaces ==" ; PGSERVICE=wiki psql -c "SELECT spcname, pg_tablespace_location(oid) FROM pg_tablespace;"
  echo "== current revision_text tablespace ==" ; PGSERVICE=wiki psql -tAc "SELECT t.spcname FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace WHERE c.relname='revision_text';"
  echo "== expected split ==" ; PGSERVICE=wiki psql -c "SELECT count(*) FILTER (WHERE rev_id < $SPLIT_REV_ID) AS p1_rows, count(*) FILTER (WHERE rev_id >= $SPLIT_REV_ID) AS p2_rows FROM revision_text;"
}

# =============================================================================
# STEP 1 — Stop the loader (verify it's already stopped, or kill it)
# =============================================================================
stop_loader() {
  if tmux has-session -t phase3-load 2>/dev/null; then
    if pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null; then
      echo "Loader is running. Send SIGINT, wait for current batches to commit, then kill workers."
      read -p "Proceed with graceful stop? [y/N] " yn
      [[ "$yn" == "y" ]] || { echo "aborted"; return 1; }
      pkill -INT -u simone -f "^python load_pages_meta_history_xml"
      sleep 30
      pkill -TERM -u simone -f "^python load_pages_meta_history_xml" || true
      sleep 5
      pkill -KILL -u simone -f "^python load_pages_meta_history_xml" || true
      pkill -KILL -u simone -f "^7zz x -so" || true
    else
      echo "(loader not running in tmux phase3-load)"
    fi
  fi
  if pgrep -u simone -f "^python load_pages_meta_history_xml" >/dev/null; then
    echo "WARNING: loader procs still alive — manual intervention needed"
    return 1
  fi
  echo "loader stopped"
}

# =============================================================================
# STEP 2 — Print the sudo commands for lacie10 tablespace setup
# =============================================================================
print_sudo_commands() {
  cat <<EOF
Run these as root (the user must):

  sudo mkdir -p "$TS_LACIE_DIR"
  sudo chown postgres:postgres "$TS_LACIE_DIR"
  sudo chmod 700 "$TS_LACIE_DIR"
  sudo -u postgres psql -p 5434 -c \\
    "CREATE TABLESPACE $TS_NAME LOCATION '$TS_LACIE_DIR';"
  sudo -u postgres psql -p 5434 -c \\
    "GRANT CREATE ON TABLESPACE $TS_NAME TO simone;"

Verify:
  PGSERVICE=wiki psql -c "SELECT spcname, pg_tablespace_location(oid) FROM pg_tablespace WHERE spcname = '$TS_NAME';"
  PGSERVICE=wiki psql -tAc "SELECT has_tablespace_privilege('simone', '$TS_NAME', 'CREATE');"
EOF
}

# =============================================================================
# STEP 3 — Create the partitioned parent (revision_text_v2)
# =============================================================================
create_partitioned() {
  PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
\\echo Creating partitioned revision_text_v2 with two partitions
CREATE TABLE revision_text_v2 (
    rev_id         bigint NOT NULL,
    rev_text       bytea,
    rev_text_bytes bigint NOT NULL,
    PRIMARY KEY (rev_id)
)
PARTITION BY RANGE (rev_id);

CREATE TABLE revision_text_p1
    PARTITION OF revision_text_v2
    FOR VALUES FROM (MINVALUE) TO ($SPLIT_REV_ID)
    TABLESPACE wiki_ts_lacie;

CREATE TABLE revision_text_p2
    PARTITION OF revision_text_v2
    FOR VALUES FROM ($SPLIT_REV_ID) TO (MAXVALUE)
    TABLESPACE $TS_NAME;

\\echo Move partition PK indexes onto wiki_ts_sys (NVMe) for fast lookups
ALTER INDEX revision_text_p1_pkey SET TABLESPACE wiki_ts_sys;
ALTER INDEX revision_text_p2_pkey SET TABLESPACE wiki_ts_sys;

\\echo Verify
SELECT c.relname, t.spcname, pg_size_pretty(pg_relation_size(c.oid))
  FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
 WHERE c.relname IN ('revision_text_v2', 'revision_text_p1', 'revision_text_p2',
                     'revision_text_p1_pkey', 'revision_text_p2_pkey');
SQL
}

# =============================================================================
# STEP 4 — Bulk-copy the existing 6.35 TB into the partitioned parent
# (this is THE BIG ONE — ~18-22 h on lacie14 HDD; run inside tmux)
# =============================================================================
copy_data() {
  cat <<EOF
This step does:

  INSERT INTO revision_text_v2 SELECT * FROM revision_text;

Reads 6.35 TB from lacie14, writes 4.7 TB to lacie14 (p1) + 1.65 TB to
lacie10 (p2). Lacie14 is the bottleneck (it does both reads and writes).

Estimated wall time: 18-22 hours.

Run in a tmux session (e.g. \`tmux new -s pg-partition\`):

  PGSERVICE=wiki psql -d wiki20260401 -v ON_ERROR_STOP=1 <<SQL
  SET synchronous_commit = OFF;
  SET maintenance_work_mem = '4GB';
  \\timing on
  INSERT INTO revision_text_v2 SELECT * FROM revision_text;
  SQL

While it runs, monitor:
  df -h /media/simone/lacie14 /media/simone/lacie10
  PGSERVICE=wiki psql -c "SELECT count(*) FROM revision_text_v2;"
EOF
}

# =============================================================================
# STEP 5 — Swap names: drop old, rename new
# =============================================================================
swap() {
  echo "Sanity check first:"
  PGSERVICE=wiki psql -c "
    SELECT 'old' AS which, count(*) FROM revision_text
    UNION ALL
    SELECT 'new', count(*) FROM revision_text_v2;
  "
  read -p "Counts match? Proceed with drop + rename? [y/N] " yn
  [[ "$yn" == "y" ]] || { echo "aborted"; return 1; }
  PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
BEGIN;
DROP TABLE revision_text;
ALTER TABLE revision_text_v2 RENAME TO revision_text;
COMMIT;

\\echo Confirm the rename + tablespaces stuck
SELECT c.relname,
       t.spcname,
       pg_size_pretty(pg_total_relation_size(c.oid))
  FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
 WHERE c.relname IN ('revision_text', 'revision_text_p1', 'revision_text_p2',
                     'revision_text_p1_pkey', 'revision_text_p2_pkey');
SQL
}

# =============================================================================
# STEP 6 — Restart the loader (same args as before)
# =============================================================================
restart_loader() {
  if tmux has-session -t phase3-load 2>/dev/null; then
    tmux kill-session -t phase3-load
  fi
  tmux new-session -d -s phase3-load -c "$REPO" \
    'source .venv/bin/activate; exec zsh -i'
  sleep 2
  tmux send-keys -t phase3-load \
    'python load_pages_meta_history_xml.py --workers 2 --no-truncate --skip-revision-check --files $(cat /tmp/phase3_remaining_files.txt) 2>&1 | tee phase3_loader_active.log' \
    Enter
  sleep 5
  tmux capture-pane -t phase3-load -p | tail -10
  echo "==="
  ps -u simone -o pid,etime,cmd | awk '/load_pages_meta_history|7zz x -so/ {printf "%s etime=%s [args trimmed]\n", $1, $2}'
}

# Default: show menu
case "${1:-}" in
  preflight)            preflight ;;
  stop_loader)          stop_loader ;;
  print_sudo_commands)  print_sudo_commands ;;
  create_partitioned)   create_partitioned ;;
  copy_data)            copy_data ;;
  swap)                 swap ;;
  restart_loader)       restart_loader ;;
  *)
    cat <<EOF
phase3_partition_runbook.sh — span revision_text across lacie14 + lacie10

Usage: $0 <step>

Steps (in order):
  preflight             current state + capacity + expected p1/p2 row counts
  stop_loader           graceful stop of the running loader
  print_sudo_commands   prints the sudo for lacie10 tablespace setup (you run)
  create_partitioned    CREATE TABLE revision_text_v2 + p1 + p2 + move indexes
  copy_data             PRINTS the INSERT SELECT command (you run in tmux ~18-22h)
  swap                  DROP old + RENAME new (atomic, post-copy)
  restart_loader        relaunch loader with the same --no-truncate --skip-rev args

Each step is intentionally separated — read it, run it, verify, then next.

See phase3_partition_plan.md for the full plan and alternatives.
EOF
    ;;
esac
