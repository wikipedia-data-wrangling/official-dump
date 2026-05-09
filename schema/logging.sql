-- Phase 1b: loaded from enwiki-20260401-pages-logging.xml.gz (the SQL form
-- has been retired by WMF). Full historical action log: protect/unprotect/
-- move_prot/block/delete/move/... — load all types, filter at query time.
-- log_params: serialized PHP blob in older rows, JSON in newer; the loader
-- normalizes to a real JSON object so we store jsonb. log_actor_name is
-- denormalized from <contributor> for sanity-check joins without hitting the
-- actor table. log_page is nullable: old rows pre-date its introduction.

DROP TABLE IF EXISTS logging CASCADE;

CREATE TABLE logging (
    log_id          bigint PRIMARY KEY,
    log_type        text        NOT NULL,
    log_action      text        NOT NULL,
    log_timestamp   timestamptz NOT NULL,
    log_actor       bigint,
    log_actor_name  bytea,
    log_namespace   integer     NOT NULL,
    log_title       bytea       NOT NULL,
    log_page        bigint,
    log_comment     text,
    log_params      jsonb,
    log_deleted     integer     NOT NULL DEFAULT 0
);
