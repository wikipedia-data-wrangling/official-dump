# Inherited data-gathering pipeline (`__inherited__/`)

This directory holds the data-gathering code written by a prior collaborator (Richard) for the Wikipedia page-protection project. It is preserved verbatim, including the developer's database credentials and run-specific paths, so that the historical pipeline can be re-read and (if needed) re-executed without guessing what was done. Treat this directory as a frozen reference — new code should live alongside, not inside, it.

This README documents *what was done*, *how the artifacts fit together*, and *what to be aware of* before reusing or extending the pipeline.

## TL;DR

A single Postgres database (`wiki240201` on `localhost:5432`, user `richard`) was populated from the **2024-02-01 English Wikipedia full-history XML dump** (`enwiki/20240201/pages-meta-history*.7z`, 843 archive parts). For each part, the pipeline downloaded the `.7z`, decompressed it to XML, parsed it with `mwxml`, kept **only revisions on talk-related namespaces** (Talk, User talk, Wikipedia talk, …), and bulk-inserted users/pages/revisions into Postgres. Sidecar artifacts (`keywords.jsonl`, `sample_talks.ipynb`) explore downstream uses of the resulting database for talk-page toxicity / keyword analysis.

## Source data

- **Dump host**: [dumps.wikimedia.org/enwiki/20240201/](https://dumps.wikimedia.org/enwiki/20240201/)
- **Dump kind**: `pages-meta-history*.xml-pXpY.7z` — the **full revision history** with wikitext, sharded by page-ID range.
- **Manifest**: [wiki240201.csv](wiki240201.csv) — flat list of 843 dump-part filenames. `wiki0201.py` builds URLs by prefixing `https://dumps.wikimedia.org/enwiki/20240201/` to each line.
- **Per-part size**: hundreds of MB compressed; many GB uncompressed. The pipeline processes one part at a time and **deletes** the decompressed XML after insertion to keep disk usage bounded.

This is not the multistream `pages-articles` dump and not the metadata-only stub dump. Picking `pages-meta-history` was deliberate: the project needs revision-level granularity (every edit, every editor, every timestamp), not just current revisions.

## Pipeline: DDPID

The orchestrator is [wiki0201.py](wiki0201.py). The acronym in `ddpid()` is **D**ownload → **D**ecompress → **P**arse-and-**I**nsert → **D**elete.

```
ddpid(url):
    download_file(url, filename)               # streamed HTTP, retries on non-200 every 60s
    decompress_file(filename)                  # py7zr, extracts XML next to .7z
    parse_insert(dump_file_name)               # mwxml stream → bulk INSERT
    delete_file(dump_file_name)                # remove the decompressed XML
    move_file_to_finished_directory(...)       # move the .7z into finished/ as a "done" marker
```

The `__main__` block runs `ddpid` over **all not-yet-finished URLs in parallel** via `ThreadPoolExecutor` (default worker count = `min(32, os.cpu_count()+4)`). Progress is tracked with `tqdm`, and stdout/stderr are redirected to timestamped files under [logs/](logs/).

### Resumability

Resumption is filename-based and idempotent:

1. On startup the script reads `os.listdir("finished")` and **skips any URL whose filename is already in `finished/`**. This is why successful parts are *moved* (not copied) into [finished/](finished/) — that directory is the single source of truth for what's already been ingested. There are currently **408** completed parts there (out of 843).
2. Inside the database, every `INSERT` uses `ON CONFLICT (id) DO NOTHING`, so re-running a part that was partially ingested before a crash does not produce duplicates.

Reruns therefore pick up exactly where the previous run stopped, and partial parts can be re-processed safely.

### Namespace filter (load-bearing)

In `parse_insert`, only pages whose `namespace` is in this set are kept:

```
{1, 3, 5, 7, 9, 11, 13, 101, 119, 711, 829, 2301, 2303}
```

These are precisely the **odd-numbered "Talk" namespaces** (Talk, User talk, Wikipedia talk, File talk, MediaWiki talk, Template talk, Help talk, Portal talk, Draft talk, TimedText talk, Module talk, Gadget talk, Gadget-definition talk). Article (namespace 0), User (2), Wikipedia/project (4), File (6), Template (10), Category (14), and Module (828) pages were **dropped at parse time** and never reach the database.

Implication: the populated `wiki240201` DB is a **talk-page-only revision store**. Joining it against the protection log (which is largely about article-namespace pages) requires being aware that most protected pages have no rows here — the inherited DB is a corpus for *talk-page editor behavior*, not for the protected articles themselves. If revision data on article-namespace pages is needed, this filter has to be widened and the pipeline re-run on the relevant parts.

## Database schema

Hardcoded connection: `postgresql://richard:rich@localhost:5432/wiki240201`. Three tables, all created idempotently inside `insert_db`:

| Table       | Columns (key ones)                                                                                                            | Notes |
|-------------|--------------------------------------------------------------------------------------------------------------------------------|-------|
| `users`     | `id PK`, `text` (display name), `deleted BOOL`                                                                                 | One row per editor seen. Anonymous (IP-only) edits are **skipped** because the insert filter requires `user.id is not None`. |
| `pages`     | `id PK`, `title`, `namespace`, `restrictions JSONB`, `deleted BOOL`                                                            | `restrictions` is whatever `mwxml` exposes from the per-page `<restrictions>` element in the dump (legacy field; modern protection lives in the `page_restrictions` SQL table). |
| `revisions` | `id PK`, `timestamp`, `user_id FK`, `page_id FK`, `minor`, `comment`, `text`, `bytes`, `sha1`, `model`, `format`, three `deleted_*` flags | One row per revision. `text` holds full wikitext — the reason the DB is large. |

The schema and join key (`pages.id` ↔ MediaWiki `pageid`) are referenced by the open file [../key_figures.sql](../key_figures.sql) at the repo root.

### Insert batching

`parse_insert` accumulates revisions in memory and flushes to Postgres once the batch reaches **1000 revisions**, then sleeps 1 s before continuing — both to amortize round-trips and to be polite to the local DB. The final partial batch is flushed at end-of-dump with a 5 s sleep.

## Auxiliary artifacts

- **[ddpid.ipynb](ddpid.ipynb)** — interactive prototype of `wiki0201.py`. Identical logic but writes to a separate `wikitest` database with smaller batch sizes (10 instead of 1000) and a 20-revision early-exit; useful for smoke-testing the pipeline without touching `wiki240201`.
- **[download_dmup.ipynb](download_dmup.ipynb)** — a smaller download-and-decompress-only experiment (no DB writes, first 3 parts only). Predates `ddpid.ipynb`.
- **[parsexml.ipynb](parsexml.ipynb)** — scratch notebook exploring `mwxml` on a single dump part; documents the namespace listing returned by `dump.site_info.namespaces` (the source of the namespace filter above).
- **[sample_talks.ipynb](sample_talks.ipynb)** — downstream demo. Connects to Postgres via PySpark + JDBC ([postgresql-42.7.3.jar](postgresql-42.7.3.jar)), pulls the **latest revision per talk page as of `20230101`**, parses one revision into individual messages with `mwparserfromhell`, runs a keyword filter against [keywords.jsonl](keywords.jsonl), and scores each message with [Detoxify](https://github.com/unitaryai/detoxify) (`toxicity`, `severe_toxicity`, `obscene`, `threat`, `insult`, `identity_attack`). This is the clearest signal of what the inherited DB was *meant for*: talk-page toxicity / incivility analysis.
- **[keywords.jsonl](keywords.jsonl)** — 138 lines, one JSON object per word (`{"word": ..., "embeddings": [...300 floats...]}`). The wordlist is a profanity / slur lexicon used by `sample_talks.ipynb`; the embeddings appear to be GloVe-style 300-d vectors (provenance not documented, treat with care).
- **[7920.session.sql](7920.session.sql)** — saved ad-hoc query: latest revision per Talk-namespace page on or before `2022-01-01`, filtered to non-deleted rows. Mirrors what `sample_talks.ipynb` does in PySpark and is a good template for joining `pages` ↔ `revisions`.
- **[throttle.ctrl](throttle.ctrl)** — single-line `pywikibot` throttle control file (`f9c1 1 1712066978.4139411 wikipedia:en`, timestamp = 2024-04-02). Indicates that some live API access via `pywikibot` happened from this directory, but no `pywikibot` script is checked in here — likely an exploratory session.
- **[apicache/](apicache/)** — `pywikibot` API response cache (hex-named blobs). Same provenance as `throttle.ctrl`.
- **[logs/](logs/)** — timestamped `.log` / `.err` files emitted by `wiki0201.py` runs (March–April 2024). Useful for reconstructing the run timeline and any per-part failures.
- **[finished/](finished/)** — 408 `.7z` archives marking ingested dump parts. Acts as the resumption checkpoint; do not delete.
- **[finished_test/](finished_test/)** — same purpose for the `wikitest` smoke-test DB used by `ddpid.ipynb`.

## What to know before reusing this

1. **Talk-namespaces only.** The populated DB does **not** contain article revisions. Re-running with a wider namespace filter will multiply both ingestion time and disk usage by a large factor.
2. **Anonymous edits are dropped.** The insert filter `if d.get("user", {}).get("id") is not None` silently excludes IP edits. For analyses where IP editors matter (vandalism patterns, drive-by edits on protected pages), the filter has to be relaxed and a synthetic user-key scheme introduced.
3. **The 2024-02-01 dump is now stale.** Wikipedia prunes old runs after a few months — the source URLs are likely 404 today. Repointing to a current dump (`enwiki/<YYYYMMDD>/`) requires regenerating `wiki240201.csv` from that run's [dumpstatus.json](https://dumps.wikimedia.org/backup-index.html) or directory listing.
4. **Hardcoded credentials.** DB host/port/user/password live in literal strings at the top of `wiki0201.py` and `ddpid.ipynb`. Any rerun on a non-Richard workstation needs these edited (or, better, sourced from env vars).
5. **No checksum verification.** The pipeline does not download or check the `*-md5sums.txt` / `*-sha1sums.txt` files alongside each dump part. A silently truncated `.7z` would be detected only when `py7zr` raises during extraction.
6. **Page `restrictions` is the legacy XML field, not the protection log.** It captures whatever was set on the page object at dump time (e.g. `"edit=autoconfirmed:move=sysop"`-style strings) but does **not** carry the granted/denied history that the protection-log work in [../../fetch-protection-events/](../../fetch-protection-events/) collects via the API. The two sources are complementary, not redundant.
7. **Concurrency × py7zr.** `ThreadPoolExecutor` with no explicit `max_workers` plus 7-zip decompression is CPU-bound and IO-bound at the same time. On a workstation this can starve the Postgres process; consider capping workers (e.g. `ThreadPoolExecutor(max_workers=4)`) when rerunning.

## Reproducing a run (sketch)

```bash
# 1. Bring up Postgres locally and create the DB + role expected by the script.
createuser -s richard            # or edit wiki0201.py
createdb -O richard wiki240201

# 2. Make sure the working directory layout exists.
cd __inherited__
mkdir -p logs finished

# 3. Refresh the manifest if the 20240201 run is gone.
#    (Otherwise reuse wiki240201.csv as-is.)

# 4. Install deps.
pip install psycopg2-binary requests pandas py7zr mwxml tqdm

# 5. Run.
python wiki0201.py
```

Re-running is safe at any time; already-finished parts will be skipped, and `ON CONFLICT DO NOTHING` guards against duplicate inserts inside a partially-finished part.
