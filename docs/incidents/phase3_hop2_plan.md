# Phase 3 hop 2 — partition revision_text across lacie10 + lacie14 once lacie10 nears full

## Context

After **hop 1** (`ALTER DATABASE wiki20260401 SET TABLESPACE wiki_ts_lacie10`,
estimated 16-22 h, planned for execution once lacie10 reaches ≥ 9 TB free):

| | |
|---|---|
| `wiki20260401` location | lacie10 (`wiki_ts_lacie10`, new DB default tablespace) |
| `revision_text` size at hop 1 | 8.56 TB |
| lacie10 free after hop 1 | **~0.45 TB** (very tight) |
| lacie14 free after hop 1 | **~10 TB** (empty after the migration vacates `wiki_ts_lacie`) |

Phase 3 will keep loading after hop 1; estimated remaining wikitext to write
is **2-8 TB** depending on the per-row size trajectory (the loader is in the
mid-page-id range now, so per-row sizes are still trending down). At the
observed ~20-30 GB/h burn rate, lacie10's 0.45 TB headroom will be consumed
in **~2-3 weeks** — and that's when hop 2 fires.

## When to fire hop 2

Trigger condition: `lacie10 free < ~600 GB` (about 4-5 days of runway at
the historical 24 GB/h burn). The hourly cron (`26f30339`) will pick this up
the same way it picked up the lacie14 trigger.

## Goal

Span `revision_text` across both Lacie drives via declarative range
partitioning on `rev_id`, with the lion's share of existing data moving
back to the (now-empty) lacie14 and a small partition staying on lacie10
to receive future high-`rev_id` writes.

## Capacity arithmetic — the key constraint

The partition migration is an `INSERT INTO revision_text_v2 SELECT * FROM
revision_text`. During the copy, **both** the source (lacie10) and the
destination heaps coexist. Once we `DROP` the source after the copy,
lacie10 frees up — but during the copy itself, lacie10 must have enough
room for whatever portion of the new partitioned table lives on it.

Let `S` = size of `revision_text` at hop 2 firing time. At burn rate ~24 GB/h
across the post-hop-1 window, S is likely **10-11 TB** when the trigger
hits.

Let `F10` = lacie10 free at hop 2 firing time (≥ 600 GB by trigger
definition).

Let `X` = the partition boundary `rev_id`. Choose X so the lacie10
partition fits inside `F10`:

```
size_on_lacie10 = S * (rev_ids_in_[X, MAX]) / total_rev_id_range
                ≤ F10 - safety_margin (e.g. 200 GB)
```

For S = 10.5 TB, F10 = 1 TB, safety = 200 GB:
- size_on_lacie10 target ≤ 800 GB
- 800 GB / 10500 GB = 7.6 % of data on lacie10
- That puts X around the **93rd percentile** of `rev_id` (~1.25 B in the
  current range)

Concretely: choose **X = 1,250,000,000** for that scenario. (Adjust based
on the actual S and F10 values when hop 2 fires.)

| partition | range | tablespace | size | drive headroom after copy |
|---|---|---|---|---|
| `revision_text_p1` | `[MINVALUE, X)` | `wiki_ts_lacie` (lacie14, freshly empty) | ~9.7 TB | 10 - 9.7 = 0.3 TB free on lacie14 |
| `revision_text_p2` | `[X, MAXVALUE)` | `wiki_ts_lacie10` (lacie10, where source still lives) | ~0.8 TB (only the new partition; the source still occupies 10.5 TB until DROP) | F10 - 0.8 ≈ 0.2 TB free during copy |
| **after `DROP revision_text` (source)** | — | — | — | lacie10 free jumps to ~9.7 TB |

After hop 2 settles: both drives have ~9.7 TB free (on lacie14) and ~9.7 TB
free (on lacie10) for future loader writes. **Comfortable for the rest of
Phase 3** even at the pessimistic 16 TB final size estimate.

## Migration steps (Plan B — full rewrite via partitioned `INSERT SELECT`)

This mirrors the original `phase3_partition_runbook.sh` but with the
tablespaces swapped (lacie10 now contains the source; lacie14 is the
big-partition destination).

### Step 0 — preflight

```bash
# Verify state
PGSERVICE=wiki psql -tAc "SELECT spcname FROM pg_database d JOIN pg_tablespace t ON t.oid=d.dattablespace WHERE d.datname='wiki20260401';"
#  expected: wiki_ts_lacie10  (i.e., hop 1 already done)

PGSERVICE=wiki psql -tAc "SELECT relkind FROM pg_class WHERE relname='revision_text';"
#  expected: r  (single table, not yet partitioned)

PGSERVICE=wiki psql -tAc "SELECT pg_size_pretty(pg_total_relation_size('revision_text'));"
#  note this for sizing X

PGSERVICE=wiki psql -tAc "SELECT MIN(rev_id), MAX(rev_id) FROM revision_text;"
#  fast — PK index is on wiki_ts_sys (NVMe)

df -h /media/simone/lacie10 /media/simone/lacie14
# confirm lacie14 has ~10 TB free, lacie10 has ≥ 600 GB free
```

### Step 1 — choose partition boundary X

Using the size from above and the available lacie10 free, pick X by:

```
X = MAX_rev_id * (1 - (F10 - safety) / S)
```

For S = 10.5 TB, F10 = 1 TB, safety = 200 GB, MAX_rev_id ≈ 1.35 B → X ≈ 1.25 B.

Round to a clean number (e.g. 1,250,000,000) and use it consistently below.

### Step 2 — stop the loader

```bash
pkill -INT -u simone -f "^python load_pages_meta_history_xml"
sleep 30
pkill -TERM -u simone -f "^python load_pages_meta_history_xml" || true
sleep 5
pkill -KILL -u simone -f "^python load_pages_meta_history_xml" || true
pkill -KILL -u simone -f "^7zz x -so" || true
```

### Step 3 — kill stale sampler

```bash
tmux kill-session -t phase3-sampler 2>/dev/null || true
pkill -u simone -f phase3_sampler.sh || true
```

### Step 4 — create partitioned parent

```sql
CREATE TABLE revision_text_v2 (
    rev_id         bigint NOT NULL,
    rev_text       bytea,
    rev_text_bytes bigint NOT NULL,
    PRIMARY KEY (rev_id)
) PARTITION BY RANGE (rev_id);

CREATE TABLE revision_text_p1
    PARTITION OF revision_text_v2
    FOR VALUES FROM (MINVALUE) TO (1250000000)   -- substitute the chosen X
    TABLESPACE wiki_ts_lacie;                     -- lacie14 (empty)

CREATE TABLE revision_text_p2
    PARTITION OF revision_text_v2
    FOR VALUES FROM (1250000000) TO (MAXVALUE)
    TABLESPACE wiki_ts_lacie10;                   -- lacie10 (source lives here too)

-- Move both partition PK indexes to NVMe (same pattern as hop 1)
ALTER INDEX revision_text_p1_pkey SET TABLESPACE wiki_ts_sys;
ALTER INDEX revision_text_p2_pkey SET TABLESPACE wiki_ts_sys;
```

### Step 5 — bulk copy (~16-20 h)

```sql
SET temp_tablespaces = 'wiki_ts_lacie10';
SET synchronous_commit = OFF;
SET maintenance_work_mem = '4GB';
SET work_mem = '512MB';
\timing on
INSERT INTO revision_text_v2 SELECT * FROM revision_text;
```

Bottleneck: reading 10.5 TB from lacie10 + writing 9.7 TB to lacie14 +
writing 0.8 TB to lacie10. Two-drive parallel I/O should help — different
drives, mostly different writers. Expect ~16-18 h on a happy path.

### Step 6 — verify counts (use reltuples; full count(*) is too slow)

```sql
SELECT 'old' AS which, reltuples::bigint FROM pg_class WHERE relname='revision_text'
UNION ALL
SELECT 'new', reltuples::bigint FROM pg_class WHERE relname='revision_text_v2'
UNION ALL
SELECT 'p1',  reltuples::bigint FROM pg_class WHERE relname='revision_text_p1'
UNION ALL
SELECT 'p2',  reltuples::bigint FROM pg_class WHERE relname='revision_text_p2';
```

Old and new should agree within ~2 % (autovacuum sampling drift). p1 + p2
should sum to new.

### Step 7 — atomic swap

```sql
BEGIN;
DROP TABLE revision_text;            -- frees ~10.5 TB on lacie10
ALTER TABLE revision_text_v2 RENAME TO revision_text;
COMMIT;
```

### Step 8 — regenerate `--files` list and restart loader

Same approach as the post-partition relaunch documented in
`phase3_partition_chain.sh`: extract `done: seen=` lines from the live log,
subtract from `/tmp/phase3_remaining_files.txt`, restart loader with
`--no-truncate --skip-revision-check --files <trimmed_list>`.

### Step 9 — restart sampler

```bash
tmux new-session -d -s phase3-sampler -c /home/simone/githubRepos/wikipediaData/official-dump \
  "./phase3_sampler.sh phase3_loader_active.log 300"
```

## Things that *don't* work as alternative hop-2 strategies

Documented here so we don't re-explore them under pressure:

- **Just `ALTER TABLE revision_text SET TABLESPACE wiki_ts_lacie`** (move
  whole table back to lacie14). Works mechanically (lacie14 has room) but
  defeats the purpose — Phase 3 then keeps writing to lacie14 alone and
  we're back to the original "single-drive fills" problem.
- **Partial migration "7 TB now, 2 TB later"** on the *same* drive. PG
  can't physically shrink a heap without scratch space equal to the table
  on the same drive (VACUUM FULL / pg_repack / CLUSTER all need this).
  DELETE alone marks rows dead but doesn't reclaim disk.
- **`ALTER DATABASE … SET TABLESPACE`** to flip the default tablespace. Moves
  *everything* in one shot but doesn't span — same single-drive failure
  mode shifted to a new drive.
- **Per-namespace dropping** to shrink revision_text. User declined this
  on 2026-06-05 and decision is locked.

## Hop 3 — is one likely?

After hop 2 settles, both Lacie drives have ~9-10 TB free (per the
arithmetic above). Combined headroom: ~19-20 TB. Pessimistic final size
estimate: 16 TB. Optimistic: 11 TB. **Hop 3 should not be needed for
Phase 3 completion** — even pessimistic case has ~4 TB margin after hop 2.

Hop 3 *would* be needed if:
- A per-row size regression we didn't see comes (unlikely, the trend is
  toward smaller rows as page-IDs grow)
- A drive failure forces redistribution

If hop 3 ever fires, the pattern is the same as hop 2 but with the
roles rotated and ssd1 (currently empty, 6.3 TB free) added as a third
target. Not pre-documented here; deal with it then.

## Open questions to resolve at hop 2 firing time

1. **Exact partition boundary X.** Depends on `revision_text` size and
   lacie10 free at that moment. Recompute from the formula above.
2. **Whether to also move other Phase 1+2 tables off lacie10.** They're
   ~480 GB total (`revision`, `change_tag`, `logging`, `actor`, `page`,
   ...) and they're effectively read-only during Phase 3. Leaving them on
   lacie10 is fine; moving them to lacie14 is optional cleanup that could
   reclaim a bit more headroom on lacie10 for future writes.
3. **Whether to bump `max_wal_size`** before the bulk copy (defaults at
   1 GB cause spiky autovacuum/checkpoint behaviour; bumping to 8 GB
   smooths it). Saw this issue on 2026-06-07. Cosmetic but worth doing if
   we're already pausing for the migration.

## Reference

- Hop 1 runbook (for comparison): `phase3_move_db_to_lacie10.sh` (will be
  written when hop 1 fires)
- Original partition plan (for comparison): `phase3_partition_plan.md`,
  `phase3_partition_runbook.sh`, `phase3_partition_chain.sh`
- Disk-relocation runbook (precedent for the cross-drive move pattern):
  `phase3_lacie_switchover.sh`
- Living state log: `phase3_eta_samples.csv`,
  `phase3_loader_active.log`
