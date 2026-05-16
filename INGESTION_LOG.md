# Ingestion Log — enwiki 20260401 → `wiki20260401`

A **living status + activity log** for the data-gathering and ingestion pipeline.
Read [data_collection_plan.md](data_collection_plan.md) for the *plan* (phases,
locked decisions, schema rationale); read **this file** for *where things
actually stand right now*. This supersedes the dated "Status snapshot —
2026-05-09" section at the bottom of the plan.

Last updated: **2026-05-16 19:50**

---

## Current state at a glance

| Phase | What it loads | Source on disk | DB tables | State |
| --- | --- | --- | --- | --- |
| **0** — host & schema | PG18 cluster, 11-table schema | — | — | ✅ **done** |
| **1a** — native SQL dumps | page metadata, restrictions, tags, user groups | ✅ 7 files, 6.9 GB | `page`, `page_restrictions`, `protected_titles`, `user_groups`, `user_former_groups`, `change_tag`, `change_tag_def` | ✅ **done** |
| **1b** — protection log XML | historical log events | ✅ recombined `pages-logging.xml.gz`, 6.69 GB | `logging` (+ shared `actor`) | ✅ **done** |
| **2** — stub-meta-history XML | revision metadata (editor–page–time) | ✅ 27 parts, 113 GB on disk, SHA-1 verified | `revision`, `actor` | 🟡 **load running now** |
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

### 2026-05-16 (evening) — Phase 2 download done; loader started

- Phase 2 download finished cleanly during the day. All 27
  `stub-meta-history{1..27}.xml.gz` parts on disk under
  `/media/simone/ssd1/wikidumps/20260401/xml/` at expected sizes; SHA-1
  re-verified end-to-end via `download_dumps.py --phase 2` (all 35 files
  report `OK already complete`). Disk usage rose 153 GB → 266 GB
  (+113 GB compressed, matches plan).
- **Bug caught pre-download**: the Phase 2 file-selector regex matched
  both the 115 GiB recombined monolith *and* the 27 split parts — same
  bytes packaged two ways. Would have wasted ~115 GiB and made the
  loader double-insert every revision (PK collisions at best). Fixed in
  `9c09c5c`: tightened both `download_dumps.select_files` and
  `load_stub_history_xml.discover_files` to require a numeric suffix.
- **Bug caught at loader start**: first `--workers 2` run aborted on
  `TRUNCATE revision` with `cannot truncate a table referenced in a
  foreign key constraint` — schema declares
  `revision_text.rev_id -> revision.rev_id`. Postgres enforces the FK
  structurally, not by row count, so the empty `revision_text` didn't
  save us. Fixed in `5a84920`: `TRUNCATE TABLE revision CASCADE`. Safe
  because Phase 3 (which fills `revision_text`) runs strictly after
  Phase 2, and a Phase 2 re-run logically invalidates any
  `revision_text` rows anyway.
- Loader restarted in **tmux session `stub-load`**, log
  `load_stub_history_20260516_194714.log`. Indexes dropped + TRUNCATE
  CASCADE completed at 19:47:14. Workers spinning up against the 27
  parts in `--workers 2` mode.
- **Performance caveat** to watch: this loader uses the per-row
  `INSERT ... ON CONFLICT ... RETURNING actor_id` pattern for the shared
  `actor` table (with an LRU per-process), **not** the batched
  `resolve_batch` optimization that rescued Phase 1b. Should be OK
  because revisions are heavily skewed toward a small set of high-edit
  editors (high cache hit rate), unlike the `newusers` log events that
  destroyed Phase 1b's pre-optimisation throughput. If it crawls,
  backport the batched pattern.

### 2026-05-16 (morning) — Phase 1b complete

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

1. **Let Phase 2 loader finish.** Watch via
   `tmux attach -t stub-load` or
   `tail -f load_stub_history_20260516_194714.log`. On a clean finish it
   re-creates 3 `revision` indexes (the `(rev_page, rev_timestamp,
   rev_actor)` composite is the load-bearing one for the hyperevent
   model) and `ANALYZE`s `revision`. Then run
   [key_figures.sql](key_figures.sql) and diff against
   `key_figures_post_phase1b_20260516.txt` — `revision` should jump from
   0 to ~1.5–2 B rows, `actor` should grow from 51.4 M as revision
   contributors are added.
2. **`freeze2`** — `./run_pipeline.sh freeze2`: `pg_dump` (custom format)
   + `key_figures_phase2.txt` + git tag `phase2-frozen`. See the Phase 4a
   checklist in [data_collection_plan.md](data_collection_plan.md).
3. **Phase 3** — `pages-meta-history*.xml.7z` wikitext (~270 GB), only if
   the analysis needs revision text. Then `freeze3`.

## Open issues / watch-outs

- **`actor` is shared** between the Phase 1b and Phase 2 loaders — never
  `TRUNCATE` it; both use `ON CONFLICT` dedup. The Phase 2 loader started
  from the 51.4 M-row Phase-1b baseline.
- **`revision` is unindexed** for the duration of the Phase 2 load. If
  the loader is interrupted, indexes stay dropped until a clean run
  finishes. Prefer to let it finish; otherwise rebuild manually from
  [schema/indexes.sql](schema/indexes.sql) (revision-* entries only).
- **Loader does per-row `actor` INSERTs**, not the batched `resolve_batch`
  pattern from the Phase 1b post-mortem. Likely fine because of the
  high-skew editor distribution, but watch the rows/s figure once the
  first progress line lands. If it sits below ~5 k rows/s sustained, kill
  and backport the batch pattern before letting it grind for days.

## Related: API-side collection (sibling repo)

[../fetch-protection-events/](../fetch-protection-events/) holds the MediaWiki
**API** fetchers — `fetch_protection_log.py` and `fetch_rfpp.py`. The dump
pipeline here is the bulk/ground-truth source; the API side covers what dumps
don't carry — chiefly **RFPP granted-vs-denied outcomes** in talk-page
wikitext. Tracked separately in that repo.
