# Plan: Re-collect Wikipedia Data for the Protection-Policy Project

A phase-based plan for rebuilding the project's data foundation from Wikipedia's official dumps, optimized for the protection-policy research design (granted-vs-denied RFPP identification + polyadic relational hyperevent models over the editor–page network).

## Locked decisions and current state

- **Run ID**: `20260401` (latest "Dump complete" enwiki run as of 2026-05-09; `20260501` is still in progress). The 2026-04-01 cutoff is acceptable for the research design — this is a retrospective study of past protection policy, not a live-monitoring system, so a fixed snapshot is preferred (it makes results reproducible).
- **Engine**: PostgreSQL **18** (cluster `main`, port **5434**), installed alongside the existing PG15/16 clusters which are left untouched.
- **Database**: `wiki20260401`, owner `simone`, encoding **`SQL_ASCII`** (byte-transparent — Wikipedia dumps occasionally contain bytes that strict UTF-8 would reject), locale `C`, on a dedicated tablespace `wiki_ts`.
- **Storage**: every byte of `wiki20260401` lives on `/media/simone/ssd1/postgres-wiki/` (7.3 TB SSD); raw downloads in `/media/simone/ssd1/wikidumps/20260401/`. The cluster's catalog stays at `/var/lib/postgresql/18/main` (small, fine on `/`).
- **Connection convention**: `psql service=wiki` (port encoded in `~/.pg_service.conf`); future code uses libpq's service=wiki to avoid hardcoding the port.

The Phase 0 host-prep work is **complete**:

- MariaDB fully purged.
- PGDG `jammy-pgdg` repo installed; `postgresql-18` 18.3 in use.
- PG18 cluster `main` created with `pg_createcluster --start 18 main`.
- Tablespace `wiki_ts` and database `wiki20260401` created.
- `~simone/.pg_service.conf` written with `service=wiki`.
- Setup is reproducible via [setup_postgres18.sh](setup_postgres18.sh).

## What's actually available in the 20260401 dump

A discovery worth recording: WMF stopped publishing several SQL dumps a few years ago for privacy / data-minimization reasons. The same content is still published, but as XML in some cases. For this project:

| Need | Old SQL form | Status in 20260401 | Path |
| --- | --- | --- | --- |
| Page identity & namespace | `page.sql.gz` | ✅ available (2.3 GB) | direct SQL load (after MySQL→PG translation) |
| Current protection snapshot | `page_restrictions.sql.gz` | ✅ available (1.3 MB) | direct SQL load |
| Creation-protected titles | `protected_titles.sql.gz` | ✅ available (1.1 MB) | direct SQL load |
| Sysop list | `user_groups.sql.gz` | ✅ available (0.4 MB) | direct SQL load |
| Demoted admins | `user_former_groups.sql.gz` | ✅ available (small) | direct SQL load |
| Revert/mobile/etc. tags | `change_tag.sql.gz`, `change_tag_def.sql.gz` | ✅ available (4.8 GB + tiny) | direct SQL load |
| **Historical protection events** | `logging.sql.gz` | ❌ **not produced anymore** | use **`pages-logging.xml.gz`** (6.4 GB recombined; 27 splits) |
| **Revision metadata** | `revision.sql.gz` | ❌ **not produced anymore** | use **`stub-meta-history*.xml.gz`** (27 parts, ~225 GB compressed) |
| **Actor identity** | `actor.sql.gz` | ❌ **not produced anymore** | synthesize from `<contributor>` blocks in stub XML |
| **User accounts** | `user.sql.gz` | ❌ **never published** (privacy) | n/a — usernames come via stubs |

This means there is no pure-SQL path. The plan splits naturally into "things that come as `.sql.gz`" and "things that come as `.xml.gz` and need an `mwxml` parser writing INSERTs into our own tables".

## Phase 1a — Native-SQL tables (small, fast)

Target: ~9 GB compressed across 7 files, ~30–80 GB loaded.

Files to fetch:

- `enwiki-20260401-page.sql.gz` (2.3 GB) → `page` table
- `enwiki-20260401-page_restrictions.sql.gz` (1.3 MB) → `page_restrictions` (current protection snapshot)
- `enwiki-20260401-protected_titles.sql.gz` (1.1 MB) → `protected_titles` (creation-protected titles, **directly relevant to RFPP work**)
- `enwiki-20260401-user_groups.sql.gz` (0.4 MB) → `user_groups`
- `enwiki-20260401-user_former_groups.sql.gz` (small) → `user_former_groups` (demoted/desysopped admins)
- `enwiki-20260401-change_tag.sql.gz` (4.8 GB) → `change_tag` (revert flagging, etc.)
- `enwiki-20260401-change_tag_def.sql.gz` (<1 KB) → `change_tag_def`

Also fetch and store:

- `enwiki-20260401-md5sums.txt`, `enwiki-20260401-sha1sums.txt` (manifest)
- `dumpstatus.json` (job-level status, useful for later automation)

Steps:

1. **Downloader** (`download_dumps.py`, Python `requests`): streaming download to `/media/simone/ssd1/wikidumps/20260401/sql/`, SHA-1 verify against the manifest, resume on `Range: bytes=N-`, `User-Agent: SantoniWikipediaResearch/1.0 (simone.santoni.1@city.ac.uk)`, max 2 concurrent connections (WMF etiquette).

2. **MySQL → Postgres translation + load** (`load_sql_dumps.py`):
   - Hand-write Postgres DDL for each of the 7 tables, modeled on the MediaWiki schema but with Postgres types (`integer`, `bigint`, `bytea`, `text`, `timestamp`).
   - Stream the `.sql.gz`, extract `INSERT INTO ... VALUES (...)` rows, and feed them into Postgres via `COPY ... FROM STDIN` for throughput. Skip the dump's own `CREATE TABLE` (replaced by our hand-written DDL).
   - Bytea handling: `VARBINARY(N)` columns in MediaWiki (page titles, log_title, etc.) become `bytea` in Postgres — preserves byte-fidelity for any non-UTF-8 sequences.

3. **Sanity checks**: row counts per table compared against `dumpstatus.json` job summaries; spot-check `page_restrictions` against API state for a few known sysop-protected pages.

**Deliverable at end of 1a**: a queryable `wiki20260401` DB with page identity, current protection snapshot, creation-protected titles, sysop lists, and tag definitions.

## Phase 1b — Protection log via XML (~6.4 GB)

The `logging` table is no longer in SQL but **the same content** is in `pages-logging.xml.gz`. Loading it gives you the full historical protection log up to 2026-04-01.

Steps:

1. Download `enwiki-20260401-pages-logging.xml.gz` (single recombined file, 6.4 GB).
2. **Loader** (`load_logging_xml.py`): parse with `mwxml` (handles `<logitem>` elements), insert into a custom `logging` table modeled on MediaWiki's:

   ```sql
   CREATE TABLE logging (
     log_id        bigint PRIMARY KEY,
     log_type      text,
     log_action    text,
     log_timestamp timestamptz,
     log_actor     bigint,             -- synthesized actor id
     log_actor_name text,              -- denormalized for sanity
     log_namespace integer,
     log_title     bytea,              -- bytea for byte-safety
     log_page      bigint,
     log_comment   text,
     log_params    jsonb               -- parsed from the serialized blob
   );
   ```

3. **Parse `log_params` inline**: newer rows are JSON, older rows are PHP-serialized. Use `phpserialize` with a JSON fallback, materialize as `jsonb` directly during the import. JSONB lets you query `WHERE log_params->>'level' = 'sysop'` with a GIN index — a real ergonomic win over MariaDB's coarser JSON support and the reason we switched to Postgres.
4. Load **all log types**, not just `protect`/`unprotect`/`move_prot` — block/delete/move/etc. are useful covariates and the storage cost is negligible.
5. **Sanity check**: yearly count of `log_type='protect'` events should rise steeply from 2005 onward and match API-fetched counts in `fetch-protection-events/` to within a small delta.

**Deliverable at end of 1b**: full protection-event timeline. Largely supersedes the historical role of `fetch-protection-events/fetch_protection_log.py`; the API fetcher is now narrowed to "post-cutoff incremental" only.

## Phase 2 — Editor–page–time event backbone via stub-meta-history XML

For the polyadic hyperevent model. The legacy `revision.sql.gz` is gone; the equivalent content is in 27 `stub-meta-history*.xml.gz` parts totaling ~225 GB compressed.

1. Download all 27 `stub-meta-history*.xml.gz` files (parallel up to WMF's 2-concurrent-connection limit; resume-aware).
2. **Loader** (`load_stub_history_xml.py`): parse with `mwxml`, insert into:
   - A custom `revision` table: `rev_id`, `rev_page`, `rev_actor`, `rev_timestamp`, `rev_minor`, `rev_comment`, `rev_sha1`, `rev_len`, `rev_parent_id`.
   - A synthesized `actor` table built from `<contributor>` blocks: `actor_id`, `actor_name`, `actor_user_id`. Populate as a one-time deduplication during the same pass.
3. **Pre-load tweak**: drop indexes during bulk load, recreate after. Use unlogged tables during load → `ALTER TABLE … SET LOGGED` after, or a single big transaction with `wal_level=minimal` to avoid WAL bulk on the 225 GB import.
4. **Indexes for the access pattern**: `(rev_page, rev_timestamp, rev_actor)` covers the editor-on-page time-series query. Optional `(rev_actor, rev_timestamp)` for editor-centric queries.
5. **Filter discipline**: unlike the inherited pipeline, do **not** drop namespaces at load time. Filter at query time (article-only = `WHERE page_namespace = 0`; talk-page = odd namespaces).

**Deliverable at end of Phase 2**: editor–page–time event panel for any namespace, joined with the protection-event timeline from Phase 1b.

## Phase 3 — Wikitext content load

A planned phase, not optional. Enables content-level analyses on top of the editor-page-time backbone: protection-effect on edit churn, content drift before vs. after protection, citation-density shifts, revert detection via text identity. Reuses the streaming + `mwxml` + `COPY` pattern from Phase 2; the new wrinkle is that pages-meta-history is **7z-compressed** (not gzip), so the loader uses `py7zr`.

**Source files** (download with `python download_dumps.py --phase 3`):

- `enwiki-20260401-pages-meta-history*.xml.7z` — **956 sub-files** split by page-id range across 27 logical parts (job `metahistory7zdump`). **~270 GiB compressed total**; uncompressed body is several TB but the loader streams (no full extraction to disk).

**Schema addition** (`schema/revision_text.sql`, sourced from `00_apply.sql`):

```sql
CREATE TABLE revision_text (
  rev_id          bigint PRIMARY KEY REFERENCES revision(rev_id),
  rev_text        bytea,            -- byte-fidelity preserved
  rev_text_bytes  bigint            -- denormalized length, fast for stats
);
```

Keeps wikitext physically separate from revision metadata: the `revision` table stays small for fast scans/joins, and `revision_text` can later be moved to its own tablespace, partitioned, or compressed (PG TOAST handles this transparently for now).

**Loader** (`load_pages_meta_history_xml.py`):

- Stream-decompress `.xml.7z` via `py7zr`; never extract the full inner XML to disk.
- Parse with `mwxml`; for each `<revision>`, write a row to `revision_text`.
- Skip `<text deleted="deleted" />` rows (suppressed wikitext exists in `revision` but not here — that's why the `revision_text` count will be slightly less than `revision`).
- Drop the FK to `revision` during bulk load; restore after. Without this, the per-row FK check dominates wall time.
- `--workers N` to process N of the 27 parts in parallel via `ProcessPoolExecutor`. Default 1; up to 4 is reasonable on the SSD before WAL throughput becomes the bottleneck.
- Same per-session perf knobs as the other XML loaders (`synchronous_commit=OFF`, `maintenance_work_mem`, `work_mem`).

**Sanity check:** `SELECT COUNT(*) FROM revision_text` should be at most `COUNT(*) FROM revision` (delta = suppressed/deleted-text rows).

## Phase 4a — Reproducibility & handoff after Phase 2

DB at this point fully supports the project's core editor-page-time analyses without wikitext. This is a defensible scientific milestone: **freeze and document before starting Phase 3**, because Phase 3 takes days and any bug discovered mid-load shouldn't force a re-run of the cheaper phases.

Checklist (do all of these in order):

1. **Code freeze**: commit to the repo (no data files): `download_dumps.py`, `load_sql_dumps.py`, `load_logging_xml.py`, `load_stub_history_xml.py`, `schema/`, `setup_postgres18.sh`, `key_figures.sql`, `data_collection_plan.md`. Tag the commit `phase2-frozen`.
2. **Database snapshot**: `pg_dump -Fc --no-owner --no-privileges -d wiki20260401 -f /media/simone/ssd1/wikidumps/20260401/snapshots/wiki20260401_phase2.dump`. Custom-format dump; restorable on a fresh PG18 with `pg_restore`. Excludes `revision_text` (which doesn't exist yet). Expect ~50–100 GB.
3. **Numerical verification artifact**: `psql service=wiki -f key_figures.sql > /media/simone/ssd1/wikidumps/20260401/snapshots/key_figures_phase2.txt 2>&1`. This becomes the canonical "what the DB looks like at Phase 2" reference. A future re-run from raw dumps must reproduce these numbers exactly.
4. **MANIFEST update**: append to `/media/simone/ssd1/wikidumps/20260401/MANIFEST.md`: per-table row counts, total wall time per loader, snapshot path + SHA-1, `key_figures_phase2.txt` SHA-1.
5. **External sanity checks** before declaring done:
   - Sum of `revision` rows per stub-meta-history part matches the per-part `<revision>` counts in `dumpstatus.json` (within 1%; small differences come from suppressed revisions).
   - Yearly count of `log_type='protect'` events matches API-fetched counts in `fetch-protection-events/` to within 1%.
   - Hand-pick three pages with known protection histories (e.g., Donald_Trump, Climate_change, Anarchism); confirm `logging` returns plausible event sequences.

**Stop condition for Phase 4a**: every checklist item ✓; `key_figures_phase2.txt` exists; snapshot is in `snapshots/`. Only then start Phase 3.

## Phase 4b — Reproducibility & handoff after Phase 3

DB now also has wikitext. Repeat the freeze, with adjustments for the much larger data footprint.

Checklist:

1. **Code freeze**: commit `load_pages_meta_history_xml.py` and `schema/revision_text.sql`; updated `key_figures.sql` with content-level sentinels (avg/median wikitext bytes by year, revert-rate proxy via `rev_sha1` matching parent's `rev_sha1`, etc.). Tag the commit `phase3-frozen`.
2. **Database snapshot — schema-only this time**: `pg_dump -Fc --schema-only -d wiki20260401 -f .../snapshots/wiki20260401_phase3_schema.dump`. A full data dump would be multi-TB; not worth it when the source dumps + loaders are deterministic.
3. **Manifest of what was loaded**: don't dump the data — instead document everything needed to *reproduce* it. Append to MANIFEST: SHA-1s of all 27 `pages-meta-history*.xml.7z` files, the loader git commit hash, total wall time, observed `revision_text` row count, per-part rows-loaded breakdown.
4. **Numerical verification**: `psql service=wiki -f key_figures.sql > .../snapshots/key_figures_phase3.txt`. Includes the new content-level queries.
5. **Spot-check**: pick 5 known revisions from different years, fetch their `rev_text` from the DB, fetch the same revision's content from the live MediaWiki API, and confirm byte-identity. This catches subtle bugs in the 7z streaming + COPY round-trip that would otherwise only surface during analysis.

**Stop condition for Phase 4b**: every checklist item ✓; both snapshot artifacts exist; spot-check passed.

## What still needs the API

- **RFPP granted-vs-denied outcomes** — these live in talk-page wikitext (`Wikipedia:Requests for page protection/...`), not in any dump. `fetch-protection-events/fetch_rfpp.py` remains the right tool; the dump-loaded `logging` table is the "ground truth" to validate it against.

**Not needed**: bridging the dump cutoff to the present. The 2026-04-01 snapshot is sufficient for this project — `fetch_protection_log.py` is no longer load-bearing once Phase 1b is complete (it can stay in the sibling repo as historical infrastructure but won't be re-run for new data).

---

## Status snapshot — 2026-05-09 (evening)

A state-of-play check across host, schema, loaders, downloads, and DB contents. This section is a dated snapshot, not a re-plan; update or replace it on the next freeze.

### Phase 0 — host & DB setup: ✅ complete

- PostgreSQL **18.3** on cluster `main`, port `5434`, reachable as `psql service=wiki`.
- DB `wiki20260401`, owner `simone`, encoding `SQL_ASCII`, locale `C`.
- Tablespace `wiki_ts` → `/media/simone/ssd1/postgres-wiki/` (currently empty, 4 KB).
- Dump volume `/media/simone/ssd1` has **6.9 TB free** of 7.3 TB — comfortable headroom for Phase 2 (~225 GB) and Phase 3 (~270 GB) raw inputs plus loaded data.
- Reproducible via [setup_postgres18.sh](setup_postgres18.sh) and [relocate_mariadb_datadir.sh](relocate_mariadb_datadir.sh).

### Schema: ✅ all 11 tables created, all empty

[schema/](schema/) holds hand-written DDL in 13 files: `page`, `page_restrictions`, `protected_titles`, `user_groups`, `user_former_groups`, `change_tag`, `change_tag_def`, `logging`, `revision`, `actor`, `revision_text`, plus [indexes.sql](schema/indexes.sql) and an apply orchestrator [00_apply.sql](schema/00_apply.sql). Postgres reflects this — 11 tables present, **0 rows in every one**.

### Loaders: ✅ written, ❌ not yet run at scale

| Loader | Target | Status |
| --- | --- | --- |
| [download_dumps.py](download_dumps.py) | streaming download + SHA-1 verify + MANIFEST | ✅ exercised on 2 files |
| [load_sql_dumps.py](load_sql_dumps.py) | Phase 1a SQL → COPY | written, untried (only the smallest input is on disk) |
| [load_logging_xml.py](load_logging_xml.py) | Phase 1b protection log XML | written, untried |
| [load_stub_history_xml.py](load_stub_history_xml.py) | Phase 2 stub-meta-history | written, untried |
| [load_pages_meta_history_xml.py](load_pages_meta_history_xml.py) | Phase 3 wikitext | written + has a sibling [test_load_pages_meta_history_xml.py](test_load_pages_meta_history_xml.py) |
| [freeze_phase2.sh](freeze_phase2.sh), [freeze_phase3.sh](freeze_phase3.sh) | post-load handoff: pg_dump + key_figures snapshot + SHA-1s appended to MANIFEST | written, idempotent guards in place |

### Downloads: 🟡 minimal — mostly smoke tests

Inside `/media/simone/ssd1/wikidumps/20260401/`:

```text
sql/  enwiki-20260401-user_groups.sql.gz             414 KB   ✓ SHA-1 verified
xml/  enwiki-20260401-pages-logging1.xml.gz          266 MB   ✓ SHA-1 verified
xml/  enwiki-20260401-stub-meta-current1.xml.gz      4.2 MB   (not in MANIFEST — likely an ad-hoc test)
checksums/                                           empty
dumpstatus.json                                      cached (616 KB)
MANIFEST.md                                          2 entries
```

**Total fetched: ~272 MB.** Target across Phases 1a + 1b + 2 is **~240 GB**, so we are at roughly **0.1 %** of planned download volume.

**Discrepancy to resolve**: Phase 1b above describes `pages-logging.xml.gz` as a single recombined file (6.4 GB), but the WMF run is actually publishing it as ~27 split parts (`pages-logging1`, `2`, …). The fetched file `pages-logging1.xml.gz` is part 1 only — either update Phase 1b to reflect splits, or extend [download_dumps.py](download_dumps.py) with a recombiner step.

### What is genuinely loaded in Postgres: nothing

```text
relname             rows    size
all 11 tables       0       8 KB each (catalog only)
```

Database size is **8.5 MB** — just metadata for 11 empty tables. Tablespace `wiki_ts` on the SSD has **4 KB used**.

### Code repository state

- `git status` for [official-dump/](.):
  - `M CLAUDE.md`
  - **Everything else is untracked** — all loaders, the schema/ directory, both freeze scripts, this plan, [download_dumps.py](download_dumps.py), [setup_postgres18.sh](setup_postgres18.sh), [relocate_mariadb_datadir.sh](relocate_mariadb_datadir.sh), [key_figures.sql](key_figures.sql), [result_export.json](result_export.json).
- Last commits: only `6c1c959 initial commit` and `4b94e14 Initial commit`. **None of the new infrastructure is committed yet** — a power loss or accidental delete would lose ~24 hours of work.

### Summary

**Infrastructure: ~95 % done.** Postgres 18 is live, schema is in, loaders are written for all four phases (including the originally-optional Phase 3), and freeze automation exists for both Phase 2 and Phase 3 milestones.

**Data: ~0 % done.** Two small files have been download-tested end-to-end with SHA-1 verification, the manifest writer works, but no bulk download has run and Postgres holds no rows.

**Most pressing next steps, in order:**

1. **Commit the working tree.** A day-plus of scaffolding sits untracked.
2. **Reconcile the Phase 1b split-vs-recombined assumption** in either the plan or `download_dumps.py`.
3. Kick off the **full Phase 1a + 1b download** (~15 GB total, well under an hour) and run the matching loaders end-to-end — the smallest scope that actually proves the pipeline works on real data.
4. Only after that, start the Phase 2 stub-history pull (~225 GB, multi-day).
