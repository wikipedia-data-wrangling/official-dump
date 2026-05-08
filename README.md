# official-dump

Acquiring and managing Wikipedia's official data dumps.

## About Wikipedia database dumps

The Wikimedia Foundation publishes complete copies of Wikipedia (and its sister projects) as periodic database dumps. They are intended for offline reading, research, mirroring, bots, and academic analysis, and are the canonical source of Wikipedia content in bulk.

Reference: [Wikipedia:Database download](https://en.wikipedia.org/wiki/Wikipedia:Database_download).

## Where to get them

- Primary host: [dumps.wikimedia.org](https://dumps.wikimedia.org/)
- English Wikipedia: [dumps.wikimedia.org/enwiki/](https://dumps.wikimedia.org/enwiki/)
- Mirrors: [list of mirrors](https://dumps.wikimedia.org/mirrors.html), the [Internet Archive](https://archive.org/details/wikimediadownloads), and BitTorrent

## Release cadence

New dumps for each project are produced roughly **twice a month**. Each run is published under a date-stamped directory (e.g. `enwiki/20260401/`). Older runs are pruned after a few months, so pin a specific date if you need reproducibility.

## What's in a dump

Dumps come in two main flavours:

| File | Contents | Approx. size (enwiki, compressed) |
| --- | --- | --- |
| `pages-articles.xml.bz2` | Current revisions of articles, templates, and categories. No talk or user pages. | ~22 GB |
| `pages-articles-multistream.xml.bz2` | Same as above, but split into bzip2 streams so you can seek into it without decompressing the whole file (uses the accompanying `-multistream-index.txt.bz2`). | ~22 GB |
| `pages-meta-current.xml.bz2` | Current revisions of *all* pages (incl. talk, user, project namespaces). | ~25 GB |
| `pages-meta-history.xml.7z` | **Full revision history** of every page. Split into many files. | several TB uncompressed |
| `*-stub-*.xml.gz` | Page/revision metadata only (no wikitext). | small |
| SQL dumps (`*.sql.gz`) | Database tables: links, categories, redirects, page properties, etc. | varies |
| Abstracts, titles, sitelinks | Lightweight derivatives for search/indexing. | small |

For most use cases the **multistream** current-articles file is the right starting point.

Media (images, audio, video) is **not** included in the XML/SQL dumps. See [commons.wikimedia.org](https://commons.wikimedia.org/) and the [image tarballs](https://dumps.wikimedia.org/other/) for those.

## Licensing

Wikipedia text is dual-licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) and the [GFDL](https://www.gnu.org/licenses/fdl-1.3.html). Media files on Commons each carry their own licence. Attribution and share-alike obligations apply to any redistribution.

## Tooling

Working with raw dumps directly:

- [`mwxml`](https://github.com/mediawiki-utilities/python-mwxml) and [`mwparserfromhell`](https://github.com/earwig/mwparserfromhell) — Python parsing of dump XML and wikitext
- [`wikiextractor`](https://github.com/attardi/wikiextractor) — strip wikitext to plain text/JSON
- [`pydumpgen`](https://pypi.org/project/wikipedia-dump-reader/) and similar streaming readers

Pre-processed / offline browsing:

- [Kiwix](https://kiwix.org/) — offline reader using the ZIM format
- [XOWA](https://github.com/gnosygnu/xowa) — local Wikipedia browser

## License

This repository's code is released under the terms in [LICENSE](LICENSE). Wikipedia content downloaded via these tools remains under its own licence (see above).
