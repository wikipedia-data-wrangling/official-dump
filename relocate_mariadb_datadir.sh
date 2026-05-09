#!/usr/bin/env bash
# Relocate MariaDB datadir from /var/lib/mysql to /media/simone/ssd1/mariadb
# and prepare the dump-download directory.
#
# Run with: sudo bash relocate_mariadb_datadir.sh
#
# Idempotent-ish: re-running after success will refuse to overwrite an
# existing datadir at the new location.

set -euo pipefail

OLD_DATADIR="/var/lib/mysql"
NEW_DATADIR="/media/simone/ssd1/mariadb"
DUMP_DIR="/media/simone/ssd1/wikidumps"
CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
APPARMOR_LOCAL="/etc/apparmor.d/local/usr.sbin.mysqld"
USER_NAME="simone"

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root (use sudo)." >&2
  exit 1
fi

echo "==> 1. Preparing dump download directory at $DUMP_DIR"
mkdir -p "$DUMP_DIR"
chown "$USER_NAME:$USER_NAME" "$DUMP_DIR"
ls -ld "$DUMP_DIR"

echo "==> 2. Stopping MariaDB"
systemctl stop mariadb

echo "==> 3. Copying current datadir to $NEW_DATADIR (preserves attrs)"
if [[ -d "$NEW_DATADIR" && -n "$(ls -A "$NEW_DATADIR" 2>/dev/null)" ]]; then
  echo "    $NEW_DATADIR already exists and is non-empty — refusing to overwrite." >&2
  echo "    If this is a re-run after success, you can skip directly to verification." >&2
  systemctl start mariadb
  exit 1
fi
mkdir -p "$NEW_DATADIR"
rsync -a --info=progress2 "$OLD_DATADIR/" "$NEW_DATADIR/"
chown -R mysql:mysql "$NEW_DATADIR"

echo "==> 4. Patching $CONF"
# Back up once.
if [[ ! -f "${CONF}.bak" ]]; then
  cp "$CONF" "${CONF}.bak"
fi
# Set datadir in the [mysqld] section. If a datadir line exists, replace it; else append after [mysqld].
if grep -qE '^[[:space:]]*datadir[[:space:]]*=' "$CONF"; then
  sed -i -E "s|^[[:space:]]*datadir[[:space:]]*=.*|datadir = $NEW_DATADIR|" "$CONF"
else
  awk -v new="datadir = $NEW_DATADIR" '
    /^\[mysqld\]/ { print; print new; next }
    { print }
  ' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
fi
echo "    datadir line in $CONF:"
grep -nE '^[[:space:]]*datadir' "$CONF" || true

echo "==> 5. Updating AppArmor (if profile is loaded for mysqld)"
if aa-status 2>/dev/null | grep -q mysqld; then
  mkdir -p "$(dirname "$APPARMOR_LOCAL")"
  touch "$APPARMOR_LOCAL"
  if ! grep -q "$NEW_DATADIR" "$APPARMOR_LOCAL"; then
    cat >> "$APPARMOR_LOCAL" <<EOF

# Allow MariaDB to use the SSD datadir (added by relocate_mariadb_datadir.sh)
$NEW_DATADIR/ r,
$NEW_DATADIR/** rwk,
EOF
    apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld 2>/dev/null \
      || apparmor_parser -r /etc/apparmor.d/usr.sbin.mariadbd 2>/dev/null \
      || echo "    (no apparmor profile file matched; skipped reload)"
  else
    echo "    AppArmor local profile already mentions $NEW_DATADIR — skipping."
  fi
else
  echo "    No mysqld AppArmor profile loaded — nothing to do."
fi

echo "==> 6. Starting MariaDB on the new datadir"
systemctl start mariadb
sleep 2
systemctl is-active mariadb
mariadb -e "SELECT @@datadir, @@version;"

echo "==> 7. Old datadir at $OLD_DATADIR is left in place (NOT deleted)."
echo "    After verifying things work for a few days, reclaim with:"
echo "      sudo rm -rf $OLD_DATADIR"

echo
echo "Done. New datadir: $NEW_DATADIR"
echo "Dump downloads dir: $DUMP_DIR"
