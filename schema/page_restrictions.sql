-- Phase 1a: loaded from enwiki-20260401-page_restrictions.sql.gz.
-- Current-state snapshot of per-page protection (history lives in logging).
-- pr_type and pr_level are short ASCII tokens ('edit'/'move'/'sysop'/...);
-- text is fine — bytea reserved for fields where non-UTF-8 has been observed.
-- pr_cascade is tinyint(4) in MW; modeled as boolean (only 0/1 in practice).

DROP TABLE IF EXISTS page_restrictions CASCADE;

CREATE TABLE page_restrictions (
    pr_id        bigint PRIMARY KEY,
    pr_page      bigint  NOT NULL,
    pr_type      text    NOT NULL,
    pr_level     text    NOT NULL,
    pr_cascade   boolean NOT NULL DEFAULT false,
    pr_expiry    timestamptz
);
