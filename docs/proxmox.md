# Installing on Proxmox VE (one command)

On Proxmox, Dawarich usually runs in the [community-scripts](https://community-scripts.github.io/ProxmoxVE/scripts?id=dawarich)
container. One command on the Proxmox node puts this repo's code (public transport matching
against GTFS timetables, the transit pages, the Discord approval bot) into that container, and
sets it up so that it comes back by itself after every community-scripts update.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/bator/dawarich-custom/main/install/proxmox.sh)"
```

Run it as root on the node that runs the container (`pct` only reaches local containers).

```
Proxmox node                          Dawarich container (community-scripts)
install/proxmox.sh ──pct push/exec──▶ install/lxc.sh
  finds the container, or runs          git, python3 · /opt/dawarich-custom (this repo)
  the community-scripts installer       /opt/dawarich/gtfs.env · systemd drop-ins
  first                                 dawarich-gtfs-discord-bot.service (disabled)
                                        dawarich-custom-restore.path ─▶ restore_custom.py --settle
                                        restore_custom.py: files, migrations, assets, restart
                                        gtfs:seed_feeds
```

## What it asks

- **No Dawarich container on the node:** it offers to run the community-scripts installer first
  (the usual menus), then continues in the new container.
- **One container:** it asks for confirmation.
- **Several:** it asks which one.

Without questions:

```bash
CTID=123 bash -c "$(curl -fsSL https://raw.githubusercontent.com/bator/dawarich-custom/main/install/proxmox.sh)"
```

A new container without menus, using the community-scripts `var_*` settings
(here a static address; leave `var_net` out for DHCP):

```bash
NEW=1 mode=default var_ctid=150 var_net=192.168.1.150/24 var_gateway=192.168.1.1 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/bator/dawarich-custom/main/install/proxmox.sh)"
```

The community-scripts installer takes 15–30 minutes (it compiles Ruby); the custom part a few
more (migrations and asset compilation).

## Inside the container

`install/lxc.sh` can also be run by hand in the container, and again at any time (it pulls the
repo and restores again):

```bash
bash /opt/dawarich-custom/install/lxc.sh
```

It:

1. installs `git` and `python3` if missing, clones this repo to `/opt/dawarich-custom` (or pulls);
2. creates `/opt/dawarich/gtfs.env` from `docker/transit.env.example` (`GTFS_ENABLED=true`),
   unless it exists, and adds it to `dawarich-web` and `dawarich-worker` (drop-ins);
3. installs `dawarich-gtfs-discord-bot.service`, **disabled**: it would fail without a token;
4. installs `dawarich-custom-restore.path`: the community-scripts update replaces
   `/opt/dawarich/app` (and its `.app_version`), which starts `restore_custom.py --settle`; that
   waits until the update is done (the tree quiet for two minutes, web and worker running) and
   merges the custom code in again;
5. runs `restore_custom.py` now: custom files, 3-way merge of the changed upstream files,
   `db:migrate`, `assets:precompile`, restart of web and worker, and a smoke check that
   `/transit` is routed;
6. creates the timetable rows (`gtfs:seed_feeds`), all disabled.

## After the install

The commands below run in the container (`pct enter <CTID>`) with the app's environment:

```bash
cd /opt/dawarich/app && set -a && . /opt/dawarich/.env && . /opt/dawarich/gtfs.env && set +a
```

1. **Enable the timetables you need** (`budapest` and `bkk` are the same BKK network; enable
   only one) and import them now, or wait for the nightly sync at 03:30:

   ```bash
   /root/.rbenv/shims/bundle exec rails runner 'Gtfs::Feed.where(key: %w[bkk szekesfehervar]).update_all(enabled: true)'
   /root/.rbenv/shims/bundle exec rails gtfs:sync      # in Sidekiq, one feed at a time
   /root/.rbenv/shims/bundle exec rails gtfs:status
   ```

2. **Opt in:** every user turns matching on under *Settings → Transit*; the first opt-in matches
   their whole history in the background.
3. **Discord bot (optional):** set the token, channel, approvers and language on
   `/transit/discord` (admins), then `systemctl enable --now dawarich-gtfs-discord-bot`.

Settings live in `/opt/dawarich/gtfs.env` (the variables are described in
[docker.md](docker.md#settings)); restart `dawarich-web` and `dawarich-worker` after editing.

## Updates

- **Dawarich:** update as usual with the community-scripts `update` command in the container.
  The `.path` trigger then restores the custom code; `journalctl -u dawarich-custom-restore`
  shows the result. If upstream changed a file we also changed and the merge has a conflict,
  nothing is written: Dawarich keeps working without the transit pages, and the merge output is in
  `/var/lib/dawarich-custom/conflicts/<version>/`.
- **This repo:** run `bash /opt/dawarich-custom/install/lxc.sh` again in the container.

## Tested

2026-10-20 on Proxmox VE 9 with a fresh community-scripts Dawarich 1.16.0 container (Debian 13,
created unattended with `mode=default` and `var_*`): the installer, all 20 timetable rows, an
import (Paks, 579 trips), every transit page and the settings page, the bot unit left disabled, a
simulated update (an upstream `config/routes.rb` and a deleted custom view, then a new
`.app_version`: the trigger waited two quiet minutes and put both back), and a second run of the
installer (`ok, no changes`). The test container was deleted afterwards.

## Not included

The OSRM track snapping (a separate project), and the daily `track_pick` cron job, which is
tailored to one household (`bin/rails track_pick:daily`, see [docker.md](docker.md#not-included)).
