SELECT p.id AS page_id, p.title, r.id AS revision_id, r.timestamp, r.user_id, r.minor, r.comment, r.text, r.bytes, r.sha1, r.model, r.format
FROM pages p
JOIN revisions r ON p.id = r.page_id
WHERE p.namespace = 1
  AND r.timestamp <= '20220101'
  AND NOT p.deleted
  AND NOT r.deleted_text
  AND NOT r.deleted_comment
  AND NOT r.deleted_user
  AND r.id = (
    SELECT id
    FROM revisions
    WHERE page_id = p.id
      AND timestamp <= '20220101'
      AND NOT deleted_text
      AND NOT deleted_comment
      AND NOT deleted_user
    ORDER BY timestamp DESC
    LIMIT 1
  );