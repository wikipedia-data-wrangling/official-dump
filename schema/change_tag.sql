-- Phase 1a: loaded from enwiki-20260401-change_tag.sql.gz.
-- One row per (revision|log entry|recentchanges row, tag) pair. We keep the
-- ct_rc_id column for fidelity with the dump, even though recentchanges is
-- not loaded — leaving it lets a curious analyst spot rc-only tag rows.
-- ct_params is an opaque blob in MW; stored as bytea for byte-fidelity.

DROP TABLE IF EXISTS change_tag CASCADE;

CREATE TABLE change_tag (
    ct_id       bigint PRIMARY KEY,
    ct_rc_id    bigint,
    ct_log_id   bigint,
    ct_rev_id   bigint,
    ct_params   bytea,
    ct_tag_id   bigint NOT NULL
);
