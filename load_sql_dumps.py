#!/usr/bin/env python3
"""
load_sql_dumps.py - load mysqldump .sql.gz files into Postgres via COPY.

Phase 1a of the "Protecting Pages, Displacing Problems" project (see
data_collection_plan.md). Targets the 7 native-SQL tables:

    page, page_restrictions, protected_titles, user_groups,
    user_former_groups, change_tag, change_tag_def.

Approach
--------
1. Parse the dump's `CREATE TABLE` block to discover the column order written
   by mysqldump (`mysql_cols`).
2. Stream `INSERT INTO ... VALUES (...),(...);` statements, parse each tuple
   carefully (handling backslash escapes, _binary 0x..., NULL, numerics),
   then convert each value to a Postgres-typed value matching the target
   column.
3. Stream tuples into Postgres via `cursor.copy(... FROM STDIN).write_row()`.

Idempotency: each load TRUNCATEs the target table first. Per-table indexes
are dropped before COPY and recreated after (parsed out of schema/indexes.sql).

Connect via `service=wiki` (port encoded in ~/.pg_service.conf).
"""

from __future__ import annotations

import argparse
import gzip
import io
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional

import psycopg


# ---------------------------------------------------------------------------
# Constants / config
# ---------------------------------------------------------------------------

DUMP_DIR = Path("/media/simone/ssd1/wikidumps/20260401/sql")
RUN_ID = "20260401"
WIKI = "enwiki"

REPO_ROOT = Path(__file__).resolve().parent
INDEXES_SQL_PATH = REPO_ROOT / "schema" / "indexes.sql"

# Order: small tables first; big tables last. Lets the user observe progress
# on cheap ones before committing to multi-hour loads.
DEFAULT_TABLE_ORDER = [
    "change_tag_def",
    "user_former_groups",
    "user_groups",
    "page_restrictions",
    "protected_titles",
    "page",
    "change_tag",
]


# ---------------------------------------------------------------------------
# Per-table column/type metadata.
# Postgres-side column order MUST match the order we yield from the parser.
# We pin to the dump's documented column order (= MediaWiki schema order),
# which we also assert against the parsed CREATE TABLE.
# ---------------------------------------------------------------------------

# Postgres types we emit values for. Used by the COPY writer and the
# value-converter dispatcher.
PG_TYPES = {
    # int-like
    "bigint", "integer",
    # float
    "double",
    # string / blob
    "text", "bytea",
    # bool
    "boolean",
    # time
    "timestamptz",
}


TABLES: dict[str, dict] = {
    "user_groups": {
        "mysql_cols": ["ug_user", "ug_group", "ug_expiry"],
        "pg_cols":    ["ug_user", "ug_group", "ug_expiry"],
        "pg_types":   ["bigint",  "text",     "timestamptz"],
    },
    "user_former_groups": {
        "mysql_cols": ["ufg_user", "ufg_group"],
        "pg_cols":    ["ufg_user", "ufg_group"],
        "pg_types":   ["bigint",   "text"],
    },
    "page_restrictions": {
        # 20260401 dump dropped pr_user (deprecated since the actor refactor).
        # MW dump now: pr_page, pr_type, pr_level, pr_cascade, pr_expiry, pr_id
        # PG schema:   pr_id, pr_page, pr_type, pr_level, pr_cascade, pr_expiry
        "mysql_cols": ["pr_page", "pr_type", "pr_level", "pr_cascade", "pr_expiry", "pr_id"],
        "pg_cols":    ["pr_id", "pr_page", "pr_type", "pr_level", "pr_cascade", "pr_expiry"],
        # produced by the per-table converter — emitted in pg_cols order
        "pg_types":   ["bigint", "bigint", "text",   "text",     "boolean",   "timestamptz"],
    },
    "protected_titles": {
        # MW order
        "mysql_cols": ["pt_namespace", "pt_title", "pt_user", "pt_reason_id",
                       "pt_timestamp", "pt_expiry", "pt_create_perm"],
        "pg_cols":    ["pt_namespace", "pt_title", "pt_user", "pt_reason_id",
                       "pt_timestamp", "pt_expiry", "pt_create_perm"],
        "pg_types":   ["integer",      "bytea",    "bigint",  "bigint",
                       "timestamptz",  "timestamptz", "text"],
    },
    "change_tag_def": {
        "mysql_cols": ["ctd_id", "ctd_name", "ctd_user_defined", "ctd_count"],
        "pg_cols":    ["ctd_id", "ctd_name", "ctd_user_defined", "ctd_count"],
        "pg_types":   ["bigint", "text",     "boolean",          "bigint"],
    },
    "change_tag": {
        "mysql_cols": ["ct_id", "ct_rc_id", "ct_log_id", "ct_rev_id", "ct_params", "ct_tag_id"],
        "pg_cols":    ["ct_id", "ct_rc_id", "ct_log_id", "ct_rev_id", "ct_params", "ct_tag_id"],
        "pg_types":   ["bigint", "bigint",  "bigint",    "bigint",    "bytea",     "bigint"],
    },
    "page": {
        "mysql_cols": ["page_id", "page_namespace", "page_title", "page_is_redirect",
                       "page_is_new", "page_random", "page_touched", "page_links_updated",
                       "page_latest", "page_len", "page_content_model", "page_lang"],
        "pg_cols":    ["page_id", "page_namespace", "page_title", "page_is_redirect",
                       "page_is_new", "page_random", "page_touched", "page_links_updated",
                       "page_latest", "page_len", "page_content_model", "page_lang"],
        "pg_types":   ["bigint",  "integer",        "bytea",      "boolean",
                       "boolean", "double",         "timestamptz", "timestamptz",
                       "bigint",  "bigint",         "text",        "text"],
    },
}


# ---------------------------------------------------------------------------
# mysqldump VALUES tuple parser.
# ---------------------------------------------------------------------------

def _scan_mysql_string(buf: str, i: int) -> tuple[str, int]:
    """Scan a single-quoted MySQL string starting at buf[i]=="'".

    Returns (decoded_str, index_after_closing_quote). Decodes the standard
    mysqldump escape set: \\0 \\b \\n \\r \\t \\Z \\\\ \\' \\". Other
    backslash-prefixed bytes are passed through literally.
    """
    assert buf[i] == "'"
    i += 1
    out: list[str] = []
    n = len(buf)
    while i < n:
        c = buf[i]
        if c == "\\":
            i += 1
            if i >= n:
                # truncated; line continues on next chunk — caller should
                # have ensured a full statement was passed in.
                raise ValueError("truncated escape sequence in MySQL string")
            esc = buf[i]
            mapping = {
                "0": "\x00",
                "b": "\b",
                "n": "\n",
                "r": "\r",
                "t": "\t",
                "Z": "\x1a",
                "\\": "\\",
                "'": "'",
                '"': '"',
            }
            out.append(mapping.get(esc, esc))
            i += 1
        elif c == "'":
            # Could be end-of-string OR (rare) doubled '' meaning literal '.
            # mysqldump emits backslash-escaped quotes by default, but accept
            # SQL-standard doubled quotes too.
            if i + 1 < n and buf[i + 1] == "'":
                out.append("'")
                i += 2
            else:
                return "".join(out), i + 1
        else:
            out.append(c)
            i += 1
    raise ValueError("unterminated MySQL string literal")


_HEX_RE = re.compile(r"0[xX]([0-9A-Fa-f]+)")


def parse_values_tuples(insert_payload: str) -> Iterator[list]:
    """Yield raw tuples from a single `INSERT INTO ... VALUES <payload>;` body.

    `insert_payload` is the substring AFTER the keyword `VALUES` and BEFORE
    the trailing semicolon (whitespace tolerated). Each yielded tuple is a
    list whose elements are one of:

        - str   (from quoted MySQL strings — already escape-decoded)
        - int / float (from bare numerics)
        - bytes (from `_binary 0x...` literals or `0x...` hex literals)
        - None  (from bare NULL)
    """
    s = insert_payload
    n = len(s)
    i = 0
    while i < n:
        # skip whitespace, commas
        while i < n and s[i] in " \t\r\n,":
            i += 1
        if i >= n:
            return
        if s[i] != "(":
            raise ValueError(f"expected '(' at offset {i}, got {s[i]!r}")
        i += 1
        row: list = []
        while True:
            # skip whitespace
            while i < n and s[i] in " \t\r\n":
                i += 1
            if i >= n:
                raise ValueError("unterminated tuple")
            c = s[i]
            if c == "'":
                val, i = _scan_mysql_string(s, i)
                row.append(val)
            elif c == "N" and s.startswith("NULL", i):
                row.append(None)
                i += 4
            elif c == "_" and s.startswith("_binary", i):
                # _binary 'literal' or _binary 0x...
                i += len("_binary")
                while i < n and s[i] in " \t\r\n":
                    i += 1
                if i >= n:
                    raise ValueError("dangling _binary")
                if s[i] == "'":
                    val, i = _scan_mysql_string(s, i)
                    # Re-encode latin-1 so each unicode codepoint maps back to
                    # the original byte (mysqldump treats varbinary as bytes
                    # with backslash escapes, no charset).
                    row.append(val.encode("latin-1"))
                elif s[i] == "0" and i + 1 < n and s[i + 1] in "xX":
                    m = _HEX_RE.match(s, i)
                    if not m:
                        raise ValueError("bad _binary hex literal")
                    row.append(bytes.fromhex(m.group(1)))
                    i = m.end()
                else:
                    raise ValueError(f"unexpected _binary form at {i}: {s[i:i+10]!r}")
            elif c == "0" and i + 1 < n and s[i + 1] in "xX":
                # bare 0x... hex literal (mysqldump emits these for VARBINARY)
                m = _HEX_RE.match(s, i)
                if not m:
                    raise ValueError("bad hex literal")
                row.append(bytes.fromhex(m.group(1)))
                i = m.end()
            elif c in "-+0123456789.":
                # numeric literal
                j = i
                if c in "-+":
                    j += 1
                while j < n and s[j] in "0123456789.eE+-":
                    j += 1
                tok = s[i:j]
                if "." in tok or "e" in tok or "E" in tok:
                    row.append(float(tok))
                else:
                    row.append(int(tok))
                i = j
            else:
                raise ValueError(f"unexpected token at offset {i}: {s[i:i+20]!r}")
            # skip whitespace
            while i < n and s[i] in " \t\r\n":
                i += 1
            if i >= n:
                raise ValueError("unterminated tuple")
            if s[i] == ",":
                i += 1
                continue
            if s[i] == ")":
                i += 1
                yield row
                break
            raise ValueError(f"expected ',' or ')' at offset {i}, got {s[i]!r}")


# ---------------------------------------------------------------------------
# CREATE TABLE column-name discovery (sanity check vs TABLES[name]).
# ---------------------------------------------------------------------------

def discover_create_table_columns(text_iter: Iterator[str], expected_table: str) -> list[str]:
    """Read text lines until the CREATE TABLE for `expected_table` is fully
    seen, returning the bare column names in dump order. Stops once the
    closing ')' of the column list is reached.
    """
    seen_create = False
    cols: list[str] = []
    body_lines: list[str] = []
    col_re = re.compile(r"^\s*`([A-Za-z_][A-Za-z_0-9]*)`")
    target = f"CREATE TABLE `{expected_table}`"
    for line in text_iter:
        if not seen_create:
            if line.startswith(target):
                seen_create = True
            continue
        body_lines.append(line)
        # column line vs key/constraint line
        m = col_re.match(line)
        if m:
            name = m.group(1)
            # ignore index lines: PRIMARY/KEY/UNIQUE/CONSTRAINT — those don't
            # match col_re because they don't begin with backtick at col 0,
            # but defensively skip if it did.
            if name.upper() not in {"PRIMARY", "KEY", "UNIQUE", "CONSTRAINT"}:
                cols.append(name)
        if line.strip().startswith(")"):
            return cols
    raise ValueError(f"CREATE TABLE for `{expected_table}` not found")


# ---------------------------------------------------------------------------
# Streaming line iterator over a gzip file.
# ---------------------------------------------------------------------------

def stream_lines(path: Path):
    """Yield decoded lines from a gzipped mysqldump file.

    mysqldump emits CHARSET=binary, so values can contain arbitrary bytes
    (including invalid UTF-8). We decode as latin-1 so each byte becomes
    exactly one Python codepoint; the parser/escape-decoder then handles
    quoting. When converting back to bytes (for bytea), we encode latin-1
    again — round-trip is byte-exact.
    """
    with gzip.open(path, "rb") as gz:
        # Hand-rolled line reader: gzip files can be huge; use raw buffer
        # and split on b"\n". An INSERT line for `page` can exceed 100 MB,
        # so we use a tolerant chunk reader.
        buf = b""
        while True:
            chunk = gz.read(4 * 1024 * 1024)
            if not chunk:
                if buf:
                    yield buf.decode("latin-1")
                return
            buf += chunk
            while True:
                nl = buf.find(b"\n")
                if nl < 0:
                    break
                line = buf[:nl]
                buf = buf[nl + 1:]
                yield line.decode("latin-1")


# ---------------------------------------------------------------------------
# Streaming INSERT-row generator.
# ---------------------------------------------------------------------------

INSERT_PREFIX_RE = re.compile(
    r"^INSERT INTO `([A-Za-z_][A-Za-z_0-9]*)` VALUES "
)


def iter_insert_tuples(path: Path, table: str) -> Iterator[list]:
    """Yield raw tuples from every `INSERT INTO \`table\` VALUES ...;` line in
    the dump. We assume each INSERT is one logical line (mysqldump default),
    but tolerate extremely long lines (>1 GB) thanks to gzip+chunked reader.
    """
    for line in stream_lines(path):
        if not line.startswith("INSERT INTO "):
            continue
        m = INSERT_PREFIX_RE.match(line)
        if not m:
            continue
        if m.group(1) != table:
            continue
        # strip trailing ';' (and any trailing whitespace)
        body = line[m.end():].rstrip()
        if body.endswith(";"):
            body = body[:-1].rstrip()
        yield from parse_values_tuples(body)


# ---------------------------------------------------------------------------
# Per-table value conversion (raw-mysql tuple -> pg-typed tuple).
# Each function returns a list aligned with `pg_cols`.
# ---------------------------------------------------------------------------

def _mw_ts_to_dt(s: Optional[str]) -> Optional[datetime]:
    """MediaWiki 14-digit timestamp ('YYYYMMDDHHMMSS') -> aware datetime UTC.

    Returns None for None / empty / 'infinity' / all-zero placeholders.
    """
    if s is None:
        return None
    if isinstance(s, bytes):
        s = s.decode("latin-1")
    s = s.strip()
    if not s:
        return None
    if s == "infinity":
        return None
    # Some MW expiry rows use '00000000000000' as "no expiry"
    if s.startswith("0000"):
        return None
    if len(s) != 14 or not s.isdigit():
        # Unknown format — return None rather than crash; spotty rows exist.
        return None
    try:
        return datetime(
            int(s[0:4]), int(s[4:6]), int(s[6:8]),
            int(s[8:10]), int(s[10:12]), int(s[12:14]),
            tzinfo=timezone.utc,
        )
    except ValueError:
        return None


def _to_bool(v) -> Optional[bool]:
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, int):
        return bool(v)
    if isinstance(v, str):
        return v not in ("0", "", "false", "False")
    if isinstance(v, bytes):
        return v not in (b"0", b"", b"\x00")
    return bool(v)


def _to_bytes(v) -> Optional[bytes]:
    if v is None:
        return None
    if isinstance(v, bytes):
        return v
    if isinstance(v, str):
        # latin-1 is the byte-faithful inverse of how we decoded the line
        return v.encode("latin-1")
    return str(v).encode("latin-1")


def _to_text(v) -> Optional[str]:
    if v is None:
        return None
    if isinstance(v, bytes):
        # short ASCII tokens (group names, content models, etc.) — latin-1
        # decode preserves bytes identically; downstream is SQL_ASCII anyway.
        return v.decode("latin-1")
    return str(v)


def _to_int(v) -> Optional[int]:
    if v is None:
        return None
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    if isinstance(v, (bytes, str)):
        s = v.decode("latin-1") if isinstance(v, bytes) else v
        s = s.strip()
        if not s:
            return None
        return int(s)
    raise TypeError(f"can't coerce {type(v).__name__} to int")


def _to_float(v) -> Optional[float]:
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, (bytes, str)):
        s = v.decode("latin-1") if isinstance(v, bytes) else v
        s = s.strip()
        if not s:
            return None
        return float(s)
    raise TypeError(f"can't coerce {type(v).__name__} to float")


def _convert_value(raw, pg_type: str):
    if pg_type == "bigint" or pg_type == "integer":
        return _to_int(raw)
    if pg_type == "double":
        return _to_float(raw)
    if pg_type == "bytea":
        return _to_bytes(raw)
    if pg_type == "text":
        return _to_text(raw)
    if pg_type == "boolean":
        return _to_bool(raw)
    if pg_type == "timestamptz":
        return _mw_ts_to_dt(raw)
    raise ValueError(f"unknown pg_type {pg_type!r}")


# Per-table column-reorder + conversion. Returns a list aligned with pg_cols.
def convert_row(table: str, raw_row: list) -> list:
    spec = TABLES[table]
    mysql_cols = spec["mysql_cols"]
    pg_cols = spec["pg_cols"]
    pg_types = spec["pg_types"]
    if len(raw_row) != len(mysql_cols):
        raise ValueError(
            f"{table}: row arity {len(raw_row)} != expected {len(mysql_cols)}"
        )
    # Build a name->raw mapping, then pick pg_cols out of it.
    by_name = dict(zip(mysql_cols, raw_row))
    out: list = []
    for col, ptype in zip(pg_cols, pg_types):
        if col not in by_name:
            # Column exists in PG schema but not in dump (unlikely given we
            # control TABLES). Emit NULL.
            out.append(None)
            continue
        out.append(_convert_value(by_name[col], ptype))
    return out


# ---------------------------------------------------------------------------
# Indexes: parse schema/indexes.sql and group by table.
# ---------------------------------------------------------------------------

def parse_indexes_by_table(indexes_sql: str) -> dict[str, list[tuple[str, str]]]:
    """Return {table_name: [(index_name, full_create_stmt), ...]}.

    Strips psql metacommands (\\set, \\echo, etc.) before parsing — psycopg
    only understands SQL, and schema/indexes.sql contains a `\\set ON_ERROR_STOP on`
    at the top that would otherwise be glued onto the first CREATE INDEX
    statement during the `;`-split and crash on cur.execute().
    """
    cleaned_lines = []
    for line in indexes_sql.splitlines():
        s = line.lstrip()
        # Drop psql backslash metacommands (whole-line only — none mid-statement).
        if s.startswith("\\"):
            continue
        cleaned_lines.append(line)
    cleaned = "\n".join(cleaned_lines)

    out: dict[str, list[tuple[str, str]]] = {}
    stmts = [s.strip() for s in cleaned.split(";")]
    pat = re.compile(
        r"CREATE\s+(?:UNIQUE\s+)?INDEX(?:\s+IF\s+NOT\s+EXISTS)?\s+"
        r"(\w+)\s+ON\s+(\w+)",
        re.IGNORECASE | re.DOTALL,
    )
    for st in stmts:
        if not st:
            continue
        m = pat.search(st)
        if not m:
            continue
        idx_name = m.group(1)
        tbl_name = m.group(2)
        # canonical statement, terminated by ';'
        out.setdefault(tbl_name, []).append((idx_name, st + ";"))
    return out


# ---------------------------------------------------------------------------
# Loader.
# ---------------------------------------------------------------------------

def load_table(
    conn: psycopg.Connection,
    table: str,
    dump_path: Path,
    *,
    keep_indexes: bool = False,
    indexes_by_table: Optional[dict[str, list[tuple[str, str]]]] = None,
    progress_every: int = 100_000,
) -> int:
    """Load one table from `dump_path`. Returns row count loaded."""
    spec = TABLES[table]
    pg_cols = spec["pg_cols"]
    print(f"\n=== {table} ===")
    print(f"  source: {dump_path}")
    print(f"  pg cols: {pg_cols}")

    # 1. Sanity-check columns vs. dump (parse first ~200 lines for CREATE TABLE).
    discovered: list[str] = []
    try:
        prelude = []
        for i, line in enumerate(stream_lines(dump_path)):
            prelude.append(line)
            if line.startswith("/*!40000 ALTER TABLE") or line.startswith("INSERT INTO "):
                break
            if i > 1000:
                break
        discovered = discover_create_table_columns(iter(prelude), table)
    except Exception as e:
        print(f"  WARN: could not parse CREATE TABLE columns ({e}); skipping schema check")
    if discovered:
        expected = spec["mysql_cols"]
        if discovered != expected:
            print(f"  WARN: dump CREATE TABLE columns differ from expected.")
            print(f"        dump:     {discovered}")
            print(f"        expected: {expected}")
            # keep going — TABLES[mysql_cols] is the source of truth for parse order
            # but warn so the user can investigate.
        else:
            print(f"  CREATE TABLE columns match expected MW order ({len(discovered)} cols)")

    # 2. Drop indexes (per-table) unless --keep-indexes.
    dropped_idx_stmts: list[tuple[str, str]] = []
    if not keep_indexes and indexes_by_table is not None:
        with conn.cursor() as cur:
            for idx_name, stmt in indexes_by_table.get(table, []):
                cur.execute(f"DROP INDEX IF EXISTS {idx_name}")
                dropped_idx_stmts.append((idx_name, stmt))
        if dropped_idx_stmts:
            print(f"  dropped {len(dropped_idx_stmts)} non-PK indexes")

    # 3. Truncate.
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {table}")
    print(f"  TRUNCATE {table}")

    # 4. COPY rows in.
    copy_sql = f"COPY {table} ({', '.join(pg_cols)}) FROM STDIN"
    t0 = time.monotonic()
    n_rows = 0
    with conn.cursor() as cur:
        # Per-session perf knobs (per-transaction, leave cluster untouched).
        cur.execute("SET LOCAL synchronous_commit = OFF")
        cur.execute("SET LOCAL maintenance_work_mem = '2GB'")
        cur.execute("SET LOCAL work_mem = '256MB'")
        with cur.copy(copy_sql) as copy:
            for raw in iter_insert_tuples(dump_path, table):
                row = convert_row(table, raw)
                copy.write_row(row)
                n_rows += 1
                if n_rows % progress_every == 0:
                    elapsed = time.monotonic() - t0
                    rate = n_rows / elapsed if elapsed > 0 else 0
                    print(f"    {n_rows:>12,} rows  ({rate:>10,.0f} rows/s, {elapsed:>6.1f}s)")
    elapsed = time.monotonic() - t0
    rate = n_rows / elapsed if elapsed > 0 else 0
    print(f"  COPY done: {n_rows:,} rows in {elapsed:.1f}s ({rate:,.0f} rows/s)")

    # 5. Recreate indexes.
    if dropped_idx_stmts:
        with conn.cursor() as cur:
            for idx_name, stmt in dropped_idx_stmts:
                t1 = time.monotonic()
                cur.execute(stmt)
                print(f"    recreated {idx_name} ({time.monotonic() - t1:.1f}s)")

    return n_rows


# ---------------------------------------------------------------------------
# CLI.
# ---------------------------------------------------------------------------

def dump_path_for(table: str) -> Path:
    return DUMP_DIR / f"{WIKI}-{RUN_ID}-{table}.sql.gz"


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--tables", nargs="*", default=None,
        help=f"tables to load (default order: {DEFAULT_TABLE_ORDER})",
    )
    p.add_argument(
        "--dry-run", action="store_true",
        help="show the plan and exit",
    )
    p.add_argument(
        "--keep-indexes", action="store_true",
        help="don't drop/recreate indexes around COPY (slower, but useful for first-table testing)",
    )
    p.add_argument(
        "--service", default="wiki",
        help="libpq service name (default: wiki)",
    )
    args = p.parse_args(argv)

    tables = args.tables if args.tables else DEFAULT_TABLE_ORDER
    unknown = [t for t in tables if t not in TABLES]
    if unknown:
        print(f"ERROR: unknown tables: {unknown}", file=sys.stderr)
        print(f"known: {sorted(TABLES)}", file=sys.stderr)
        return 2

    plan: list[tuple[str, Path, bool]] = []
    for t in tables:
        path = dump_path_for(t)
        plan.append((t, path, path.exists()))

    print("Plan:")
    for t, path, ok in plan:
        marker = "OK" if ok else "MISSING"
        size = f"{path.stat().st_size / 1e6:8.1f} MB" if ok else "    -"
        print(f"  [{marker}] {t:25}  {size}  {path}")
    if args.dry_run:
        print("\n--dry-run: exiting without loading.")
        return 0

    missing = [(t, p) for t, p, ok in plan if not ok]
    if missing:
        print("\nERROR: missing dump files:", file=sys.stderr)
        for t, p in missing:
            print(f"  {t}: {p}", file=sys.stderr)
        return 2

    indexes_by_table = parse_indexes_by_table(INDEXES_SQL_PATH.read_text())

    total_rows = 0
    t_global = time.monotonic()
    with psycopg.connect(f"service={args.service}", autocommit=False) as conn:
        for t, path, _ in plan:
            with conn.transaction():
                n = load_table(
                    conn, t, path,
                    keep_indexes=args.keep_indexes,
                    indexes_by_table=indexes_by_table,
                )
            total_rows += n
    print(
        f"\nAll done: {total_rows:,} rows across {len(plan)} table(s) "
        f"in {time.monotonic() - t_global:.1f}s."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
