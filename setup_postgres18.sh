#!/usr/bin/env bash
# Tear down the MariaDB setup, install PostgreSQL 18 from PGDG (jammy),
# and create a fresh wiki20260401 database whose data lives on
# /media/simone/ssd1.
#
# Run with: sudo bash setup_postgres18.sh
#
# Idempotent-ish: re-runs after partial success will skip already-done steps.
# Existing PG15 (port 5432, richard) and PG16 (port 5433) are NOT touched.

set -euo pipefail

USER_NAME="simone"
SSD_BASE="/media/simone/ssd1"
TABLESPACE_DIR="$SSD_BASE/postgres-wiki"
DUMP_DIR="$SSD_BASE/wikidumps"
DB_NAME="wiki20260401"
TABLESPACE_NAME="wiki_ts"
PG_VERSION="18"

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root (use sudo)." >&2
  exit 1
fi

# ============================================================
# 1. Tear down MariaDB
# ============================================================
echo "==> 1. Tearing down MariaDB"
if systemctl list-unit-files | grep -q '^mariadb\.service'; then
  systemctl stop mariadb || true
  systemctl disable mariadb || true
fi
if dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
  DEBIAN_FRONTEND=noninteractive apt-get -y remove --purge 'mariadb-server*' || true
  apt-get -y autoremove --purge || true
fi
if [[ -d "$SSD_BASE/mariadb" ]]; then
  echo "    Removing relocated MariaDB datadir $SSD_BASE/mariadb"
  rm -rf "$SSD_BASE/mariadb"
fi
echo "    MariaDB teardown done."

# ============================================================
# 2. Fix the PGDG apt repo (focal -> jammy) and install PG18
# ============================================================
echo "==> 2. Configuring PGDG (jammy) and installing postgresql-$PG_VERSION"

# Disable any stale focal-pgdg entries in /etc/apt/sources.list.d
for f in /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.sources /etc/apt/sources.list.d/*pgdg*.list; do
  [[ -e "$f" ]] || continue
  if grep -q 'focal-pgdg' "$f"; then
    echo "    Disabling stale focal-pgdg entries in $f"
    sed -i 's|^\(deb .*focal-pgdg.*\)$|# \1  # disabled by setup_postgres18.sh|' "$f"
  fi
done

# Use postgresql-common's official PGDG setup script to write the jammy repo
# and install the signing key. Idempotent.
apt-get update -y || true
apt-get install -y postgresql-common ca-certificates curl gnupg lsb-release
# Feed the script a single newline via a here-string. We deliberately don't use
# `yes |` here: when the PGDG script finishes, `yes` gets SIGPIPE (exit 141)
# and `set -o pipefail` would propagate that, killing the rest of the script.
/usr/share/postgresql-common/pgdg/apt.postgresql.org.sh <<< ""

apt-get update -y
apt-get install -y "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION" "postgresql-contrib-$PG_VERSION"

# Debian's postgresql-N postinst usually auto-creates a 'main' cluster, but on
# this host it did not. Create it explicitly if missing.
if ! pg_lsclusters --no-header | awk -v v="$PG_VERSION" '$1==v && $2=="main" {found=1} END{exit !found}'; then
  echo "    No PG$PG_VERSION 'main' cluster found — creating with pg_createcluster"
  pg_createcluster --start "$PG_VERSION" main
fi

# Confirm cluster is up; pg_lsclusters lists all installed clusters.
echo "    Cluster status:"
pg_lsclusters

# Resolve the port for the new PG18 cluster (auto-assigned by Debian's pg_createcluster).
PG_PORT="$(pg_lsclusters --no-header | awk -v v="$PG_VERSION" '$1==v && $2=="main" {print $3}')"
if [[ -z "${PG_PORT:-}" ]]; then
  echo "ERROR: could not determine port for PG$PG_VERSION cluster 'main'." >&2
  exit 1
fi
echo "    PG$PG_VERSION 'main' cluster is on port $PG_PORT"

# ============================================================
# 3. Prepare SSD tablespace directory + dump download dir
# ============================================================
echo "==> 3. Preparing $TABLESPACE_DIR and $DUMP_DIR"
mkdir -p "$TABLESPACE_DIR"
chown postgres:postgres "$TABLESPACE_DIR"
chmod 700 "$TABLESPACE_DIR"
mkdir -p "$DUMP_DIR"
chown "$USER_NAME:$USER_NAME" "$DUMP_DIR"
ls -ld "$TABLESPACE_DIR" "$DUMP_DIR"

# ============================================================
# 4. Create role + tablespace + database
# ============================================================
echo "==> 4. Creating role '$USER_NAME', tablespace '$TABLESPACE_NAME', DB '$DB_NAME' on PG$PG_VERSION"

# Role can be created inside a DO block.
sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$USER_NAME') THEN
    CREATE ROLE $USER_NAME WITH LOGIN CREATEDB;
  END IF;
END
\$\$;
SQL

# CREATE TABLESPACE and CREATE DATABASE can't run inside a DO block (or any
# transaction-affecting function context), so guard them with a SELECT first.
TS_EXISTS="$(sudo -u postgres psql -p "$PG_PORT" -tAc "SELECT 1 FROM pg_tablespace WHERE spcname='$TABLESPACE_NAME'")"
if [[ "$TS_EXISTS" != "1" ]]; then
  sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 -c \
    "CREATE TABLESPACE $TABLESPACE_NAME OWNER $USER_NAME LOCATION '$TABLESPACE_DIR';"
else
  echo "    Tablespace $TABLESPACE_NAME already exists — skipping CREATE TABLESPACE."
fi

DB_EXISTS="$(sudo -u postgres psql -p "$PG_PORT" -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
if [[ "$DB_EXISTS" != "1" ]]; then
  sudo -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 -c \
    "CREATE DATABASE $DB_NAME OWNER $USER_NAME TABLESPACE $TABLESPACE_NAME ENCODING 'SQL_ASCII' LC_COLLATE='C' LC_CTYPE='C' TEMPLATE template0;"
else
  echo "    DB $DB_NAME already exists — skipping CREATE DATABASE."
fi

# ============================================================
# 5. Set up a pg_service entry for the simone user so future
#    code can connect with `service=wiki` without specifying the port.
# ============================================================
echo "==> 5. Writing ~$USER_NAME/.pg_service.conf"
SVC_FILE="/home/$USER_NAME/.pg_service.conf"
cat > "$SVC_FILE" <<EOF
[wiki]
host=/var/run/postgresql
port=$PG_PORT
dbname=$DB_NAME
user=$USER_NAME
EOF
chown "$USER_NAME:$USER_NAME" "$SVC_FILE"
chmod 600 "$SVC_FILE"

# ============================================================
# 6. Verify
# ============================================================
echo "==> 6. Verifying connection as $USER_NAME"
sudo -u "$USER_NAME" psql "service=wiki" -c "SELECT current_database(), current_user, current_setting('server_version'), pg_size_pretty(pg_database_size(current_database())) AS db_size, (SELECT spcname FROM pg_tablespace WHERE oid = (SELECT dattablespace FROM pg_database WHERE datname=current_database())) AS tablespace;"

echo
echo "Done."
echo "  PG version : $PG_VERSION"
echo "  Port       : $PG_PORT"
echo "  Database   : $DB_NAME (encoding SQL_ASCII, on tablespace $TABLESPACE_NAME at $TABLESPACE_DIR)"
echo "  Connect as : psql service=wiki   (from the simone user)"
echo "  Dump dir   : $DUMP_DIR"
