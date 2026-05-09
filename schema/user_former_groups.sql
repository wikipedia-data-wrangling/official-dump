-- Phase 1a: loaded from enwiki-20260401-user_former_groups.sql.gz.
-- Records of revoked group memberships — the only way to find desysopped
-- admins, important for the project's admin-population denominator.

DROP TABLE IF EXISTS user_former_groups CASCADE;

CREATE TABLE user_former_groups (
    ufg_user    bigint NOT NULL,
    ufg_group   text   NOT NULL,
    PRIMARY KEY (ufg_user, ufg_group)
);
