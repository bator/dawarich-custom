# Running dawarich-custom with Docker

The custom code (public transport matching against GTFS timetables, the transit pages, the
Discord approval bot, `track_pick`) can run in a normal [Dawarich](https://github.com/Freika/dawarich)
Docker install. `docker/Dockerfile` builds an image on top of the official image of the same
version, [`freikin/dawarich`](https://hub.docker.com/r/freikin/dawarich) on Docker Hub (the one
upstream's `docker/docker-compose.yml` uses; the GitHub owner is `Freika`, the Docker Hub one
`freikin`), and `docker/docker-compose.transit.yml` switches the upstream compose file over to it.

```
freikin/dawarich:1.19.0 ──┐
                          ├─ overlay stage: restore_custom.py export (3-way merge of ours/, plus files/)
this repo ────────────────┘        │
                                   ▼
            final stage: upstream image + merged files → bundle install → assets:precompile
                                   │
                                   ▼
                     dawarich-custom:1.19.0 (app, sidekiq, discord bot)
```

The merge is the same one `restore_custom.py` does after an upgrade of the LXC install: if
upstream changed a file we also changed and the merge has a conflict, or upstream now ships a
file at one of our paths, **the build fails** instead of producing a half-patched image.

## Requirements

- Docker with Compose v2 (`docker compose`), on amd64 or arm64.
- The upstream compose file of the same Dawarich version: PostGIS, Redis, app and Sidekiq.
  Nothing extra is needed in the database: the custom migrations run with the upstream ones.
- About 3 GB of disk for the image, plus the GTFS data in PostgreSQL: Budapest (BKK) alone is
  several million stop times, so plan for a few GB more per large feed.

## Install

```bash
mkdir dawarich && cd dawarich

# 1. the upstream compose file of the same version
curl -fLo docker-compose.yml \
  https://raw.githubusercontent.com/Freika/dawarich/1.19.0/docker/docker-compose.yml

# 2. this repo, the compose override and the environment file
git clone https://github.com/bator/dawarich-custom.git
cp dawarich-custom/docker/docker-compose.transit.yml .
cp dawarich-custom/docker/transit.env.example transit.env

# 3. a real secret for Rails (the upstream default is CHANGE_ME)
echo "SECRET_KEY_BASE=$(openssl rand -hex 64)" >> .env
```

Edit `transit.env` (see [Settings](#settings)), set `TIME_ZONE` and `APPLICATION_HOSTS` in `.env`
as for any Dawarich install, then build and start:

```bash
docker compose -f docker-compose.yml -f docker-compose.transit.yml up -d --build
```

The first build takes a few minutes (gems, `npm ci`, asset compilation). The web container runs
the migrations on start, as upstream does. On an empty database Rails loads upstream's
`db/schema.rb` first, which marks our older migrations as done without creating our tables;
`lib/tasks/gtfs_schema.rake` unmarks them right after the schema load, so the same run creates
them in order (the log says `[gtfs] schema load: N custom migration(s) left to run`). On an
existing database it does nothing.

A shorter command: `export COMPOSE_FILE=docker-compose.yml:docker-compose.transit.yml`, then plain
`docker compose ...` works. The examples below use that.

## First steps

1. **Create the feed rows.** They start disabled:

   ```bash
   docker compose exec dawarich_app bin/rails gtfs:seed_feeds
   ```

2. **Enable the feeds you need** (one per network; `budapest` and `bkk` are the same BKK
   network, enable only one of them):

   ```bash
   docker compose exec dawarich_app bin/rails runner \
     'Gtfs::Feed.where(key: %w[bkk szekesfehervar]).update_all(enabled: true)'
   ```

3. **Import them.** The daily job does this at 03:30; to start now:

   ```bash
   docker compose exec dawarich_app bin/rails gtfs:sync      # all enabled feeds, in Sidekiq
   docker compose exec dawarich_app bin/rails gtfs:status    # validity, last import
   ```

   An import runs in the `gtfs` Sidekiq queue, one at a time (`GTFS_QUEUE_CONCURRENCY`).

4. **Opt in.** Every user turns matching on under *Settings → Transit* and picks the timetables
   they use. The first opt-in starts matching their whole history in the background; after that,
   yesterday's points are matched every night at 03:00.

The pages are under *Travel* in the top menu (`/transit`): Rides, Overview, Tracking, and for
admins Timetables and Discord.

## Settings

All in `transit.env` (read by the app, Sidekiq and the bot); the example file lists them with
comments. The important ones:

| Variable | Default | What |
|---|---|---|
| `GTFS_ENABLED` | `false` | master switch; without it the jobs and the daily sync do nothing |
| `GTFS_QUEUE_CONCURRENCY` | `1` | Sidekiq threads for imports and matching |
| `RAILS_MAX_THREADS` | unset (pool 10, Puma 5 threads) | DB pool and Puma threads; set it only when `BACKGROUND_PROCESSING_CONCURRENCY` exceeds 10 |
| `GTFS_MATCH_CRON`, `GTFS_SYNC_CRON` | `0 3 * * *`, `30 3 * * *` (Europe/Budapest) | daily match and feed sync |
| `GTFS_MAV_URL`, `GTFS_MAV_USERNAME`, `GTFS_MAV_PASSWORD` | – | Hungarian rail (MÁV-START / GYSEV): no public URL, access on request |
| `GTFS_MAP_TILE_CONTACT` | app URL | contact for the OpenStreetMap tile policy (Discord map images) |
| `DISCORD_TRANSIT_APP_URL` | from `APPLICATION_PROTOCOL` / `APPLICATION_HOSTS` | base of the map links in Discord |
| `GTFS_WALK_SNAP_ENABLED`, `GTFS_WALK_VALHALLA_URL` | off | snap walks to footpaths through Dawarich Atlas or Valhalla |

The feed list itself is `files/config/gtfs_feeds.yml` (BKK and 18 regional Hungarian networks).
Another network needs an entry there and a rebuild.

## Discord bot

The bot posts new rides to a channel with *Approve* / *Reject* buttons and a map image, in
Hungarian or English. It runs as its own container from the same image, under the `discord`
compose profile, so it does not start (and crash-loop) before it is configured.

1. Create a bot in the Discord developer portal and invite it to your server.
2. As an admin, open `/transit/discord`: paste the token, the channel ID and the Discord user IDs
   that may approve, pick the language, switch it on and save. The page shows a preview of the
   message. (The same values can come from `transit.env`; a value saved on the page wins.)
3. Start the bot:

   ```bash
   docker compose --profile discord up -d dawarich_discord_bot
   docker compose logs -f dawarich_discord_bot        # "[GTFS discord] connected as ..."
   ```

When the token or the on/off switch changes on the page, the bot exits and the restart policy
brings it back with the new settings within a minute. The bot needs the same `SECRET_KEY_BASE`
(and `OTP_ENCRYPTION_*` keys, if you set them) as the app: the token is stored encrypted with
them. Put them in `.env`, which every service reads.

## Upgrading Dawarich

1. Download the new upstream `docker-compose.yml` and compare it with the old one.
2. Pull this repo (`git -C dawarich-custom pull`).
3. Build with the new version:

   ```bash
   DAWARICH_VERSION=1.19.0 docker compose up -d --build
   ```

   (or put `DAWARICH_VERSION=1.19.0` into `.env`).

If upstream did not touch our files, the build just works. If the merge has conflicts, the build
stops with `CONFLICT ...` lines naming the files, and the running containers keep the old image.
Then the custom code has to be adapted to the new version first (the same `rebase` step as for the
LXC install, see the README).

## Not included

- The OSRM track snapping and its overlays (a separate project on the LXC install).
- `track_pick`, the daily "whose track goes to the target account" pick, is in the image but not
  scheduled. It is tailored to one household. To use it, set its users on `/transit/discord`,
  mount a volume for its state at `/opt/dawarich/track-pick` with an `ENABLED` file in it, and
  run `bin/rails track_pick:daily` from a host cron job (e.g. 05:10).
- Backups: the data is in the upstream volumes (`dawarich_db_data` and the others); back them up
  as for any Dawarich install.

## Tested

2026-10-20 on Docker 29.9 with Compose v5.6 and `freikin/dawarich:1.16.0`: fresh install from
these files, all migrations, `gtfs:seed_feeds`, import of the Paks feed (7 routes, 579 trips),
the daily jobs in sidekiq-cron, the `gtfs` queue, every transit page and the settings page
rendered without missing translations, and the bot container under the `discord` profile (without
a token it reports what is missing and the restart policy retries). Not tested in Docker: a real
Discord connection and matching of real location history (both run on the LXC install).

## Troubleshooting

| Symptom | Check |
|---|---|
| `/transit` is 404 | the container runs the plain upstream image: `docker compose images` should show `dawarich-custom` |
| No rides after opting in | `GTFS_ENABLED=true` in `transit.env`, feeds enabled and imported (`gtfs:status`), Sidekiq running |
| Import stuck in "importing" | `docker compose exec dawarich_app bin/rails gtfs:cleanup` recovers it |
| Bot restarts every few seconds | `docker compose logs dawarich_discord_bot`: "does not start: ..." lists the missing settings |
| Build fails with `CONFLICT` | see [Upgrading Dawarich](#upgrading-dawarich) |
| `relation "gtfs_feeds" does not exist` | migrations not finished yet, or the repair did not run: `docker compose exec dawarich_app bin/rails gtfs:repair_fresh_schema` |
