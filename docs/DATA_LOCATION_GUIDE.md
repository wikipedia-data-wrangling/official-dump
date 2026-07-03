# Data location guide — what part of Wikipedia lives where

A reader-friendly, conceptual companion to [STORAGE_LAYOUT.md](STORAGE_LAYOUT.md).
This file answers the question **"if I want to look at *X*, which physical
drive will the disk reads come from?"** — written for the researcher
rather than the dbadmin.

If you want the technical tablespace / partition / index details, read
`STORAGE_LAYOUT.md` instead. If you want to know "where does my data
sit", you're in the right place.

---

## 1. The mental model in one paragraph

**`revision_text` (the actual wikitext) is the only thing big enough to
need spanning across drives — everything else (revisions metadata,
pages, editors, logs, tags) lives entirely on one drive.** We split
`revision_text` into two halves at `rev_id = 1,000,000,000`: revisions
older than that (mostly pre-2012) live on **lacie14** (slow external
HDD), revisions newer than that live on **ssd1** (fast internal SSD).
Everything else lives on **lacie14**. Primary-key indexes for *every*
table live on **NVMe** so lookups are always fast no matter which drive
holds the data.

---

## 2. The split, visualised

```
                          ┌──────────────────────────────────────────┐
                          │         NVMe (/dev/nvme0n1p3)            │
                          │              ~50 GB used                 │
                          │                                          │
                          │  Every primary-key index for every       │
                          │  Wikipedia table lives here:             │
                          │    revision_pkey               (34 GB)   │
                          │    revision_text_p1_pkey       (15 GB)   │
                          │    revision_text_p2_pkey       ( 3 GB)   │
                          │    (smaller PKs for page, actor, ...)    │
                          │                                          │
                          │  Plus PG cluster catalog + WAL           │
                          └──────────────────────────────────────────┘
                              ▲                              ▲
                              │                              │
                              │ index lookups for ALL tables │
                              │                              │
        ┌─────────────────────┴─────────┐          ┌─────────┴────────────────┐
        │     lacie14 (/dev/sde1)       │          │     ssd1 (/dev/sdc)      │
        │     11 TB total, ~7.5 TB used │          │  7.3 TB total, ~3.7 used │
        │     EXTERNAL HDD              │          │  INTERNAL SATA SSD       │
        │                               │          │                          │
        │  ──────────────────────────   │          │  ──────────────────────  │
        │  WIKITEXT (older half)        │          │  WIKITEXT (newer half)   │
        │                               │          │                          │
        │  revision_text_p1   7,142 GB  │          │  revision_text_p2  2,145 │
        │  (rev_id < 1B —               │          │  (rev_id ≥ 1B —          │
        │   roughly pre-2012 edits)     │          │   roughly 2012-onward)   │
        │                               │          │                          │
        │  ──────────────────────────   │          │                          │
        │  STRUCTURED DATA              │          │                          │
        │                               │          │                          │
        │  revision        336 GB       │          │   (nothing else from     │
        │  change_tag       66 GB       │          │    the wiki dataset      │
        │  logging          54 GB       │          │    lives on ssd1)        │
        │  actor            15 GB       │          │                          │
        │  page             13 GB       │          │                          │
        │  page_restrictions  22 MB     │          │                          │
        │  user_groups        11 MB     │          │                          │
        │  protected_titles  8.8 MB     │          │                          │
        │  user_former_grp   2.2 MB     │          │                          │
        │  change_tag_def     88 KB     │          │                          │
        │                               │          │                          │
        │  Phase 2 secondary indexes    │          │                          │
        │  (revision_page_timestamp_    │          │                          │
        │   actor_idx etc.) ~130 GB est │          │                          │
        │                               │          │                          │
        │  ──────────────────────────   │          │                          │
        │  SOURCE ARTIFACTS             │          │                          │
        │  wikidumps/ (956 .7z files,   │          │                          │
        │             7 .sql.gz)        │          │                          │
        │                  ~397 GB      │          │                          │
        └───────────────────────────────┘          └──────────────────────────┘
```

Note: **lacie10 is empty reserve** (8.6 TB free, no wiki data) — held
back for hop 3 if/when one of the above drives fills again. ssd, hdd,
ext1 contain non-Wikipedia data and are untouched by this project.

---

## 3. By logical concept — where each piece of Wikipedia lives

### 3.1 The wikitext itself (`revision_text`)

The 9.3 TB of raw wiki markup, one row per edit ever made to any
Wikipedia page in any namespace. It is **split** across two drives:

| half | physical relation | drive | size | rough chronological window |
|---|---|---|---|---|
| older half | `revision_text_p1` | **lacie14** (HDD) | 7,142 GB | revisions with `rev_id < 1,000,000,000` — roughly pre-mid-2012 |
| newer half | `revision_text_p2` | **ssd1** (SSD) | 2,145 GB | revisions with `rev_id ≥ 1,000,000,000` — roughly mid-2012 onward |

PG handles the split automatically — if you query
`SELECT rev_text FROM revision_text WHERE rev_id = X`, the planner picks
the right partition based on X. You never need to know which half a
revision is in.

The boundary `rev_id = 1B` was chosen because the existing data split
roughly 74/26 across the two ranges at the time of the partition
migration — putting the bigger half on the larger drive.

### 3.2 The revision metadata (`revision`)

One row per Wikipedia edit ever — **1.249 billion rows** — recording
who, when, on what page, with what edit summary, and pointing at the
parent revision for chain reconstruction. **All of it on lacie14
(HDD).**

This is the "join table" between the wikitext, the pages, and the
editors. Phase 2 built three secondary indexes on it to make
hyperevent-style queries practical:
- `revision_page_timestamp_actor_idx` — the load-bearing index for
  edit-history queries
- `revision_actor_timestamp_idx` — editor-centric queries
- `revision_parent_idx` — revert / chain reconstruction

These indexes are also on lacie14 (HDD), totalling ~130 GB estimated.
PK index (`revision_pkey`, 34 GB) is on NVMe.

### 3.3 The pages (`page`)

One row per Wikipedia page (article, talk, user, file, ...) — **65 M
rows**. Records page_id, title, namespace, length, current restriction
status. **All on lacie14 (HDD).**

### 3.4 The editors (`actor`)

One row per unique editor (registered user or IP) — **111 M rows**.
Records actor_id, actor_user, actor_name. Shared between Phase 1b's
logging and Phase 2's revisions. **All on lacie14 (HDD).**

### 3.5 The protection / admin log (`logging`)

One row per admin action (protection, deletion, block, etc.) —
**158 M rows**. Records what action, by whom, when, with what
parameters (JSONB). **All on lacie14 (HDD).** GIN index on
`log_params` for `'level' = 'sysop'` queries.

### 3.6 Edit tags and tag definitions (`change_tag`, `change_tag_def`)

**547 M change_tag rows + 335 tag definitions.** Identifies which
revisions were flagged as reverts, bot edits, mobile edits, vandalism,
etc. **All on lacie14 (HDD).**

### 3.7 Current page-protection state (`page_restrictions`,
`protected_titles`)

Snapshot of which pages are currently protected and which protected
titles refuse creation. **All on lacie14 (HDD).**

### 3.8 User-group memberships (`user_groups`, `user_former_groups`)

Which editors hold which admin/bot/autopatrolled/etc. roles. Tiny.
**All on lacie14 (HDD).**

### 3.9 Source dumps (the `.7z` and `.sql.gz` files)

The 956 `pages-meta-history*.xml-pNpM.7z` archives, the 27
`stub-meta-history*.xml.gz`, the `pages-logging.xml.gz`, and the 7
Phase 1a SQL dumps. **All on lacie14 in `wikidumps/20260401/`.**

Kept around for re-runs and forensics. Could in principle be deleted
once Phase 3 + freeze are done and verified, but it's only ~400 GB so
the value of keeping them is high relative to the cost.

---

## 4. By drive — what wiki content is on each

### 4.1 lacie14 — bulk capacity HDD

**Holds 100% of the structured Wikipedia data + the older half of the
raw wikitext + the source dumps.**

| concept | size | comment |
|---|---|---|
| revision_text_p1 (older wikitext) | 7,142 GB | the biggest item by far |
| revision (1.25 B rows of edit metadata) | 336 GB | including secondary indexes |
| change_tag | 66 GB | edit tags |
| logging | 54 GB | admin action log |
| actor | 15 GB | editor identities |
| page | 13 GB | page metadata |
| smaller tables | ~50 MB | protection state, user groups, etc. |
| source `.7z` + `.sql.gz` dumps | 397 GB | re-runnable artifacts |
| **total Wikipedia content** | **~8.0 TB** | |

### 4.2 ssd1 — fast internal SATA SSD

**Holds nothing structured — only the newer half of the raw wikitext.**

| concept | size | comment |
|---|---|---|
| revision_text_p2 (newer wikitext) | 2,145 GB | the *only* Wikipedia content on ssd1 |
| **total Wikipedia content** | **~2,145 GB** | |

(Other things on ssd1 — `backup/`, `linux-kernel-archive/`,
`postgres-lk/` — are unrelated user data, not part of `wiki20260401`.)

### 4.3 NVMe (root drive) — indexes + cluster files

**Holds all primary-key indexes** for the Wikipedia tables:
- `revision_pkey` (34 GB)
- `revision_text_p1_pkey` (15 GB)
- `revision_text_p2_pkey` (3 GB)
- Smaller PKs for `page`, `actor`, `logging`, `change_tag`, etc.

Plus the PG cluster catalog, WAL log, and configuration — these are
not Wikipedia-specific but are required for the cluster to run.

Total Wikipedia-PK content on NVMe: ~54 GB.

### 4.4 lacie10 — empty reserve

**Currently empty.** Held back as a "hop 3" destination if one of the
other drives fills up before Phase 3 finishes. 8.6 TB free.

---

## 5. The why — one sentence each

| design choice | why |
|---|---|
| The wikitext is split at `rev_id = 1B` | This is the only natural axis we have for partitioning; rev_ids increase roughly chronologically, so a single boundary cleanly splits "old, dense, less-edited" from "new, sparse, more-edited" without needing per-row decisions. |
| Older wikitext on the slow HDD; newer on the fast SSD | Older revisions are referenced less often by the hyperevent analysis (the matched-pairs RFPP design focuses on recent protection events); putting the cold half on cheap HDD and the hot half on fast SSD optimises typical access patterns. |
| All structured tables (`revision`, `page`, `actor`, `logging`) on lacie14 | They're small enough (<500 GB combined) that fitting them on a single drive is trivial; co-locating them means joins across these tables don't need to cross drives. |
| PK indexes on NVMe | Random index lookups dominate Postgres query time on any moderate query; putting *all* PKs on NVMe means even queries that hit slow HDD heaps still resolve their index in <100 µs. |
| Source dumps kept on lacie14 | Re-runnable safety net; small (~400 GB) relative to the value of being able to re-ingest from scratch if anything goes wrong. |
| Phase 2 secondary indexes on lacie14 (not NVMe) | They're large (~130 GB combined); moving them to NVMe is a viable optimisation if downstream queries are slow but hasn't been done yet — see open question in `STORAGE_LAYOUT.md` §10. |

---

## 6. Lookup table — "I want X, where is it?"

Maps research-side concepts to physical relations and drives.

| I want to look at... | Postgres relation(s) | Drive(s) touched |
|---|---|---|
| The wikitext of revision N (any N) | `revision_text` | NVMe (PK) + lacie14 *or* ssd1 (depending on N) |
| The metadata of revision N (author, time, page, length, parent) | `revision` | NVMe (PK) + lacie14 (heap + secondary indexes) |
| All revisions of page X | `revision` (by `rev_page` via `revision_page_timestamp_actor_idx`) | NVMe (index) + lacie14 (heap) |
| All revisions by editor Y | `revision` (by `rev_actor` via `revision_actor_timestamp_idx`) | NVMe (index) + lacie14 (heap) |
| The page record (title, namespace) for page X | `page` | NVMe (PK) + lacie14 (heap) |
| The protection log for page X | `logging` (filtered by `log_page = X`) | lacie14 (heap + log_params GIN index) |
| All currently-protected pages | `page_restrictions` | lacie14 |
| All requests for protection (granted vs denied) | **not in this DB** — see sibling repo `fetch-protection-events/` (fetched via API, lives separately) |
| The editor record for actor_id Z | `actor` | NVMe (PK) + lacie14 (heap) |
| Whether revision N was tagged as a revert / vandalism / bot | `change_tag` (filtered by `ct_rev_id = N`) | lacie14 (heap) |
| Source 7z for revisions of pages [pX, pY] | `wikidumps/20260401/xml/enwiki-20260401-pages-meta-history*-pXpY.7z` | lacie14 (filesystem) |

---

## 7. Common research scenarios and what they touch

Based on the [proposal_v33.tex](proposal_v33%20%281%29.tex) plan
(polyadic relational hyperevent model on the editor-page network with
matched-pairs RFPP identification).

### 7.1 Build an editor-page-time event log for the hyperevent model

```sql
SELECT r.rev_actor, r.rev_page, r.rev_timestamp, r.rev_id,
       ct.ct_tag_id    -- revert detection
  FROM revision r
  LEFT JOIN change_tag ct ON ct.ct_rev_id = r.rev_id
                          AND ct.ct_tag_id IN (...revert tag ids...)
 WHERE r.rev_timestamp BETWEEN $start AND $end
   AND r.rev_page IN (SELECT page_id FROM page WHERE page_namespace = 0);
```

| join step | drive(s) |
|---|---|
| `revision` heap + `revision_page_timestamp_actor_idx` index scan | lacie14 |
| `change_tag` heap | lacie14 |
| `page` PK lookup for namespace filter | NVMe (PK) + lacie14 (heap) |

**All on lacie14 (with NVMe-resident PKs for fast index lookups).** No
ssd1 reads — the wikitext heap isn't touched.

### 7.2 Compute edit-content features (revert detection by SHA-1 chain
+ wikitext diff)

```sql
SELECT r.rev_id, r.rev_sha1, rt.rev_text
  FROM revision r
  JOIN revision_text rt ON rt.rev_id = r.rev_id
 WHERE r.rev_page = $page_id
 ORDER BY r.rev_timestamp;
```

| join step | drive(s) |
|---|---|
| `revision` lookup by page (secondary index) | lacie14 |
| `revision_text` PK seek | NVMe (PK) → lacie14 *and* ssd1 (heap fetches scatter across both partitions because a single page has revisions spanning the full rev_id range) |

**Touches both lacie14 *and* ssd1.** For a heavily-edited article, the
ssd1 portion will return faster but the lacie14 portion dominates wall
time.

### 7.3 Match granted-vs-denied RFPP requests against actual
protection log

```sql
-- The RFPP requests themselves come from the sibling repo
-- (fetch-protection-events/fetch_rfpp.py output, lives outside this DB).
-- This is what the wiki20260401 side contributes:
SELECT l.log_page, l.log_timestamp, l.log_params,
       p.page_title, p.page_namespace
  FROM logging l
  JOIN page p ON p.page_id = l.log_page
 WHERE l.log_type = 'protect'
   AND l.log_timestamp BETWEEN $start AND $end;
```

| join step | drive(s) |
|---|---|
| `logging` filter + GIN index on `log_params` | lacie14 |
| `page` PK lookup | NVMe + lacie14 |

**All on lacie14.** RFPP data integration happens at the application
layer with the sibling-repo CSV output.

### 7.4 Editor-network co-edit graph

```sql
SELECT a1.actor_id AS editor_1, a2.actor_id AS editor_2,
       count(*) AS co_edit_count
  FROM revision r1
  JOIN revision r2 ON r2.rev_page = r1.rev_page
                   AND r2.rev_actor <> r1.rev_actor
  JOIN actor a1 ON a1.actor_id = r1.rev_actor
  JOIN actor a2 ON a2.actor_id = r2.rev_actor
 WHERE r1.rev_timestamp BETWEEN $start AND $end
   AND r2.rev_timestamp BETWEEN r1.rev_timestamp AND r1.rev_timestamp + INTERVAL '30 days'
 GROUP BY a1.actor_id, a2.actor_id;
```

| join step | drive(s) |
|---|---|
| `revision` self-join via `revision_page_timestamp_actor_idx` | lacie14 |
| `actor` PK lookups | NVMe + lacie14 |

**All on lacie14.** The wikitext is not needed; the heaviest cost is
the self-join on revision, which lacie14's secondary index makes
tractable.

---

## 8. Implications for downstream work

### Most analysis queries don't touch the wikitext at all

The polyadic relational hyperevent model fits on the **event log**
(editor-page-time triples), not the wikitext bodies. That means the
overwhelming majority of analysis queries hit only lacie14 (revision +
page + actor + logging + change_tag + their indexes). The
9.3 TB of wikitext is *latent* storage that gets queried only when
content features are needed (revert diffing, topic modelling,
vandalism classification).

### When you do touch the wikitext, expect a mix

Any single page has revisions spanning the full rev_id range, so a
"give me all wikitext for article X" query hits **both** lacie14
(older revisions) and ssd1 (newer ones). The ssd1 portion returns
much faster.

### Bulk wikitext export for offline NLP

If you need to export wikitext to a flat file or another system for
offline processing, expect ~3–5 days of read time given lacie14's HDD
random-read latency on TOAST data (~5–15 ms per chunk). Consider
exporting one partition at a time:
- `revision_text_p1` (lacie14) — slow (~3–4 days for the 7 TB heap)
- `revision_text_p2` (ssd1) — fast (~12–18 h for the 2 TB heap)

### Backup strategy

A full `pg_dump` of `wiki20260401` would write ~3–5 TB of
custom-format compressed output. Currently no drive has comfortable
free space for that (lacie10 with 8.6 TB free is the obvious target).
This is owed work for the `freeze_phase3.sh` step.

### Drive-failure impact

| drive lost | impact on the dataset |
|---|---|
| NVMe | total loss — cluster won't start; all indexes gone |
| **lacie14** | **catastrophic** — loses 100% of structured data + half the wikitext + source dumps; effectively requires re-ingesting from scratch |
| ssd1 | loses 2.1 TB of newer wikitext (the rev_id ≥ 1B partition); the smaller half — re-ingestion would take ~1–2 weeks from the source 7z files (which are on lacie14, so they survive) |
| lacie10 | no impact (empty reserve) |

The dataset is **not redundant across drives**. A backup is owed
post-Phase-3.

---

## 9. Cross-references

| file | content |
|---|---|
| [STORAGE_LAYOUT.md](STORAGE_LAYOUT.md) | the operational/technical companion to this file (tablespace mechanics, capacity math, recovery scenarios) |
| [CLAUDE.md](CLAUDE.md) | top-level project guide |
| [data_collection_plan.md](data_collection_plan.md) | phase-by-phase ingest plan |
| [proposal_v33 (1).tex](proposal_v33%20%281%29.tex) | the underlying research design that motivates the data layout |

---

*Last updated: 2026-06-25 11:50 BST.*
