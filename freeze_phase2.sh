#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# freeze_phase2.sh
#
# Automates the Phase 4a freeze/handoff checklist from data_collection_plan.md
# for the wiki20260401 enwiki dump database. After Phase 1+2 loaders have
# populated all 10 base tables (page, page_restrictions, protected_titles,
# user_groups, user_former_groups, change_tag, change_tag_def, logging,
# revision, actor), this script:
#
#   (a) verifies all 10 tables are non-empty,
#   (b) ensures the snapshots directory exists,
#   (c) creates a custom-format pg_dump of the whole DB,
#   (d) snapshots the output of key_figures.sql,
#   (e) computes SHA-1 of both artifacts,
#   (f) appends a "## Phase 2 freeze (UTC ...)" section to MANIFEST.md
#       with row counts, paths, hashes, sizes, and the git commit hash,
#   (g) prints a final "Phase 2 freeze complete" message.
#
# Idempotency: refuses to overwrite existing snapshot files unless --force
# is passed. MANIFEST.md is always *appended* to, never rewritten.
#
# Usage:
#   ./freeze_phase2.sh           # normal run
#   ./freeze_phase2.sh --force   # overwrite existing snapshot files
#
# Requirements: bash, psql, pg_dump, sha1sum, awk, sed, find. Postgres
# connection uses the `wiki` service entry from ~/.pg_service.conf.
# ----------------------------------------------------------------------------

set -euo pipefail

# ---- config ----------------------------------------------------------------
PG_SERVICE="service=wiki"
DB_NAME="wiki20260401"
REPO_DIR="/home/simone/githubRepos/wikipediaData/official-dump"
DUMP_ROOT="/media/simone/ssd1/wikidumps/20260401"
SNAP_DIR="${DUMP_ROOT}/snapshots"
SNAP_FILE="${SNAP_DIR}/wiki20260401_phase2.dump"
KEYFIG_FILE="${SNAP_DIR}/key_figures_phase2.txt"
MANIFEST="${DUMP_ROOT}/MANIFEST.md"
KEYFIG_SQL="${REPO_DIR}/key_figures.sql"

PHASE2_TABLES=(
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
)

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

step() { echo "==> $*"; }

# ---- (a) pre-condition check ----------------------------------------------
step "Pre-condition: checking that DB '${DB_NAME}' exists and all 10 Phase 1+2 tables are non-empty"

# DB existence: psql will exit non-zero if connection/db is bad.
if ! psql "${PG_SERVICE}" -tAc 'SELECT 1' >/dev/null 2>&1; then
  echo "ERROR: cannot connect to Postgres via '${PG_SERVICE}' (db ${DB_NAME})." >&2
  echo "       Verify ~/.pg_service.conf has a [wiki] entry pointing at ${DB_NAME}, and that PG18 on port 5434 is up." >&2
  exit 1
fi

# Build a single SQL UNION ALL that returns "tablename<TAB>count" for each.
counts_sql=""
for t in "${PHASE2_TABLES[@]}"; do
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
  echo "ERROR: pre-condition failed — the following Phase 1+2 table(s) have 0 rows:" >&2
  for t in "${empty_tables[@]}"; do
    case "${t}" in
      page|page_restrictions|protected_titles|user_groups|user_former_groups|change_tag|change_tag_def)
        loader="load_sql_dumps.py" ;;
      logging)
        loader="load_logging_xml.py" ;;
      revision|actor)
        loader="load_stub_history_xml.py" ;;
      *)
        loader="(unknown loader)" ;;
    esac
    echo "  - table ${t} has 0 rows; re-run ${loader}" >&2
  done
  exit 1
fi

step "All 10 tables non-empty. Row counts:"
for t in "${PHASE2_TABLES[@]}"; do
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

# ---- (c) pg_dump -----------------------------------------------------------
step "Running pg_dump (custom format, no owner/privileges) -> ${SNAP_FILE}"
# Remove any stale file when --force was given so pg_dump starts clean.
if [[ "${FORCE}" -eq 1 ]]; then
  rm -f "${SNAP_FILE}"
fi
pg_dump -Fc --no-owner --no-privileges -d "${DB_NAME}" -f "${SNAP_FILE}"
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

# ---- (e) SHA-1s ------------------------------------------------------------
step "Computing SHA-1 of snapshot artifacts"
snap_sha1=$(sha1sum "${SNAP_FILE}" | awk '{print $1}')
keyfig_sha1=$(sha1sum "${KEYFIG_FILE}" | awk '{print $1}')
keyfig_size=$(stat -c '%s' "${KEYFIG_FILE}")
echo "    ${SNAP_FILE}    ${snap_sha1}"
echo "    ${KEYFIG_FILE}  ${keyfig_sha1}"

# ---- (f) MANIFEST append ---------------------------------------------------
step "Appending Phase 2 freeze section to ${MANIFEST}"
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

git_hash=$( (cd "${REPO_DIR}" && git rev-parse HEAD 2>/dev/null) || echo "(uncommitted)" )

mkdir -p "$(dirname "${MANIFEST}")"
touch "${MANIFEST}"

{
  echo ""
  echo "## Phase 2 freeze (UTC ${ts})"
  echo ""
  echo "**Git commit:** \`${git_hash}\`"
  echo ""
  echo "### Per-table row counts"
  echo ""
  echo "| table | rows |"
  echo "|---|---|"
  for t in "${PHASE2_TABLES[@]}"; do
    echo "| ${t} | ${row_counts[${t}]} |"
  done
  echo ""
  echo "### Snapshot artifacts"
  echo ""
  echo "| artifact | path | SHA-1 | size (bytes) |"
  echo "|---|---|---|---|"
  echo "| pg_dump (custom-format, full data) | \`${SNAP_FILE}\` | \`${snap_sha1}\` | ${snap_size} |"
  echo "| key_figures output | \`${KEYFIG_FILE}\` | \`${keyfig_sha1}\` | ${keyfig_size} (lines: ${keyfig_lines}) |"
  echo ""
} >> "${MANIFEST}"

# ---- (g) done --------------------------------------------------------------
step "Phase 2 freeze complete."
echo ""
echo "Artifacts:"
echo "  - pg_dump:      ${SNAP_FILE}"
echo "  - key_figures:  ${KEYFIG_FILE}"
echo "  - manifest:     ${MANIFEST}"
