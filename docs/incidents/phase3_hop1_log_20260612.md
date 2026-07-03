# Phase 3 hop 1 — incident + migration log (2026-06-09 → 2026-06-12)

Live activity log for the move of `revision_text` from lacie14 (which filled
to 0 free) to lacie10 (newly cleared to 8.56 TiB free). Captures the
67-hour dead-loader period, the decision shape, and the runbook firing.

## Timeline

### 2026-06-09 21:05 BST — loader dies, lacie14 hits 0 bytes free

Last log line in `phase3_loader_active.log`:

```
2026-06-09 21:05:13,589 INFO load_pages_meta_history_xml [pid=3602391]
  [enwiki-20260401-pages-meta-history15.xml-p16826423p16927403.7z]
  30000 revisions parsed (1208 rev/s)
```

Workers were hot at 1208 rev/s when `/dev/sde1` (lacie14) hit its hard
ENOSPC limit. The loader died mid-batch; no rollback corruption, no PK
violations, just a write that couldn't complete.

State at death:
- `revision_text`: 629,086,912 rows / 8,561 GB
- 176 files done (out of the 606-file SKIP=350 cut list)
- lacie14: 11 TB used / 0 GB free
- lacie10: 5.7 TB used / 3.0 TB free
- Loader PIDs (3602387, 3602391, 3602392) exited

### 2026-06-09 21:05 → 2026-06-12 16:44 BST — 67-hour idle period

- No PG writes to `wiki20260401` during this window (lacie14 default
  tablespace was full; any write would have failed)
- `revision_text` heap stayed intact at 8,561 GB
- User actively clearing lacie10 to reach the originally-stated 9 TB free
  target
- Hourly cron (`26f30339`) kept firing but reported "loader: not running"
  on each tick

### 2026-06-12 10:28 BST — discovery

User requested a status check. I queried current state and found:
- Loader procs: 0
- lacie14 free: 0.000 GiB (precise)
- Loader last log line: 37 hours stale

Reported the situation to the user. Began drafting the recovery plan.

### 2026-06-12 ~16:30 BST — decision tree

Surveyed available drives:

| drive | free | role |
|---|---|---|
| lacie14 (`/dev/sde1`) | 0 GB | ❌ source, full |
| **lacie10 (`/dev/sdd1`)** | **6.6 TB** (rising) | ✅ candidate destination |
| ssd1 (`/dev/sdc`) | 6.3 TB | empty since the May 25 → Jun 4 ALTER DATABASE |
| ssd (`/dev/sdb`) | 4.6 TB | other data |
| nvme `/` | 317 GB | PG WAL + `wiki_ts_sys` (PK indexes) |

Discussed three approaches with the user:

1. **Wait for lacie10 to reach ≥ 9 TB free, then single `ALTER TABLE` move
   to lacie10**. User's preference — matches their original "9 TB free"
   target. Simpler than partitioning, defers complexity to a future hop 2.
2. **Partition revision_text across ssd1 + lacie10 now**. Drops downtime
   waiting but adds operational complexity (two tablespaces) and uses
   internal SSD for what could be external storage.
3. **Partition revision_text in two steps** (the user's creative
   suggestion: "7 TB now, 2 TB later"). Explained why this doesn't work
   directly: PG can't physically shrink a heap on a single drive without
   scratch space, and "2 TB stays on lacie14" requires lacie14 to have
   write capacity it doesn't have.

User chose option 1 (wait + single `ALTER TABLE`).

### 2026-06-12 ~16:45 BST — pre-documentation work

While waiting for lacie10 clearing, I:
- Wrote `phase3_hop2_plan.md` documenting the second-hop partition
  migration that will be needed once lacie10 itself nears full (estimated
  2-3 weeks of post-hop-1 loading)
- Drafted the loader patch needed for hop 1: add
  `SET temp_tablespaces = 'wiki_ts_sys'` to the per-session SET block so
  the TEMP `_rev_text_stage` table doesn't try to land on the still-full
  `wiki_ts_lacie` after the heap moves to lacie10

### 2026-06-12 16:44 → 21:18 BST — lacie10 clearing completes

User's clearing finished. lacie10 went from 3.0 TB → 8.56 TB free,
within rounding of the 9 TB target. Status check confirmed:
- `df -B1` precise: 8.56 TiB free on lacie10
- revision_text relation size (per `pg_total_relation_size`): 8,561 GB
- Heap + TOAST to move: ~8.35 TiB (PK index 11 GB stays on `wiki_ts_sys`)
- **Margin after the move: ~200 GiB** on lacie10

Reported the math to the user, including the choice between `ALTER TABLE`
(only revision_text moves, fits with 200 GiB margin) and `ALTER DATABASE`
(everything moves, ~270 GiB short — won't fit without freeing more on
lacie10). User chose `ALTER TABLE` (option A).

### 2026-06-12 21:18 BST — hop 1 fires

Applied the patch to [load_pages_meta_history_xml.py](load_pages_meta_history_xml.py):

```python
cur.execute("SET synchronous_commit = OFF")
cur.execute("SET maintenance_work_mem = '2GB'")
cur.execute("SET work_mem = '256MB'")
# The DB default tablespace is wiki_ts_lacie (lacie14) which is
# full; route TEMP tables (incl. _rev_text_stage) to wiki_ts_sys
# (NVMe, plenty of room and fast for small staging).
cur.execute("SET temp_tablespaces = 'wiki_ts_sys'")
```

Wrote [phase3_move_table_to_lacie10.sh](phase3_move_table_to_lacie10.sh)
— a 4-step autonomous chain:

1. preflight + verify tablespace + verify GRANT + verify loader stopped
2. `ALTER TABLE revision_text SET TABLESPACE wiki_ts_lacie10` (~16-22 h)
3. regenerate `--files` list (subtract files completed since the SKIP=350
   cut)
4. relaunch loader (tmux `phase3-load`) + sampler (tmux `phase3-sampler`)

Launched in dedicated tmux session `phase3-move`. Chain log
`phase3_move_to_lacie10_20260612_211820.log` started writing.

Preflight passed clean:
- loader: not running ✅
- tablespace `wiki_ts_lacie10` at `/media/simone/lacie10/postgres-wiki` ✅
- GRANT verified ✅
- revision_text is a regular table on `wiki_ts_lacie` ✅
- lacie10 free: 8.56 TiB ✅
- loader patch present ✅
- wiki20260401 backends: 0 ✅

Step 1 (the ALTER TABLE) entered execution at 2026-06-12T20:18:21Z (UTC).

## Current state (at file-write time)

- ALTER TABLE in flight inside the `phase3-move` tmux session
- Expected completion: **Sat 13 Jun late afternoon → Sun 14 Jun morning
  BST** (16-22 h from start)
- Steps 2-4 will auto-fire on completion
- After completion: lacie14 ~10 TB free; lacie10 ~200 GiB free
- Loader resumes against the 8.56 TB revision_text now on lacie10, using
  the patched `SET temp_tablespaces` so the TEMP staging table goes to
  NVMe instead of the empty-but-still-default-tablespace lacie14
- Phase 3 will continue at the pre-hop-1 rate (~24-30 GB/h on lacie10);
  expect ~600 GiB / 28 GB/h = 21 h before lacie10 free reaches 0 unless
  user keeps freeing or hop 2 fires

## Lessons captured

- **PG default tablespace points at lacie14 still.** That's why the
  loader patch is needed: TEMP staging table follows
  `temp_tablespaces` (and falls through to `default_tablespace` if unset),
  not the relation's own tablespace. Without the patch, after hop 1 the
  loader would try to create `_rev_text_stage` on lacie14 (still default,
  still empty-of-writeable-space because lacie14's wiki_ts_lacie heap is
  ~480 GB of Phase 1+2 tables but no room) and fail immediately.
- **`ALTER DATABASE SET TABLESPACE` vs `ALTER TABLE SET TABLESPACE`** — we
  considered both. `ALTER DATABASE` is "cleaner" (whole DB ends up on one
  tablespace, default flips automatically) but moves everything (~8.79 TiB
  in our case) which didn't fit lacie10's 8.56 TiB free. `ALTER TABLE`
  moves only what we needed (~8.35 TiB) and fit with margin.
- **The hop 2 plan exists pre-event.** `phase3_hop2_plan.md` documents the
  partition migration with the lacie10/lacie14 roles rotated. When
  lacie10 itself nears full (~600 GB free trigger threshold), we'll know
  exactly what to do.

## Files involved

- [load_pages_meta_history_xml.py](load_pages_meta_history_xml.py) —
  patched (added `SET temp_tablespaces = 'wiki_ts_sys'`)
- [phase3_move_table_to_lacie10.sh](phase3_move_table_to_lacie10.sh) —
  the runbook chain firing right now
- [phase3_hop2_plan.md](phase3_hop2_plan.md) — next-hop partition
  documentation
- `phase3_move_to_lacie10_20260612_211820.log` — chain progress log (lives
  in this repo dir)
- `phase3_loader_active.log` — will be archived to
  `phase3_loader_pre_move_<timestamp>.log` and replaced when step 3 fires
