#!/usr/bin/env python3
"""
test_load_pages_meta_history_xml.py — synthetic-fixture tests for the
Phase 3 loader. No real pages-meta-history*.xml.7z required.

Covers:
  1. parse_revisions yields exactly the expected (rev_id, rev_text bytes,
     rev_text_bytes) tuples from a hand-built .7z fixture.
  2. <text deleted="deleted" /> revisions are skipped.
  3. The DB-backed `revision` existence check filters out rev_ids that
     aren't in `revision`. Uses a temporary set of rev_ids inserted into
     `revision` then cleaned up.
  4. Loader runs end-to-end with --dry-run when no real files are present
     (lists 0 candidate files).
"""

from __future__ import annotations

import datetime as dt
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import psycopg
import py7zr

import load_pages_meta_history_xml as L


# ---------------------------------------------------------------------------
# Fixture builder
# ---------------------------------------------------------------------------

# Long XML namespace declarations are intrinsic to MediaWiki export-0.11;
# noqa: E501 on the next line keeps them readable as one line.
INNER_XML_TEMPLATE = (  # noqa: E501
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<mediawiki xmlns="http://www.mediawiki.org/xml/export-0.11/" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
    'xsi:schemaLocation="http://www.mediawiki.org/xml/export-0.11/ '
    'http://www.mediawiki.org/xml/export-0.11.xsd" '
    'version="0.11" xml:lang="en">\n'
) + """<siteinfo>
<sitename>Wikipedia</sitename>
<dbname>enwiki</dbname>
<base>https://en.wikipedia.org/wiki/Main_Page</base>
<generator>MediaWiki 1.42</generator>
<case>first-letter</case>
<namespaces>
<namespace key="0" case="first-letter">Article</namespace>
</namespaces>
</siteinfo>
<page>
<title>Test page</title>
<ns>0</ns>
<id>{page_id}</id>
<revision>
<id>{rev_a}</id>
<timestamp>2020-01-01T00:00:00Z</timestamp>
<contributor><username>Alice</username><id>100</id></contributor>
<text bytes="11" xml:space="preserve">hello world</text>
<sha1>aaaa</sha1>
</revision>
<revision>
<id>{rev_b}</id>
<timestamp>2020-01-02T00:00:00Z</timestamp>
<contributor><username>Bob</username><id>101</id></contributor>
<text bytes="0" deleted="deleted" />
<sha1>bbbb</sha1>
</revision>
<revision>
<id>{rev_c}</id>
<timestamp>2020-01-03T00:00:00Z</timestamp>
<contributor><username>Carol</username><id>102</id></contributor>
<text bytes="13" xml:space="preserve">goodbye world</text>
<sha1>cccc</sha1>
</revision>
</page>
</mediawiki>
"""


def build_fixture_7z(tmpdir: Path, page_id: int, rev_a: int, rev_b: int,
                    rev_c: int) -> Path:
    inner_xml = INNER_XML_TEMPLATE.format(
        page_id=page_id, rev_a=rev_a, rev_b=rev_b, rev_c=rev_c,
    ).encode("utf-8")
    target = tmpdir / "fixture.xml.7z"
    with py7zr.SevenZipFile(str(target), mode="w") as zf:
        zf.writestr(inner_xml, "fixture.xml")
    return target


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_parse_yields_expected_rows():
    """Test 1: parse_revisions yields the expected (id, bytes, len) tuples."""
    with tempfile.TemporaryDirectory() as td:
        fx = build_fixture_7z(Path(td), page_id=1,
                              rev_a=10, rev_b=11, rev_c=12)
        stats = L.ParseStats()
        rows = list(L.parse_revisions(fx, stats))
        assert len(rows) == 2, f"expected 2 rows (B is deleted), got {len(rows)}"
        assert rows[0].rev_id == 10
        assert rows[0].rev_text == b"hello world"
        assert rows[0].rev_text_bytes == 11
        assert rows[1].rev_id == 12
        assert rows[1].rev_text == b"goodbye world"
        assert rows[1].rev_text_bytes == 13
        assert stats.revisions_seen == 3
        assert stats.revisions_loaded == 2
        assert stats.skipped_text_deleted == 1
    print("test_parse_yields_expected_rows: PASSED")


def test_db_revision_existence_filter():
    """Test 2: the per-batch `revision` existence check drops dangling rev_ids.

    Fixture yields rev_ids 9990 (text), 9999 (deleted, skipped), 9992 (text).
    We pre-insert ONLY 9992 into `revision`; 9990 is dangling and must be
    filtered out. Final state: only 9992 lands in revision_text.
    Cleans up after.
    """
    fake_ids_in_revision = (9992,)
    rev_a, rev_b, rev_c = 9990, 9999, 9992
    all_fixture_ids = (rev_a, rev_b, rev_c)

    # Pre-create revision row so the existence guard has a match.
    with psycopg.connect(L.PG_SERVICE) as conn:
        with conn.cursor() as cur:
            for rid in fake_ids_in_revision:
                cur.execute(
                    "INSERT INTO revision (rev_id, rev_page, rev_timestamp) "
                    "VALUES (%s, %s, %s) "
                    "ON CONFLICT (rev_id) DO NOTHING",
                    (rid, 999_999, dt.datetime(2020, 1, 1,
                                                tzinfo=dt.timezone.utc)),
                )
        conn.commit()

    try:
        # Drop FK + clear any leftover test rows in revision_text.
        with psycopg.connect(L.PG_SERVICE) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "ALTER TABLE revision_text DROP CONSTRAINT "
                    "IF EXISTS revision_text_rev_id_fkey"
                )
                cur.execute(
                    "DELETE FROM revision_text WHERE rev_id = ANY(%s)",
                    (list(all_fixture_ids),),
                )
            conn.commit()

        with tempfile.TemporaryDirectory() as td:
            fx = build_fixture_7z(
                Path(td), page_id=999_999,
                rev_a=rev_a, rev_b=rev_b, rev_c=rev_c,
            )
            res = L.load_one_file(fx, limit=None, dry_run=False,
                                  skip_revision_check=False)
            # `loaded` counts what the parser yielded (= 2 non-deleted
            # revisions); the existence filter then drops 1.
            assert res["loaded"] == 2, f"loaded={res['loaded']} expected 2"
            assert res["skipped_text_deleted"] == 1
            assert res["skipped_no_revision_match"] == 1, (
                f"skipped_no_revision_match={res['skipped_no_revision_match']}"
                " expected 1 (rev 9990 dangling)"
            )

            # Verify only 9992 is in revision_text.
            with psycopg.connect(L.PG_SERVICE) as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT rev_id, rev_text, rev_text_bytes "
                        "FROM revision_text "
                        "WHERE rev_id = ANY(%s) ORDER BY rev_id",
                        (list(all_fixture_ids),),
                    )
                    rows = cur.fetchall()
            assert len(rows) == 1, f"expected 1 row, got {len(rows)}"
            assert rows[0][0] == 9992
            assert bytes(rows[0][1]) == b"goodbye world"
            assert rows[0][2] == 13
    finally:
        # Cleanup.
        with psycopg.connect(L.PG_SERVICE) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "DELETE FROM revision_text WHERE rev_id = ANY(%s)",
                    (list(all_fixture_ids),),
                )
                cur.execute(
                    "DELETE FROM revision WHERE rev_id = ANY(%s)",
                    (list(fake_ids_in_revision),),
                )
                # Re-create FK for hygiene.
                cur.execute(
                    "ALTER TABLE revision_text "
                    "ADD CONSTRAINT revision_text_rev_id_fkey "
                    "FOREIGN KEY (rev_id) REFERENCES revision(rev_id)"
                )
            conn.commit()
    print("test_db_revision_existence_filter: PASSED")


def test_dry_run_no_files():
    """Test 3: `--dry-run` with no real files exits cleanly with 0 candidates.

    Points DUMP_XML_DIR at an empty tmpdir via env-var override (subprocess).
    """
    with tempfile.TemporaryDirectory() as td:
        # Run loader as subprocess with a monkey-patched module: we override
        # DUMP_XML_DIR via a small driver script.
        driver = (
            "import load_pages_meta_history_xml as L\n"
            f"L.DUMP_XML_DIR = __import__('pathlib').Path({td!r})\n"
            "import sys\n"
            "sys.exit(L.main(['--dry-run']))\n"
        )
        env = os.environ.copy()
        # Force venv python.
        py = sys.executable
        proc = subprocess.run(
            [py, "-c", driver],
            cwd=str(Path(__file__).resolve().parent),
            capture_output=True, text=True, env=env,
        )
        assert proc.returncode == 0, (
            f"non-zero exit: rc={proc.returncode}\n"
            f"stdout={proc.stdout}\nstderr={proc.stderr}"
        )
        # Either log message acceptable (warning + clean exit).
        combined = proc.stdout + proc.stderr
        assert "0 candidate files" in combined or "no input files" in combined
    print("test_dry_run_no_files: PASSED")


def test_dry_run_against_fixture():
    """Test 4: --dry-run against a real .7z fixture parses without DB."""
    with tempfile.TemporaryDirectory() as td:
        fx = build_fixture_7z(Path(td), page_id=1,
                              rev_a=10, rev_b=11, rev_c=12)
        stats = L.ParseStats()
        rows = list(L.parse_revisions(fx, stats))
        # In dry-run mode the loader's load_one_file just iterates parse_*.
        res = L.load_one_file(fx, limit=None, dry_run=True)
        assert res["loaded"] == 2
        assert res["skipped_text_deleted"] == 1
    print("test_dry_run_against_fixture: PASSED")


if __name__ == "__main__":
    import logging
    logging.basicConfig(level=logging.WARNING)
    test_parse_yields_expected_rows()
    test_dry_run_against_fixture()
    test_db_revision_existence_filter()
    test_dry_run_no_files()
    print("\nALL TESTS PASSED")
