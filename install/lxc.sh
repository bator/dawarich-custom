#!/usr/bin/env bash
# Install (or update) dawarich-custom inside a community-scripts Dawarich LXC
# (https://community-scripts.github.io/ProxmoxVE/scripts?id=dawarich). Run as
# root in the container; install/proxmox.sh does that from the Proxmox host.
# Safe to run again: it pulls the repo and re-applies the restore.
#
#   - clones or updates the repo in /opt/dawarich-custom
#   - creates /opt/dawarich/gtfs.env (GTFS_ENABLED=true) unless it exists
#   - adds that file to dawarich-web and dawarich-worker (systemd drop-ins)
#   - installs dawarich-gtfs-discord-bot.service, disabled until configured
#   - installs a .path trigger: after every community-scripts update the
#     restore runs again (restore_custom.py --settle)
#   - runs the restore (files, migrations, assets, restart, smoke check)
#   - creates the timetable rows (all disabled)
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/bator/dawarich-custom.git}
BRANCH=${BRANCH:-main}
REPO_DIR=${REPO_DIR:-/opt/dawarich-custom}
APP=/opt/dawarich/app
ENV_FILE=/opt/dawarich/.env
GTFS_ENV=/opt/dawarich/gtfs.env
UNITS=/etc/systemd/system
BUNDLE=/root/.rbenv/shims/bundle

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$APP" ] && [ -f "$ENV_FILE" ] || die "no community-scripts Dawarich install here ($APP, $ENV_FILE)"
systemctl cat dawarich-web.service >/dev/null 2>&1 || die "dawarich-web.service missing"
[ -x "$BUNDLE" ] || die "$BUNDLE missing (rbenv Ruby of the community-scripts install)"

say "packages: git, python3"
if ! command -v git >/dev/null || ! command -v python3 >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git python3 ca-certificates >/dev/null
fi

if [ -d "$REPO_DIR/.git" ]; then
  say "updating $REPO_DIR"
  git -C "$REPO_DIR" fetch -q origin "$BRANCH"
  git -C "$REPO_DIR" merge -q --ff-only FETCH_HEAD || die "$REPO_DIR has local commits; merge by hand"
else
  say "cloning $REPO_URL into $REPO_DIR"
  git clone -q --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

app_version=$(cat "$APP/.app_version" 2>/dev/null || echo unknown)
base_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_version"])' "$REPO_DIR/manifest.json")
if [ "$app_version" != "$base_version" ]; then
  say "note: Dawarich here is $app_version, the custom code is based on $base_version; the restore merges it and stops on a conflict"
fi

if [ ! -f "$GTFS_ENV" ]; then
  say "creating $GTFS_ENV"
  install -m 600 "$REPO_DIR/docker/transit.env.example" "$GTFS_ENV"
else
  say "keeping $GTFS_ENV"
fi

say "systemd: gtfs.env for web and worker, bot unit, restore trigger"
for unit in dawarich-web dawarich-worker; do
  mkdir -p "$UNITS/$unit.service.d"
  cat >"$UNITS/$unit.service.d/gtfs.conf" <<EOF
# dawarich-custom (install/lxc.sh): GTFS settings
[Service]
EnvironmentFile=-$GTFS_ENV
EOF
done

if [ ! -f "$UNITS/dawarich-gtfs-discord-bot.service" ]; then
  cat >"$UNITS/dawarich-gtfs-discord-bot.service" <<EOF
# dawarich-custom (install/lxc.sh). Enable once the bot is set up on
# /transit/discord: systemctl enable --now dawarich-gtfs-discord-bot
[Unit]
Description=Dawarich GTFS Discord bot (gateway for the ride approval buttons)
After=network-online.target postgresql.service redis-server.service dawarich-web.service
Requires=postgresql.service redis-server.service
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$APP
EnvironmentFile=$ENV_FILE
EnvironmentFile=-$GTFS_ENV
ExecStart=$BUNDLE exec rails gtfs:discord_bot
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
fi

if [ -f "$UNITS/dawarich-osrm-restore.path" ]; then
  say "an OSRM overlay trigger exists; not adding a second one (chain the restore there, see systemd/)"
else
  cat >"$UNITS/dawarich-custom-restore.service" <<EOF
# dawarich-custom (install/lxc.sh): put the custom code back after an update
[Unit]
Description=Restore dawarich-custom after a Dawarich update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $REPO_DIR/restore_custom.py --settle
TimeoutStartSec=90min
Nice=10
EOF
  cat >"$UNITS/dawarich-custom-restore.path" <<EOF
# dawarich-custom (install/lxc.sh): the community-scripts update replaces
# $APP, and with it .app_version
[Unit]
Description=Trigger the dawarich-custom restore when the Dawarich version file changes

[Path]
PathChanged=$APP/.app_version
Unit=dawarich-custom-restore.service

[Install]
WantedBy=paths.target
EOF
  systemctl daemon-reload
  systemctl enable -q --now dawarich-custom-restore.path
fi
systemctl daemon-reload

say "restore: custom files, migrations, assets, restart (a few minutes)"
python3 "$REPO_DIR/restore_custom.py"

say "timetable rows (created disabled)"
(
  cd "$APP"
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  # shellcheck source=/dev/null
  [ -f "$GTFS_ENV" ] && . "$GTFS_ENV"
  set +a
  export RAILS_ENV=${RAILS_ENV:-production}
  "$BUNDLE" exec rails gtfs:seed_feeds 2>&1 | grep -v '^OIDC' | sed 's/^/    /'
)

cat <<EOF

Done. Next steps (docs/proxmox.md):
  1. Enable the timetables you need, e.g.:
       cd $APP && set -a && . $ENV_FILE && . $GTFS_ENV && set +a && \\
       $BUNDLE exec rails runner 'Gtfs::Feed.where(key: %w[bkk]).update_all(enabled: true)'
     then import them now or wait for the nightly sync: $BUNDLE exec rails gtfs:sync
  2. Every user turns matching on under Settings -> Transit.
  3. Discord bot (optional): set it up on /transit/discord, then
       systemctl enable --now dawarich-gtfs-discord-bot
Settings: $GTFS_ENV (restart dawarich-web dawarich-worker after editing).
EOF
