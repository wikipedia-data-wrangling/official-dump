# Phase 3 ETA breakdown — 2026-06-09 (08:35 local)

## Live state snapshot at time of estimate

| | |
|---|---|
| loader uptime | T+3 d 21 h 03 m (since the post-optimization restart on 2026-06-05) |
| files done / 606 | **147** |
| `revision_text` size | **8.22 TB** |
| recent file pace | 1.51 files/h (last 10.6 h window) |
| recent per-file rev/s | 353–436 rev/s per worker (≈ ~800 rev/s combined) |
| lacie14 free | **1.5 TB** (burning ~19 GB/h) |
| lacie10 free | 6.3 TB |
| nvme `/` free | 258 GB |
| partition trigger threshold | lacie14 < 1 TB free |
| projected trigger time | **≈ 26 h from now** (mid-day Mon 9 Jun → early Tue 10 Jun) |

## Five (or six) phases remaining

| phase | what | est. duration |
|---|---|---|
| **A. continue loading until partition trigger** | files done climbs from 147 to ~165; lacie14 free 1.5 TB → 1 TB | **~26 h** |
| **B. partition migration** | Plan B full rewrite: `CREATE PARTITION BY RANGE` parent → `INSERT INTO revision_text_v2 SELECT * FROM revision_text` (bulk copy 6.7+ TB on lacie14 → split between lacie14 + lacie10) → swap; see [phase3_partition_plan.md](phase3_partition_plan.md) | **~18–22 h** |
| **C. loader resumes, finishes remaining ~440 files** | at ~1.5 files/h sustained; partitioned parent transparently routes inserts by `rev_id` | **~12 days** |
| **D. FK recreate** (`revision_text.rev_id → revision.rev_id`) | full 1.25 B-row validation scan; both PK indexes already on the NVMe `wiki_ts_sys` tablespace so random lookups are fast | **~6 h** |
| **E. `ANALYZE revision_text`** | planner statistics on the partitioned table | **~2 h** |

**Phase 3 *complete* (loader done + FK + ANALYZE) → ~14 days from now ≈ 23 Jun 2026.**

Optional sixth phase for the formal Phase 4b freeze (per `run_pipeline.sh`):

| phase | what | est. duration |
|---|---|---|
| **F. `freeze_phase3.sh`** | `pg_dump` of the full `wiki20260401` (custom format), `key_figures.sql` snapshot, MANIFEST.md append, API spot-check against `dumpstatus.json`, `git tag phase3-frozen` | **+1–2 days** |

**Full "Phase 3 frozen and shippable" → ≈ 24–25 Jun 2026.**

## Risks and bounds

**Upside risks (could land earlier):**
- Per-file rates have been climbing as page-IDs increase — recent `history14` files ~400 rev/s/worker vs early-`history11` ~150 rev/s/worker. If the trend holds, Phase C's 12 days compresses to ~9–10 days. → Phase 3 complete could land **~21 Jun**.
- Post-partition writes to the lacie10 partition may also benefit from the empty drive (no fragmentation, fresh inode tables).

**Downside risks (could push later):**
- **Duplicate-heavy "boundary draggers."** We've hit two so far: the 45 h `history10.xml-p5131815…` file (was in-flight at the 2026-06-03 crash, mostly already loaded → almost all ON CONFLICT skips → throughput collapsed to 10 rev/s) and a 7.4 h `history13.xml-p11380448…` (37 rev/s). Each future dragger we encounter could add 6–48 h. Estimated ≤ 5 remaining draggers (the boundary slack of 10 files I built into the `--files` cut should be mostly past now).
- **Partition migration is one-shot.** If `INSERT SELECT` hits unexpected issues mid-copy (WAL space exhaustion, autovacuum interference, network/disk hiccup that requires retry), recovery adds 1–2 days. The 22 h estimate is for the happy path.
- **FK recreate cost** depends heavily on how recently autovacuum has touched `revision`. If statistics are very stale, the validation could take longer than 6 h. Adding 6 h headroom for safety.

**Net wall-clock band still inside your accepted "3–6 weeks":**
- Optimistic: ~10 days → finish ~19 Jun
- Point estimate: ~14 days → finish ~23 Jun
- Pessimistic (with 2 draggers + migration recovery): ~20 days → finish ~29 Jun

Phase 3 started 2026-05-26 at 15:14 local (the optimized 7zz+staging-table loader). At the 23-Jun point estimate, total Phase 3 wall-clock is **~28 days ≈ 4 weeks** — right in the middle of your acceptance band.

## What triggers a re-estimate

- Hourly cron `26f30339` automatically watches the lacie14 < 1 TB trigger and flags partition migration timing.
- After the partition migration completes, re-baseline the rate with the first 24 h of post-migration data (the lacie10 partition has never been written before; we don't have data on its sustained throughput).
- After every ~50 files done, the file-pace number stabilises enough that ETA estimates become more reliable.

## File references

- [phase3_partition_plan.md](phase3_partition_plan.md) — partition design + alternatives
- [phase3_partition_runbook.sh](phase3_partition_runbook.sh) — executable runbook (review then fire)
- [phase3_lacie_switchover.sh](phase3_lacie_switchover.sh) — prior switchover runbook (kept for reference)
- [phase3_eta_samples.csv](phase3_eta_samples.csv) — 5-min sampler trajectory
- [phase3_loader_active.log](phase3_loader_active.log) — current loader log (overwritten on each restart)
