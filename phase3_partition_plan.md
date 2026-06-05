# Phase 3 partitioning plan — span `revision_text` across lacie14 + lacie10

## Why

Current `revision_text` is **6.35 TB on lacie14**. lacie14 has **3.3 TB free**;
at the observed ~28 GB/h growth rate (post-optimization), the table fills
the drive in roughly **5 days**. Estimated final size is **12–15 TB** — won't
fit on any single drive on this box. Spanning across lacie14 + lacie10 keeps
all wiki data on the two external Lacie HDDs and out of the internal disks.

## Where the boundaries land

| | |
|---|---|
| current `rev_id` range in `revision_text` | `[1, 1,346,611,823]` |
| chosen partition split | **`rev_id = 1,000,000,000`** |
| existing data → `p1` (lacie14) — `[1, 1B)` | **~4.7 TB** (= 1.0/1.35 × 6.35) |
| existing data → `p2` (lacie10) — `[1B, MAXVALUE)` | **~1.65 TB** (= 0.35/1.35 × 6.35) |
| lacie10 free needed for `p2` migration | **≥ 2 TB** (1.65 + ~20 % overhead) |
| lacie10 free **now** | 3.0 TB — fits, but tight long-term |

This boundary keeps the existing **74 % of bytes on lacie14** (where the heap
already lives — no I/O cost to leave it) and ships only the **26 % above
1B** over the wire to lacie10. The actual moved data is **~1.65 TB**,
not 6.35 TB — much cheaper than a full rewrite.

## Capacity outlook after migration

| | lacie14 | lacie10 |
|---|---|---|
| current free | 3.3 TB | 3.0 TB |
| holds after migration | ~4.7 TB existing + future `p1` writes | ~1.65 TB existing + future `p2` writes |
| net free after migration | 3.3 TB | 1.35 TB |
| future write distribution (assuming uniform `rev_id`) | ~74 % | ~26 % |
| effective runway at 28 GB/h total | ~5.4 days on lacie14 / ~7.1 days on lacie10 | |

**The 5-day lacie14 runway hasn't changed much.** This is the unavoidable
truth of trying to fit 12–15 TB final on two 7–11 TB drives. To actually
buy long-term headroom, either:
- the user frees ~3 more TB on lacie10 before/during the migration, OR
- we plan a **second hop**: add a third partition on ssd1 (now empty)
  when the first hop's runway runs down. ssd1 has 7.0 TB free.

I'd recommend keeping ssd1 in reserve as the third tablespace; we don't
need to commit to it now, but if Phase 3 hits ENOSPC again mid-run we have
a clean place to land.

## Migration strategy — the cheaper-than-full-copy route

The naive "create partitioned parent, INSERT SELECT, drop old" approach
costs a full 6.35 TB write (~17 h at HDD speed). We can do much better by
**ATTACH-ing the existing table as `p1` directly** and only moving the
slice that doesn't fit `p1`'s bounds.

### Steps

1. **Stop the loader** — needed because every step touches `revision_text`.

2. **(sudo) Set up `wiki_ts_lacie10` tablespace** — same ritual as
   `wiki_ts_lacie`:
   ```
   sudo mkdir -p /media/simone/lacie10/postgres-wiki
   sudo chown postgres:postgres /media/simone/lacie10/postgres-wiki
   sudo chmod 700 /media/simone/lacie10/postgres-wiki
   sudo -u postgres psql -p 5434 -c \
     "CREATE TABLESPACE wiki_ts_lacie10 LOCATION '/media/simone/lacie10/postgres-wiki';"
   sudo -u postgres psql -p 5434 -c \
     "GRANT CREATE ON TABLESPACE wiki_ts_lacie10 TO simone;"
   ```

3. **Extract the rows that belong in `p2`** to a staging table on lacie10
   (this is the only real data movement, ~1.65 TB):
   ```sql
   CREATE TABLE revision_text_p2_stage (
       rev_id         bigint NOT NULL,
       rev_text       bytea,
       rev_text_bytes bigint NOT NULL
   ) TABLESPACE wiki_ts_lacie10;

   INSERT INTO revision_text_p2_stage
   SELECT * FROM revision_text WHERE rev_id >= 1000000000;
   -- ~1.65 TB write to lacie10
   -- ~ETA: 1.65 TB / 100 MB/s ≈ 4.6 h (parallel read from lacie14 + write to lacie10)
   ```

4. **Delete the moved rows from `revision_text`** so it only contains
   `[1, 1B)` rows (matches the future `p1` partition's bounds):
   ```sql
   DELETE FROM revision_text WHERE rev_id >= 1000000000;
   -- ~360 M rows deleted; doesn't reclaim disk (VACUUM FULL would, but we
   -- can leave the bloat — it's only 26% of the table and will be
   -- naturally compacted by autovacuum over time)
   ```

5. **Add CHECK constraint matching `p1`'s bounds** (required for ATTACH
   without scanning):
   ```sql
   ALTER TABLE revision_text
     ADD CONSTRAINT revision_text_p1_bound CHECK (rev_id < 1000000000) NOT VALID;
   ALTER TABLE revision_text VALIDATE CONSTRAINT revision_text_p1_bound;
   -- VALIDATE scans the table; ~6.35 TB read on lacie14, ~9 h.
   -- BUT: we already DELETEd above; check is satisfied; validation can be
   -- cheap because every live row satisfies the constraint.
   ```

6. **Rename and create the partitioned parent:**
   ```sql
   ALTER TABLE revision_text RENAME TO revision_text_p1;
   ALTER INDEX revision_text_pkey RENAME TO revision_text_p1_pkey;

   CREATE TABLE revision_text (
       rev_id         bigint NOT NULL,
       rev_text       bytea,
       rev_text_bytes bigint NOT NULL
   ) PARTITION BY RANGE (rev_id);

   -- Re-create the parent PK (logical only on partitioned tables; PG creates
   -- one child index per partition with this declaration)
   ALTER TABLE revision_text ADD PRIMARY KEY (rev_id);
   ```

7. **ATTACH `revision_text_p1` as the `[1, 1B)` partition:**
   ```sql
   ALTER TABLE revision_text ATTACH PARTITION revision_text_p1
     FOR VALUES FROM (MINVALUE) TO (1000000000);
   -- O(1) — just a catalog update because the CHECK constraint satisfies the
   -- bounds without a scan.
   ```

8. **Create `p2` partition on lacie10 + load the staged rows:**
   ```sql
   CREATE TABLE revision_text_p2
     PARTITION OF revision_text
     FOR VALUES FROM (1000000000) TO (MAXVALUE)
     TABLESPACE wiki_ts_lacie10;

   INSERT INTO revision_text_p2 SELECT * FROM revision_text_p2_stage;
   -- Same 1.65 TB, but this time onto the proper partition. ~4.6 h.
   -- ALTERNATIVELY: rename revision_text_p2_stage -> revision_text_p2 and
   -- ATTACH it as the partition. Same trick as step 7 — O(1) — saves 4.6 h.
   ```

9. **Move PK indexes for each partition to `wiki_ts_sys`** (the NVMe tablespace
   we set up; keeps random PK lookups fast):
   ```sql
   ALTER INDEX revision_text_p1_pkey  SET TABLESPACE wiki_ts_sys;  -- already there
   ALTER INDEX revision_text_p2_pkey  SET TABLESPACE wiki_ts_sys;  -- ~6 GB move
   ```

10. **Drop the staging table** (its rows are now in `p2`):
    ```sql
    DROP TABLE revision_text_p2_stage;
    ```

11. **Restart loader** with the same `--no-truncate --skip-revision-check
    --files <606>` invocation. The partitioned parent transparently routes
    each INSERT to the correct partition by `rev_id`.

### Best-path total wall time

| step | cost |
|---|---|
| 2 (sudo + tablespace) | seconds |
| 3 (INSERT into p2_stage on lacie10) | **~4.6 h** |
| 4 (DELETE from revision_text) | ~1 h (slow on HDD even with index) |
| 5 (VALIDATE CHECK) | ~9 h — **biggest cost** |
| 6 (rename + create parent) | seconds |
| 7 (ATTACH p1) | seconds |
| 8 (ATTACH p2 — if we ATTACH instead of INSERT-SELECT) | seconds |
| 9 (ALTER INDEX) | minutes |
| **total** | **~14–15 h** with the ATTACH-trick variants |

Better than a full rewrite (~17 h), but still a big chunk. The lion's
share is step 5 (`VALIDATE CONSTRAINT`) which has to read the full
4.7 TB of `p1` on lacie14.

### Optimisation: skip step 5 entirely

PG allows `ATTACH PARTITION ... DEFAULT`-style or also accepts adding
the CHECK with `NOT VALID` and skipping the validation. But the
`ATTACH PARTITION` semantics REQUIRE a CHECK proving partition bounds.
There's no clean way to skip this scan for a partition that already
contains millions of rows.

**However**: if we run step 5 in parallel with steps 3 + 4 (they don't
overlap on the same indexes), wall time collapses to `max(3+4, 5)` ≈ 9 h.

## Recommended decision

- **Do this now** (well before lacie14 fills): user is freeing lacie10
  to make room. Once lacie10 has ≥ 2 TB free, we can run the migration.
  Total downtime ~ 9 h with parallel execution; ~14 h sequential.
- **Don't full-rewrite**: the ATTACH-trick saves ~3 h vs naive copy
  and keeps the existing 6 TB heap unmoved.
- **Keep ssd1 in reserve** as a future third partition tablespace if
  lacie14+lacie10 fill before Phase 3 completes.
- **Restart loader with same args** post-migration. The PG planner
  routes inserts by `rev_id` automatically; no loader code change needed.

## Open questions for the user

1. Free space target on lacie10 — confirm you'll get to **≥ 2 TB free**
   (you said you're freeing space; current is 3.0 TB free, so we're good
   for the migration but tight for medium-term growth).
2. Are you OK with the **9–14 h loader downtime**? If so, I'll write the
   shell+SQL script (in the same style as the `phase3_lacie_switchover.sh`
   runbook) and queue it for your approval.
3. Should we **also schedule the ssd1-as-third-partition plan** so it's
   pre-approved if needed mid-run? (No execution, just a documented
   ready-to-fire procedure.)
