-- Phase 1a: loaded from enwiki-20260401-change_tag_def.sql.gz.
-- Tag id -> name mapping (e.g. 'mw-reverted', 'mobile edit'). ctd_count is the
-- precomputed hit count carried in the dump; we keep it but do not maintain it.

DROP TABLE IF EXISTS change_tag_def CASCADE;

CREATE TABLE change_tag_def (
    ctd_id            bigint PRIMARY KEY,
    ctd_name          text    NOT NULL UNIQUE,
    ctd_user_defined  boolean NOT NULL DEFAULT false,
    ctd_count         bigint  NOT NULL DEFAULT 0
);
