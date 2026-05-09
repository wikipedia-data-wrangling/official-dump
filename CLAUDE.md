# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Tooling for acquiring and managing Wikipedia's official database dumps (from [dumps.wikimedia.org](https://dumps.wikimedia.org/)). Feeds an empirical research project on Wikipedia's page protection policy and editor–page relational dynamics — see [proposal_v33 (1).tex](proposal_v33%20%281%29.tex). Downstream analysis is polyadic relational hyperevent models with a granted-vs-denied RFPP matched-pairs identification, so any schema or extraction code must preserve **`pageid`, `revid`, editor identity, and ISO 8601 UTC timestamps** at revision-level granularity.

## Top-level layout

Two generations of code live here side-by-side. The current generation is at the repo root; the legacy generation is quarantined under [\_\_inherited\_\_/](__inherited__/). They target **different databases on different Postgres clusters** — never confuse them.

| Layer | Location | Postgres |
| --- | --- | --- |
| Current pipeline (active) | repo root | PG18 cluster `main`, port 5434, DB `wiki20260401`, role `simone`, `service=wiki` |
| Legacy pipeline (read-only) | [\_\_inherited\_\_/](__inherited__/) | PG15, port 5432, DB `wiki240201`, role `richard` (talk-pages only — see Critical filter below) |

The detailed phase-by-phase plan, locked decisions, and current state-of-play live in [data_collection_plan.md](data_collection_plan.md) — read it before making non-trivial changes to loaders or schema.

## Current pipeline (`wiki20260401`)

### Locked infrastructure decisions

- **Run ID `20260401`** — last "Dump complete" enwiki run as of 2026-05-09. The project is a retrospective study, so a fixed snapshot is preferred.
- **PostgreSQL 18.3**, cluster `main`, port **5434**, encoding **`SQL_ASCII`** (byte-transparent — Wikipedia dumps occasionally contain bytes that strict UTF-8 would reject), locale `C`, dedicated tablespace `wiki_ts`.
- **All bulk data lives on `/media/simone/ssd1/`**: tablespace at `postgres-wiki/`, raw dumps at `wikidumps/20260401/{sql,xml}/`. The PG cluster catalog itself stays at `/var/lib/postgresql/18/main`.
- **Connect with `psql service=wiki`** (port encoded in `~/.pg_service.conf`). New code should use libpq `service=wiki` rather than hardcoding host/port.
- Provisioning is reproducible via [setup_postgres18.sh](setup_postgres18.sh) (run as `sudo`); existing PG15/PG16 clusters are left untouched.

### Pipeline shape

The data load is split into four phases because WMF stopped publishing several SQL dumps for privacy reasons; the same content is now only available as XML and needs an `mwxml` parser.

| Phase | Source | Loader | Tables populated |
| --- | --- | --- | --- |
| 1a | 7 native `*.sql.gz` files (~9 GB) | [load_sql_dumps.py](load_sql_dumps.py) | `page`, `page_restrictions`, `protected_titles`, `user_groups`, `user_former_groups`, `change_tag`, `change_tag_def` |
| 1b | `pages-logging.xml.gz` (~6.4 GB; **published as 27 splits, not one recombined file** — open discrepancy) | [load_logging_xml.py](load_logging_xml.py) | `logging` (+ inserts into shared `actor`) |
| 2 | 27 `stub-meta-history*.xml.gz` (~225 GB) | [load_stub_history_xml.py](load_stub_history_xml.py) | `revision`, `actor` |
| 3 | 956 `pages-meta-history*.xml.7z` (~270 GiB) | [load_pages_meta_history_xml.py](load_pages_meta_history_xml.py) | `revision_text` |

Orchestrate end-to-end with [run_pipeline.sh](run_pipeline.sh):

```bash
./run_pipeline.sh phase1     # download + load 1a + 1b
./run_pipeline.sh phase2     # download + load stub-meta-history
./run_pipeline.sh freeze2    # pg_dump + key_figures snapshot + git tag phase2-frozen
./run_pipeline.sh phase3     # download + load wikitext (multi-day)
./run_pipeline.sh freeze3    # snapshot + API spot-check + git tag phase3-frozen
./run_pipeline.sh all        # all of the above in order
```

The script `cd`s to the repo, activates `.venv/`, and runs from there. Long runs should be inside `tmux`/`screen`. Idempotency: the downloader skips files matching their manifest SHA-1; loaders TRUNCATE their target table before loading, so re-running a phase is safe (with one critical exception — see *Actor identity* below).

### Schema (`schema/`)

Hand-written DDL in 13 files, applied via [schema/00_apply.sql](schema/00_apply.sql) (`psql service=wiki -f schema/00_apply.sql`). Tables model MediaWiki's column names but use Postgres types (`bigint`, `bytea`, `timestamptz`, `jsonb`).

- **No FKs are declared during the apply** — bulk loads run faster without them, and loaders insert in arbitrary order. The single FK that *does* exist (`revision_text.rev_id -> revision.rev_id`) is dropped by the Phase 3 loader at start and re-created at end.
- **All non-PK indexes live in [schema/indexes.sql](schema/indexes.sql)**, separated so loaders can `DROP INDEX` before COPY and re-run that file after. Each index is annotated with the access pattern it serves; the load-bearing one for the hyperevent model is `revision_page_timestamp_actor_idx`.
- **`bytea` for any MediaWiki `VARBINARY` column** (page titles, log_title, rev_text, …) — preserves byte-fidelity for non-UTF-8 sequences. When displaying in psql, wrap in `encode(…, 'escape')`.
- **`log_params` is `jsonb`** — newer rows are JSON, older rows are PHP-serialized; the loader normalizes both via `phpserialize` with a JSON fallback. There's a GIN index, so `WHERE log_params->>'level' = 'sysop'` is the idiomatic protection-level query.

### Actor identity — read before changing any loader

[schema/actor.sql](schema/actor.sql) declares `actor_id GENERATED BY DEFAULT AS IDENTITY` with `UNIQUE NULLS NOT DISTINCT (actor_user, actor_name)`. **Never allocate `actor_id` manually** and **never `TRUNCATE actor`** from a loader — both `load_logging_xml.py` and `load_stub_history_xml.py` write to it. Inserts use `INSERT … ON CONFLICT (actor_user, actor_name) DO NOTHING RETURNING actor_id`, falling back to a SELECT if a sibling loader inserted the row first; a bounded in-process LRU caches resolved ids per process.

The shared-`actor` invariant is why the loaders deliberately diverge from "TRUNCATE everything I write" — re-running Phase 1b after Phase 2 must not nuke the actors Phase 2 created.

### Filter discipline (current pipeline)

**Do not filter by namespace at load time.** Keep all namespaces in the loaded tables and filter at query time (`WHERE page_namespace = 0` for articles, odd namespaces for talk). This is a deliberate departure from `__inherited__/wiki0201.py`, whose talk-only filter was silently lossy (see below).

### Verification & freeze

- [key_figures.sql](key_figures.sql) is the canonical sentinel script — row counts per table, namespace breakdown, yearly protect-event counts, top admins by protection actions, currently-protected pages joined to their last protect event. Run it before/after any non-trivial change. Ad-hoc throwaway SQL belongs here too.
- [freeze_phase2.sh](freeze_phase2.sh) and [freeze_phase3.sh](freeze_phase3.sh) implement the Phase 4a/4b handoff checklists from `data_collection_plan.md`: pg_dump (custom format) → `key_figures.sql` snapshot → SHA-1 → append a dated section to `MANIFEST.md` on the SSD. Both refuse to overwrite existing snapshots without `--force`. `freeze_phase3.sh` needs `jq` (for `dumpstatus.json` parsing).
- The repo has no other test suite. The exception is [test_load_pages_meta_history_xml.py](test_load_pages_meta_history_xml.py), which builds synthetic `.xml.7z` fixtures and round-trips them through the Phase 3 loader; it touches the real DB to test the existence-filter, so run it against a non-production cluster.

### Downloader etiquette

[download_dumps.py](download_dumps.py) drives off the official `dumpstatus.json` (so SHA-1s and sizes are never hardcoded), streams to disk with HTTP `Range:` resume, verifies SHA-1 against the manifest, and respects WMF etiquette: **max 2 concurrent connections** and `User-Agent: SantoniWikipediaResearch/1.0 (simone.santoni.1@city.ac.uk)`. Don't increase concurrency or change the UA without a reason.

## Legacy pipeline (`__inherited__/`)

[\_\_inherited\_\_/wiki0201.py](__inherited__/wiki0201.py) targets the 2024-02-01 enwiki run, writing to a separate Postgres DB `wiki240201` (host `localhost:5432`, user `richard`, password `rich` — credentials hardcoded). Read \_\_inherited\_\_/ notes only via this file.

**Critical filter — easy to miss.** `parse_insert()` keeps only pages whose namespace is in `[1, 3, 5, 7, 9, 11, 13, 101, 119, 711, 829, 2301, 2303]` — all **odd namespaces, i.e. *Talk* pages**. The populated `revisions` table therefore contains *only talk-page edits*. Any analysis that assumes article revisions in `wiki240201` will be silently wrong. The current pipeline's no-filter-at-load policy is a direct response to this bug.

Notebooks alongside `wiki0201.py` (`ddpid.ipynb`, `parsexml.ipynb`, `sample_talks.ipynb`, …) are exploratory scratch from the same era — treat as history unless the user points at one.

## Working with Wikipedia dumps (domain notes)

Key facts that affect implementation choices and aren't obvious from a quick web search:

- **Multistream vs. monolithic**: `pages-articles-multistream.xml.bz2` is the same content as `pages-articles.xml.bz2` but split into independently-decompressible bzip2 streams with a companion `-multistream-index.txt.bz2`. Always prefer multistream for random access — you can seek to a single page without decompressing tens of GB.
- **Current vs. history**: `pages-articles*` contains only current revisions. For revision-level analysis (which this project needs), use `pages-meta-history*.xml.7z` (Phase 3) or — if you only need revision metadata, no wikitext — the much smaller `stub-meta-history*.xml.gz` (Phase 2).
- **Run identifiers**: dumps live under date-stamped directories (e.g. `enwiki/20260401/`) and old runs are pruned after a few months. Always pin a specific run ID for reproducibility, and download checksums (`*-md5sums.txt`, `*-sha1sums.txt`) alongside the data.
- **Page protection data** lives in **SQL dumps** (`page_restrictions`, `logging`) — *not* in the article XML. WMF stopped publishing `logging.sql.gz` and `revision.sql.gz`; both arrive as XML now and need the Phase 1b/2 loaders.
- **No media in XML/SQL dumps**: images/audio/video are separate (Commons tarballs under `dumps.wikimedia.org/other/`).

## Conventions

- New code defaults to Python (the `.gitignore` is configured for it). The active venv is `.venv/` at the repo root.
- Throwaway SQL goes in `key_figures.sql`; new persistent tables go in `schema/` and into [schema/00_apply.sql](schema/00_apply.sql)'s order.
- Don't introduce a build system, monorepo tooling, or root-level requirements file at the workspace level — the sibling `fetch-protection-events/` is a separate repo and should stay independent.
