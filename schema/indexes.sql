-- All non-PK indexes for wiki20260401. Kept separate so the loaders can
-- DROP INDEX before bulk COPY and re-run this file afterwards.
-- Run with: psql service=wiki -f schema/indexes.sql
-- Each index is annotated with the access pattern it serves.

\set ON_ERROR_STOP on

-- ---------- page ----------
-- title lookup ('what's the page_id of "Barack Obama" in NS 0?')
CREATE INDEX IF NOT EXISTS page_namespace_title_idx
    ON page (page_namespace, page_title);
-- redirect-only filtering for namespace summaries
CREATE INDEX IF NOT EXISTS page_redirect_namespace_idx
    ON page (page_is_redirect, page_namespace);

-- ---------- page_restrictions ----------
-- per-page lookup of all current protections
CREATE INDEX IF NOT EXISTS page_restrictions_page_idx
    ON page_restrictions (pr_page);
-- 'all sysop-protected pages' filtering
CREATE INDEX IF NOT EXISTS page_restrictions_type_level_idx
    ON page_restrictions (pr_type, pr_level);

-- ---------- protected_titles ----------
-- timestamp index for chronological scans (matches MW's MUL on pt_timestamp)
CREATE INDEX IF NOT EXISTS protected_titles_timestamp_idx
    ON protected_titles (pt_timestamp);

-- ---------- user_groups ----------
-- 'list all current sysops'
CREATE INDEX IF NOT EXISTS user_groups_group_idx
    ON user_groups (ug_group);
-- expiring grants (filtered: most rows are NULL = indefinite)
CREATE INDEX IF NOT EXISTS user_groups_expiry_idx
    ON user_groups (ug_expiry) WHERE ug_expiry IS NOT NULL;

-- ---------- user_former_groups ----------
-- 'list all desysopped users'
CREATE INDEX IF NOT EXISTS user_former_groups_group_idx
    ON user_former_groups (ufg_group);

-- ---------- change_tag ----------
-- per-revision tag lookup (the dominant access pattern: 'is this rev a revert?')
CREATE INDEX IF NOT EXISTS change_tag_rev_idx
    ON change_tag (ct_rev_id) WHERE ct_rev_id IS NOT NULL;
-- per-log-entry tag lookup
CREATE INDEX IF NOT EXISTS change_tag_log_idx
    ON change_tag (ct_log_id) WHERE ct_log_id IS NOT NULL;
-- 'all rows with tag X' (e.g. mw-reverted)
CREATE INDEX IF NOT EXISTS change_tag_tag_idx
    ON change_tag (ct_tag_id);

-- ---------- change_tag_def ----------
-- ctd_name already UNIQUE (implicit index); nothing else needed.

-- ---------- actor ----------
-- 'find the actor for username X' / IP lookup
CREATE INDEX IF NOT EXISTS actor_name_idx
    ON actor (actor_name);
-- 'all actor rows for a registered user_id'
CREATE INDEX IF NOT EXISTS actor_user_idx
    ON actor (actor_user) WHERE actor_user IS NOT NULL;

-- ---------- logging ----------
-- yearly counts and log_type filtering ('all protect events in 2018')
CREATE INDEX IF NOT EXISTS logging_type_timestamp_idx
    ON logging (log_type, log_timestamp);
-- per-page lookup when log_page is null (true for many older rows)
CREATE INDEX IF NOT EXISTS logging_namespace_title_idx
    ON logging (log_namespace, log_title);
-- per-page lookup when log_page is populated
CREATE INDEX IF NOT EXISTS logging_page_idx
    ON logging (log_page) WHERE log_page IS NOT NULL;
-- admin-centric queries ('every action by actor X')
CREATE INDEX IF NOT EXISTS logging_actor_idx
    ON logging (log_actor);
-- jsonb predicate queries on log_params (e.g. WHERE log_params->>'level' = 'sysop')
CREATE INDEX IF NOT EXISTS logging_params_gin_idx
    ON logging USING GIN (log_params);

-- ---------- revision ----------
-- the core hyperevent access pattern: editor-on-page time series
CREATE INDEX IF NOT EXISTS revision_page_timestamp_actor_idx
    ON revision (rev_page, rev_timestamp, rev_actor);
-- editor-centric queries ('all edits by actor X over time')
CREATE INDEX IF NOT EXISTS revision_actor_timestamp_idx
    ON revision (rev_actor, rev_timestamp);
-- parent-revision walks (used by revert/diff tooling)
CREATE INDEX IF NOT EXISTS revision_parent_idx
    ON revision (rev_parent_id) WHERE rev_parent_id IS NOT NULL;
