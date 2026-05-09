#!/usr/bin/env python3
"""
download_dumps.py — fetch the Wikipedia 20260401 dump files needed by the
"Protecting Pages, Displacing Problems" project.

Drives downloads off the official dumpstatus.json manifest (so SHA-1s and sizes
are never hardcoded), streams to disk with resume support, verifies SHA-1
against the manifest, respects WMF etiquette (max 2 concurrent connections,
identifying User-Agent), and is idempotent.

Output layout (under DUMP_ROOT):
    sql/                         # *.sql.gz
    xml/                         # *.xml.gz
    checksums/                   # md5sums.txt, sha1sums.txt
    dumpstatus.json              # cached manifest copy
    MANIFEST.md                  # human-readable per-file status
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Optional

import requests
from tqdm import tqdm


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

WIKI = "enwiki"
RUN = "20260401"
DUMP_BASE = f"https://dumps.wikimedia.org/{WIKI}/{RUN}"
DUMPSTATUS_URL = f"{DUMP_BASE}/dumpstatus.json"

DUMP_ROOT = Path(f"/media/simone/ssd1/wikidumps/{RUN}")
SQL_DIR = DUMP_ROOT / "sql"
XML_DIR = DUMP_ROOT / "xml"
CHECKSUMS_DIR = DUMP_ROOT / "checksums"
DUMPSTATUS_LOCAL = DUMP_ROOT / "dumpstatus.json"
MANIFEST_MD = DUMP_ROOT / "MANIFEST.md"

USER_AGENT = "SantoniWikipediaResearch/1.0 (simone.santoni.1@city.ac.uk)"
MAX_WORKERS = 2  # WMF etiquette: max 2 concurrent connections.
CHUNK_BYTES = 1024 * 1024  # 1 MiB
HTTP_TIMEOUT = (30, 300)  # (connect, read)
RETRY_ATTEMPTS = 3
RETRY_BACKOFF_SEC = 5

# Manifest cache TTL: re-fetch dumpstatus.json if older than this.
MANIFEST_CACHE_SECONDS = 24 * 3600  # 24h

# ---------------------------------------------------------------------------
# Default file set (Phase 1a SQL + Phase 1b XML).
# Each filename is mapped to its target subdirectory under DUMP_ROOT.
# Phase 2 stubs are only included when --phase 2 is passed.
# ---------------------------------------------------------------------------

PHASE_1A_SQL = [
    "enwiki-20260401-page.sql.gz",
    "enwiki-20260401-page_restrictions.sql.gz",
    "enwiki-20260401-protected_titles.sql.gz",
    "enwiki-20260401-user_groups.sql.gz",
    "enwiki-20260401-user_former_groups.sql.gz",
    "enwiki-20260401-change_tag.sql.gz",
    "enwiki-20260401-change_tag_def.sql.gz",
]

PHASE_1B_XML = [
    "enwiki-20260401-pages-logging.xml.gz",
]

PHASE_2_XML_PREFIX = "enwiki-20260401-stub-meta-history"  # match all 27 parts.

# Phase 3: per-revision wikitext, 7z-compressed. The 27 logical "parts"
# (history1..history27) are themselves split into many sub-parts by page-id
# range (~956 files for the 20260401 run) — we pull all of them gated behind
# --phase 3 because the total exceeds 250 GiB.
PHASE_3_XML_7Z_PREFIX = "enwiki-20260401-pages-meta-history"
PHASE_3_JOB = "metahistory7zdump"  # job name in dumpstatus.json
PHASE_3_TARGET_SUBDIR = "xml"  # 7z files land alongside other XML dumps

# Side-car checksum files (small, always fetch).
CHECKSUM_FILES = [
    "enwiki-20260401-md5sums.txt",
    "enwiki-20260401-sha1sums.txt",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def target_dir_for(filename: str) -> Path:
    if filename.endswith(".sql.gz"):
        return SQL_DIR
    if filename.endswith(".xml.gz"):
        return XML_DIR
    if filename.endswith(".7z"):
        # Phase 3 wikitext archives land alongside the other XML dumps.
        return XML_DIR
    if filename.endswith(".txt"):
        return CHECKSUMS_DIR
    # Default to DUMP_ROOT for anything else (e.g. dumpstatus.json itself).
    return DUMP_ROOT


def ensure_dirs() -> None:
    for d in (DUMP_ROOT, SQL_DIR, XML_DIR, CHECKSUMS_DIR):
        d.mkdir(parents=True, exist_ok=True)


def session_factory() -> requests.Session:
    s = requests.Session()
    s.headers.update({"User-Agent": USER_AGENT})
    return s


def sha1_of_file(path: Path) -> str:
    h = hashlib.sha1()
    with path.open("rb") as f:
        while True:
            b = f.read(CHUNK_BYTES)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

def load_manifest(session: requests.Session, force_refresh: bool = False) -> dict:
    """Fetch (or load cached) dumpstatus.json. Returns the parsed dict."""
    ensure_dirs()
    if not force_refresh and DUMPSTATUS_LOCAL.exists():
        age = time.time() - DUMPSTATUS_LOCAL.stat().st_mtime
        if age < MANIFEST_CACHE_SECONDS:
            with DUMPSTATUS_LOCAL.open("r", encoding="utf-8") as f:
                return json.load(f)
    print(f"[manifest] fetching {DUMPSTATUS_URL}")
    r = session.get(DUMPSTATUS_URL, timeout=HTTP_TIMEOUT)
    r.raise_for_status()
    DUMPSTATUS_LOCAL.write_bytes(r.content)
    return r.json()


def index_files(manifest: dict) -> dict[str, dict]:
    """Flatten the manifest into a single {filename: {size, sha1, md5, url, job}} dict."""
    flat: dict[str, dict] = {}
    for job_name, job in manifest.get("jobs", {}).items():
        for fname, meta in (job.get("files") or {}).items():
            entry = dict(meta)
            entry["job"] = job_name
            flat[fname] = entry
    return flat


# ---------------------------------------------------------------------------
# MANIFEST.md (status table)
# ---------------------------------------------------------------------------

_manifest_lock = threading.Lock()


def _read_manifest_entries() -> dict[str, dict]:
    """Read MANIFEST.md and parse out the existing rows. Robust to a missing file."""
    if not MANIFEST_MD.exists():
        return {}
    entries: dict[str, dict] = {}
    cols = ["filename", "server_sha1", "observed_sha1", "size_bytes",
            "started_utc", "finished_utc", "status"]
    with MANIFEST_MD.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.startswith("|"):
                continue
            if line.startswith("| filename") or line.startswith("|---"):
                continue
            parts = [p.strip() for p in line.strip("|").split("|")]
            if len(parts) != len(cols):
                continue
            row = dict(zip(cols, parts))
            entries[row["filename"]] = row
    return entries


def _write_manifest_entries(entries: dict[str, dict]) -> None:
    cols = ["filename", "server_sha1", "observed_sha1", "size_bytes",
            "started_utc", "finished_utc", "status"]
    headers = ["filename", "server SHA-1", "observed SHA-1", "size (bytes)",
               "started (UTC)", "finished (UTC)", "status"]
    lines = []
    lines.append(f"# Wikipedia dump download manifest — {WIKI} {RUN}")
    lines.append("")
    lines.append(f"Generated/updated by `download_dumps.py`. Run root: `{DUMP_ROOT}`.")
    lines.append("")
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join(["---"] * len(headers)) + "|")
    for fname in sorted(entries.keys()):
        row = entries[fname]
        lines.append("| " + " | ".join(row.get(c, "") for c in cols) + " |")
    lines.append("")
    MANIFEST_MD.write_text("\n".join(lines), encoding="utf-8")


def update_manifest_md(filename: str, **fields) -> None:
    """Insert or update a row in MANIFEST.md. Thread-safe."""
    with _manifest_lock:
        entries = _read_manifest_entries()
        row = entries.get(filename, {"filename": filename})
        row["filename"] = filename
        for k, v in fields.items():
            row[k] = "" if v is None else str(v)
        # Keep blanks for any unset columns.
        for col in ("server_sha1", "observed_sha1", "size_bytes",
                    "started_utc", "finished_utc", "status"):
            row.setdefault(col, "")
        entries[filename] = row
        _write_manifest_entries(entries)


# ---------------------------------------------------------------------------
# Download core
# ---------------------------------------------------------------------------

class DownloadResult:
    __slots__ = ("filename", "status", "message", "observed_sha1", "size_bytes")

    def __init__(self, filename: str, status: str, message: str = "",
                 observed_sha1: str = "", size_bytes: int = 0):
        self.filename = filename
        self.status = status  # "ok" | "skipped" | "mismatch" | "failed"
        self.message = message
        self.observed_sha1 = observed_sha1
        self.size_bytes = size_bytes


def download_one(session: requests.Session, filename: str, meta: dict) -> DownloadResult:
    """Download a single file. Returns a DownloadResult.

    Logic:
      - If file exists and SHA-1 matches manifest → skipped.
      - If file exists and SHA-1 mismatches at the right size → mismatch (no
        silent re-download).
      - If file is partial (smaller than manifest size) → resume with Range.
      - If file is missing → fresh download.
    After write, verify SHA-1 against the manifest.
    """
    server_sha1 = meta.get("sha1") or ""
    server_size = int(meta.get("size") or 0)
    target_dir = target_dir_for(filename)
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / filename
    url = f"{DUMP_BASE}/{filename}"

    # Pre-check existing file.
    if target.exists():
        local_size = target.stat().st_size
        if server_size and local_size == server_size:
            print(f"[{filename}] existing file at expected size; verifying SHA-1...")
            obs = sha1_of_file(target)
            if obs == server_sha1:
                update_manifest_md(
                    filename,
                    server_sha1=server_sha1,
                    observed_sha1=obs,
                    size_bytes=local_size,
                    finished_utc=utc_now_iso(),
                    status="ok",
                )
                msg = "already complete (SHA-1 ok)"
                print(f"[{filename}] OK already complete")
                return DownloadResult(filename, "skipped", msg, obs, local_size)
            else:
                update_manifest_md(
                    filename,
                    server_sha1=server_sha1,
                    observed_sha1=obs,
                    size_bytes=local_size,
                    finished_utc=utc_now_iso(),
                    status="mismatch",
                )
                msg = (f"local file size matches server but SHA-1 differs "
                       f"(local={obs}, server={server_sha1}). Refusing to "
                       f"silently re-download. Resolve manually (e.g. delete "
                       f"and re-run).")
                print(f"[{filename}] ERROR SHA-1 mismatch — {msg}")
                return DownloadResult(filename, "mismatch", msg, obs, local_size)
        elif server_size and local_size > server_size:
            msg = (f"local file ({local_size} B) is larger than server "
                   f"({server_size} B). Refusing to truncate; resolve manually.")
            print(f"[{filename}] ERROR oversize — {msg}")
            update_manifest_md(
                filename, server_sha1=server_sha1, size_bytes=local_size,
                status="failed",
            )
            return DownloadResult(filename, "failed", msg, "", local_size)
        else:
            # Partial download — resume.
            resume_offset = local_size
            return _stream_to_disk(
                session, url, target, server_size, server_sha1, filename,
                resume_offset=resume_offset,
            )
    else:
        return _stream_to_disk(
            session, url, target, server_size, server_sha1, filename,
            resume_offset=0,
        )


def _stream_to_disk(session: requests.Session, url: str, target: Path,
                    server_size: int, server_sha1: str, filename: str,
                    resume_offset: int = 0) -> DownloadResult:
    started = utc_now_iso()
    update_manifest_md(
        filename,
        server_sha1=server_sha1,
        size_bytes=server_size,
        started_utc=started,
        status="downloading",
    )

    last_exc: Optional[Exception] = None
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        headers: dict[str, str] = {}
        mode = "wb"
        offset = 0
        if resume_offset > 0:
            headers["Range"] = f"bytes={resume_offset}-"
            mode = "ab"
            offset = resume_offset
            print(f"[{filename}] resuming from byte {offset}")
        try:
            with session.get(url, headers=headers, stream=True,
                             timeout=HTTP_TIMEOUT) as r:
                if resume_offset > 0 and r.status_code == 200:
                    # Server ignored our Range header; restart from scratch.
                    print(f"[{filename}] server ignored Range; restarting fresh")
                    mode = "wb"
                    offset = 0
                elif resume_offset > 0 and r.status_code != 206:
                    r.raise_for_status()
                else:
                    r.raise_for_status()

                total = server_size if server_size else None
                desc = filename if len(filename) <= 50 else filename[-50:]
                with target.open(mode) as f, tqdm(
                    total=total, initial=offset, unit="B", unit_scale=True,
                    unit_divisor=1024, desc=desc, leave=True,
                ) as bar:
                    for chunk in r.iter_content(chunk_size=CHUNK_BYTES):
                        if not chunk:
                            continue
                        f.write(chunk)
                        bar.update(len(chunk))
            break  # success
        except (requests.RequestException, OSError) as e:
            last_exc = e
            print(f"[{filename}] attempt {attempt}/{RETRY_ATTEMPTS} failed: {e}")
            if attempt < RETRY_ATTEMPTS:
                time.sleep(RETRY_BACKOFF_SEC * attempt)
                # Next attempt resumes from current on-disk size.
                resume_offset = target.stat().st_size if target.exists() else 0
            else:
                update_manifest_md(
                    filename,
                    finished_utc=utc_now_iso(),
                    status="failed",
                )
                return DownloadResult(filename, "failed", str(e), "",
                                      target.stat().st_size if target.exists() else 0)
    else:
        # Loop exhausted without break.
        return DownloadResult(filename, "failed", str(last_exc) if last_exc else "unknown error")

    # Post-download verification.
    final_size = target.stat().st_size
    if server_size and final_size != server_size:
        msg = (f"size after download ({final_size}) != manifest "
               f"({server_size}); marking partial.")
        print(f"[{filename}] WARNING {msg}")
        update_manifest_md(
            filename,
            size_bytes=final_size,
            finished_utc=utc_now_iso(),
            status="partial",
        )
        return DownloadResult(filename, "failed", msg, "", final_size)

    print(f"[{filename}] verifying SHA-1...")
    obs = sha1_of_file(target)
    if obs == server_sha1:
        update_manifest_md(
            filename,
            server_sha1=server_sha1,
            observed_sha1=obs,
            size_bytes=final_size,
            finished_utc=utc_now_iso(),
            status="ok",
        )
        print(f"[{filename}] OK SHA-1 verified ({obs})")
        return DownloadResult(filename, "ok", "downloaded and SHA-1 verified",
                              obs, final_size)
    else:
        update_manifest_md(
            filename,
            server_sha1=server_sha1,
            observed_sha1=obs,
            size_bytes=final_size,
            finished_utc=utc_now_iso(),
            status="mismatch",
        )
        msg = (f"SHA-1 mismatch after download (local={obs}, "
               f"server={server_sha1}).")
        print(f"[{filename}] ERROR {msg}")
        return DownloadResult(filename, "mismatch", msg, obs, final_size)


# ---------------------------------------------------------------------------
# Selection logic
# ---------------------------------------------------------------------------

def select_files(manifest_index: dict[str, dict],
                 explicit: Optional[list[str]],
                 phase: int) -> list[str]:
    """Return the ordered list of filenames to download."""
    if explicit:
        unknown = [f for f in explicit if f not in manifest_index]
        if unknown:
            raise SystemExit(
                f"Unknown filename(s) not in manifest: {unknown}\n"
                f"(Are you sure the run ID is {RUN}?)"
            )
        return list(explicit)

    selected: list[str] = []
    selected.extend(PHASE_1A_SQL)
    selected.extend(PHASE_1B_XML)

    if phase >= 2:
        stubs = sorted(
            f for f in manifest_index
            if f.startswith(PHASE_2_XML_PREFIX) and f.endswith(".xml.gz")
        )
        selected.extend(stubs)

    if phase >= 3:
        # pages-meta-history*.xml-pNpM.7z — pulled from metahistory7zdump.
        # The 27 logical "parts" (history1..history27) split into ~956
        # sub-files by page-id range; we pull every sub-file in the job.
        # Filter on both filename prefix and the manifest's own job tag,
        # so we don't accidentally pick up unrelated 7z files.
        meta_history = sorted(
            f for f, m in manifest_index.items()
            if f.startswith(PHASE_3_XML_7Z_PREFIX)
            and f.endswith(".7z")
            and m.get("job") == PHASE_3_JOB
        )
        selected.extend(meta_history)

    # Always include side-car checksum files when they are present in any job.
    for ck in CHECKSUM_FILES:
        if ck in manifest_index and ck not in selected:
            selected.append(ck)

    # Validate they all exist in manifest.
    missing = [f for f in selected if f not in manifest_index]
    if missing:
        raise SystemExit(
            f"The following defaulted filenames are not present in the "
            f"manifest for {RUN}: {missing}"
        )
    return selected


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dry-run", action="store_true",
                   help="Show planned downloads and exit without fetching.")
    p.add_argument("--files", nargs="+", default=None,
                   help="Specific filenames to download (must match manifest).")
    p.add_argument("--phase", type=int, default=1, choices=[1, 2, 3],
                   help="1 (default): Phase 1a SQL + Phase 1b logging XML. "
                        "2: also fetch all 27 stub-meta-history*.xml.gz parts. "
                        "3: also fetch all pages-meta-history*.xml.7z parts "
                        "(huge — 250+ GiB; only when wikitext is needed).")
    p.add_argument("--refresh-manifest", action="store_true",
                   help="Re-fetch dumpstatus.json even if a recent cache exists.")
    args = p.parse_args(argv)

    ensure_dirs()
    session = session_factory()
    manifest = load_manifest(session, force_refresh=args.refresh_manifest)
    index = index_files(manifest)

    try:
        files = select_files(index, args.files, args.phase)
    except SystemExit as e:
        print(str(e), file=sys.stderr)
        return 2

    print(f"\n[plan] run = {WIKI}/{RUN}")
    print(f"[plan] root = {DUMP_ROOT}")
    print(f"[plan] {len(files)} file(s) to consider:")
    total_size = 0
    for f in files:
        meta = index[f]
        size = int(meta.get("size") or 0)
        total_size += size
        target = target_dir_for(f) / f
        size_mb = size / (1024 * 1024) if size else 0.0
        print(f"  - {f}  ({size_mb:,.1f} MB)  -> {target}")
    print(f"[plan] total approx size: {total_size / (1024 ** 3):,.2f} GiB")

    if args.dry_run:
        print("\n[dry-run] no downloads performed.")
        return 0

    print(f"\n[run] starting downloads (max {MAX_WORKERS} concurrent, "
          f"User-Agent: {USER_AGENT!r})")

    results: list[DownloadResult] = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futures = {ex.submit(download_one, session, f, index[f]): f
                   for f in files}
        for fut in as_completed(futures):
            fname = futures[fut]
            try:
                results.append(fut.result())
            except Exception as e:  # noqa: BLE001
                print(f"[{fname}] uncaught error: {e}")
                results.append(DownloadResult(fname, "failed", str(e)))

    # Summary.
    n_ok = sum(1 for r in results if r.status == "ok")
    n_skip = sum(1 for r in results if r.status == "skipped")
    n_mismatch = sum(1 for r in results if r.status == "mismatch")
    n_fail = sum(1 for r in results if r.status == "failed")
    print("\n=========================== SUMMARY ===========================")
    print(f"  complete (downloaded this run): {n_ok}")
    print(f"  skipped (already complete):     {n_skip}")
    print(f"  SHA-1 mismatch:                 {n_mismatch}")
    print(f"  failed:                         {n_fail}")
    print(f"  manifest report:                {MANIFEST_MD}")
    print("===============================================================")

    if n_mismatch or n_fail:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
