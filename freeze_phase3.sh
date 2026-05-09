#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# freeze_phase3.sh
#
# Automates the Phase 4b freeze/handoff checklist from data_collection_plan.md
# for the wiki20260401 enwiki dump database. After the Phase 3 wikitext load
# (revision_text) has finished, this script:
#
#   (a) verifies all 11 tables are non-empty (10 Phase 2 tables + revision_text),
#   (b) ensures the snapshots directory exists,
#   (c) creates a *schema-only* custom-format pg_dump (full data dump would be
#       multi-TB and unhelpful — the source 7z files + loader are the
#       reproducibility primitives),
#   (d) snapshots the output of key_figures.sql,
#   (e) computes SHA-1 of both artifacts,
#   (f) appends a "## Phase 3 freeze (UTC ...)" section to MANIFEST.md with
#       row counts, paths, hashes, sizes, git commit hash, and SHA-1s of all
#       enwiki pages-meta-history*.xml.7z parts (warning, not failure, if
#       those parts have been removed to reclaim disk),
#   (g) prints final "Phase 3 freeze complete" message,
#   (h) **spot-check**: samples 5 rev_ids from revision_text and verifies the
#       stored rev_text matches what the live MediaWiki API returns for the
#       same revision. Network failures degrade to a warning so a transient
#       outage doesn't block the freeze; content mismatches are fatal.
#
# Idempotency: refuses to overwrite existing snapshot files unless --force.
# MANIFEST.md is always *appended* to.
#
# Usage:
#   ./freeze_phase3.sh           # normal run
#   ./freeze_phase3.sh --force   # overwrite existing snapshot files
#
# Requirements: bash, psql, pg_dump, sha1sum, curl, jq, awk, find.
# ----------------------------------------------------------------------------

set -euo pipefail

# ---- config ----------------------------------------------------------------
PG_SERVICE="service=wiki"
DB_NAME="wiki20260401"
REPO_DIR="/home/simone/githubRepos/wikipediaData/official-dump"
DUMP_ROOT="/media/simone/ssd1/wikidumps/20260401"
XML_DIR="${DUMP_ROOT}/xml"
SNAP_DIR="${DUMP_ROOT}/snapshots"
SNAP_FILE="${SNAP_DIR}/wiki20260401_phase3_schema.dump"
KEYFIG_FILE="${SNAP_DIR}/key_figures_phase3.txt"
MANIFEST="${DUMP_ROOT}/MANIFEST.md"
KEYFIG_SQL="${REPO_DIR}/key_figures.sql"

USER_AGENT='SantoniWikipediaResearch/1.0 (simone.santoni.1@city.ac.uk)'
API_URL='https://en.wikipedia.org/w/api.php'

PHASE3_TABLES=(
  page
  page_restrictions
  protected_titles
  user_groups
  user_former_groups
  change_tag
  change_tag_def
  logging
  revision
  actor
  revision_text
)

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

step() { echo "==> $*"; }

# ---- tool checks -----------------------------------------------------------
for bin in psql pg_dump sha1sum curl jq awk find; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: required tool '${bin}' not found on PATH." >&2
    if [[ "${bin}" == "jq" ]]; then
      echo "       Install with: sudo apt-get install -y jq" >&2
    fi
    exit 1
  fi
done

# ---- (a) pre-condition check ----------------------------------------------
step "Pre-condition: checking that DB '${DB_NAME}' exists and all 11 Phase 1+2+3 tables are non-empty"

if ! psql "${PG_SERVICE}" -tAc 'SELECT 1' >/dev/null 2>&1; then
  echo "ERROR: cannot connect to Postgres via '${PG_SERVICE}' (db ${DB_NAME})." >&2
  echo "       Verify ~/.pg_service.conf has a [wiki] entry pointing at ${DB_NAME}, and that PG18 on port 5434 is up." >&2
  exit 1
fi

# Confirm revision_text exists at all — if Phase 3 schema wasn't applied, the
# UNION query below would fail with a confusing relation-doesn't-exist error.
if ! psql "${PG_SERVICE}" -tAc "SELECT to_regclass('public.revision_text')" | grep -q 'revision_text'; then
  echo "ERROR: table revision_text does not exist." >&2
  echo "       Apply schema/revision_text.sql before running freeze_phase3.sh." >&2
  exit 1
fi

counts_sql=""
for t in "${PHASE3_TABLES[@]}"; do
  if [[ -n "${counts_sql}" ]]; then
    counts_sql+=" UNION ALL "
  fi
  counts_sql+="SELECT '${t}' AS tbl, COUNT(*)::bigint AS n FROM ${t}"
done
counts_sql+=" ORDER BY tbl;"

counts_out=$(psql "${PG_SERVICE}" -tAF $'\t' -c "${counts_sql}")

empty_tables=()
declare -A row_counts
while IFS=$'\t' read -r tbl n; do
  [[ -z "${tbl}" ]] && continue
  row_counts["${tbl}"]="${n}"
  if [[ "${n}" == "0" ]]; then
    empty_tables+=("${tbl}")
  fi
done <<< "${counts_out}"

if (( ${#empty_tables[@]} > 0 )); then
  echo "ERROR: pre-condition failed — the following table(s) have 0 rows:" >&2
  for t in "${empty_tables[@]}"; do
    case "${t}" in
      page|page_restrictions|protected_titles|user_groups|user_former_groups|change_tag|change_tag_def)
        loader="load_sql_dumps.py" ;;
      logging)
        loader="load_logging_xml.py" ;;
      revision|actor)
        loader="load_stub_history_xml.py" ;;
      revision_text)
        loader="load_pages_meta_history_xml.py" ;;
      *)
        loader="(unknown loader)" ;;
    esac
    echo "  - table ${t} has 0 rows; re-run ${loader}" >&2
  done
  exit 1
fi

step "All 11 tables non-empty. Row counts:"
for t in "${PHASE3_TABLES[@]}"; do
  printf '    %-22s %s\n' "${t}" "${row_counts[${t}]}"
done

# ---- (b) snapshot dir ------------------------------------------------------
step "Ensuring snapshot directory exists: ${SNAP_DIR}"
mkdir -p "${SNAP_DIR}"

# ---- idempotency check before any write -----------------------------------
for f in "${SNAP_FILE}" "${KEYFIG_FILE}"; do
  if [[ -e "${f}" && "${FORCE}" -ne 1 ]]; then
    echo "ERROR: ${f} already exists. Re-run with --force to overwrite, or move/delete the existing file." >&2
    exit 1
  fi
done

# ---- (c) pg_dump (schema-only) --------------------------------------------
step "Running pg_dump --schema-only (custom format) -> ${SNAP_FILE}"
if [[ "${FORCE}" -eq 1 ]]; then
  rm -f "${SNAP_FILE}"
fi
pg_dump -Fc --schema-only --no-owner --no-privileges -d "${DB_NAME}" -f "${SNAP_FILE}"
snap_size=$(stat -c '%s' "${SNAP_FILE}")
step "pg_dump complete. File size: ${snap_size} bytes"

# ---- (d) key_figures snapshot ---------------------------------------------
step "Capturing key_figures.sql output -> ${KEYFIG_FILE}"
if [[ "${FORCE}" -eq 1 ]]; then
  rm -f "${KEYFIG_FILE}"
fi
psql "${PG_SERVICE}" -f "${KEYFIG_SQL}" > "${KEYFIG_FILE}" 2>&1
keyfig_lines=$(wc -l < "${KEYFIG_FILE}")
step "key_figures snapshot written. Line count: ${keyfig_lines}"

# ---- (e) SHA-1s of snapshot artifacts -------------------------------------
step "Computing SHA-1 of snapshot artifacts"
snap_sha1=$(sha1sum "${SNAP_FILE}" | awk '{print $1}')
keyfig_sha1=$(sha1sum "${KEYFIG_FILE}" | awk '{print $1}')
keyfig_size=$(stat -c '%s' "${KEYFIG_FILE}")
echo "    ${SNAP_FILE}    ${snap_sha1}"
echo "    ${KEYFIG_FILE}  ${keyfig_sha1}"

# ---- SHA-1s of pages-meta-history*.xml.7z ---------------------------------
step "Computing SHA-1 of pages-meta-history*.xml.7z files in ${XML_DIR}"
xml7z_lines=""
xml7z_count=0
if [[ -d "${XML_DIR}" ]]; then
  while IFS= read -r -d '' f; do
    sha=$(sha1sum "${f}" | awk '{print $1}')
    base=$(basename "${f}")
    sz=$(stat -c '%s' "${f}")
    xml7z_lines+="| ${base} | ${sha} | ${sz} |"$'\n'
    xml7z_count=$((xml7z_count + 1))
    echo "    ${base}  ${sha}"
  done < <(find "${XML_DIR}" -maxdepth 1 -type f -name 'enwiki-*-pages-meta-history*.xml.7z' -print0 | sort -z)
fi
if (( xml7z_count == 0 )); then
  echo "    WARNING: no enwiki-*-pages-meta-history*.xml.7z files found in ${XML_DIR}." >&2
  echo "             They may have been removed post-load to reclaim space; continuing." >&2
fi

# ---- (f) MANIFEST append ---------------------------------------------------
step "Appending Phase 3 freeze section to ${MANIFEST}"
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
git_hash=$( (cd "${REPO_DIR}" && git rev-parse HEAD 2>/dev/null) || echo "(uncommitted)" )

mkdir -p "$(dirname "${MANIFEST}")"
touch "${MANIFEST}"

{
  echo ""
  echo "## Phase 3 freeze (UTC ${ts})"
  echo ""
  echo "**Git commit:** \`${git_hash}\`"
  echo ""
  echo "### Per-table row counts"
  echo ""
  echo "| table | rows |"
  echo "|---|---|"
  for t in "${PHASE3_TABLES[@]}"; do
    echo "| ${t} | ${row_counts[${t}]} |"
  done
  echo ""
  echo "### Snapshot artifacts"
  echo ""
  echo "| artifact | path | SHA-1 | size (bytes) |"
  echo "|---|---|---|---|"
  echo "| pg_dump (custom-format, schema-only) | \`${SNAP_FILE}\` | \`${snap_sha1}\` | ${snap_size} |"
  echo "| key_figures output | \`${KEYFIG_FILE}\` | \`${keyfig_sha1}\` | ${keyfig_size} (lines: ${keyfig_lines}) |"
  echo ""
  echo "### pages-meta-history*.xml.7z source files"
  echo ""
  if (( xml7z_count == 0 )); then
    echo "_No \`enwiki-*-pages-meta-history*.xml.7z\` files present in \`${XML_DIR}\` at freeze time (likely removed post-load to reclaim space)._"
  else
    echo "| filename | SHA-1 | size (bytes) |"
    echo "|---|---|---|"
    printf '%s' "${xml7z_lines}"
  fi
  echo ""
} >> "${MANIFEST}"

# ---- (h) Spot-check vs. MediaWiki API -------------------------------------
step "Spot-check: comparing 5 sampled revision_text rows against the live MediaWiki API"

# Sample 5 rev_ids. TABLESAMPLE BERNOULLI(0.001) over a billion-row table
# yields ~1M candidates; LIMIT 5 picks five. If the sample comes up empty
# (extremely unlikely), retry with a wider sample.
sample_sql="SELECT rev_id FROM revision_text TABLESAMPLE BERNOULLI(0.001) LIMIT 5"
sample_ids=$(psql "${PG_SERVICE}" -tAc "${sample_sql}" | tr -d '[:space:]' | tr ',' '\n' | grep -v '^$' || true)
# psql -tA returns one rev_id per line already; the tr above is defensive.
sample_ids=$(psql "${PG_SERVICE}" -tAc "${sample_sql}")

if [[ -z "${sample_ids//[[:space:]]/}" ]]; then
  step "Sample empty; widening sample"
  sample_ids=$(psql "${PG_SERVICE}" -tAc "SELECT rev_id FROM revision_text ORDER BY random() LIMIT 5")
fi

mapfile -t sample_arr < <(echo "${sample_ids}" | sed '/^[[:space:]]*$/d')
if (( ${#sample_arr[@]} == 0 )); then
  echo "ERROR: could not sample any rev_ids from revision_text (table is non-empty per pre-check; this is unexpected)." >&2
  exit 1
fi

# Probe API reachability with HEAD; if unreachable, downgrade to warning.
api_ok=1
if ! curl -sS -A "${USER_AGENT}" --max-time 15 -o /dev/null -w '%{http_code}' \
      "${API_URL}?action=query&meta=siteinfo&format=json" | grep -q '^200$'; then
  api_ok=0
  echo "    WARNING: MediaWiki API unreachable (curl probe failed). Skipping spot-check." >&2
fi

mismatches=()
ok_count=0
if (( api_ok == 1 )); then
  for rid in "${sample_arr[@]}"; do
    rid_clean=$(echo "${rid}" | tr -d '[:space:]')
    [[ -z "${rid_clean}" ]] && continue

    # Fetch wikitext from API.
    api_resp=$(curl -sS -A "${USER_AGENT}" --max-time 30 \
      --data-urlencode "action=query" \
      --data-urlencode "prop=revisions" \
      --data-urlencode "rvprop=content|ids" \
      --data-urlencode "rvslots=main" \
      --data-urlencode "revids=${rid_clean}" \
      --data-urlencode "format=json" \
      -G "${API_URL}" || echo "")

    if [[ -z "${api_resp}" ]]; then
      echo "    WARNING: API call for rev_id ${rid_clean} failed; skipping spot-check." >&2
      api_ok=0
      break
    fi

    # Pull out the revision content. Path:
    #   query.pages[<pageid>].revisions[0].slots.main.* (key '*' contains text in JSON).
    # First check the API actually returned the revision (not a 'badrevids').
    badrev=$(echo "${api_resp}" | jq -r '.query.badrevids // {} | keys[]?' 2>/dev/null || true)
    if [[ -n "${badrev}" ]]; then
      mismatches+=("${rid_clean} (API reports badrevids — revision not accessible, possibly suppressed)")
      continue
    fi

    api_text=$(echo "${api_resp}" | jq -r '
      .query.pages
      | to_entries[0].value.revisions[0].slots.main."*" // empty
    ' 2>/dev/null || true)

    if [[ -z "${api_text}" ]]; then
      mismatches+=("${rid_clean} (API returned no content; response: $(echo "${api_resp}" | head -c 200))")
      continue
    fi

    # Fetch DB-stored text. revision_text.rev_text is bytea per Phase 3 schema;
    # encode as base64 to round-trip binary cleanly through psql, then compare
    # SHA-1 hashes of the byte sequences. We re-encode the API JSON string as
    # UTF-8 (jq -r already emits UTF-8 bytes on stdout) so the hash inputs are
    # apples-to-apples bytes.
    db_b64=$(psql "${PG_SERVICE}" -tAc "SELECT encode(rev_text, 'base64') FROM revision_text WHERE rev_id = ${rid_clean}")
    if [[ -z "${db_b64//[[:space:]]/}" ]]; then
      mismatches+=("${rid_clean} (no rev_text row in DB despite earlier sample)")
      continue
    fi

    db_sha=$(echo "${db_b64}" | tr -d '\n' | base64 -d | sha1sum | awk '{print $1}')
    api_sha=$(printf '%s' "${api_text}" | sha1sum | awk '{print $1}')

    if [[ "${db_sha}" == "${api_sha}" ]]; then
      ok_count=$((ok_count + 1))
      echo "    rev_id ${rid_clean}: OK (sha1=${db_sha})"
    else
      mismatches+=("${rid_clean} (db_sha=${db_sha} api_sha=${api_sha})")
      echo "    rev_id ${rid_clean}: MISMATCH (db_sha=${db_sha}, api_sha=${api_sha})"
    fi
  done
fi

if (( api_ok == 1 )); then
  if (( ${#mismatches[@]} == 0 && ok_count == ${#sample_arr[@]} )); then
    echo "OK"
  else
    echo "ERROR: spot-check failed for the following rev_id(s):" >&2
    for m in "${mismatches[@]}"; do
      echo "  - ${m}" >&2
    done
    exit 1
  fi
fi

# ---- (g) done --------------------------------------------------------------
step "Phase 3 freeze complete."
echo ""
echo "Artifacts:"
echo "  - pg_dump (schema-only): ${SNAP_FILE}"
echo "  - key_figures:           ${KEYFIG_FILE}"
echo "  - manifest:              ${MANIFEST}"
