#!/usr/bin/env bash
# Phase 3 hop 3 (step A) — relocate read-only Phase 1/2 tables off the
# 94%-full lacie14 onto the empty lacie10 reserve, to extend p1's runway
# WITHOUT pausing the running revision_text loader.
#
# Safe to run live: the Phase 3 loader runs with --skip-revision-check and
# writes only revision_text, so it never touches these tables. ALTER TABLE
# SET TABLESPACE takes a brief AccessExclusiveLock per table (no contention),
# moves heap+TOAST only (indexes stay on wiki_ts_sys / NVMe), copying data
# lacie14 -> lacie10.
#
# Does NOT move `actor` (shared/append-only, 15 GB, left in place) or
# revision_text_p1 (9 TB, doesn't fit lacie10 — separate decision).

set -euo pipefail
REPO=/home/simone/githubRepos/wikipediaData/official-dump
TS_NEW=wiki_ts_lacie10
LOG="$REPO/phase3_hop3_relocate_$(date -u +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
say(){ echo "[$(ts)] $*"; }

say "=== hop3 step A: relocate Phase1/2 tables to $TS_NEW ==="
say "lacie14/lacie10 BEFORE:"; df -h /media/simone/lacie14 /media/simone/lacie10

for tbl in revision change_tag logging page; do
  say "--- ALTER TABLE $tbl SET TABLESPACE $TS_NEW ---"
  T0=$(date +%s)
  PGSERVICE=wiki psql -v ON_ERROR_STOP=1 <<SQL
SET lock_timeout = '2min';
SET statement_timeout = 0;
\timing on
ALTER TABLE public.$tbl SET TABLESPACE $TS_NEW;
SQL
  T1=$(date +%s)
  say "$tbl moved in $((T1-T0))s"
done

say "=== verify placement (reltablespace) ==="
PGSERVICE=wiki psql -P pager=off -c "
  SELECT c.relname, coalesce(t.spcname,'(db default = lacie14)') AS tablespace,
         pg_size_pretty(pg_table_size(c.oid)) AS heap_toast
    FROM pg_class c LEFT JOIN pg_tablespace t ON t.oid=c.reltablespace
   WHERE c.relname IN ('revision','change_tag','logging','page','actor')
   ORDER BY 1;"

say "lacie14/lacie10 AFTER:"; df -h /media/simone/lacie14 /media/simone/lacie10
say "=== DONE === log: $LOG"
