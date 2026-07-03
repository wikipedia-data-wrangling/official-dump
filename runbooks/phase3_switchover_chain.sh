#!/usr/bin/env bash
# Phase 3 lacie14 switchover — autonomous chain (steps 6-10 of the runbook).
# Runs inside its own tmux session `phase3-switchover`.
#
#   6. rsync the 956 .7z files from ssd1 → lacie14, verify tree, delete source
#   7. patch DUMP_XML_DIR in the loader to point at the new path
#   8. ALTER DATABASE wiki20260401 SET TABLESPACE wiki_ts_lacie  (~18 h)
#   9. launch the loader in tmux `phase3-load` with --no-truncate
#  10. launch the sampler in tmux `phase3-sampler`
#
# Pre-conditions: steps 1-5 of phase3_lacie_switchover.sh already done
# (tablespace wiki_ts_lacie exists, ssd1 has snapshot-reclaimed headroom,
# stale sampler/loader sessions are dead).

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
LACIE_ROOT=/media/simone/lacie14
DUMP_DIR_OLD=/media/simone/ssd1/wikidumps
DUMP_DIR_NEW="$LACIE_ROOT/wikidumps"
TS_NAME=wiki_ts_lacie
CHAIN_LOG="$REPO/phase3_switchover_chain_$(date +%Y%m%d_%H%M%S).log"

# Mirror everything to a chain-level log file
exec > >(tee -a "$CHAIN_LOG") 2>&1

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }

cd "$REPO"

# ---------------------------------------------------------------------------
say "=== STEP 6: rsync dumps ssd1 -> lacie14 ==="
SRC_SIZE=$(du -sb "$DUMP_DIR_OLD" | awk '{print $1}')
say "source size: $(numfmt --to=iec "$SRC_SIZE")"
mkdir -p "$DUMP_DIR_NEW"
rsync -a --info=progress2 "$DUMP_DIR_OLD/" "$DUMP_DIR_NEW/"
say "rsync done — verifying tree integrity"
if diff -q \
     <(cd "$DUMP_DIR_OLD" && find . -type f | sort) \
     <(cd "$DUMP_DIR_NEW" && find . -type f | sort); then
  say "file lists match — deleting source"
  rm -rf "$DUMP_DIR_OLD"
else
  say "FILE TREE MISMATCH — source preserved; aborting"
  exit 1
fi
df -h /media/simone/ssd1 "$LACIE_ROOT"

# ---------------------------------------------------------------------------
say "=== STEP 7: patch DUMP_XML_DIR in load_pages_meta_history_xml.py ==="
sed -i.bak \
  "s|^DUMP_XML_DIR = Path(\"/media/simone/ssd1/wikidumps/20260401/xml\")|DUMP_XML_DIR = Path(\"$LACIE_ROOT/wikidumps/20260401/xml\")|" \
  load_pages_meta_history_xml.py
grep -n "^DUMP_XML_DIR" load_pages_meta_history_xml.py
# shellcheck disable=SC1091
source .venv/bin/activate
python -c "import load_pages_meta_history_xml as L
print('new DUMP_XML_DIR =', L.DUMP_XML_DIR)
print('files visible    =', len(L.discover_files()))"

# ---------------------------------------------------------------------------
say "=== STEP 8: ALTER DATABASE SET TABLESPACE (BIG; ~18 h) ==="
ACTIVE=$(PGSERVICE=wiki psql -d postgres -tAc \
  "SELECT count(*) FROM pg_stat_activity \
   WHERE datname='wiki20260401' AND pid <> pg_backend_pid();")
if [ "$ACTIVE" -gt 0 ]; then
  say "WARNING: $ACTIVE active connections to wiki20260401:"
  PGSERVICE=wiki psql -d postgres -c \
    "SELECT pid, usename, application_name, query_start \
       FROM pg_stat_activity WHERE datname='wiki20260401' \
        AND pid <> pg_backend_pid();"
  say "aborting; terminate those connections first"
  exit 1
fi

ALTER_T0=$(date +%s)
PGSERVICE=wiki psql -d postgres -v ON_ERROR_STOP=1 <<SQL
\\timing on
ALTER DATABASE wiki20260401 SET TABLESPACE $TS_NAME;
SELECT d.datname, t.spcname AS new_default_ts
  FROM pg_database d JOIN pg_tablespace t ON t.oid=d.dattablespace
 WHERE d.datname='wiki20260401';
SQL
ALTER_T1=$(date +%s)
say "ALTER DATABASE completed in $((ALTER_T1 - ALTER_T0)) s"
df -h /media/simone/ssd1 "$LACIE_ROOT"

# ---------------------------------------------------------------------------
say "=== STEP 9: restart loader in tmux phase3-load ==="
if tmux has-session -t phase3-load 2>/dev/null; then
  tmux kill-session -t phase3-load
fi
tmux new-session -d -s phase3-load -c "$REPO" \
  'source .venv/bin/activate; exec zsh -i'
sleep 2
# Stable active-log name so the sampler can target it.
tmux send-keys -t phase3-load \
  'python load_pages_meta_history_xml.py --workers 2 --no-truncate 2>&1 | tee phase3_loader_active.log' \
  Enter
sleep 5
say "phase3-load pane tail:"
tmux capture-pane -t phase3-load -p | tail -10

# ---------------------------------------------------------------------------
say "=== STEP 10: restart sampler in tmux phase3-sampler ==="
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
