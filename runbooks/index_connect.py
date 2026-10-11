"""Resume post-load indexes and validated FKs on wiki20260401, PG18:5434.

Run using .venv/bin/python, preferably in a systemd user unit. No data is
rewritten. Newly added FKs that fail validation are removed.
The full sentinel query can run separately; status is written after each step.
"""
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "logs" / "index-connect-status.json"


def now():
    return datetime.now(timezone.utc).isoformat()


def main():
    STATUS.parent.mkdir(exist_ok=True)
    report = {"started": now(), "state": "running", "steps": []}

    def record(step, state, **details):
        report["steps"].append(dict(step=step, state=state, time=now(), **details))
        temp = STATUS.with_suffix(".tmp")
        temp.write_text(json.dumps(report, indent=2) + "\n")
        temp.replace(STATUS)
        print(now(), step, state, details, flush=True)

    with psycopg.connect("service=wiki", autocommit=True,
                         options="-c client_encoding=UTF8",
                         application_name="wiki-index-connect") as conn:
        db, port = conn.execute(
            "SELECT current_database(),current_setting('port')").fetchone()
        if (db, port) != ("wiki20260401", "5434"):
            raise RuntimeError(f"Wrong target: {db}:{port}")
        if not conn.execute("SELECT pg_try_advisory_lock(20260401,5434)").fetchone()[0]:
            raise RuntimeError("Another index/connect job is running")
        conn.execute("SET lock_timeout='5s'")
        conn.execute("SET maintenance_work_mem='2GB'")
        conn.execute("SET work_mem='8GB'")
        conn.execute("SET max_parallel_workers_per_gather=2")
        conn.execute("SET max_parallel_maintenance_workers=2")
        conn.execute("SET temp_tablespaces='wiki_ts_sys'")
        record("target", "verified", database=db, port=port)
        # Concurrent builds wait for older snapshots as well as table locks;
        # a short lock_timeout would abort an otherwise successful build.
        conn.execute("SET lock_timeout=0")

        for name, columns, predicate in [
            ("actor_name_idx", "actor_name", ""),
            ("actor_user_idx", "actor_user", " WHERE actor_user IS NOT NULL"),
        ]:
            row = conn.execute(
                "SELECT i.indisvalid,pg_get_indexdef(i.indexrelid) "
                "FROM pg_index i WHERE i.indexrelid=to_regclass(%s)",
                (f"public.{name}",)).fetchone()
            if row:
                if not row[0]:
                    raise RuntimeError(f"Invalid index {name}; inspect before retrying")
                record(name, "existing", definition=row[1])
                continue
            record(name, "building")
            conn.execute(sql.SQL(
                "CREATE INDEX CONCURRENTLY {} ON public.actor ({}) "
                "TABLESPACE wiki_ts_sys {}"
            ).format(sql.Identifier(name), sql.Identifier(columns), sql.SQL(predicate)))
            record(name, "complete")

        conn.execute("ANALYZE public.actor")
        record("actor statistics", "complete")
        conn.execute("SET lock_timeout='5s'")
        conn.execute("SET effective_cache_size='128GB'")

        # Independent loads are different snapshots, so even plausible links
        # can fail. Commit NOT VALID first to release the initial write lock;
        # validation uses a lighter lock, allowing concurrent reads/writes.
        for table, column, parent, key in [
            ("logging", "log_actor", "actor", "actor_id"),
            ("revision", "rev_actor", "actor", "actor_id"),
            ("revision", "rev_page", "page", "page_id"),
            ("change_tag", "ct_tag_id", "change_tag_def", "ctd_id"),
        ]:
            name = f"{table}_{column}_fkey"
            record(name, "validating")
            added = False
            try:
                existing = conn.execute(
                    "SELECT convalidated, pg_get_constraintdef(oid) "
                    "FROM pg_constraint WHERE conrelid=to_regclass(%s) "
                    "AND conname=%s", (f"public.{table}", name)).fetchone()
                if not existing:
                    conn.execute(sql.SQL(
                        "ALTER TABLE public.{} ADD CONSTRAINT {} "
                        "FOREIGN KEY ({}) REFERENCES public.{} ({}) NOT VALID"
                    ).format(*map(sql.Identifier, (table, name, column, parent, key))))
                    added = True
                conn.execute(sql.SQL("ALTER TABLE public.{} VALIDATE CONSTRAINT {}")
                             .format(sql.Identifier(table), sql.Identifier(name)))
                record(name, "validated")
            except psycopg.errors.ForeignKeyViolation as exc:
                if added:
                    conn.execute(sql.SQL("ALTER TABLE public.{} DROP CONSTRAINT {}")
                                 .format(sql.Identifier(table), sql.Identifier(name)))
                record(name, "skipped_missing_reference", reason=str(exc))
        record("foreign keys", "complete")
        record("after sentinel", "running")
        with (ROOT / "logs" / "relationships-after-20261010.log").open("a") as log:
            subprocess.run(["psql", "-X", "service=wiki", "-v", "ON_ERROR_STOP=1",
                            "-f", str(ROOT / "key_figures.sql")],
                           stdout=log, stderr=subprocess.STDOUT, check=True,
                           env=dict(os.environ, PGOPTIONS="-c effective_cache_size=128GB -c work_mem=256MB"))
        record("after sentinel", "complete")
        report["state"] = "complete"
        record("job", "complete")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        report = json.loads(STATUS.read_text()) if STATUS.exists() else {}
        report.update(state="failed", error=str(exc), failed=now())
        STATUS.write_text(json.dumps(report, indent=2) + "\n")
        raise
