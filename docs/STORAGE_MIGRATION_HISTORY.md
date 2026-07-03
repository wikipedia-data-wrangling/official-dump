# Storage migration history — every move the `wiki20260401` data has done

The companion to [STORAGE_LAYOUT.md](STORAGE_LAYOUT.md) (current state)
and [DATA_LOCATION_GUIDE.md](DATA_LOCATION_GUIDE.md) (conceptual
where-is-what). This file is the **historical record of how the data
got to its current location** — why drives filled, why they emptied,
what we tried at each turn, and what we learned.

Read this if you need to:
- Understand why `lacie10` is empty today even though it briefly held
  the entire `revision_text`
- Plan the next hop and not repeat a past failure mode
- Reason about backup choices (knowing which drives have held what
  data over the past two months)
- Explain to a collaborator why `ssd1` hosts a small partition rather
  than the whole table

---

## 1. Big picture — the data has lived on three different drives in 50 days

| period | primary `revision_text` location | reason |
|---|---|---|
| 2026-05-09 → 2026-06-03 | **ssd1** (the original tablespace `wiki_ts`) | initial setup; PG18 cluster created with `wiki_ts` as DB default |
| 2026-06-04 → 2026-06-09 | **lacie14** (`wiki_ts_lacie`) | hop 0: ssd1 filled at 6.5 TB; moved whole DB via `ALTER DATABASE … SET TABLESPACE` |
| 2026-06-12 → 2026-06-14 | **lacie10** (`wiki_ts_lacie10`) | hop 1: lacie14 filled at 11 TB; moved table via `ALTER TABLE … SET TABLESPACE` |
| 2026-06-16 → 2026-06-24 | **lacie10** (still — chain stuck) + lacie14 + ssd1 (loaded partitioned copy waiting in limbo) | hop 2 INSERT SELECT completed but the chain aborted at the verify step due to a `reltuples=-1` bug |
| **2026-06-24 → present** | **lacie14 + ssd1** (partitioned: p1 + p2) | hop 2 recovery: deferred `DROP TABLE` + `RENAME` finally swapped the partitioned copy into place |

`lacie10` is currently empty because the last act of the hop 2 recovery
(2026-06-24 18:58 BST) was to drop the source `revision_text` heap that
had been sitting on it as the read-only source of the partition copy.

---

## 2. Original layout (2026-05-09 → 2026-06-03)

### What was on disk

```
ssd1 (/dev/sdc, mounted /media/simone/ssd1)
└── postgres-wiki/    ← wiki_ts tablespace
    ├── (Phase 1+2 tables: revision, page, actor, logging, ...)
    └── revision_text     ← Phase 3 wikitext, grew from 0 → 6.05 TB
```

All Wikipedia data lived on **one drive**: the internal SATA SSD at
`/media/simone/ssd1`. The `wiki20260401` database was created with
`wiki_ts` as its default tablespace (`/media/simone/ssd1/postgres-wiki`).
This was the layout described in the initial CLAUDE.md.

### What changed

Phase 1a + 1b + 2 loaded cleanly over the first two weeks. Phase 3
started 2026-05-26 against `revision_text` on `wiki_ts`.

### What went wrong

On 2026-06-03 at ~19:27 BST, the Phase 3 loader crashed with a
`UniqueViolation` on `rev_id = 711706` ("Gasoline", first edit
2001-09-24). Investigation revealed the WMF
`pages-meta-history*.7z` files **are not strictly disjoint by `rev_id`**
— some revisions appear in multiple sub-files. The loader's naive
`COPY ... FROM STDIN` hit the PK constraint the moment any later
worker's batch contained an already-inserted rev_id.

Investigating the disk state revealed a *second*, more serious problem:
`ssd1` was at 6.4 TB used out of 7.3 TB capacity — the wikitext had
grown faster than initially budgeted (the loader's per-row size was
higher than the data_collection_plan assumed because of how WMF dumps
TOAST), and ssd1 was projected to fill within days.

---

## 3. Hop 0 — ssd1 → lacie14 (2026-06-04 → 2026-06-05)

### Decision

Move the entire database off ssd1 onto the much larger external HDD
`lacie14` (11 TB) before Phase 3 hits ENOSPC. Add a new tablespace
`wiki_ts_lacie` at `/media/simone/lacie14/postgres-wiki` and switch the
database's default tablespace to it.

### Approach

`ALTER DATABASE wiki20260401 SET TABLESPACE wiki_ts_lacie`.

This is a single-statement, transactional operation. PG rewrites every
relation on the old default tablespace into the new one. No partial
state — either everything is on the new tablespace or nothing is.

### What we did along the way

While the `ALTER DATABASE` ran (~10 h), we also:
1. Patched the Phase 3 loader (`copy_batch`) to use a per-session TEMP
   staging table with `INSERT … SELECT DISTINCT ON (rev_id) … ON
   CONFLICT (rev_id) DO NOTHING`. This made the loader idempotent under
   re-runs and immune to the dump-overlap bug.
2. Created `wiki_ts_sys` at `/var/lib/postgres-wiki-idx` on the NVMe
   root drive, and moved `revision_text_pkey` (11 GB at the time) and
   `revision_pkey` (34 GB) there. Random PK lookups jumped from ~5–15 ms
   (lacie14 HDD) to <100 µs (NVMe), a >50× speedup.
3. Patched the loader to skip the per-batch existence check
   (`--skip-revision-check`) — the staging-table guard made it
   redundant.

### Result

- ssd1 freed from 6.4 TB used → ~50 GB used (just non-Phase-3 stuff)
- lacie14 populated with the full ~6.5 TB DB
- Phase 3 loader restarted with new defenses; sustained throughput
  jumped from ~80 rev/s/worker to ~700–1,000 rev/s/worker

### What we didn't anticipate

Lacie14's external HDD random-write speed for TOAST'd bytea was
slower than ssd1's. The loader's burn rate against lacie14
was higher in bytes/h than against ssd1 — the wikitext kept arriving
at ~24–28 GB/h. Even at 11 TB capacity, lacie14 would fill in ~5 days.

The plan hadn't accounted for this. The drive filled on 2026-06-09 at
21:05 BST.

---

## 4. Hop 1 — lacie14 → lacie10 (2026-06-12 → 2026-06-13)

### Decision

By 2026-06-12 the user had cleared `lacie10` (a separate external 9.1 TB
HDD) to 8.56 TiB free, comfortably more than the 8.35 TiB needed.
Migrate `revision_text` (and only `revision_text` — the Phase 1+2 small
tables were ~480 GB and could stay on lacie14) to lacie10.

### Approach

`ALTER TABLE revision_text SET TABLESPACE wiki_ts_lacie10`.

This is the same shape as hop 0 but scoped to a single relation
(plus its TOAST companion). The PK index already lived on `wiki_ts_sys`
(NVMe) so it didn't need to move.

### What we did along the way

1. Created `wiki_ts_lacie10` at `/media/simone/lacie10/postgres-wiki`
   (sudo dance for the dir + tablespace + GRANT).
2. Patched the loader to `SET temp_tablespaces = 'wiki_ts_sys'` so the
   TEMP `_rev_text_stage` table didn't try to land on the still-full
   `wiki_ts_lacie` after the heap moved off.

### Result

- lacie14 freed: 11 TB used → 2.0 TB used (kept Phase 1+2 tables +
  source dumps)
- lacie10 populated with the 8.35 TiB `revision_text` heap
- Phase 3 loader resumed on 2026-06-13 14:31 BST, picked up where it
  had left off (file index 350 in the natural-ordered cut list)

### What went wrong

Lacie10 had ~228 GiB of free space after the move. At ~30 GB/h burn
rate, that gave roughly 7-8 hours of runway. The user wasn't told this
was a hop intended to "buy time", not "solve capacity" — and **after
~22 h of loading**, lacie10 hit ENOSPC again at 2026-06-14 ~12:07 BST.
The loader died with a `psycopg.errors.DiskFull`.

The mistake was firing hop 1 without simultaneously planning hop 2:
hop 1 was a 17-hour wall-time operation that gained only ~22 hours of
loading runway. Net was almost zero.

---

## 5. Hop 2 — lacie10 → lacie14 + ssd1 partitioned (2026-06-14 → 2026-06-16
attempt; 2026-06-24 recovery)

### Decision

Stop trying to fit `revision_text` on a single drive. Convert it to a
range-partitioned table split at `rev_id = 1B`, putting partition `p1`
([MIN, 1B)) on lacie14 and partition `p2` ([1B, MAX)) on ssd1 (which had
~5.3 TB free of the original 7.3 TB). The lacie10 copy would be
*dropped* at the end, recovering the 8.6 TB.

The split point `rev_id = 1B` was chosen because the existing data
was approximately 74/26 between the two ranges at the time, putting
~6.5 TB on lacie14 (well within its 9.5 TB free post-cleanup) and
~2.3 TB on ssd1 (well within its 5.3 TB free).

### Approach

Plan B from `phase3_partition_plan.md` — full rewrite via `INSERT
SELECT` into a new partitioned table, then atomic swap:

```sql
-- 1. Create new partitioned parent + partitions
CREATE TABLE revision_text_v2 (...) PARTITION BY RANGE (rev_id);
CREATE TABLE revision_text_p1 PARTITION OF revision_text_v2
    FOR VALUES FROM (MINVALUE) TO (1000000000)
    TABLESPACE wiki_ts_lacie;
CREATE TABLE revision_text_p2 PARTITION OF revision_text_v2
    FOR VALUES FROM (1000000000) TO (MAXVALUE)
    TABLESPACE wiki_ts;       -- ssd1's existing tablespace
ALTER INDEX revision_text_p1_pkey SET TABLESPACE wiki_ts_sys;
ALTER INDEX revision_text_p2_pkey SET TABLESPACE wiki_ts_sys;

-- 2. Bulk copy
INSERT INTO revision_text_v2 SELECT * FROM revision_text;  -- 58 h

-- 3. Atomic swap
BEGIN;
DROP TABLE revision_text;    -- frees lacie10
ALTER TABLE revision_text_v2 RENAME TO revision_text;
COMMIT;
```

### What we did along the way

Before firing the chain we also:
1. **Dropped ~1.14 TB of leftover cruft on lacie14** (`revision_text_v2`,
   `revision_text_p1`, `revision_text_p2` from an earlier failed hop-2
   attempt that had created the partition shells but never been
   cleaned up).
2. Verified `simone` already had `CREATE` on `wiki_ts` (no extra sudo).

### What went wrong (first time)

The chain script's STEP 3 verify check used `pg_class.reltuples` to
compare old vs new row counts. Newly-created partitioned tables have
`reltuples = -1` until `ANALYZE` runs — autovacuum hadn't touched the
new tree yet. The chain saw `new reltuples: -1` vs `old reltuples:
659,527,936`, computed "100% divergence", and aborted with `set -e`
before the swap.

The `INSERT 0 670,640,642` had completed cleanly (per the PG output in
the chain log) — the data was on disk. But the chain script *killed
itself* before doing the `DROP + RENAME`.

**8 days passed before anyone noticed.** The loader was stopped (waiting
for the chain to restart it). The chain process was dead. The
partitioned copy sat fully loaded but un-renamed; the source sat on
lacie10 still claiming to be `revision_text`.

### Hop 2 recovery (2026-06-24)

Wrote `phase3_hop2_recovery.sh`:
- Treats the chain log's `INSERT 0 670,640,642` line as proof of
  completion (the row count is authoritative; reltuples is sampled).
- Runs the deferred swap (`DROP TABLE revision_text` + `RENAME
  revision_text_v2 → revision_text`).
- Regenerates the `--files` list (adding the new "since the last
  archive" run to the completed-files set).
- Restarts the loader with the trimmed list (using the `$(cat ...)` trick
  to avoid the tmux send-keys length cap that bit us in hop 1).
- Restarts the sampler.

The `DROP TABLE revision_text` took 68 seconds — that's PG unlinking
~8.6 TB worth of TOAST + heap files from `/media/simone/lacie10/postgres-wiki/`.
The unlink work counts as "uncommitted" until the `COMMIT` line of the
swap returns; that's why the chain log shows "Time: 68396.958 ms" for
COMMIT alone.

### Result

- **lacie10 freed: 8.6 TB used → ~420 KB used** (just ext4 metadata +
  PG tablespace marker)
- revision_text (partitioned) now lives on lacie14 (`p1`, 6,776 GB) +
  ssd1 (`p2`, 2,038 GB)
- Loader restarted, processing the remaining 412 files at ~2 files/h
- lacie10 is now empty reserve — ready to accept a hop 3 if either p1
  or p2 fills before the loader finishes

---

## 6. Why lacie10 is empty *right now*

Direct answer to the question that triggered this file:

**The 8.6 TB that lacie10 held was the *source* of the hop 2 partition
copy.** During hop 2's 58-hour `INSERT SELECT`, every row was read from
the lacie10 heap and written into the new partitions on lacie14 + ssd1.
Lacie10 itself didn't receive any new writes — it was strictly the
read-only source.

Once the copy finished and the partitioned copy was verified complete,
the original `revision_text` on lacie10 became **redundant** — every
row in it was now also on lacie14 or ssd1. The final step of any
copy-based migration is to delete the source so the storage can be
reclaimed.

The hop 2 recovery script's `DROP TABLE revision_text` was that
deletion. It told PG to unlink every heap and TOAST file backing the
old `revision_text` — about 8.6 TB worth of files on lacie10. The
`COMMIT` then made the deletion durable: ~68 seconds of file unlink I/O
on the HDD.

After that COMMIT, lacie10's `postgres-wiki/` directory had nothing
but its tablespace marker file (~420 KB of metadata). That's the
state today — the drive is **available, mounted, with a registered PG
tablespace (`wiki_ts_lacie10`), but containing no relations**.

---

## 7. The migration pattern, distilled

Looking across all three hops, the same operational pattern recurs:

```
   ┌─────────────┐                ┌─────────────┐
   │  SOURCE     │  read-only     │ DESTINATION │
   │  (full)     │ ───────────────▶  (empty)    │
   │             │  during copy   │             │
   └─────────────┘                └─────────────┘
           │                              │
           │ "DROP source"                │
           │ when verified                │
           ▼                              ▼
   ┌─────────────┐                ┌─────────────┐
   │   (empty)   │                │  populated  │
   │  reserved   │                │             │
   └─────────────┘                └─────────────┘
```

Each migration takes one drive from "full" to "empty" and another from
"empty" to "full". The drive that just emptied becomes the next hop's
destination candidate. This is *why* the pattern is iterable.

The catch (which bit us at hop 1 and hop 2's verify): the wall time
to do the migration is comparable to the wall time the destination
drive's free space buys. So unless the destination has **substantially
more** free space than the projected burn rate × migration wall time,
the loader will fill the new drive before it's worth the migration
cost.

Quick capacity-vs-runtime calculator:

```
runway_hours_after_migration = (destination_free - source_size) / burn_rate
total_useful_hours = runway_hours_after_migration
total_cost_hours   = migration_wall_time

# Worth doing only if:
total_useful_hours >> total_cost_hours
```

Hop 1 violated this (228 GiB free / 30 GB/h = 7.6 h useful for 17 h
cost). Hop 0 satisfied it comfortably (5 TB free / 28 GB/h = 178 h
useful for 10 h cost). Hop 2's partitioning approach changed the
calculus entirely — by spanning across two drives, future writes are
absorbed by *combined* free space.

---

## 8. Lessons learned (the hard way)

1. **Single-drive `ALTER TABLE SET TABLESPACE` is "buy time", not
   "solve capacity"** unless the destination has multiples of the
   source size in free space.

2. **`pg_class.reltuples` is sampled, not authoritative.** A freshly
   created partitioned parent has `reltuples = -1`, not 0. Verify
   migrations using the `INSERT 0 N` returned-row-count from the
   bulk copy, *or* run `ANALYZE` before reading reltuples.

3. **Long-running multi-step scripts need a clear "what's safe to
   resume" semantics.** The hop 2 chain aborted at step 3 with the
   verify error, leaving the database in a mid-migration state for 8
   days because nobody noticed. The `phase3_hop2_recovery.sh` script
   shows the right shape: be honest about where you are, accept the
   prior step's output as a fact, and finish the swap.

4. **`tmux send-keys` has a per-message length cap.** Hop 1 step 3's
   relaunched loader command was 65 KB of file paths inlined into a
   single `send-keys` call, which silently failed. The fix is to use
   `$(cat …)` in the *destination* shell so tmux receives a short
   command and the destination expands it.

5. **The DB default tablespace is sticky.** After hop 0,
   `wiki_ts_lacie` became the default. The Phase 3 loader's TEMP
   staging table inherited that default and tried to write to lacie14
   even when lacie14 was full. Patching the loader to
   `SET temp_tablespaces = 'wiki_ts_sys'` fixed this; making
   `wiki_ts_sys` the DB-level temp_tablespaces would prevent recurrence.

6. **Partitioning was the right answer all along.** Hops 0 and 1
   bounced the whole table between single drives. Hop 2 finally
   spanned it. In retrospect we should have gone straight from hop 0 to
   a partitioned `revision_text` (skipping hop 1 entirely), saving
   ~3 days of bouncing.

7. **A drive returning to "empty" after a successful migration is
   *normal*, not a sign something went wrong.** Drive-emptying is
   what closes the migration loop — without it, each hop would
   permanently consume drive after drive.

---

## 9. Forward implications

### What `lacie10` is *for* now

It's the **reserve drive for hop 3**, if either `p1` (lacie14) or `p2`
(ssd1) fills before Phase 3 loading finishes (~late June by current
ETA). At the time of writing:

| drive | Phase 3 partition | free | est. burn rate | runway |
|---|---|---|---|---|
| lacie14 | p1 (rev_id < 1B) | 2.5 TB | ~22 GB/h | ~4.7 days |
| ssd1 | p2 (rev_id ≥ 1B) | 3.2 TB | ~6.4 GB/h | ~20.8 days |
| **lacie10** | (none — reserve) | **8.6 TB** | — | — |

The file-pace ETA is ~7.7 days. So `lacie14`'s p1 will likely fill
~4–5 days before the loader finishes — that's when the hop 3 trigger
fires.

### The hop 3 shape (if it fires)

`ALTER TABLE revision_text_p1 SET TABLESPACE wiki_ts_lacie10`.

This moves only the `p1` partition (~7+ TB at that point) from lacie14
to lacie10. The partition stays attached to the parent
`revision_text` throughout — no schema change, no INSERT SELECT, no
`reltuples` verify trap. Just a single-relation tablespace move.

Wall time estimate: 14–18 h at lacie14's ~150 MB/s sustained HDD
output.

### Other forward implications

- **The data is *not* redundant.** Despite three migrations, every
  byte of `revision_text` exists in exactly one place (it just moves
  around). A single drive failure is catastrophic.
- **A backup is owed.** `freeze_phase3.sh` is supposed to create a
  `pg_dump` snapshot. The custom-format dump of `wiki20260401` will
  compress the wikitext to ~3–5 TB. lacie10 with its 8.6 TB free is
  the obvious target.
- **The source `.7z` dumps on lacie14 are the canonical re-ingestion
  fallback.** If both lacie14 and ssd1 burn down tomorrow, we have to
  re-download nothing — the dumps are still there — but we lose ~3
  weeks of bulk-load time.

---

## 10. Cross-references

| file | content |
|---|---|
| [STORAGE_LAYOUT.md](STORAGE_LAYOUT.md) | the *current* state (technical / operational reference) |
| [DATA_LOCATION_GUIDE.md](DATA_LOCATION_GUIDE.md) | the *current* state (conceptual / researcher-friendly) |
| [phase3_partition_plan.md](phase3_partition_plan.md) | hop 2 design notes |
| [phase3_hop2_plan.md](phase3_hop2_plan.md) | hop 2 design (refined) |
| [phase3_hop2_chain.sh](phase3_hop2_chain.sh) | hop 2 execution script (the one that aborted at verify) |
| [phase3_hop2_recovery.sh](phase3_hop2_recovery.sh) | hop 2 recovery script that completed the swap |
| [phase3_hop1_log_20260612.md](phase3_hop1_log_20260612.md) | hop 1 incident log |
| [phase3_ingestion_assessment_20260609.md](phase3_ingestion_assessment_20260609.md) | mid-flight assessment after hop 0 |
| [phase3_lacie_switchover.sh](phase3_lacie_switchover.sh) | hop 0 runbook |
| [INGESTION_LOG.md](INGESTION_LOG.md) | dated activity log (high-level) |

---

*Last updated: 2026-06-25 12:00 BST. Covers the period from
2026-05-09 (cluster creation) through 2026-06-24 (hop 2 recovery
completion).*
