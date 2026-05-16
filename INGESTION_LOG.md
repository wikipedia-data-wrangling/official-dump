# Ingestion Log — enwiki 20260401 → `wiki20260401`

A **living status + activity log** for the data-gathering and ingestion pipeline.
Read [data_collection_plan.md](data_collection_plan.md) for the *plan* (phases,
locked decisions, schema rationale); read **this file** for *where things
actually stand right now*. This supersedes the dated "Status snapshot —
2026-05-09" section at the bottom of the plan.

Last updated: **2026-05-16 09:30**

---

## Current state at a glance

| Phase | What it loads | Source on disk | DB tables | State |
| --- | --- | --- | --- | --- |
| **0** — host & schema | PG18 cluster, 11-table schema | — | — | ✅ **done** |
| **1a** — native SQL dumps | page metadata, restrictions, tags, user groups | ✅ 7 files, 6.9 GB | `page`, `page_restrictions`, `protected_titles`, `user_groups`, `user_former_groups`, `change_tag`, `change_tag_def` | ✅ **done** |
| **1b** — protection log XML | historical log events | ✅ recombined `pages-logging.xml.gz`, 6.69 GB | `logging` (+ shared `actor`) | ✅ **done** |
| **2** — stub-meta-history XML | revision metadata (editor–page–time) | ❌ not downloaded | `revision`, `actor` | ⬜ not started |
| **3** — pages-meta-history XML | revision wikitext | ❌ not downloaded | `revision_text` | ⬜ not started |
| **4** — freeze / verify | pg_dump + `key_figures` snapshots | — | — | ⬜ not started |

## What is loaded in Postgres (as of 2026-05-16 09:30)

| Table | Rows | Notes |
| --- | --- | --- |
| `page` | 65,401,140 | Phase 1a |
| `change_tag` | 546,583,142 | Phase 1a |
| `change_tag_def` | 335 | Phase 1a |
| `page_restrictions` | 192,836 | Phase 1a — current protection state |
| `protected_titles` | 58,920 | Phase 1a — protected non-existent pages |
| `user_groups` | 103,060 | Phase 1a |
| `user_former_groups` | 22,004 | Phase 1a |
| `logging` | 157,840,090 | Phase 1b ✅ — indexes rebuilt + `ANALYZE` done |
| `actor` | 51,427,383 | shared; 51,124,222 registered + 303,161 anon |
| `revision` | 0 | Phase 2 not started |
| `revision_text` | 0 | Phase 3 not started |

Raw dumps live at `/media/simone/ssd1/wikidumps/20260401/{sql,xml}/`.
No freeze snapshots exist yet (`snapshots/` not created); a sanity-only
`key_figures` capture from the end of Phase 1b is kept in-repo at
[key_figures_post_phase1b_20260516.txt](key_figures_post_phase1b_20260516.txt).

---

## Activity log (most recent first)

### 2026-05-16 — Phase 1b complete

- Loader hit `DONE in 139178.6s` at **08:25:03** (run started 17:45 on
  05-14, ~38.7 h wall time). Final tally: `seen=157,840,101
  inserted=114,440,090` — the inserted count is just the new rows added by
  this resumed run; the prior interrupted run had already loaded ~43.4 M.
  Database now reports **157,840,090** `logging` rows (matches `seen` to
  within 11; the discrepancy is the expected dedup against PK).
- All 5 indexes rebuilt cleanly on the same run (timings, longest last):
  `logging_type_timestamp_idx` 239.8 s, `logging_namespace_title_idx` 195.6
  s, `logging_page_idx` 14.9 s, `logging_actor_idx` 84.4 s,
  `logging_params_gin_idx` **489.0 s** (the GIN over `log_params jsonb`).
  Followed by `ANALYZE logging, actor`. `logging` is now queryable.
- Top `log_type` rows (from the loader's final summary, mirrored in the
  `key_figures` snapshot): `newusers` 51.5 M, `block` 28.6 M, `create`
  22.2 M, `delete` 18.6 M, `move` 9.2 M, `patrol` 7.7 M, `upload` 5.3 M.
  **`protect` = 842,471** events total, with the yearly shape rising
  steeply from 2004 (129) to 2008 peak (~81 k) then settling at 30–50 k/yr
  — matches the proposal's qualitative description.
- `actor` table: **51,427,383** rows (51,124,222 registered + 303,161
  anon). This is the floor for Phase 2 — `load_stub_history_xml.py` will
  add revision contributors that don't appear in the log.
- Ran [key_figures.sql](key_figures.sql) end-to-end; saved as
  [key_figures_post_phase1b_20260516.txt](key_figures_post_phase1b_20260516.txt).
  Not a formal Phase 4a freeze (that's after Phase 2) — just a sanity
  capture so we can diff later if anything looks off downstream.
- `tmux` session `logging-load` killed.

### 2026-05-14 — Phase 1b loader optimised & resumed
- A prior `--resume` run of [load_logging_xml.py](load_logging_xml.py) was
  crawling at ~536 rows/s (avg, incl. fast-forward) and was interrupted
  manually (`Ctrl-C` ~17:35).
- Diagnosed three bottlenecks and fixed them in the loader:
  1. **Per-row actor round-trips** → `ActorRegistry.resolve_batch()`: cache
     misses for a whole batch go through a session `TEMP` table + one
     `INSERT … SELECT … ON CONFLICT` + one join. (~19 M distinct actors vs a
     1 M LRU made the old per-row path near-100 % miss in `newusers` regions.)
  2. **iterparse memory leak** — `<mediawiki>` root accumulated ~50 M emptied
     `<logitem>` shells; now `root.clear()` after each item.
  3. `BATCH_SIZE` 5000 → 10000.
- Verified: in-script `--self-test` passes; real-DB smoke test of
  `resolve_batch` confirmed correct ids, zero spurious `actor` rows.
- Resumed at 17:45 in **tmux session `logging-load`**, logging to
  `load_logging_20260401_174523.log`. Fast-forward ~31 k items/s; insert
  phase steady at **~1,550 rows/s** (~5× the prior rate).
- Indexes on `logging` are **dropped** for the duration; they are rebuilt
  only on a clean finish. Do not query `logging` for analysis until `DONE`.

### ~2026-05-09 → 05-14 — Phase 1a complete, Phase 1b begun
- All 7 native SQL dumps downloaded (6.9 GB) and loaded via
  [load_sql_dumps.py](load_sql_dumps.py); committed as `cec34f8 load dumps
  onto sql`.
- Recombined `enwiki-20260401-pages-logging.xml.gz` (6.69 GB) downloaded
  — resolves the old "27 splits vs 1 recombined file" discrepancy; the
  loader's `DEFAULT_FILE` points at this single file.
- First Phase 1b load run(s): reached ~43.4 M `logging` rows before the
  slow resume run noted above.

### 2026-05-09 — infrastructure stood up
- PostgreSQL 18.3, cluster `main`, port 5434, DB `wiki20260401`,
  `SQL_ASCII`/`C`, tablespace `wiki_ts` on `/media/simone/ssd1/`.
- 11-table schema applied from [schema/](schema/); all loaders + freeze
  scripts written. (See plan's 2026-05-09 snapshot for detail.)

---

## What's next

1. **Phase 2 download + load** — `stub-meta-history*.xml.gz` (~225 GB, 27
   parts, multi-day). Not yet downloaded. Run via `./run_pipeline.sh phase2`
   inside a fresh `tmux` session. Loader is `load_stub_history_xml.py`;
   targets `revision` (currently 0 rows) and continues writing into the
   shared `actor`.
2. **`freeze2`** — pg_dump + `key_figures_phase2.txt` + git tag
   `phase2-frozen`. See the Phase 4a checklist in
   [data_collection_plan.md](data_collection_plan.md).
3. **Phase 3** — `pages-meta-history*.xml.7z` wikitext (~270 GB), only if
   the analysis needs revision text. Then `freeze3`.

## Open issues / watch-outs

- **`actor` is shared** between the Phase 1b and Phase 2 loaders — never
  `TRUNCATE` it; both use `ON CONFLICT` dedup. The Phase 2 loader will
  start from a 51.4 M-row baseline rather than empty.
- **Phase 2 download is the largest cheap step**: ~225 GB compressed over
  27 parts at WMF's 2-concurrent-connection cap. Plan for it to finish
  overnight at best, multi-day at worst depending on mirror speed; the
  downloader is resume-aware (`Range: bytes=N-`) so an interrupted run
  picks up cleanly.
- Working tree is clean as of the start of today's session
  (`load_logging_xml.py` optimisation + INGESTION_LOG.md baseline are
  already in commit `4dd6931`).

## Related: API-side collection (sibling repo)

[../fetch-protection-events/](../fetch-protection-events/) holds the MediaWiki
**API** fetchers — `fetch_protection_log.py` and `fetch_rfpp.py`. The dump
pipeline here is the bulk/ground-truth source; the API side covers what dumps
don't carry — chiefly **RFPP granted-vs-denied outcomes** in talk-page
wikitext. Tracked separately in that repo.
