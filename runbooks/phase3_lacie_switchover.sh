#!/usr/bin/env bash
# Phase 3 disk-relocation runbook: move the wiki20260401 DB and source dumps
# from /media/simone/ssd1 (full) to /media/simone/lacie14 (empty after the
# lacie14->lacie10 cleanup), then resume the loader with the staging-table
# patch + --no-truncate to preserve the 393 M rows already loaded.
#
# This script is NOT meant to be `bash` ran end-to-end. Each STEP is intended
# to be reviewed and copy-pasted (or, for the long ones, kicked off in a
# dedicated tmux pane). Steps with `# REQUIRES SUDO` need explicit auth.
#
# Pre-conditions (verify before starting):
#   * Phase 3 loader IS stopped (no `load_pages_meta_history_xml.py` procs)
#   * lacie14 is empty (or has >= ~8 TB free if you only want to move dumps + a
#     subset of the DB)
#   * Postgres 18 is running, port 5434, service=wiki resolves
#   * The staging-table patch is already applied to
#     load_pages_meta_history_xml.py (commit: copy_batch uses _rev_text_stage)
#
# Expected wall time end-to-end: ~18-22 hours (dominated by the database-
# wide tablespace move, single-threaded I/O against an external HDD).

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
LACIE_ROOT=/media/simone/lacie14
TS_DIR="$LACIE_ROOT/postgres-wiki"
DUMP_DIR_OLD=/media/simone/ssd1/wikidumps
DUMP_DIR_NEW="$LACIE_ROOT/wikidumps"
TABLESPACE_NAME=wiki_ts_lacie

# =============================================================================
# STEP 0 — Pre-flight verification (always safe to run)
# =============================================================================
preflight() {
  echo "== loader procs ==" ; ps -u simone -o pid,etime,cmd | grep -E "load_pages_meta|7zz x -so" | grep -v grep || echo "(none — good)"
  echo "== tmux sessions ==" ; tmux ls 2>&1 || true
  echo "== lacie14 free ==" ; df -h "$LACIE_ROOT"
  echo "== ssd1 free ==" ; df -h /media/simone/ssd1
  echo "== pg health ==" ; pg_isready -p 5434
  echo "== wiki20260401 size ==" ; PGSERVICE=wiki psql -tAc "SELECT pg_size_pretty(pg_database_size('wiki20260401'));"
  echo "== tablespaces ==" ; PGSERVICE=wiki psql -c "SELECT spcname, pg_tablespace_location(oid) FROM pg_tablespace;"
  echo "== revision_text rows ==" ; PGSERVICE=wiki psql -tAc "SELECT count(*) FROM revision_text;"
  echo "== applied staging-table patch? ==" ; grep -q "_rev_text_stage" "$REPO/load_pages_meta_history_xml.py" \
    && echo "yes — staging patch present" || echo "NO — patch missing, abort"
}

# =============================================================================
# STEP 1 — Reclaim cheap space on ssd1 (~90 GB)
# Drop the empty/aborted Phase 2 snapshot; the phase2-frozen git tag still
# records the schema/state, and the dump can be rebuilt from the live DB if
# needed.
# =============================================================================
reclaim_snapshot() {
  ls -la /media/simone/ssd1/wikidumps/20260401/snapshots/
  read -p "Confirm delete wiki20260401_phase2.dump (~90 GB)? [y/N] " yn
  [[ "$yn" == "y" ]] || { echo "aborted"; return 1; }
  rm -v /media/simone/ssd1/wikidumps/20260401/snapshots/wiki20260401_phase2.dump
  df -h /media/simone/ssd1
}

# =============================================================================
# STEP 2 — Stop the sampler before we do anything DB-side
# (sampler queries the DB every 5 min; we don't want it hitting the DB during
# the ALTER DATABASE move).
# =============================================================================
stop_sampler() {
  if tmux has-session -t phase3-sampler 2>/dev/null; then
    echo "stopping phase3-sampler tmux session"
    tmux kill-session -t phase3-sampler
  else
    echo "(phase3-sampler not running)"
  fi
  pgrep -fa phase3_sampler.sh || true
}

# =============================================================================
# STEP 3 — Create the tablespace target directory   # REQUIRES SUDO
# Postgres tablespaces must be owned by the postgres user and chmod 700.
# =============================================================================
mk_tablespace_dir() {
  cat <<EOF
Run as root (e.g. via sudo):

  sudo mkdir -p "$TS_DIR"
  sudo chown postgres:postgres "$TS_DIR"
  sudo chmod 700 "$TS_DIR"
  ls -ld "$TS_DIR"

EOF
}

# =============================================================================
# STEP 4 — Create the tablespace inside Postgres (no sudo)
# =============================================================================
mk_tablespace_pg() {
  PGSERVICE=wiki psql <<EOF
\\echo Creating tablespace $TABLESPACE_NAME at $TS_DIR
CREATE TABLESPACE $TABLESPACE_NAME LOCATION '$TS_DIR';
\\echo Tablespaces now:
SELECT spcname, pg_tablespace_location(oid) FROM pg_tablespace;
EOF
}

# =============================================================================
# STEP 5 — Move the 7z source dumps off ssd1 (~390 GB)
# `mv` is atomic within a filesystem but cross-FS — so it's actually a copy +
# delete. Run inside tmux; figure ~1-2 hours on an external HDD.
# =============================================================================
move_dumps() {
  echo "size of dumps to move:"; du -sh "$DUMP_DIR_OLD"
  read -p "Confirm move dumps to $DUMP_DIR_NEW? [y/N] " yn
  [[ "$yn" == "y" ]] || { echo "aborted"; return 1; }
  # rsync first so an interruption can resume cheaply, then delete the
  # source after a checksum-free dirsize comparison.
  rsync -a --info=progress2 "$DUMP_DIR_OLD/" "$DUMP_DIR_NEW/"
  diff -q <(cd "$DUMP_DIR_OLD" && find . | sort) \
          <(cd "$DUMP_DIR_NEW" && find . | sort) \
    && rm -rf "$DUMP_DIR_OLD" \
    || { echo "FILE TREE MISMATCH — NOT deleting source"; return 1; }
  df -h /media/simone/ssd1 "$LACIE_ROOT"
}

# =============================================================================
# STEP 6 — Update DUMP_XML_DIR in the loader (sed-edit, then verify)
# =============================================================================
patch_dump_path() {
  sed -i.bak \
    "s|^DUMP_XML_DIR = Path(\"/media/simone/ssd1/wikidumps/20260401/xml\")|DUMP_XML_DIR = Path(\"$LACIE_ROOT/wikidumps/20260401/xml\")|" \
    "$REPO/load_pages_meta_history_xml.py"
  grep -n "^DUMP_XML_DIR" "$REPO/load_pages_meta_history_xml.py"
  cd "$REPO" && source .venv/bin/activate \
    && python -c "import load_pages_meta_history_xml as L; print('new DUMP_XML_DIR =', L.DUMP_XML_DIR); print('files visible:', len(L.discover_files()))"
}

# =============================================================================
# STEP 7 — Move the database to the new tablespace.   THE BIG STEP.
#
# `ALTER DATABASE wiki20260401 SET TABLESPACE wiki_ts_lacie` rewrites EVERY
# relation currently on the old default tablespace (wiki_ts on the full
# /dev/sdc) into the new one (wiki_ts_lacie on /dev/sde1). All ~6.5 TB,
# single-threaded I/O.
#
# It takes an exclusive lock on the database for the duration — no other
# connections allowed. Run from `psql -d postgres` (NOT the wiki DB), with
# every other session disconnected.
#
# Expected wall time: ~16-20 hours at ~100 MB/s external HDD throughput.
# Run inside tmux. Do NOT interrupt — partial rewrites are recoverable but
# messy.
# =============================================================================
move_database() {
  cat <<EOF
Before running this:
  * Confirm NO sessions are connected to wiki20260401:
      psql service=wiki -c "SELECT pid, usename, application_name, query_start FROM pg_stat_activity WHERE datname='wiki20260401';"
  * If any rows other than your own, terminate / wait.

Then, IN A FRESH TMUX SESSION (e.g. tmux new -s pg-move), run:

  PGSERVICE=wiki psql -d postgres <<'SQL'
  -- Lock check
  SELECT pid, usename, application_name FROM pg_stat_activity WHERE datname='wiki20260401' AND pid <> pg_backend_pid();
  -- Move
  ALTER DATABASE wiki20260401 SET TABLESPACE $TABLESPACE_NAME;
  -- Verify default tablespace
  SELECT d.datname, t.spcname FROM pg_database d JOIN pg_tablespace t ON t.oid=d.dattablespace WHERE d.datname='wiki20260401';
  SQL

After it finishes, ssd1 should have ~6.5 TB free.
EOF
}

# =============================================================================
# STEP 8 — Restart the loader with --no-truncate
# =============================================================================
restart_loader() {
  tmux new-session -d -s phase3-load -c "$REPO" 'source .venv/bin/activate; exec zsh -i'
  sleep 2
  tmux send-keys -t phase3-load \
    'python load_pages_meta_history_xml.py --workers 2 --no-truncate 2>&1 | tee phase3_loader_resume_$(date +%Y%m%d_%H%M%S).log' \
    Enter
  sleep 5
  tmux capture-pane -t phase3-load -p | tail -15
  ps -u simone -o pid,etime,pcpu,cmd | grep -E "load_pages_meta|7zz x -so" | grep -v grep || echo "(no loader procs yet)"
}

# =============================================================================
# STEP 9 — Restart the sampler
# =============================================================================
restart_sampler() {
  tmux new-session -d -s phase3-sampler -c "$REPO" "./phase3_sampler.sh phase3_loader_active.log 300"
  sleep 2
  tmux ls
}

# Default: print menu.
case "${1:-}" in
  preflight)         preflight ;;
  reclaim_snapshot)  reclaim_snapshot ;;
  stop_sampler)      stop_sampler ;;
  mk_tablespace_dir) mk_tablespace_dir ;;
  mk_tablespace_pg)  mk_tablespace_pg ;;
  move_dumps)        move_dumps ;;
  patch_dump_path)   patch_dump_path ;;
  move_database)     move_database ;;
  restart_loader)    restart_loader ;;
  restart_sampler)   restart_sampler ;;
  *)
    cat <<EOF
phase3_lacie_switchover.sh — Phase 3 disk relocation runbook

Usage: $0 <step>

Steps (in order):
  preflight          show current state; verify pre-conditions
  reclaim_snapshot   delete 90 GB phase2 snapshot to free ssd1
  stop_sampler       stop the 5-min sampler (prevents stale DB queries)
  mk_tablespace_dir  PRINT the sudo commands to create the target dir
  mk_tablespace_pg   CREATE TABLESPACE inside the running PG
  move_dumps         rsync the 956 .7z files lacie14 + delete the source
  patch_dump_path    update DUMP_XML_DIR in the loader (sed; .bak backup)
  move_database      PRINT the ALTER DATABASE command (you run in tmux)
  restart_loader     launch loader with --no-truncate in tmux phase3-load
  restart_sampler    re-launch sampler in tmux phase3-sampler

Each step is intentionally a separate command — read it, run it, verify,
then move on.
EOF
    ;;
esac
