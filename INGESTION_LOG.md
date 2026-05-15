# Ingestion Log — enwiki 20260401 → `wiki20260401`

A **living status + activity log** for the data-gathering and ingestion pipeline.
Read [data_collection_plan.md](data_collection_plan.md) for the *plan* (phases,
locked decisions, schema rationale); read **this file** for *where things
actually stand right now*. This supersedes the dated "Status snapshot —
2026-05-09" section at the bottom of the plan.

Last updated: **2026-05-14 18:30**

---

## Current state at a glance

| Phase | What it loads | Source on disk | DB tables | State |
| --- | --- | --- | --- | --- |
| **0** — host & schema | PG18 cluster, 11-table schema | — | — | ✅ **done** |
| **1a** — native SQL dumps | page metadata, restrictions, tags, user groups | ✅ 7 files, 6.9 GB | `page`, `page_restrictions`, `protected_titles`, `user_groups`, `user_former_groups`, `change_tag`, `change_tag_def` | ✅ **done** |
| **1b** — protection log XML | historical log events | ✅ recombined `pages-logging.xml.gz`, 6.69 GB | `logging` (+ shared `actor`) | 🟡 **running now** |
| **2** — stub-meta-history XML | revision metadata (editor–page–time) | ❌ not downloaded | `revision`, `actor` | ⬜ not started |
| **3** — pages-meta-history XML | revision wikitext | ❌ not downloaded | `revision_text` | ⬜ not started |
| **4** — freeze / verify | pg_dump + `key_figures` snapshots | — | — | ⬜ not started |

## What is loaded in Postgres (as of 2026-05-14 18:30)

| Table | Rows | Notes |
| --- | --- | --- |
| `page` | 65,414,499 | Phase 1a |
| `change_tag` | 545,880,887 | Phase 1a |
| `change_tag_def` | 335 | Phase 1a |
| `page_restrictions` | 192,836 | Phase 1a — current protection state |
| `protected_titles` | 58,920 | Phase 1a — protected non-existent pages |
| `user_groups` | 103,060 | Phase 1a |
| `user_former_groups` | 22,004 | Phase 1a |
| `logging` | ~45.3 M ↑ | Phase 1b **in progress** — climbing |
| `actor` | ~20.3 M ↑ | shared; grows with `logging`, later with `revision` |
| `revision` | 0 | Phase 2 not started |
| `revision_text` | 0 | Phase 3 not started |

Raw dumps live at `/media/simone/ssd1/wikidumps/20260401/{sql,xml}/`.
No freeze snapshots exist yet (`snapshots/` not created).

---

## Activity log (most recent first)

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

1. **Let Phase 1b finish.** Watch via `tmux attach -t logging-load`. On a
   clean finish it rebuilds 5 `logging` indexes (the GIN one is slow) and
   `ANALYZE`s. Then sanity-check with [key_figures.sql](key_figures.sql).
2. **Phase 2 download + load** — `stub-meta-history*.xml.gz` (~225 GB, 27
   parts, multi-day). Not yet downloaded. Run via `./run_pipeline.sh phase2`.
3. **`freeze2`** — pg_dump + `key_figures_phase2.txt` + git tag.
4. **Phase 3** — `pages-meta-history*.xml.7z` wikitext (~270 GB), only if
   the analysis needs revision text. Then `freeze3`.

## Open issues / watch-outs

- **`logging` is unindexed right now.** If the running load is interrupted
  again, indexes stay dropped until a run completes cleanly. Prefer to let
  it finish; otherwise rebuild manually from [schema/indexes.sql](schema/indexes.sql).
- **Total `logging` row count is unknown** until the run completes — no
  reliable ETA for Phase 1b. (Dump `max(log_id)` ≈ 52.6 M, but log_ids are
  sparse.)
- **`actor` is shared** between the Phase 1b and Phase 2 loaders — never
  `TRUNCATE` it; both use `ON CONFLICT` dedup.
- Uncommitted in the working tree: `load_logging_xml.py` (today's
  optimisation), `.vscode/settings.json`, plus untracked
  `namespaces_diagram.{tex,pdf}`. Commit the loader change once Phase 1b
  verifies clean.

## Related: API-side collection (sibling repo)

[../fetch-protection-events/](../fetch-protection-events/) holds the MediaWiki
**API** fetchers — `fetch_protection_log.py` and `fetch_rfpp.py`. The dump
pipeline here is the bulk/ground-truth source; the API side covers what dumps
don't carry — chiefly **RFPP granted-vs-denied outcomes** in talk-page
wikitext. Tracked separately in that repo.
