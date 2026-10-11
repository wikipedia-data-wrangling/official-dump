"""Run the baseline sentinel once concurrent actor indexes release snapshots."""
import os
import subprocess
import time
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parents[1]
with psycopg.connect("service=wiki", autocommit=True,
                    application_name="wiki-index-connect-audit") as conn:
    while True:
        ready = conn.execute(
            "SELECT count(*)=2 AND bool_and(indisvalid) FROM pg_index "
            "WHERE indexrelid IN (to_regclass('public.actor_name_idx'), "
            "to_regclass('public.actor_user_idx'))"
        ).fetchone()[0]
        if ready:
            break
        time.sleep(30)
with (ROOT / "logs" / "relationships-before-20261010.log").open("w") as log:
    subprocess.run(["psql", "-X", "service=wiki", "-v", "ON_ERROR_STOP=1",
                    "-f", str(ROOT / "key_figures.sql")],
                   stdout=log, stderr=subprocess.STDOUT, check=True,
                   env=dict(os.environ, PGOPTIONS="-c effective_cache_size=128GB -c work_mem=256MB"))
