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

# DATABASE_URL split like the upstream entrypoints do: psql does not take
# Rails' postgis:// scheme, nor its query parameters (pool=...).
if [ -n "$DATABASE_URL" ]; then
  _db_url_stripped="${DATABASE_URL#*://}"
  _db_credentials="${_db_url_stripped%%@*}"
  _db_host_path="${_db_url_stripped#*@}"
  DATABASE_USERNAME="${_db_credentials%%:*}"
  DATABASE_PASSWORD="${_db_credentials#*:}"
  _db_host_port="${_db_host_path%%/*}"
  DATABASE_NAME="${_db_host_path#*/}"
  DATABASE_NAME="${DATABASE_NAME%%\?*}"
  DATABASE_HOST="${_db_host_port%%:*}"
  if [ "$_db_host_port" != "$DATABASE_HOST" ]; then
    DATABASE_PORT="${_db_host_port#*:}"
  else
    DATABASE_PORT="5432"
  fi
fi

db_ready() {
  PGPASSWORD="$DATABASE_PASSWORD" psql -h "$DATABASE_HOST" -p "${DATABASE_PORT:-5432}" \
    -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -c '\q' >/dev/null 2>&1
}

echo "⏳ Waiting for the database..."
until db_ready; do
  >&2 echo "Postgres is unavailable - retrying..."
  sleep 2
done
echo "✅ PostgreSQL is ready, starting: $*"

exec bundle exec "$@"
