#!/usr/bin/env python3
"""
load_pages_meta_history_xml.py — Phase 3 ingest of enwiki pages-meta-history
XML.7z files into the Postgres ``revision_text`` table of the wiki20260401 DB.

The ``pages-meta-history*.xml.7z`` files are the only published source of
per-revision wikitext on the WMF dump server. Unlike the gzip stub dumps used
by Phase 2, these are **7z-compressed**, so this loader uses ``py7zr`` to
stream-decompress and pipe the inner XML into ``mwxml`` without ever
materializing the (multi-GB) inner XML on disk.

Loader strategy
---------------
1. Drop the FK ``revision_text.rev_id -> revision.rev_id`` (per-row FK
   verification dominates wall time on a multi-billion-row revision table).
2. ``TRUNCATE revision_text`` (after dropping FK).
3. For each input ``.xml.7z`` file: spawn a producer thread that runs
   ``py7zr.SevenZipFile.extract(factory=...)`` and pushes decompressed bytes
   onto a bounded queue; the main thread consumes the queue as a file-like
   object that ``mwxml.Dump.from_file`` can read. For each revision write
   ``(rev_id, rev_text bytes, rev_text_bytes)`` via psycopg's binary COPY
   into ``revision_text``.
4. After all files: re-create the FK and ANALYZE.

Edge cases
----------
* ``<text deleted="deleted" />`` (suppressed wikitext): skip — the row is
  represented in ``revision`` (with whatever metadata survived) but not here.
  Hence ``COUNT(revision_text) <= COUNT(revision)``.
* Missing/empty ``<text>``: empty string treated as 0-byte wikitext (still
  inserted), since an empty edit is meaningfully distinct from a suppressed one.
* rev_ids not present in ``revision`` (which is loaded by the Phase 2 stub
  loader before Phase 3 runs): a defensive per-batch existence check filters
  them out so the post-load FK re-creation never fails on dangling rows.

CLI
---
    python load_pages_meta_history_xml.py
    python load_pages_meta_history_xml.py --files <p1> <p2>
    python load_pages_meta_history_xml.py --dry-run
    python load_pages_meta_history_xml.py --limit N
    python load_pages_meta_history_xml.py --workers N
    python load_pages_meta_history_xml.py --keep-fk

Connect via libpq ``service=wiki`` (port encoded in ~/.pg_service.conf).
"""

from __future__ import annotations

import argparse
import dataclasses
import io
import logging
import queue
import threading
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Iterator, Optional

import mwxml
import psycopg
import py7zr

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DUMP_XML_DIR = Path("/media/simone/ssd1/wikidumps/20260401/xml")
META_HISTORY_GLOB = "enwiki-20260401-pages-meta-history*.xml.7z"

PG_SERVICE = "service=wiki"
BATCH_SIZE = 5_000
PROGRESS_EVERY = 100_000
QUEUE_MAXSIZE = 8  # bounded backpressure between decompressor + parser

# FK we drop/recreate around bulk load.
FK_NAME = "revision_text_rev_id_fkey"
FK_CREATE_SQL = (
    f"ALTER TABLE revision_text "
    f"ADD CONSTRAINT {FK_NAME} "
    f"FOREIGN KEY (rev_id) REFERENCES revision(rev_id)"
)

logger = logging.getLogger("load_pages_meta_history_xml")


# ---------------------------------------------------------------------------
# Tuple shape for COPY
# ---------------------------------------------------------------------------

@dataclasses.dataclass(slots=True)
class RevisionTextRow:
    rev_id: int
    rev_text: bytes
    rev_text_bytes: int


# ---------------------------------------------------------------------------
# 7z streaming helpers
# ---------------------------------------------------------------------------

class _QueuePy7zIO(py7zr.io.Py7zIO):
    """Py7zIO whose ``write`` calls push decompressed bytes onto a Queue.

    py7zr 1.x replaced the old ``read()`` API with a factory-based extract
    interface: ``zf.extract(factory=...)`` invokes ``factory.create(name)``
    once per archive entry and writes the decompressed payload via the
    returned Py7zIO's ``write`` method. We ignore the supposedly-readable
    side of Py7zIO — bytes are consumed off the queue by the parser thread.
    """

    def __init__(self, q: queue.Queue):
        self._q = q
        self._size = 0

    def write(self, s):  # py7zr -> us
        if isinstance(s, (bytes, bytearray, memoryview)):
            chunk = bytes(s)
        else:
            chunk = bytes(s)
        if chunk:
            self._q.put(chunk)
            self._size += len(chunk)
        return len(chunk)

    def read(self, size=None):  # unused
        return b""

    def seek(self, offset, whence=0):  # unused
        return 0

    def size(self):
        return self._size

    def flush(self):
        pass


class _QueueFactory(py7zr.io.WriterFactory):
    """WriterFactory yielding a single _QueuePy7zIO for the inner xml file.

    These dumps contain exactly one inner .xml file per .7z. We assert that
    invariant: a multi-entry archive would silently corrupt the stream.
    """

    def __init__(self, q: queue.Queue):
        self.q = q
        self.created_names: list[str] = []

    def create(self, filename: str):
        self.created_names.append(filename)
        if len(self.created_names) > 1:
            raise RuntimeError(
                f"Unexpected multi-entry .7z (entries: {self.created_names}); "
                f"these dumps are documented as one inner XML per archive."
            )
        return _QueuePy7zIO(self.q)


class _QueueRawReader(io.RawIOBase):
    """RawIOBase that reads bytes off a Queue produced by _QueuePy7zIO.

    The producer puts ``None`` to signal EOF. Wrap in BufferedReader/
    TextIOWrapper for mwxml.
    """

    def __init__(self, q: queue.Queue):
        self._q = q
        self._buf = b""
        self._eof = False

    def readable(self) -> bool:
        return True

    def readinto(self, b) -> int:
        n = len(b)
        out = memoryview(b)
        filled = 0
        while filled < n:
            if self._buf:
                take = min(len(self._buf), n - filled)
                out[filled:filled + take] = self._buf[:take]
                self._buf = self._buf[take:]
                filled += take
                continue
            if self._eof:
                break
            chunk = self._q.get()
            if chunk is None:
                self._eof = True
                break
            self._buf = chunk
        return filled


def open_7z_xml_stream(path: Path) -> tuple[io.IOBase, threading.Thread, list]:
    """Stream-decompress ``path`` (.xml.7z) and return (text_fp, producer, errors).

    The caller iterates ``mwxml.Dump.from_file(text_fp)``; the producer thread
    fills the underlying queue. After consumption, caller must ``producer.join()``
    and check ``errors`` (a list — non-empty means the producer raised).
    """
    q: queue.Queue = queue.Queue(maxsize=QUEUE_MAXSIZE)
    factory = _QueueFactory(q)
    errors: list[BaseException] = []

    def _produce():
        try:
            with py7zr.SevenZipFile(str(path), mode="r") as zf:
                zf.extract(factory=factory)
        except BaseException as e:  # noqa: BLE001
            errors.append(e)
        finally:
            q.put(None)

    t = threading.Thread(target=_produce, name=f"7z-extract:{path.name}",
                         daemon=True)
    t.start()
    raw = _QueueRawReader(q)
    buf = io.BufferedReader(raw)
    text_fp = io.TextIOWrapper(buf, encoding="utf-8", errors="surrogatepass")
    return text_fp, t, errors


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

@dataclasses.dataclass
class ParseStats:
    revisions_seen: int = 0
    revisions_loaded: int = 0
    skipped_text_deleted: int = 0
    skipped_no_revision_match: int = 0  # rev_id not in revision (defensive)


def _open_xml_for_parse(path: Path) -> tuple[io.IOBase, Optional[threading.Thread], Optional[list]]:
    """Open path as a text file-like for mwxml. Returns (fp, producer_or_None, errors_or_None)."""
    if path.suffix == ".7z":
        return open_7z_xml_stream(path)
    if path.suffix == ".gz":
        # Useful for tests and gzip-of-XML files mwxml normally handles.
        import gzip
        fp = gzip.open(str(path), "rt", encoding="utf-8", errors="surrogatepass")
        return fp, None, None
    fp = open(path, "rt", encoding="utf-8", errors="surrogatepass")
    return fp, None, None


def parse_revisions(
    path: Path,
    stats: ParseStats,
    limit: Optional[int] = None,
) -> Iterator[RevisionTextRow]:
    """Stream-parse ``path`` and yield RevisionTextRow for each non-deleted text.

    ``limit`` caps the number of *yielded* rows (i.e. rows that reach the DB)
    per file — useful for fast unit/integration tests.
    """
    text_fp, producer, errors = _open_xml_for_parse(path)
    try:
        dump = mwxml.Dump.from_file(text_fp)
        for page in dump:
            for rev in page:
                stats.revisions_seen += 1
                if limit is not None and stats.revisions_loaded >= limit:
                    return
                # <text deleted="deleted" /> -> rev.deleted.text True.
                if rev.deleted and rev.deleted.text:
                    stats.skipped_text_deleted += 1
                    continue
                text_str = rev.text or ""
                # Encode wikitext as UTF-8 bytes; bytea is byte-transparent.
                rev_text = text_str.encode("utf-8", errors="surrogatepass")
                yield RevisionTextRow(
                    rev_id=int(rev.id),
                    rev_text=rev_text,
                    rev_text_bytes=len(rev_text),
                )
                stats.revisions_loaded += 1
    finally:
        try:
            text_fp.close()
        except Exception:
            pass
        if producer is not None:
            producer.join(timeout=5)
        if errors:
            raise errors[0]


# ---------------------------------------------------------------------------
# COPY writer
# ---------------------------------------------------------------------------

COPY_COLUMNS = ("rev_id", "rev_text", "rev_text_bytes")


def filter_existing_rev_ids(
    conn: psycopg.Connection, batch: list[RevisionTextRow]
) -> list[RevisionTextRow]:
    """Return the subset of ``batch`` whose rev_ids exist in revision.

    Defensive guard: with the FK dropped during bulk load, a stray rev_id from
    a corrupt/mismatched dump file would silently pollute revision_text. A
    cheap per-batch existence check preserves the post-load FK invariant.
    """
    if not batch:
        return batch
    ids = [r.rev_id for r in batch]
    with conn.cursor() as cur:
        cur.execute(
            "SELECT rev_id FROM revision WHERE rev_id = ANY(%s)",
            (ids,),
        )
        present = {row[0] for row in cur.fetchall()}
    return [r for r in batch if r.rev_id in present]


def copy_batch(conn: psycopg.Connection, rows: list[RevisionTextRow]) -> None:
    if not rows:
        return
    cols = ", ".join(COPY_COLUMNS)
    sql = f"COPY revision_text ({cols}) FROM STDIN WITH (FORMAT BINARY)"
    with conn.cursor() as cur, cur.copy(sql) as cp:
        cp.set_types(["int8", "bytea", "int8"])
        for r in rows:
            cp.write_row((r.rev_id, r.rev_text, r.rev_text_bytes))


# ---------------------------------------------------------------------------
# Per-file driver
# ---------------------------------------------------------------------------

def load_one_file(
    path: Path,
    limit: Optional[int],
    dry_run: bool,
    skip_revision_check: bool = False,
) -> dict:
    """Load (or dry-parse) one .xml.7z file. Returns a stats dict.

    Each call opens its own DB connection so it is safe under
    ProcessPoolExecutor.
    """
    t0 = time.time()
    stats = ParseStats()

    if dry_run:
        for _row in parse_revisions(path, stats, limit=limit):
            n = stats.revisions_loaded
            if n and n % PROGRESS_EVERY == 0:
                logger.info("[%s] dry-run: %d revisions parsed",
                            path.name, n)
        elapsed = time.time() - t0
        logger.info(
            "[%s] dry-run done: seen=%d parsed=%d skipped_text_deleted=%d "
            "in %.1fs",
            path.name, stats.revisions_seen, stats.revisions_loaded,
            stats.skipped_text_deleted, elapsed,
        )
        return {
            "file": path.name,
            "seen": stats.revisions_seen,
            "loaded": stats.revisions_loaded,
            "skipped_text_deleted": stats.skipped_text_deleted,
            "skipped_no_revision_match": stats.skipped_no_revision_match,
            "elapsed_sec": elapsed,
        }

    with psycopg.connect(PG_SERVICE) as conn:
        with conn.cursor() as cur:
            cur.execute("SET LOCAL synchronous_commit = OFF")
            cur.execute("SET LOCAL maintenance_work_mem = '2GB'")
            cur.execute("SET LOCAL work_mem = '256MB'")

        batch: list[RevisionTextRow] = []
        last_logged = 0
        for row in parse_revisions(path, stats, limit=limit):
            batch.append(row)
            if len(batch) >= BATCH_SIZE:
                if skip_revision_check:
                    keep = batch
                else:
                    keep = filter_existing_rev_ids(conn, batch)
                    stats.skipped_no_revision_match += len(batch) - len(keep)
                copy_batch(conn, keep)
                conn.commit()
                batch.clear()
            if stats.revisions_loaded - last_logged >= PROGRESS_EVERY:
                logger.info(
                    "[%s] %d revisions parsed (%.0f rev/s)",
                    path.name, stats.revisions_loaded,
                    stats.revisions_loaded / max(time.time() - t0, 1e-6),
                )
                last_logged = stats.revisions_loaded
        if batch:
            if skip_revision_check:
                keep = batch
            else:
                keep = filter_existing_rev_ids(conn, batch)
                stats.skipped_no_revision_match += len(batch) - len(keep)
            copy_batch(conn, keep)
            conn.commit()
            batch.clear()

    elapsed = time.time() - t0
    logger.info(
        "[%s] done: seen=%d loaded=%d skipped_text_deleted=%d "
        "skipped_no_revision_match=%d in %.1fs (%.0f rev/s)",
        path.name, stats.revisions_seen, stats.revisions_loaded,
        stats.skipped_text_deleted, stats.skipped_no_revision_match, elapsed,
        stats.revisions_loaded / max(elapsed, 1e-6),
    )
    return {
        "file": path.name,
        "seen": stats.revisions_seen,
        "loaded": stats.revisions_loaded,
        "skipped_text_deleted": stats.skipped_text_deleted,
        "skipped_no_revision_match": stats.skipped_no_revision_match,
        "elapsed_sec": elapsed,
    }


# ---------------------------------------------------------------------------
# Top-level orchestration
# ---------------------------------------------------------------------------

def discover_files() -> list[Path]:
    return sorted(DUMP_XML_DIR.glob(META_HISTORY_GLOB))


def _natural_part_key(p: Path):
    """Sort pages-meta-historyN.xml-pAApBB.7z by (N, A) for natural order."""
    import re
    m = re.search(r"pages-meta-history(\d+)\.xml(?:-p(\d+)p\d+)?", p.name)
    if not m:
        return (-1, -1)
    return (int(m.group(1)), int(m.group(2)) if m.group(2) else -1)


def drop_fk(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(f"ALTER TABLE revision_text DROP CONSTRAINT IF EXISTS {FK_NAME}")
        logger.info("dropped FK %s (will be re-created post-load)", FK_NAME)
    conn.commit()


def recreate_fk(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("SET maintenance_work_mem = '4GB'")
        t0 = time.time()
        logger.info("re-creating FK %s ...", FK_NAME)
        cur.execute(FK_CREATE_SQL)
        logger.info("re-created FK %s in %.1fs", FK_NAME, time.time() - t0)
        logger.info("ANALYZE revision_text ...")
        cur.execute("ANALYZE revision_text")
    conn.commit()


def truncate_revision_text(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE revision_text")
        logger.info("TRUNCATEd revision_text")
    conn.commit()


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--files", nargs="+", default=None,
                   help="Specific pages-meta-history*.xml.7z files to load.")
    p.add_argument("--dry-run", action="store_true",
                   help="Parse and count only; do not connect to the DB.")
    p.add_argument("--limit", type=int, default=None,
                   help="Limit total revisions parsed per file (testing).")
    p.add_argument("--workers", type=int, default=1,
                   help="Parallel processes loading files (default 1; >4 not "
                        "advised — WAL becomes the bottleneck).")
    p.add_argument("--keep-fk", action="store_true",
                   help="Do not drop / recreate the FK to revision.")
    p.add_argument("--keep-indexes", action="store_true",
                   help="Alias of --keep-fk (revision_text has no non-PK "
                        "indexes by default).")
    p.add_argument("--no-truncate", action="store_true",
                   help="Skip TRUNCATE revision_text (testing/incremental).")
    p.add_argument("--skip-revision-check", action="store_true",
                   help="Trust input rev_ids; skip the per-batch existence "
                        "check against revision (faster, less defensive).")
    p.add_argument("--log-level", default="INFO",
                   help="Logging level (default INFO).")
    args = p.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    if args.files:
        files = [Path(f) for f in args.files]
    else:
        files = discover_files()

    if not files:
        logger.warning("no input files matched %s/%s",
                       DUMP_XML_DIR, META_HISTORY_GLOB)
        if args.dry_run:
            logger.info("dry-run: 0 candidate files; nothing to do")
            return 0
        return 2
    files = sorted(files, key=_natural_part_key)

    keep_fk = args.keep_fk or args.keep_indexes

    logger.info("plan: %d files, workers=%d dry_run=%s limit=%s keep_fk=%s",
                len(files), args.workers, args.dry_run, args.limit, keep_fk)
    for f in files:
        if not f.exists():
            logger.error("missing file: %s", f)
            return 2
        logger.info("  %s (%.1f MB)", f, f.stat().st_size / (1024 * 1024))

    if not args.dry_run:
        with psycopg.connect(PG_SERVICE) as conn:
            if not keep_fk:
                drop_fk(conn)
            if not args.no_truncate:
                truncate_revision_text(conn)

    t0 = time.time()
    results: list[dict] = []
    if args.workers > 1 and not args.dry_run:
        with ProcessPoolExecutor(max_workers=args.workers) as ex:
            futures = {
                ex.submit(load_one_file, f, args.limit, args.dry_run,
                          args.skip_revision_check): f
                for f in files
            }
            for fut in as_completed(futures):
                results.append(fut.result())
    else:
        for f in files:
            results.append(load_one_file(
                f, args.limit, args.dry_run, args.skip_revision_check))

    if not args.dry_run and not keep_fk:
        with psycopg.connect(PG_SERVICE) as conn:
            recreate_fk(conn)

    total_loaded = sum(r["loaded"] for r in results)
    total_seen = sum(r["seen"] for r in results)
    total_skipped_dt = sum(r["skipped_text_deleted"] for r in results)
    total_skipped_nm = sum(r["skipped_no_revision_match"] for r in results)
    elapsed = time.time() - t0
    logger.info("=" * 60)
    logger.info(
        "ALL DONE in %.1fs: seen=%d loaded=%d skipped_text_deleted=%d "
        "skipped_no_revision_match=%d",
        elapsed, total_seen, total_loaded, total_skipped_dt, total_skipped_nm,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
