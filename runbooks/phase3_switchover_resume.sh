#!/usr/bin/env bash
# Continuation of phase3_switchover_chain.sh from step 7 onward.
# Step 6 (rsync) completed successfully — data is on lacie14, just the
# empty source dir couldn't be removed due to /media/simone/ssd1/ being
# owned by root. That's cosmetic; we proceed.

set -euo pipefail

REPO=/home/simone/githubRepos/wikipediaData/official-dump
LACIE_ROOT=/media/simone/lacie14
TS_NAME=wiki_ts_lacie
CHAIN_LOG="$REPO/phase3_switchover_resume_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$CHAIN_LOG") 2>&1
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }

cd "$REPO"

# ---------------------------------------------------------------------------
say "=== STEP 7: patch DUMP_XML_DIR ==="
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
say "=== STEP 8: ALTER DATABASE SET TABLESPACE (BIG; ~8-10 h) ==="
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
say "resume log: $CHAIN_LOG"
