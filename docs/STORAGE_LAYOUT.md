# Storage layout — `wiki20260401` Postgres database

Complete inventory of where every part of the Wikipedia dataset physically
lives on this host, the Postgres tablespaces that group them, and the
operational implications. Updated 2026-06-24 after the hop-2 partition
recovery; reflects the **current production state of the data**.

Read this file before:
- Reasoning about query performance (which storage path a join touches)
- Planning a backup strategy
- Investigating an `ENOSPC` event
- Working on the partition runbooks
- Spanning new data to another drive

---

## 1. Executive summary

The `wiki20260401` database is spread across **three storage tiers**:

| tier | medium | what's on it | why |
|---|---|---|---|
| **fast random I/O** | NVMe SSD (`nvme0n1p3`, mounted at `/`) | all primary-key indexes; PG cluster catalog; WAL | hot index path for joins + crash recovery |
| **fast bulk I/O** | internal SATA SSD (`/dev/sdc`, mounted at `/media/simone/ssd1`) | `revision_text_p2` (the rev_id ≥ 1B wikitext partition) | TOAST writes for new-rev-id revisions land here at ~50× HDD random-write speed |
| **bulk capacity** | external HDDs (LaCie 11 TB + 9 TB) | Phase 1/2 tables; `revision_text_p1` (rev_id < 1B wikitext partition); source XML/7z dumps; idle capacity reserve | the cheap-per-TB tier holding the 6+ TB of cold wikitext that doesn't fit on internal storage |

The "default" tablespace of the `wiki20260401` database is
`wiki_ts_lacie`, which points at lacie14 — so any table created without an
explicit `TABLESPACE` clause lands there.

---

## 2. Physical drive inventory

| device | mount | size | used | free | role for wiki20260401 |
|---|---|---|---|---|---|
| `/dev/nvme0n1p3` | `/` | 930 GB | 565 GB | 317 GB | PG cluster + WAL + all PK indexes (`wiki_ts_sys`) |
| `/dev/sda` | `/media/simone/hdd` | 7.3 TB | 5.8 TB | 1.2 TB | (not used by `wiki20260401`) |
| `/dev/sdb` | `/media/simone/ssd` | 7.3 TB | 2.4 TB | 4.6 TB | (not used by `wiki20260401`) |
| `/dev/sdc` | `/media/simone/ssd1` | 7.3 TB | 3.6 TB | 3.3 TB | `wiki_ts` → `revision_text_p2` |
| **`/dev/sdd1`** | `/media/simone/lacie10` | 9.1 TB | <1 GB | **8.6 TB** | `wiki_ts_lacie10` (empty reserve for hop 3) |
| **`/dev/sde1`** | `/media/simone/lacie14` | 11 TB | 7.5 TB | 2.9 TB | `wiki_ts_lacie` → `revision_text_p1` + Phase 1/2 tables + source dumps |
| `/dev/sdf1` | `/media/simone/ext1` | 3.6 TB | 2.9 TB | 566 GB | (not used by `wiki20260401`) |

Drive size note: the "11 TB" `lacie14` and "14 TB" labelled drives only
show 10.83 TiB / etc. because manufacturers use base-10 (`14 × 10¹²`
bytes) and `df` reports base-2 (TiB). Subtract another ~5 % for ext4
root-reserved blocks and ~12 % for inodes/journal/metadata and you get
the observed available space.

---

## 3. Tablespace map

| tablespace | physical path | size | hosts |
|---|---|---|---|
| `wiki_ts_lacie` (← **database default**) | `/media/simone/lacie14/postgres-wiki` | ~7.0 TB | Phase 1 + Phase 2 tables + `revision_text_p1` + Phase 2 secondary indexes |
| `wiki_ts` | `/media/simone/ssd1/postgres-wiki` | ~2.0 TB | `revision_text_p2` |
| `wiki_ts_sys` | `/var/lib/postgres-wiki-idx` | ~54 GB | all `*_pkey` indexes (revision_pkey 34 GB, revision_text_p1_pkey 15 GB, revision_text_p2_pkey 3 GB, plus smaller ones) |
| `wiki_ts_lacie10` | `/media/simone/lacie10/postgres-wiki` | **0 GB (empty)** | nothing — held in reserve as hop-3 destination if `revision_text_p2` outgrows ssd1 |
| `pg_default` (cluster default) | `/var/lib/postgresql/18/main/base` | — | only used for `wiki20260401`'s system catalogs (not user data) |
| `pg_global` | `/var/lib/postgresql/18/main/global` | — | cluster-wide catalogs (`pg_authid`, etc.) |

`pg_default` and `pg_global` are on the root NVMe so PG can always start
even if external drives are not present.

---

## 4. Per-table inventory (largest first)

Sizes from `pg_total_relation_size` (includes heap + TOAST + all indexes).
Tablespace shown as `(default)` means `pg_class.reltablespace = 0`, which
resolves to `wiki_ts_lacie` (the DB default).

### Phase 3 — wikitext

| relation | kind | size | tablespace | physical drive | notes |
|---|---|---|---|---|---|
| `revision_text` | partitioned table | (logical) | (default) | — | partitioned `BY RANGE (rev_id)`; split at `rev_id = 1,000,000,000` |
| ↳ `revision_text_p1` | regular table | **6,776 GB** | (default) → `wiki_ts_lacie` | lacie14 | revisions with `rev_id < 1B` |
| ↳ `revision_text_p2` | regular table | **2,038 GB** | `wiki_ts` | ssd1 | revisions with `rev_id ≥ 1B` |
| `revision_text_p1_pkey` | btree index | 15 GB | `wiki_ts_sys` | nvme | PK on (`rev_id`) |
| `revision_text_p2_pkey` | btree index | 3 GB | `wiki_ts_sys` | nvme | PK on (`rev_id`) |

Total `revision_text` data: ~8.81 TB (670,640,642 rows currently — this
will grow as Phase 3 loading continues; final estimate 12–17 TB).

### Phase 2 — revision metadata

| relation | kind | size | tablespace | physical drive | notes |
|---|---|---|---|---|---|
| `revision` | regular table | 336 GB (heap + indexes + TOAST) | (default) → `wiki_ts_lacie` | lacie14 | 1,249,246,504 rows; one row per Wikipedia revision |
| ↳ `revision_pkey` | btree index | 34 GB | `wiki_ts_sys` | nvme | PK on (`rev_id`) |
| ↳ `revision_page_timestamp_actor_idx` | btree index | (~50 GB est.) | (default) | lacie14 | the load-bearing index for the hyperevent model |
| ↳ `revision_actor_timestamp_idx` | btree index | (~50 GB est.) | (default) | lacie14 | actor-centric queries |
| ↳ `revision_parent_idx` | btree index | (~30 GB est.) | (default) | lacie14 | parent-rev_id lookups (revert detection) |
| `actor` | regular table | 15 GB | (default) | lacie14 | shared between Phase 1b + Phase 2; ~111 M editors |

### Phase 1 — page metadata + tags + groups + logging

| relation | size | tablespace | physical drive |
|---|---|---|---|
| `change_tag` | 66 GB | (default) → `wiki_ts_lacie` | lacie14 |
| `logging` | 54 GB | (default) | lacie14 |
| `page` | 13 GB | (default) | lacie14 |
| `page_restrictions` | 22 MB | (default) | lacie14 |
| `user_groups` | 11 MB | (default) | lacie14 |
| `protected_titles` | 8.8 MB | (default) | lacie14 |
| `user_former_groups` | 2.2 MB | (default) | lacie14 |
| `change_tag_def` | 88 kB | (default) | lacie14 |

### Source artifacts (non-PG)

| path | size | drive | what |
|---|---|---|---|
| `/media/simone/lacie14/wikidumps/20260401/xml/` | ~390 GB | lacie14 | 956 `.7z` source files (stub-meta-history, pages-meta-history, logging, ...) |
| `/media/simone/lacie14/wikidumps/20260401/sql/` | 6.9 GB | lacie14 | Phase 1a SQL dumps |
| `/media/simone/lacie14/wikidumps/20260401/MANIFEST.md` | < 100 KB | lacie14 | download manifest + SHA-1 ledger |
| `/media/simone/lacie14/wikidumps/20260401/dumpstatus.json` | 620 KB | lacie14 | the upstream WMF `dumpstatus.json` snapshot |

---

## 5. Logical → physical query path

This is what happens when a downstream analytic query touches several
tables. Worth knowing for join performance reasoning.

```
Query:
  SELECT rt.rev_id, rt.rev_text, r.rev_timestamp, p.page_title
    FROM revision_text rt
    JOIN revision r       ON r.rev_id = rt.rev_id
    JOIN page p           ON p.page_id = r.rev_page
   WHERE rt.rev_id BETWEEN 10000 AND 20000;
```

| step | I/O on | drive | speed |
|---|---|---|---|
| 1. Index seek on `revision_text_pkey` (rev_id range) | `wiki_ts_sys` | nvme | very fast |
| 2. The seek lands in p1 (rev_ids 10k-20k < 1B) → heap fetch from `revision_text_p1` | `wiki_ts_lacie` | lacie14 (HDD) | slow random read; TOAST de-chunking |
| 3. Index seek on `revision_pkey` | `wiki_ts_sys` | nvme | very fast |
| 4. Heap fetch from `revision` for matching rev_ids | `wiki_ts_lacie` | lacie14 (HDD) | slow random read |
| 5. Hash join or nested loop to `page` | `wiki_ts_lacie` | lacie14 (HDD) | depending on planner |

**The HDD random-read pattern is the dominant cost** for any
revision-text-heavy query. Mitigations:
- For range queries that touch many revisions, prefer
  `WHERE rev_id BETWEEN ... AND ...` so the planner can use a sequential
  TOAST scan rather than scattered TOAST reads
- For analytics workloads, materialise summary tables (revert flags, edit
  counts per editor) so the wikitext heap isn't touched repeatedly
- If query workload becomes bottlenecked on lacie14 random reads,
  consider moving the Phase 2 secondary indexes
  (`revision_page_timestamp_actor_idx` etc.) to `wiki_ts_sys` (NVMe).
  ~130 GB of NVMe headroom available

---

## 6. How we got here (one-line per major event)

| date | event |
|---|---|
| 2026-05-09 | PG18 cluster set up; `wiki_ts` tablespace created at `/media/simone/ssd1/postgres-wiki`; `wiki20260401` database created on `wiki_ts` |
| 2026-05-09 → 24 | Phase 1a + 1b + 2 loaded on `wiki_ts` (ssd1) |
| 2026-05-25 | Phase 2 finished (1.249 B `revision` rows) |
| 2026-05-26 → 06-03 | Phase 3 wikitext loader runs on `wiki_ts` (ssd1) — completes ~350 files |
| 2026-06-03 | Loader crashes on `rev_id 711706` PK violation; ssd1 hits 100 % full at 6+ TB of revision_text |
| 2026-06-04 | **Hop 0**: created `wiki_ts_lacie` at `/media/simone/lacie14/postgres-wiki`; `ALTER DATABASE wiki20260401 SET TABLESPACE wiki_ts_lacie` moves the whole DB from ssd1 → lacie14 over ~10 h |
| 2026-06-04 | PK indexes split off: created `wiki_ts_sys` at `/var/lib/postgres-wiki-idx`, `ALTER INDEX … SET TABLESPACE wiki_ts_sys` for `revision_text_pkey` and `revision_pkey` |
| 2026-06-09 | lacie14 fills (loader was burning 28 GB/h); loader dies at ENOSPC |
| 2026-06-12 | **Hop 1**: created `wiki_ts_lacie10` at `/media/simone/lacie10/postgres-wiki`; `ALTER TABLE revision_text SET TABLESPACE wiki_ts_lacie10` moves the table from lacie14 → lacie10 over ~17 h |
| 2026-06-13 | Loader resumes against `revision_text` on lacie10 |
| 2026-06-14 | lacie10 fills 22 h later (228 GB margin exhausted); loader dies at ENOSPC again |
| 2026-06-14 → 16 | **Hop 2**: `INSERT INTO revision_text_v2 SELECT * FROM revision_text` over 58 h splits the table into `revision_text_p1` (lacie14, rev_id < 1B) and `revision_text_p2` (ssd1, rev_id ≥ 1B) |
| 2026-06-16 → 24 | Hop-2 chain aborts at verify step due to a `reltuples=-1` bug; database sits in mid-migration limbo for 8 days; no data lost |
| 2026-06-24 | Recovery script runs the deferred `DROP TABLE revision_text + ALTER TABLE revision_text_v2 RENAME` swap; loader resumes against the partitioned table |

This is the **current state** and is intended to be the last
storage-layout change of Phase 3 — assuming the per-row size trajectory
holds and a hop 3 isn't needed.

---

## 7. Operational implications

### 7.1 Backup

`pg_dump` of `wiki20260401` will pull data from lacie14 + ssd1 + nvme
simultaneously and write the output to a single file. Plan accordingly:
- The dump file destination needs at least ~3–5 TB of free space
  (custom-format dump compresses the bytea wikitext)
- The dump itself reads sequentially within each relation; lacie14 + ssd1
  random-read contention is moderate
- Expected wall time: 12–24 h for a full custom-format dump

For incremental safety, consider `pg_dump --schema-only` snapshots at
each migration checkpoint, plus a one-time full dump after Phase 3 freeze
(see `freeze_phase3.sh`).

### 7.2 Disk full responses

| drive | what runs out | response |
|---|---|---|
| lacie14 (`wiki_ts_lacie`) | All Phase 1/2 tables stop accepting writes; `revision_text_p1` stops accepting future rev_ids < 1B | Already empty: lacie10 (8.6 TB free). Migrate p1 to `wiki_ts_lacie10` via `ALTER TABLE revision_text_p1 SET TABLESPACE wiki_ts_lacie10` (~18 h). |
| ssd1 (`wiki_ts`) | `revision_text_p2` stops accepting future rev_ids ≥ 1B | Same: migrate p2 to `wiki_ts_lacie10`. Or use `ALTER TABLE … SPLIT PARTITION` (PG17+) to split p2's rev_id range and put the new sub-partition on lacie10. |
| nvme (`wiki_ts_sys` / WAL) | Index updates fail; WAL fills | Critical. Free space on `/` first (system logs, snap caches, old kernels). If needed, move secondary indexes back to lacie14 via `ALTER INDEX`. |
| lacie10 | (nothing — it's empty reserve) | — |

### 7.3 Performance characteristics by tablespace

| tablespace | seq read | seq write | random read (small) | random write |
|---|---|---|---|---|
| `wiki_ts_sys` (NVMe) | ~3 GB/s | ~2 GB/s | very fast (~10–100 µs) | very fast |
| `wiki_ts` (SATA SSD) | ~500 MB/s | ~400 MB/s | fast (~100 µs) | fast |
| `wiki_ts_lacie`/`_lacie10` (USB HDD) | ~180 MB/s | ~150 MB/s | slow (~5–15 ms) | slow |

This is why PK indexes live on NVMe and the high-frequency-write
revision_text_p2 partition lives on SSD — random write performance is
where Postgres was bottlenecked during Phase 3 loading.

### 7.4 Drive failure scenarios

| drive lost | impact |
|---|---|
| nvme0n1 | catastrophic — both the cluster catalog AND all PK indexes gone; would need full restore from `pg_dump` |
| lacie14 | catastrophic for `wiki20260401` — loses Phase 1/2 tables + `revision_text_p1` (the bigger half); would need to reload from source dumps (still on lacie14! redundant — also lost) and Phase 2 stub-history |
| ssd1 | loses `revision_text_p2` heap (rev_id ≥ 1B); the PKs on NVMe survive but point at dead heap files. ~3.5 TB of wikitext would need re-loading from `pages-meta-history*.7z` (on lacie14) |
| lacie10 | no impact today (empty) |

The data is **not redundant across drives**. A backup strategy is owed
once Phase 3 finishes (`freeze_phase3.sh` is the start of that).

---

## 8. How to verify the layout

Run these queries to confirm what this file describes:

```sql
-- Tablespace inventory + total sizes
SELECT spcname,
       pg_tablespace_location(oid) AS path,
       pg_size_pretty(pg_tablespace_size(oid)) AS size
  FROM pg_tablespace
 ORDER BY pg_tablespace_size(oid) DESC;

-- Database default tablespace
SELECT d.datname, t.spcname AS db_default_tablespace
  FROM pg_database d
  JOIN pg_tablespace t ON t.oid = d.dattablespace
 WHERE d.datname = 'wiki20260401';

-- Per-table inventory with tablespace
SELECT c.relname,
       c.relkind,
       coalesce(t.spcname, '(default)') AS tablespace,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
  FROM pg_class c
  LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
 WHERE c.relnamespace = 'public'::regnamespace
   AND c.relkind IN ('r','p','i','I')
 ORDER BY pg_total_relation_size(c.oid) DESC NULLS LAST;

-- revision_text partitions
SELECT inhrelid::regclass AS child, inhparent::regclass AS parent
  FROM pg_inherits
 WHERE inhparent::regclass::text LIKE 'revision_text%';

-- Disk-level inventory (shell)
df -h /media/simone/lacie14 /media/simone/lacie10 \
       /media/simone/ssd1   /media/simone/ssd /
```

---

## 9. Cross-references

| file | content |
|---|---|
| [CLAUDE.md](CLAUDE.md) | top-level project guide; locked decisions |
| [data_collection_plan.md](data_collection_plan.md) | phase-by-phase ingest plan |
| [INGESTION_LOG.md](INGESTION_LOG.md) | dated activity log |
| [phase3_partition_plan.md](phase3_partition_plan.md) | the original hop-2 partition design (pre-actual-hop-2) |
| [phase3_hop1_log_20260612.md](phase3_hop1_log_20260612.md) | hop 1 incident + migration log |
| [phase3_hop2_plan.md](phase3_hop2_plan.md) | hop 2 design notes (pre-execution) |
| [phase3_hop2_chain.sh](phase3_hop2_chain.sh) | the chain script that ran 2026-06-14 → 16 |
| [phase3_hop2_recovery.sh](phase3_hop2_recovery.sh) | the recovery script that ran 2026-06-24 |
| [phase3_ingestion_assessment_20260609.md](phase3_ingestion_assessment_20260609.md) | mid-flight quality assessment |
| [setup_postgres18.sh](setup_postgres18.sh) | original cluster provisioning |
| `~/.pg_service.conf` | `service=wiki` connection alias (encodes port 5434) |

---

## 10. Open questions / future work

- **`freeze_phase2.sh` has never been run** — Phase 2's `revision` table
  is "frozen" only in the sense that no loader writes to it. We owe a
  formal pg_dump snapshot + `phase2-frozen` git tag.
- **`freeze_phase3.sh` is the next deliverable** after Phase 3 loading
  finishes (~late June by current ETA). Will need a target with ~3–5 TB
  free for the custom-format dump. lacie10 is the obvious target.
- **The Phase 2 secondary indexes are still on lacie14** (HDD). If
  downstream hyperevent queries are slow, moving the hot ones to
  `wiki_ts_sys` (NVMe) is a cheap win (~130 GB of headroom). Profile
  before committing.
- **Backup strategy:** there is none today beyond the source `.7z` files
  and `dumpstatus.json` checksums. A target post-freeze deliverable is
  at least one offsite or off-host pg_dump.
- **`temp_tablespaces` is set to `wiki_ts_sys`** in the Phase 3 loader's
  per-session SET block (so the TEMP staging table doesn't try to land
  on whichever drive is currently full). Should be made permanent at
  the database level — `ALTER DATABASE wiki20260401 SET
  temp_tablespaces = 'wiki_ts_sys'`. Owed cleanup.
- **The DB default tablespace is `wiki_ts_lacie`** (lacie14). New tables
  created without explicit `TABLESPACE` will land there. May want to
  change the default to `wiki_ts_sys` post-Phase-3 so analytics-side
  derived tables (small, hot) land on NVMe by default.

---

*Last updated: 2026-06-24 18:58 BST (immediately after the hop-2
recovery completed and the loader was relaunched against the partitioned
`revision_text`).*
