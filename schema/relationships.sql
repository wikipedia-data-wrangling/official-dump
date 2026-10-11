-- Optional post-load query interface. Apply with psql service=wiki -f this_file.
-- LEFT JOIN preserves suppressed identities and references absent from dumps.
-- These are ordinary views: filter by IDs/time before fetching large results.
\set ON_ERROR_STOP on
CREATE SCHEMA IF NOT EXISTS wiki_relations;

CREATE OR REPLACE VIEW wiki_relations.revision AS
SELECT r.*, p.page_namespace, p.page_title, a.actor_user, a.actor_name,
       p.page_id IS NOT NULL AS page_found,
       a.actor_id IS NOT NULL AS actor_found
FROM public.revision r
LEFT JOIN public.page p ON p.page_id = r.rev_page
LEFT JOIN public.actor a ON a.actor_id = r.rev_actor;

CREATE OR REPLACE VIEW wiki_relations.logging AS
SELECT l.*, a.actor_user, a.actor_name,
       p.page_namespace AS current_page_namespace,
       p.page_title AS current_page_title,
       p.page_id IS NOT NULL AS page_found,
       a.actor_id IS NOT NULL AS actor_found
FROM public.logging l
LEFT JOIN public.actor a ON a.actor_id = l.log_actor
LEFT JOIN public.page p ON p.page_id = l.log_page;

CREATE OR REPLACE VIEW wiki_relations.change_tag AS
SELECT t.*, d.ctd_name, r.rev_page, r.rev_actor, r.rev_timestamp,
       l.log_type, l.log_action, l.log_timestamp,
       d.ctd_id IS NOT NULL AS tag_found,
       r.rev_id IS NOT NULL AS revision_found,
       l.log_id IS NOT NULL AS log_found
FROM public.change_tag t
LEFT JOIN public.change_tag_def d ON d.ctd_id = t.ct_tag_id
LEFT JOIN public.revision r ON r.rev_id = t.ct_rev_id
LEFT JOIN public.logging l ON l.log_id = t.ct_log_id;

CREATE OR REPLACE VIEW wiki_relations.page_restrictions AS
SELECT pr.*, p.page_namespace, p.page_title,
       p.page_id IS NOT NULL AS page_found
FROM public.page_restrictions pr
LEFT JOIN public.page p ON p.page_id = pr.pr_page;

-- A user can have several historical actor names; these views intentionally
-- return one row per membership/title AND matching actor (not one per user).
CREATE OR REPLACE VIEW wiki_relations.user_groups AS
SELECT g.*, a.actor_id, a.actor_name
FROM public.user_groups g
LEFT JOIN public.actor a ON a.actor_user = g.ug_user;

CREATE OR REPLACE VIEW wiki_relations.user_former_groups AS
SELECT g.*, a.actor_id, a.actor_name
FROM public.user_former_groups g
LEFT JOIN public.actor a ON a.actor_user = g.ufg_user;

CREATE OR REPLACE VIEW wiki_relations.protected_titles AS
SELECT t.*, a.actor_id, a.actor_name
FROM public.protected_titles t
LEFT JOIN public.actor a ON a.actor_user = t.pt_user;

COMMENT ON SCHEMA wiki_relations IS
'Post-load joins over the frozen Wikipedia snapshot. LEFT JOIN preserves absent references; group/title actor joins can return multiple names per user. Wikitext stays in public.revision_text, joined by rev_id.';
