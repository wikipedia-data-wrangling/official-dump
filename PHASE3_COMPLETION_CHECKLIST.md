# Phase 3 → data-collection completion checklist

Status as of 2026-06-29. Goal: `wiki20260401` fully **loaded → balanced → frozen**,
ready for analysis. Steps are **serial** (the rebalance needs the loader stopped).

Legend: `[ ]` todo · `[~]` in progress · `[x]` done

---

## 1. Finish Phase 3 load (revision_text)  `[~]`  — ETA ~1.5–2 days
- [~] Loader running (`tmux phase3-load`, 2 workers, `--skip-revision-check`)
- [ ] All `--files` for the run reported `done: seen=…` in `phase3_loader_active.log`
- [ ] Loader exits cleanly (no traceback; FK re-create attempted at end-of-run)
- [ ] **Verify:** `revision_text` rows ≈ `revision` rows minus text-deleted
      `SELECT (SELECT n_live_tup FROM pg_stat_all_tables WHERE relname LIKE 'revision_text_p%') ...`
      vs `revision` reltuples (1,249,572,224). Small shortfall = deleted-text revs (expected).

## 2. Rebalance p1 across drives  `[ ]`  — ETA ~1 day  — `runbooks/phase3_rebalance_p1.sh`
Fires automatically via the monitoring loop on **load completion** OR **lacie14 < 150 GB**.
- [ ] Loader confirmed stopped (script stops it if still running)
- [ ] `DETACH` old p1 → `revision_text_p1_old`; create `_p1_lo`@lacie10 + `_p1_hi`@ssd1
- [ ] Range-routed copy completes (descending sweep; ssd1 validated first)
- [ ] **Verify:** `count(p1_lo)+count(p1_hi) == count(old)` — script refuses to drop otherwise
- [ ] `DROP revision_text_p1_old` → frees ~9 TB on lacie14; `ANALYZE` new partitions
- [ ] **Verify layout:** lacie14 ~9.5 TB free · lacie10 holds p1_lo+metadata · ssd1 holds p2+p1_hi

## 3. Recreate the FK  `[ ]`  — ETA ~2–5 h
- [ ] `ALTER TABLE revision_text ADD CONSTRAINT … FOREIGN KEY (rev_id) REFERENCES revision(rev_id)`
      (only if not already re-created by the loader's clean end-of-run)
- [ ] **Verify:** `SELECT conname FROM pg_constraint WHERE conrelid='revision_text'::regclass AND contype='f';` returns 1 row

## 4. Phase 4b freeze / handoff  `[ ]`  — ETA ~1–2 h  — `freeze_phase3.sh`
- [ ] Schema-only pg_dump → `snapshots/wiki20260401_phase3_schema.dump` (NOT full data — multi-TB, skipped by design)
- [ ] `key_figures.sql` snapshot → `key_figures_phase3.txt` (+ content sentinels: avg/median wikitext bytes by year)
- [ ] **Spot-check:** 5 known revisions across years — DB `rev_text` byte-identical to live MediaWiki API
- [ ] SHA-1s appended to `MANIFEST.md` on the SSD
- [ ] Code freeze: commit loaders/schema; tag `phase3-frozen`

---

## Done when
All of §1–§4 checked; both snapshot artifacts exist; FK present; spot-check passed.
**Overall ETA: ~3–4 days (~Jul 2–3, slipping to ~Jul 4 if the load rate stays slow).**

## Watching it
Monitoring loop polls hourly: fires §2 on completion/danger, then I drive §3–§4.
Disk burn + progress tracked via `phase3_eta_samples.csv` and `key_figures.sql`.
