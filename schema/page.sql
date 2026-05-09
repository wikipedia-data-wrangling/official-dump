-- Phase 1a: loaded from enwiki-20260401-page.sql.gz.
-- page_title is bytea: MediaWiki stores it as VARBINARY(255) and historical
-- titles include non-UTF-8 byte sequences. page_latest is bigint because
-- rev_id has long since exceeded 2^31; same logic for page_id and page_len
-- to keep id/length types uniform across the schema.

DROP TABLE IF EXISTS page CASCADE;

CREATE TABLE page (
    page_id              bigint PRIMARY KEY,
    page_namespace       integer          NOT NULL,
    page_title           bytea            NOT NULL,
    page_is_redirect     boolean          NOT NULL DEFAULT false,
    page_is_new          boolean          NOT NULL DEFAULT false,
    page_random          double precision NOT NULL,
    page_touched         timestamptz,
    page_links_updated   timestamptz,
    page_latest          bigint           NOT NULL,
    page_len             bigint           NOT NULL,
    page_content_model   text,
    page_lang            text
);
