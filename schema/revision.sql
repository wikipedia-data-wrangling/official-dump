-- Phase 2: loaded from enwiki-20260401-stub-meta-history*.xml.gz (27 parts).
-- Metadata-only: no wikitext (that lives in pages-meta-history if Phase 3 is
-- ever run). MW's column is rev_minor_edit; we follow the project spec and
-- name it rev_minor as a boolean. rev_comment is text per the spec — comments
-- are byte-transparent under SQL_ASCII so bytea adds no value here.
-- rev_parent_id nullable: page-creation revisions have no parent.
-- rev_actor nullable: revisions with <contributor deleted="deleted"/> are
-- real revisions whose actor we don't know. Dropping them loses data; we
-- preserve the row and NULL out rev_actor instead.

DROP TABLE IF EXISTS revision CASCADE;

CREATE TABLE revision (
    rev_id          bigint PRIMARY KEY,
    rev_page        bigint      NOT NULL,
    rev_actor       bigint,
    rev_timestamp   timestamptz NOT NULL,
    rev_minor       boolean     NOT NULL DEFAULT false,
    rev_comment     text,
    rev_sha1        text,
    rev_len         bigint,
    rev_parent_id   bigint
);
