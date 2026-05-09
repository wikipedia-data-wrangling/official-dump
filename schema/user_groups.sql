-- Phase 1a: loaded from enwiki-20260401-user_groups.sql.gz.
-- Current group memberships (sysop, bot, bureaucrat, ...). ug_group is
-- VARBINARY(255) in MW but in practice all values are short ASCII tokens, so
-- text is sufficient. ug_expiry NULL means an indefinite (non-temporary) grant.

DROP TABLE IF EXISTS user_groups CASCADE;

CREATE TABLE user_groups (
    ug_user    bigint NOT NULL,
    ug_group   text   NOT NULL,
    ug_expiry  timestamptz,
    PRIMARY KEY (ug_user, ug_group)
);
