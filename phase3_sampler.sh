#!/usr/bin/env bash
# Per-interval sampler for Phase 3 loader. Appends one CSV row per tick to
# phase3_eta_samples.csv with timestamp, revision_text count, table size,
# completed-file count (parsed from the active loader log), and active
# worker / 7zz process counts.
#
# Usage:
#   ./phase3_sampler.sh <loader_log_path> [interval_sec=300]

set -euo pipefail

LOG="${1:?usage: phase3_sampler.sh <loader_log_path> [interval_sec=300]}"
INTERVAL="${2:-300}"
CSV="/home/simone/githubRepos/wikipediaData/official-dump/phase3_eta_samples.csv"

if [[ ! -f "$CSV" ]]; then
  echo "ts_utc,rows,bytes,table_size_pretty,files_done,workers,sevenz_procs,loader_etime_sec" > "$CSV"
fi

while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # rows (approximate, from pg_class.reltuples — instant; updated by ANALYZE)
  # and bytes (pg_total_relation_size — fast metadata lookup, not a scan).
  # Wrapped in statement_timeout=30s so a stalled query never piles up and
  # blocks DDL on revision_text (lesson from 2026-06-05: count(*) on the
  # 6 TB lacie14-resident table took >>5 min, held AccessShareLock, and
  # blocked the loader's ALTER TABLE DROP CONSTRAINT).
  # psql emits "SET" on its own line before the SELECT result; take only the
  # last non-empty line to discard it.
  read -r ROWS BYTES PRETTY <<<"$(PGSERVICE=wiki psql -tAF$'\t' -c \
    "SET statement_timeout='30s'; \
     SELECT reltuples::bigint, \
            pg_total_relation_size('revision_text'), \
            pg_size_pretty(pg_total_relation_size('revision_text')) \
       FROM pg_class WHERE relname='revision_text';" 2>/dev/null \
    | grep -v '^SET$' | grep -v '^$' | tail -1 \
    || echo $'\t\t')"
  ROWS=${ROWS:-NA}
  BYTES=${BYTES:-NA}
  PRETTY=${PRETTY:-NA}

  # completed file count (grep -c / pgrep -c return 0 + rc=1 when no matches;
  # the || branch would double-print "0" with an embedded newline → keep the
  # number it emitted and just neutralize the rc with `|| true`)
  if [[ -f "$LOG" ]]; then
    FILES_DONE=$(grep -c "done: seen=" "$LOG" 2>/dev/null || true)
  else
    FILES_DONE=NA
  fi
  FILES_DONE=${FILES_DONE:-0}

  # worker + 7zz process counts
  WORKERS=$(pgrep -u simone -fc "load_pages_meta_history_xml.py" 2>/dev/null || true)
  WORKERS=${WORKERS:-0}
  SEVENZ=$(pgrep -u simone -fc "^7zz x -so" 2>/dev/null || true)
  SEVENZ=${SEVENZ:-0}

  # loader elapsed seconds (parent pid)
  PARENT_PID=$(pgrep -u simone -f "load_pages_meta_history_xml.py --workers" | head -1 || echo "")
  if [[ -n "$PARENT_PID" ]]; then
    ETIME_SEC=$(ps -p "$PARENT_PID" -o etimes= 2>/dev/null | tr -d ' ' || echo NA)
  else
    ETIME_SEC=NA
  fi

  echo "${TS},${ROWS},${BYTES},${PRETTY// /_},${FILES_DONE},${WORKERS},${SEVENZ},${ETIME_SEC}" >> "$CSV"

  sleep "$INTERVAL"
done
