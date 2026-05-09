-- Sentinel queries for the wiki20260401 database.
-- Run with:  psql service=wiki -f key_figures.sql
-- Empty/near-empty results are expected before the bulk loads run.

\echo
\echo === connection ===
SELECT current_database(), current_user, current_setting('server_version');

\echo
\echo === row counts per table ===
SELECT 'page'                AS tbl, COUNT(*) FROM page              UNION ALL
SELECT 'page_restrictions'   ,        COUNT(*) FROM page_restrictions UNION ALL
SELECT 'protected_titles'    ,        COUNT(*) FROM protected_titles  UNION ALL
SELECT 'user_groups'         ,        COUNT(*) FROM user_groups       UNION ALL
SELECT 'user_former_groups'  ,        COUNT(*) FROM user_former_groups UNION ALL
SELECT 'change_tag'          ,        COUNT(*) FROM change_tag        UNION ALL
SELECT 'change_tag_def'      ,        COUNT(*) FROM change_tag_def    UNION ALL
SELECT 'logging'             ,        COUNT(*) FROM logging           UNION ALL
SELECT 'revision'            ,        COUNT(*) FROM revision          UNION ALL
SELECT 'actor'               ,        COUNT(*) FROM actor;

\echo
\echo === page: counts by namespace ===
SELECT page_namespace, COUNT(*) AS pages
FROM page
GROUP BY page_namespace
ORDER BY page_namespace;

\echo
\echo === page_restrictions: protection types and levels ===
SELECT pr_type, pr_level, COUNT(*) AS n
FROM page_restrictions
GROUP BY pr_type, pr_level
ORDER BY pr_type, pr_level;

\echo
\echo === protected_titles: creation-protection levels (relevant to RFPP analysis) ===
SELECT pt_create_perm, COUNT(*) AS n
FROM protected_titles
GROUP BY pt_create_perm
ORDER BY pt_create_perm;

\echo
\echo === logging: event counts by log_type ===
SELECT log_type, COUNT(*) AS n
FROM logging
GROUP BY log_type
ORDER BY n DESC;

\echo
\echo === logging: protect/unprotect/move_prot events by year ===
SELECT EXTRACT(YEAR FROM log_timestamp)::int AS yr, log_type, COUNT(*) AS n
FROM logging
WHERE log_type IN ('protect', 'unprotect', 'move_prot')
GROUP BY yr, log_type
ORDER BY yr, log_type;

\echo
\echo === logging: sample of recent protect events with parsed log_params ===
SELECT log_timestamp,
       log_namespace,
       encode(log_title, 'escape') AS title,
       log_params
FROM logging
WHERE log_type = 'protect'
ORDER BY log_timestamp DESC
LIMIT 5;

\echo
\echo === revision: total + by year ===
SELECT EXTRACT(YEAR FROM rev_timestamp)::int AS yr, COUNT(*) AS revisions
FROM revision
GROUP BY yr
ORDER BY yr;

\echo
\echo === actor: registered vs anon ===
SELECT
  COUNT(*) FILTER (WHERE actor_user IS NOT NULL) AS registered,
  COUNT(*) FILTER (WHERE actor_user IS NULL)     AS anon,
  COUNT(*)                                       AS total
FROM actor;

\echo
\echo === user_groups: current group membership counts ===
SELECT ug_group, COUNT(*) AS members
FROM user_groups
GROUP BY ug_group
ORDER BY members DESC
LIMIT 15;

\echo
\echo === cross-table: top admins by protect-action count ===
SELECT encode(a.actor_name, 'escape') AS admin,
       COUNT(*) AS protect_actions
FROM logging l
JOIN actor a ON l.log_actor = a.actor_id
WHERE l.log_type = 'protect'
GROUP BY a.actor_id, a.actor_name
ORDER BY protect_actions DESC
LIMIT 10;

\echo
\echo === cross-table: pages currently protected, with most recent protect event ===
SELECT
  encode(p.page_title, 'escape') AS title,
  p.page_namespace,
  pr.pr_type,
  pr.pr_level,
  pr.pr_expiry,
  (
    SELECT MAX(l.log_timestamp)
    FROM logging l
    WHERE l.log_namespace = p.page_namespace
      AND l.log_title     = p.page_title
      AND l.log_type      = 'protect'
  ) AS last_protect_event
FROM page_restrictions pr
JOIN page p ON pr.pr_page = p.page_id
ORDER BY p.page_namespace, p.page_title
LIMIT 10;
