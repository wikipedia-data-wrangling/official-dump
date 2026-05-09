-- Phase 3: populated by load_pages_meta_history_xml.py from
-- enwiki-20260401-pages-meta-history*.xml.7z. bytea preserves byte-fidelity
-- of wikitext under the SQL_ASCII DB encoding. rev_text_bytes is denormalized
-- (= length(rev_text)) so length-only stats can scan a small column without
-- detoasting. FK to revision keyed on rev_id ties wikitext back to its
-- metadata; loader drops + re-creates the FK around bulk COPY.

DROP TABLE IF EXISTS revision_text CASCADE;

CREATE TABLE revision_text (
    rev_id          bigint PRIMARY KEY REFERENCES revision(rev_id),
    rev_text        bytea,
    rev_text_bytes  bigint
);
