#!/bin/sh
# Entrypoint of the Discord transit bot container (`rails gtfs:discord_bot`):
# like the upstream sidekiq entrypoint, wait for the database, then run the
# command. The bot exits 3 when the token or the on/off switch changes on
# /transit/discord, and 1 when it is not configured; the compose restart
# policy starts it again.
unset BUNDLE_PATH
unset BUNDLE_BIN

set -e

# Optional privilege drop, as in the upstream entrypoints (PUID/PGID).
if [ "$(id -u)" = "0" ] && [ -n "${PUID}${PGID}" ]; then
  TARGET_UID="${PUID:-1000}"
  TARGET_GID="${PGID:-1000}"
  for _dir in storage tmp log; do
    _path="$APP_PATH/$_dir"
    [ -d "$_path" ] || continue
    if [ "$(stat -c '%u' "$_path")" != "$TARGET_UID" ]; then
      chown -R "$TARGET_UID:$TARGET_GID" "$_path"
    fi
  done
  exec gosu "$TARGET_UID:$TARGET_GID" "$0" "$@"
fi

# With DATABASE_URL, psql gets it as a URI (libpq decodes %-escapes and
# takes any host form), with the postgresql scheme instead of Rails' postgis
# and without the query, whose Rails options (pool=...) libpq would refuse.
if [ -n "$DATABASE_URL" ]; then
  _db_uri="postgresql://${DATABASE_URL#*://}"
  _db_uri="${_db_uri%%\?*}"
fi

db_ready() {
  if [ -n "$DATABASE_URL" ]; then
    psql "$_db_uri" -c '\q' >/dev/null 2>&1
  else
    PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "${DATABASE_PORT:-5432}" \
      -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -c '\q' >/dev/null 2>&1
  fi
}

echo "⏳ Waiting for the database..."
until db_ready; do
  >&2 echo "Postgres is unavailable - retrying..."
  sleep 2
done
echo "✅ PostgreSQL is ready, starting: $*"

exec bundle exec "$@"
