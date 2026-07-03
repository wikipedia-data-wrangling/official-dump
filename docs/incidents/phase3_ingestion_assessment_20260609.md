# Phase 3 ingestion assessment — 2026-06-09 (mid-flight)

Honest, balanced read of the Phase 3 wikitext ingestion to date. Written
~24 % through the cut-list (147 / 606 files done after the
post-optimization restart; ~46 % through by row count if you include the
~393 M rows preserved from the pre-crash run).

## Bottom line

**Provisionally successful so far; formally successful after `freeze_phase3.sh`'s spot-check on ~23 Jun.**

> The *data* is good — clean, verifiable, schema-faithful, no loss.
> The *process* has been bumpy in ways that are partly avoidable.
> "Successful" in the research sense will be true once Phase 3 finishes
> and the freeze spot-check confirms wikitext matches the live MediaWiki
> API.

---

## What's gone right (the substance)

- **956 source `.7z` files downloaded, SHA-1 verified**, byte-perfect
  against `dumpstatus.json`. No silent corruption.
- **577 M wikitext revisions loaded so far with zero data loss** — even
  through:
  - a `UniqueViolation` crash (rev_id 711706 / "Gasoline", same overlap
    bug Phase 2 hit; staged-table fix shipped)
  - a `/dev/sdc` disk-full event
  - a full 6.5 TB cross-drive tablespace migration via `ALTER DATABASE …
    SET TABLESPACE`
  - an external-HDD performance collapse from random PK lookups
- **No data corruption signal**:
  - `skipped_no_revision_match = 0` across every completed file — every
    `rev_id` in the wikitext maps to a real `revision` row
  - `skipped_text_deleted` matches the WMF dump's `<text
    deleted="deleted"/>` markers (expected, not a quality issue)
- **All schema invariants intact**:
  - `rev_id` PK uniqueness preserved via the staging table +
    `INSERT … SELECT DISTINCT ON (rev_id) … ON CONFLICT (rev_id) DO NOTHING`
    pattern
  - The `revision_text.rev_id → revision.rev_id` FK is recreatable at end
    (dropped during load by design)
- **Durable engineering improvements** captured in the codebase, not just
  one-off hacks:
  - `META_HISTORY_GLOB` correctly matches the page-range-suffixed
    `.xml-pNpM.7z` files
  - `7zz` subprocess swap replaces `py7zr` (~50–100 × decompression
    speedup)
  - Staging-table `copy_batch` pattern (now provably idempotent under
    re-runs and cross-file dump overlap)
  - `_init_worker_logging` initializer for `ProcessPoolExecutor` children
  - `PROGRESS_EVERY` lowered to 10 k for fine-grained telemetry
  - NVMe-resident PK indexes on `wiki_ts_sys` for fast random lookups
  - `--skip-revision-check` flag honored once the rev_id-existence
    invariant is established by Phase 2

## What's gone less well (the process)

- **Original `run_pipeline.sh` docstring promised "multi-day" Phase 3.**
  Actual: ~4 weeks. ~10 × misestimate that was partly knowable at the
  time (full dump size + external-HDD characteristics).
- **My ETA point-estimates have been wildly inconsistent**: 4.6 years →
  6 months → 5–7 days → 14 days. Each was internally consistent given
  the rate observed at that moment, but several were under-grounded.
  Treat my point estimates with appropriate skepticism; the wide
  bands have been the honest signal.
- **Required substantial emergency intervention**:
  - Disk-full event mid-load (`/dev/sdc` 100 %)
  - Performance collapse to 42 rev/s combined (the lacie14
    random-I/O bottleneck)
  - Off-by-one boundary on the `--files` cut: assumed `350` and the
    crash record said `350`, so I went with `SKIP=350` — but the
    in-flight file was already mid-COPY. Result: the 45-h dragger
    on `history10.xml-p5131815…` (1.6 M rows × ON CONFLICT skips
    against the lacie14 heap at ~10 rev/s)
  - Multiple sudo-needs to the user (tablespace creation, GRANT,
    package install) that a properly-planned Phase 3 wouldn't need
- **Boundary slack should have been larger.** I chose `SKIP=350` on
  positional reasoning. Choosing `SKIP=340` would have re-processed
  ~10 extra files via ON CONFLICT (some hours each) but avoided
  the 45-h worst case. A "trust but verify with DB-level checks"
  approach would have been more conservative.

## What we haven't proven yet (matters for "success")

- **`recreate_fk` hasn't run.** If any `revision_text.rev_id` is not
  in `revision`, the FK recreate fails. The defensive guard says
  this can't happen, but until the recreate runs, that's a claim,
  not a proof. Cost when it does run: ~6 h on the now-NVMe PK
  indexes.
- **No end-to-end spot check against live MediaWiki API.** The
  `freeze_phase3.sh` step is supposed to pick a random sample of
  rev_ids, fetch via API, and compare wikitext byte-for-byte. Until
  that runs, "the data matches what WMF published" is an
  inference from SHA-1 of inputs, not a measurement of outputs.
- **Downstream analysis queries haven't been touched.** A relational
  hyperevent join across `revision_text × revision × page × actor ×
  logging` may surface issues that load-time stats can't see:
  - namespace skew (the user wants all namespaces — but did all
    of them load with realistic rev_text payloads?)
  - timestamp issues (is `rev_timestamp` in UTC everywhere?)
  - actor identity coherence (Phase 2's shared-actor handling was
    intricate; does cross-table joining produce sane editor IDs?)

## Quality measurements available now

| metric | value | source | interpretation |
|---|---|---|---|
| rows in `revision_text` | ~577 M (`reltuples`) | `pg_class` | within ~1 % of true count |
| rows in `revision` (Phase 2 final) | 1,249,246,504 (exact) | Phase 2 ALL DONE log | the target |
| % loaded by row | ~46 % | derived | mid-flight |
| files done / total | 147 / 606 (in cut list) + ~350 inherited from pre-crash | loader log | ~82 % by file count if you count inherited |
| `skipped_no_revision_match` (cumulative) | 0 | done-line stats | clean — no orphan rev_ids |
| `skipped_text_deleted` (cumulative across done files this run) | ~2,000–5,000 per file (≪ 1 % of seen) | done-line stats | expected (suppressed wikitext) |
| `revision_text` PK violations during load | 0 (post-fix) | log | staging-table fix works |
| disk integrity (no `pg_get_xlog_replay_pause` / unsafe shutdowns) | clean | `pg_stat_activity` history | no corruption events |

## Lessons that should make it into CLAUDE.md / a postmortem

1. **External HDD performance is dominated by random I/O, not
   sequential.** Sequential gets you ~200 MB/s; random PK lookups on
   the same drive can drop to ~20 MB/s effective. Always plan PK
   indexes for the fast tablespace (NVMe / SSD), even if the heap
   has to live on slower storage.
2. **`tee phase3_loader_active.log` (no `-a`) silently destroys the
   prior run's log.** That cost us the ability to compute the
   `done`-list precisely after the crash; we fell back on positional
   reasoning instead and paid for it in re-processing time. Always
   `tee -a` for cumulative artifacts that may matter for forensics.
3. **`count(*)` queries from a status poller on a TOAST-heavy table
   on slow storage will pile up and block DDL.** Use `pg_class.reltuples`
   for approximate counts in monitoring, with a `statement_timeout`
   as a backstop.
4. **PG cluster-default `synchronous_commit = on` doesn't propagate
   to the loader's session because the loader uses `SET LOCAL`.** Use
   plain `SET` so the per-session optimization persists across
   batch commits.
5. **`--no-truncate` + `ON CONFLICT DO NOTHING` is excellent for
   idempotency but terrible for re-processing performance on slow
   storage.** Pair with a `--skip-files` capability or file-level
   checkpointing so you don't pay full I/O cost to confirm
   duplicates you already know about.
6. **Estimate ETAs in bands, not point estimates.** When physical
   bottlenecks are uncertain (random vs. sequential I/O distribution,
   per-row size trajectory across page-IDs), the realistic ETA is a
   2× band. Quoting a single number invites false confidence.

## What "success" looks like at the finish line

The terminal check, once Phase 3 + freeze complete:

- `count(revision_text) BETWEEN 1.23B AND 1.25B` (the tiny gap is
  `skipped_text_deleted`)
- `revision_text_rev_id_fkey` recreated cleanly (no FK violation)
- `ANALYZE revision_text` completed; planner statistics fresh
- `freeze_phase3.sh` ran: `pg_dump` of `wiki20260401` exists with
  SHA-1 recorded; `key_figures.sql` snapshot taken; MANIFEST.md
  appended; `phase3-frozen` git tag exists
- Spot-check: random 50 rev_ids fetched via MediaWiki API match the
  bytes in `revision_text.rev_text` exactly
- Sanity query: `SELECT count(*) FROM revision_text rt JOIN revision r
  ON r.rev_id = rt.rev_id WHERE r.rev_page IS NOT NULL;` returns
  ~1.25 B (no dangling joins)

Today, **none of those are validated**. By ~23 Jun (point estimate)
they should be. Then "successful" stops being provisional.

---

*This assessment was written while Phase 3 is still actively loading
(loader uptime T+3 d 21 h, lacie14 free 1.5 TB, partition migration
queued to fire when lacie14 < 1 TB).*
