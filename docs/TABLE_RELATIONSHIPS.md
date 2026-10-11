# Post-load indexes and table relationships

Target: `wiki20260401`, PostgreSQL 18, port 5434 (`service=wiki`).
The base snapshot and downstream `analysis` tables retain their data.

`schema/indexes.sql` defines the base query indexes. The post-load runbook
`runbooks/index_connect.py` builds the missing actor-name and actor-user
indexes concurrently on `wiki_ts_sys` (NVMe), refreshes actor statistics,
and validates four candidate foreign keys. Existing revision page/time,
actor/time, parent, tag, and logging indexes are reused.

| Source | Target | Treatment |
| --- | --- | --- |
| `revision_text.rev_id` | `revision.rev_id` | Existing validated FK, including both partitions |
| `revision.rev_actor` | `actor.actor_id` | Validate post-load; NULL means suppressed identity |
| `revision.rev_page` | `page.page_id` | Validate post-load; skip if the separate dumps disagree |
| `logging.log_actor` | `actor.actor_id` | Validate post-load; NULL allowed |
| `change_tag.ct_tag_id` | `change_tag_def.ctd_id` | Validate post-load |
| `page_restrictions.pr_page` | `page.page_id` | LEFT JOIN; observed missing references, including 0 and 17848 |
| `logging.log_page` | `page.page_id` | LEFT JOIN; historical/deleted pages and NULL IDs |
| `change_tag.ct_rev_id` | `revision.rev_id` | LEFT JOIN; absent/deleted revisions possible |
| `change_tag.ct_log_id` | `logging.log_id` | LEFT JOIN; separately collected dumps |
| `revision.rev_parent_id` | `revision.rev_id` | Logical link; deleted/suppressed parents may be absent |
| `page.page_latest` | `revision.rev_id` | Logical link; SQL/XML snapshots may differ |
| `user_groups.ug_user`, `user_former_groups.ufg_user`, `protected_titles.pt_user` | `actor.actor_user` | LEFT JOIN; user ID is distinct from actor ID and not unique in actor |
| `protected_titles.(pt_namespace, pt_title)` | page namespace/title | Creation-protected titles can have no existing page |
| `change_tag.ct_rc_id` | recent changes | No target table is loaded |

The runner commits new FKs as `NOT VALID` to release initial write locks,
then validates existing rows. Missing references cause it to drop the new
constraint and record the offending key; it never deletes or edits rows.
`logs/index-connect-status.json` and `logs/index-connect-20261010.log`
record progress. A constraint is fully checked only when `convalidated`
is true. New FKs affect future loading/TRUNCATE operations: a new bulk
import must explicitly drop/recreate them in dependency order.

`schema/relationships.sql` creates seven ordinary views in `wiki_relations`
that connect these tables without copying the large dataset. Apply after
the base schema has been loaded; the destructive schema apply driver does
not install post-load views/FKs. LEFT JOIN keeps unmatched rows, and
`*_found` flags distinguish missing targets. Membership/title views can
return several rows for one user if that user has several actor names.

```sql
-- Indexed revision -> page -> editor lookup.
SELECT rev_id, rev_timestamp, encode(page_title, 'escape') AS page_title,
       encode(actor_name, 'escape') AS editor, page_found, actor_found
FROM wiki_relations.revision
WHERE rev_page = 13465879
ORDER BY rev_timestamp
LIMIT 20;

-- Tags, dictionary names, and corresponding revision/log metadata.
SELECT ct_id, ctd_name, rev_page, revision_found, log_found
FROM wiki_relations.change_tag
WHERE ct_rev_id = 1000000000;

-- Fetch wikitext by revision ID; avoids reading it in metadata-only queries.
SELECT r.rev_id, r.rev_timestamp, t.rev_text
FROM wiki_relations.revision r
LEFT JOIN public.revision_text t USING (rev_id)
WHERE r.rev_id = 1000000000;

-- Actual FK status rather than inferred relationships.
SELECT conrelid::regclass AS source, conname, convalidated,
       pg_get_constraintdef(oid)
FROM pg_constraint
WHERE contype = 'f' AND connamespace = 'public'::regnamespace;
```

Run the resumable migration with `.venv/bin/python runbooks/index_connect.py`
from the repository root. Long jobs should use a systemd user service so
they survive terminal/tunnel restarts. Full before/after sentinels use
`psql -X service=wiki -v ON_ERROR_STOP=1 -f key_figures.sql`; their scans
are substantial at this scale.
