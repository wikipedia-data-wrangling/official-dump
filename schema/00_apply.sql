-- Apply driver: idempotent, dependency-safe order.
-- Run with: psql service=wiki -f schema/00_apply.sql
-- No FKs are declared (loaders insert in arbitrary order, and bulk loads run
-- faster without them) — the order below is purely the logical hierarchy.

\set ON_ERROR_STOP on

-- Identity tables (no dependencies)
\i page.sql
\i actor.sql

-- Group memberships (depend logically on user ids, but no FK)
\i user_groups.sql
\i user_former_groups.sql

-- Protection state (depends logically on page)
\i page_restrictions.sql
\i protected_titles.sql

-- Tag dictionary then tag rows
\i change_tag_def.sql
\i change_tag.sql

-- Event tables (depend logically on page + actor)
\i logging.sql
\i revision.sql

-- Wikitext (Phase 3): FK -> revision, must come AFTER revision.sql.
\i revision_text.sql
