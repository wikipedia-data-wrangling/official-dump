-- Phase 1a: loaded from enwiki-20260401-protected_titles.sql.gz.
-- Creation-protected (non-existent) titles. Load-bearing for RFPP analysis:
-- some "denied" requests result in title-creation protection, not page-level.
-- pt_reason_id references MW's comment table which we do not load; keep the
-- id as bigint so future joins remain possible if comment dumps reappear.
-- pt_user nullable because old rows can carry user_id=0 / NULL after the
-- actor-table migration.

DROP TABLE IF EXISTS protected_titles CASCADE;

CREATE TABLE protected_titles (
    pt_namespace    integer NOT NULL,
    pt_title        bytea   NOT NULL,
    pt_user         bigint,
    pt_reason_id    bigint,
    pt_timestamp    timestamptz NOT NULL,
    pt_expiry       timestamptz,
    pt_create_perm  text    NOT NULL,
    PRIMARY KEY (pt_namespace, pt_title)
);
