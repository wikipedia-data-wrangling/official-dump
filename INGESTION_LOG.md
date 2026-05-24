# Ingestion Log — enwiki 20260401 → `wiki20260401`

A **living status + activity log** for the data-gathering and ingestion pipeline.
Read [data_collection_plan.md](data_collection_plan.md) for the *plan* (phases,
locked decisions, schema rationale); read **this file** for *where things
actually stand right now*. This supersedes the dated "Status snapshot —
2026-05-09" section at the bottom of the plan.

Last updated: **2026-05-24 01:55**

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

### 2026-05-24 — Phase 2 UniqueViolation; loader patched + restarted at workers=6

- The 2026-05-17 restart of the loader ran for ~3.3 days and **crashed at
  21:01:12 on 2026-05-20** with
  `psycopg.errors.UniqueViolation: duplicate key value violates unique
  constraint "revision_pkey"`, DETAIL `Key (rev_id)=(711706) already
  exists`. The exception only surfaced ~3 days later when `status` was
  checked — `as_completed` had been collecting other workers' results in
  the background while the failed file's future sat waiting.
- All 26 *other* files completed cleanly (`done: seen=…` lines for
  files 1–6, 8–27). File 7's worker hit the duplicate mid-COPY, raised,
  and the ProcessPoolExecutor pool kept the other workers going. Final
  DB state at the catch: **1,243,967,331 revision rows** (~83 % of the
  expected ~1.5 B); indexes still dropped.
- **Root cause**: the WMF 20260401 `stub-meta-history*.xml.gz` splits
  are **not strictly disjoint by `rev_id`**. The duplicate rev_id 711706
  (page 23639 "Gasoline", first revision 2001-09-24) appears in at
  least two split files (1 and 11; confirmed by `zgrep`). The loader's
  direct `COPY ... FROM STDIN` into `revision` therefore hit the PK the
  moment any later worker's batch contained an already-inserted rev_id.
  The split-disjointness assumption was implicit and undocumented.
- **Fix in `8ea1b1b`**: `copy_batch` now uses a per-session TEMP
  staging table `_rev_stage` (no PK). Each batch: `TRUNCATE _rev_stage`
  → `COPY` into staging → `INSERT INTO revision (...) SELECT DISTINCT
  ON (rev_id) ... FROM _rev_stage ON CONFLICT (rev_id) DO NOTHING`.
  DISTINCT ON guards against intra-batch duplicates; ON CONFLICT guards
  against cross-batch / cross-file duplicates. Loader is now idempotent
  under both dump-overlap *and* arbitrary re-runs. Smoke-tested against
  the real DB before the restart.
- Loader restarted at **01:52 on 2026-05-24** in tmux `stub-load`,
  `--workers 6` (user-authorized after diagnostic showed 20 cores, 100 %
  CPU per worker at `--workers 2`, ~21 % overall system utilisation).
  TRUNCATE wiped the 1.24 B rows; expected wall time at 6 workers:
  ~28–36 h, assuming sub-linear scaling from the staging-table overhead
  and any PG-side contention.
- **Phase 3 download is running in parallel** (`download_dumps.py
  --phase 3` in tmux `phase3`, started 01:08 by user). Network-bound
  (~5 MB/s per file), no compete with the CPU/PG-bound loader. Disk at
  292 GB / 7.3 TB used.

### 2026-05-17 — Phase 2 loader killed by apt upgrade; restarted from scratch

- Loader ran cleanly from 19:56:37 on 2026-05-16 for ~100 min,
  reaching **21,250,000 revisions** at a sustained ~3.8 k combined
  rev/s before dying with
  `psycopg.errors.AdminShutdown: terminating connection due to
  administrator command`.
- Root cause: `dpkg.log` shows `postgresql-18` was upgraded from
  18.3 → **18.4** (`18.4-1.pgdg22.04+1`) at 21:34:31 BST; the package
  post-install restarted the service at 21:32:30, which terminated
  all client connections. `unattended-upgrades.log` does NOT show
  this — PGDG is outside Ubuntu's security-only auto-update scope —
  so the upgrade was triggered by GNOME Software auto-update or a
  manual `apt upgrade`. PG 18.3 → 18.4 is a point release, so the
  loaded data is untouched.
- **Mitigation for the next run**: optionally
  `sudo apt-mark hold postgresql-18 postgresql-18-jit postgresql-client-18 postgresql`
  to block PGDG upgrades during the load; `apt-mark unhold` to
  release after `freeze2`. Not done automatically (system-level
  change requires explicit auth).
- Loader restarted at **19:40 on 2026-05-17** in tmux `stub-load`,
  log `load_stub_history_20260517_194000.log`. TRUNCATE wiped the
  21 M revisions; starting from scratch.

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
- **Performance caveat hit immediately** — first `--workers 2` run did
  collapse, but for a different reason than the Phase 1b post-mortem
  predicted. The `ActorResolver` SELECT fallback used
  `actor_user IS NOT DISTINCT FROM $1` (so NULL anon and integer user-id
  could share one query), but **that operator is not sargable against
  the `(actor_user, actor_name)` btree** — Postgres planned a parallel
  seq scan over all 51 M+ Phase-1b actors at **1,439 ms per lookup**
  (measured via EXPLAIN ANALYZE). Workers sat at near-0% CPU waiting
  on PG.
- **Fix in `539a98b`**: split the SELECT into two prepared statements
  (`actor_user = $1 …` for registered, `actor_user IS NULL …` for
  anon) — both forms hit the index in ~0.2 ms / ~4 ms. Also flipped to
  SELECT-then-INSERT (Phase 2 starts at 51 M actors, so the common case
  is a hit; the prior INSERT-then-fallback wasted a round-trip per
  resolution). Smoke-tested against the real DB before restart.
- Loader restarted at 19:50:27 with the sargability fix. Worker 1
  immediately CPU-bound at ~81 %, but the run stalled again after only
  100 k revisions inserted. **Second root cause**: inter-worker lock
  contention. Each worker held a long-lived implicit transaction across
  one entire `BATCH_SIZE=50 000` batch (~10 s), and any actor INSERT
  done inside that transaction locked the `(actor_user, actor_name)`
  row until commit. The sibling worker's INSERT…ON CONFLICT on any
  overlapping key blocked on `Lock: transactionid` for the full batch
  duration. `pg_blocking_pids()` showed worker B blocked by worker A's
  `idle in transaction` connection on the actor INSERT.
- **Fix in `0bf5846`**: `ActorResolver` now owns its OWN psycopg
  connection with `autocommit=True`, separate from the worker's main
  COPY connection. Actor inserts commit in ms; the COPY connection
  keeps its long-lived per-batch transaction. Also flipped
  `SET LOCAL synchronous_commit = OFF` → plain `SET` on the main
  connection, because LOCAL settings reset on each commit and the
  perf knobs were silently being lost after the very first batch.
- Loader restarted at 19:53:18 with the lock fix. Both workers active,
  no transactionid waits, but combined throughput capped at **~2 k
  rev/s** — much less than expected. **Third root cause**: each actor
  INSERT in the autocommit connection triggered a WAL fsync (~5 ms).
  At ~10 % cache miss rate per worker that was the dominant cost.
- **Fix in `1c4ee7f`**: `SET synchronous_commit = OFF` on the
  ActorResolver's autocommit connection too. Safe — actor inserts are
  idempotent (`ON CONFLICT`) and the in-memory LRU is rebuilt from
  scratch on each loader start, so losing a fsync window costs
  nothing on a crash.
- Loader restarted at 19:56:37 with all four fixes. Cold-start rates
  per worker hit ~3.1 k / 2.7 k rev/s (combined ~5.85 k) — **~3× the
  pre-fix combined rate**. Marginal rate gradually drifted toward
  ~1.7 k/worker over the first few hundred-k revisions; LRU is likely
  filling up and miss rate is rising. Combined ~3.5 k rev/s
  sustained — still above threshold. For 1.5 B revisions that's an
  ETA of ~5 days. Will monitor; if it drops below ~3 k combined,
  consider raising `ActorResolver.max_size` from 1 M or backporting
  the Phase 1b TEMP-table batched resolver.

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
- **Watch the rows/s figure once the first progress line lands.** With
  the sargability fix in `539a98b`, expectations: ~5–15 k rev/s per
  worker depending on cache-hit ratio. If it sits below ~2 k rev/s
  sustained, the per-row resolver may still be the bottleneck and a
  backport of Phase 1b's batched `resolve_batch` (TEMP table + JOIN) is
  the next escalation.

## Related: API-side collection (sibling repo)

[../fetch-protection-events/](../fetch-protection-events/) holds the MediaWiki
**API** fetchers — `fetch_protection_log.py` and `fetch_rfpp.py`. The dump
pipeline here is the bulk/ground-truth source; the API side covers what dumps
don't carry — chiefly **RFPP granted-vs-denied outcomes** in talk-page
wikitext. Tracked separately in that repo.
