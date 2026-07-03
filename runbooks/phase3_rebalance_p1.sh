#!/usr/bin/env bash
# Phase 3 rebalance — spread revision_text_p1 (~9 TB, currently all on lacie14)
# across lacie10 (bulk) + ssd1 (tail), freeing lacie14. Achieves a balanced
# 3-drive final layout and stops lacie14 from ever filling.
#
# WHY NOT in-place / SET TABLESPACE: p1 (9.1 TB) doesn't fit on any single
# remaining drive (lacie10 has 8.4 TB free, ssd1 3.3 TB), so it must be SPLIT
# across two — which requires a rewrite. We do it as detach + range-routed
# copy + verify + drop, keeping the original partition intact until the new
# ones are verified row-for-row (the source .7z dumps are the ultimate backup).
#
# RUN WHEN: the loader is stopped — ideally after Phase 3 completes (system
# idle = fast), or if lacie14 is about to fill mid-load (this script stops the
# loader, rebalances, then you resume the loader on remaining files).
#
# SAFETY: abort-safe. The old partition is only DROPped after the new
# partitions' combined row count matches it exactly. A mis-chosen boundary or
# a full target drive aborts the copy with the original data untouched.

set -euo pipefail
REPO=/home/simone/githubRepos/wikipediaData/official-dump
cd "$REPO"

# --- tunables -----------------------------------------------------------------
# FINAL layout: p1 lands on lacie10 (lo) + lacie14 (hi); ssd1 stays dedicated
# to p2 (which still has ~700 GB of growth from the final history segment).
# Mechanics are two-pass because lacie14 has no free space until old p1 is
# dropped: PASS 1 copies p1 -> lacie10 (lo) + ssd1 (hi, TRANSIENT), drops old
# p1 (frees lacie14); PASS 2 moves the hi partition ssd1 -> lacie14.
#
# B = boundary rev_id. Default 800M puts ~top-14%-of-rows (~1.9 TB, byte-
# back-loaded) into hi. The copy is descending (hi/ssd1 written first) so a
# too-low B trips the ssd1 reserve and aborts BEFORE touching lacie10 — old
# data intact; re-run with a higher B.
B=${B:-800000000}
TS_LO=wiki_ts_lacie10          # lacie10  -> revision_text_p1_lo  [min, B)
TS_HI=wiki_ts                  # ssd1     -> revision_text_p1_hi  [B, 1e9)  (TRANSIENT)
TS_HI_FINAL=wiki_ts_lacie      # lacie14  -> revision_text_p1_hi  final home (pass 2)
# Stop the copy if a target drive falls below this many GiB free.
LACIE10_RESERVE_GIB=${LACIE10_RESERVE_GIB:-500}
SSD1_RESERVE_GIB=${SSD1_RESERVE_GIB:-500}
CHUNK=${CHUNK:-10000000}       # rev_id window per committed copy batch
LOG="$REPO/phase3_rebalance_$(date -u +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
say(){ echo "[$(ts)] $*"; }
die(){ echo "[$(ts)] FATAL: $*" >&2; exit 1; }
psql_(){ PGSERVICE=wiki psql -v ON_ERROR_STOP=1 -tAc "$1"; }
free_gib(){ echo $(( $(df -B1 --output=avail "$1" | tail -1) / 1073741824 )); }

# --- STEP 0: preflight ---------------------------------------------------------
say "=== STEP 0: preflight (B=$B  lo->$TS_LO  hi->$TS_HI) ==="
if pgrep -u simone -f "load_pages_meta_history_xml" >/dev/null; then
  say "loader is RUNNING — stopping it (tmux phase3-load + procs) before restructure"
  tmux kill-session -t phase3-load 2>/dev/null || true
  pkill -u simone -f "load_pages_meta_history_xml" || true
  sleep 5
  pgrep -u simone -f "load_pages_meta_history_xml" >/dev/null && die "loader still alive"
fi
say "loader: not running (good)"
# revision_text must be partitioned and p1 a leaf partition
[ "$(psql_ "SELECT relkind FROM pg_class WHERE relname='revision_text'")" = "p" ] \
  || die "revision_text is not partitioned"
[ "$(psql_ "SELECT count(*) FROM pg_class WHERE relname='revision_text_p1'")" = "1" ] \
  || die "revision_text_p1 not found"
# target tablespaces must exist + be writable
for t in "$TS_LO" "$TS_HI"; do
  [ "$(psql_ "SELECT has_tablespace_privilege('simone','$t','CREATE')")" = "t" ] \
    || die "simone lacks CREATE on $t"
done
OLDROWS=$(psql_ "SET statement_timeout=0; SELECT count(*) FROM revision_text_p1")
say "revision_text_p1 row count (authoritative): $OLDROWS"
say "free now: lacie10=$(free_gib /media/simone/lacie10)GiB ssd1=$(free_gib /media/simone/ssd1)GiB lacie14=$(free_gib /media/simone/lacie14)GiB"

# --- STEP 1: detach old p1, create the two new partitions ----------------------
say "=== STEP 1: detach old p1 + create lo/hi partitions ==="
psql_ "SET statement_timeout=0;
  ALTER TABLE revision_text DETACH PARTITION revision_text_p1;
  ALTER TABLE revision_text_p1 RENAME TO revision_text_p1_old;
  CREATE TABLE revision_text_p1_lo PARTITION OF revision_text
    FOR VALUES FROM (MINVALUE) TO ($B) TABLESPACE $TS_LO;
  CREATE TABLE revision_text_p1_hi PARTITION OF revision_text
    FOR VALUES FROM ($B) TO (1000000000) TABLESPACE $TS_HI;"
say "detached old p1 -> revision_text_p1_old (still on lacie14, untouched); new lo/hi created empty"

# --- STEP 2: copy, HI first (validate the tight drive early), then LO ----------
# Descending rev_id sweep: high rev_ids (-> p1_hi/ssd1) are copied first.
say "=== STEP 2: range-routed copy (descending; ssd1 validated first) ==="
hi=1000000000
while [ "$hi" -gt 0 ]; do
  lo=$(( hi - CHUNK )); [ "$lo" -lt 0 ] && lo=0
  l10=$(free_gib /media/simone/lacie10); sd1=$(free_gib /media/simone/ssd1)
  if [ "$sd1" -lt "$SSD1_RESERVE_GIB" ]; then
    die "ssd1 free ${sd1}GiB < reserve ${SSD1_RESERVE_GIB}GiB at rev_id window [$lo,$hi). Old data intact. Re-run with higher B (more to lacie10)."
  fi
  if [ "$l10" -lt "$LACIE10_RESERVE_GIB" ]; then
    die "lacie10 free ${l10}GiB < reserve ${LACIE10_RESERVE_GIB}GiB at [$lo,$hi). Old data intact. Re-run with lower B (more to ssd1)."
  fi
  psql_ "SET statement_timeout=0; SET synchronous_commit=off;
    INSERT INTO revision_text (rev_id, rev_text, rev_text_bytes)
    SELECT rev_id, rev_text, rev_text_bytes FROM revision_text_p1_old
     WHERE rev_id >= $lo AND rev_id < $hi;" >/dev/null
  say "copied [$lo,$hi)  | free: lacie10=${l10}GiB ssd1=${sd1}GiB"
  hi=$lo
done

# --- STEP 3: verify row counts before destroying anything ----------------------
say "=== STEP 3: verify ==="
NEWROWS=$(psql_ "SET statement_timeout=0;
  SELECT (SELECT count(*) FROM revision_text_p1_lo)
        +(SELECT count(*) FROM revision_text_p1_hi)")
say "old=$OLDROWS  new(lo+hi)=$NEWROWS"
[ "$NEWROWS" = "$OLDROWS" ] || die "row count mismatch — NOT dropping old. Investigate."

# --- STEP 4: drop the old partition (frees ~9 TB on lacie14) -------------------
say "=== STEP 4: drop old partition (frees lacie14) ==="
psql_ "SET statement_timeout=0; DROP TABLE revision_text_p1_old;"
say "old p1 dropped; lacie14 free now: $(free_gib /media/simone/lacie14)GiB"

# --- STEP 4b (PASS 2): relocate hi partition ssd1 -> lacie14 -------------------
# lacie14 is now empty; move p1_hi off ssd1 so ssd1 stays free for p2 growth.
say "=== STEP 4b: PASS 2 move revision_text_p1_hi -> $TS_HI_FINAL (lacie14) ==="
l14=$(free_gib /media/simone/lacie14)
hisz=$(psql_ "SELECT (pg_table_size('revision_text_p1_hi')/1073741824)::bigint")
say "p1_hi is ${hisz}GiB; lacie14 free ${l14}GiB"
[ "$l14" -gt $(( hisz + 300 )) ] || die "lacie14 free ${l14}GiB too small for p1_hi ${hisz}GiB — leaving p1_hi on ssd1"
psql_ "SET statement_timeout=0; ALTER TABLE revision_text_p1_hi SET TABLESPACE $TS_HI_FINAL;"
psql_ "ANALYZE revision_text_p1_lo; ANALYZE revision_text_p1_hi;" || true

# --- STEP 5: report ------------------------------------------------------------
say "=== DONE ==="
PGSERVICE=wiki psql -P pager=off -c "
  SELECT c.relname, t.spcname AS tablespace,
         pg_size_pretty(pg_total_relation_size(c.oid)) AS size
    FROM pg_class c JOIN pg_tablespace t ON t.oid=c.reltablespace
   WHERE c.relname IN ('revision_text_p1_lo','revision_text_p1_hi','revision_text_p2')
   ORDER BY 1;"
df -h /media/simone/lacie14 /media/simone/lacie10 /media/simone/ssd1
say "If this ran mid-load: resume the loader on its remaining --files, then"
say "re-create the FK revision_text.rev_id->revision (the loader does this at clean end-of-run)."
say "log: $LOG"
