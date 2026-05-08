# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Tooling for acquiring and managing Wikipedia's official database dumps (from [dumps.wikimedia.org](https://dumps.wikimedia.org/)). The dumps feed an empirical research project on Wikipedia's page protection policy and editor–page relational dynamics — see `proposal_v33 (1).tex` for the research design (target outcome: polyadic relational hyperevent models over the editor–page network, with a matched-pairs identification strategy comparing granted vs. denied protection requests). When designing data extraction or transformation code, prefer schemas that preserve editor identity, page identity, timestamps, and revision-level granularity, since all three mechanisms in the proposal (attention reallocation, core–periphery consolidation, coalition migration) require revision-level editor–page event data.

## Current state

The repository currently contains only `README.md`, `LICENSE`, `.gitignore`, and the LaTeX proposal — no source code, build system, or tests yet. There are no project-specific commands to run. The `.gitignore` is configured for Python, so new code should default to Python unless the user specifies otherwise.

## Working with Wikipedia dumps (domain notes)

Key facts that affect implementation choices and that aren't obvious from a quick web search:

- **Multistream vs. monolithic**: `pages-articles-multistream.xml.bz2` is the same content as `pages-articles.xml.bz2` but split into independently-decompressible bzip2 streams with a companion `-multistream-index.txt.bz2`. Always prefer multistream for random access — you can seek to a single page without decompressing tens of GB.
- **Current vs. history**: `pages-articles*` contains only current revisions. For revision-level analysis (which this project needs) the right files are `pages-meta-history*.xml.7z`, which are split into many parts and total several TB uncompressed for enwiki.
- **Stub dumps**: `*-stub-*.xml.gz` files contain page/revision metadata only (no wikitext). For network/edit-event analysis that doesn't need article text, stubs are dramatically smaller and faster.
- **Run identifiers**: dumps live under date-stamped directories (e.g. `enwiki/20260401/`) and old runs are pruned after a few months. Always pin a specific run ID for reproducibility, and download checksums (`*-md5sums.txt`, `*-sha1sums.txt`) alongside the data.
- **No media in XML/SQL dumps**: images/audio/video are separate (Commons tarballs under `dumps.wikimedia.org/other/`).
- **Page protection data** (central to this project) lives in the SQL dumps — specifically the `page_restrictions` table and protection log entries in the `logging` table — not in the article XML.
