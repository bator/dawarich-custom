# dawarich-custom

Custom code on top of upstream [Dawarich](https://github.com/Freika/dawarich) for CT 139 (`minipc`):
GTFS public-transit matcher (`/transit`, transit layers on `/map/v2`, Discord ride approvals via
`dawarich-gtfs-discord-bot`) and `track_pick`. OSRM overlays stay in `/opt/dawarich-osrm`.

Community-script upgrades replace `/opt/dawarich/app` wholesale. `restore_custom.py` puts this back.

## Layout

| Path | What |
|---|---|
| `files/<rel>` | custom-only files, copied verbatim into the app |
| `ours/<rel>` | our version of a modified upstream file |
| `upstream/<base_version>/<rel>` | pristine upstream file that `ours/` was made from (merge base) |
| `patches/<rel>.patch` | `upstream` → `ours` diff, for reading only (generated) |
| `manifest.json` | `base_version`, `custom_files`, `patched_files` |
| `systemd/` | drop-in that chains the restore after the OSRM overlay restore |

Not stored: `app/assets/builds/tailwind.css` and `config/sprockets-manifest.json` (rebuilt by
`assets:precompile`), secrets (`/opt/dawarich/.env`, `/opt/dawarich/gtfs.env`).

## How the restore works

Trigger: `dawarich-osrm-restore.path` (`/opt/dawarich/app/.app_version` changes) →
`dawarich-osrm-restore.service` → overlays, then `restore_custom.py`.

1. Plan without writing: copy `files/`; 3-way merge each `ours/` file
   (`git merge-file ours upstream/<base> <new upstream>`).
2. Guards that refuse the whole restore (Discord alert, nothing written):
   - any merge conflict (diff3 output in `/var/lib/dawarich-custom/conflicts/<version>/`)
   - a custom-only path that now exists upstream, or a live file edited without `capture`
   - a migration version used by both upstream and us (db:migrate silently skips the second one)
3. Write (backup in `/var/lib/dawarich-custom/backup/<ts>/`), `bundle check || bundle install`
   if the Gemfile changed, `db:migrate`, `assets:precompile`. A failure rolls the files back and
   does not restart.
4. Restart `dawarich-web`, `dawarich-web-local`, `dawarich-worker`, `dawarich-gtfs-discord-bot`.
5. Smoke check: `/transit` on :3000 and :3002 must not be 404/5xx, the bot must stay active.

State: `/var/lib/dawarich-custom/state.json` (which file we wrote, per version).

## Commands (in CT 139)

```bash
python3 /opt/dawarich-custom/restore_custom.py --dry-run   # plan only
python3 /opt/dawarich-custom/restore_custom.py             # restore now
python3 /opt/dawarich-custom/restore_custom.py capture     # live app -> repo after editing on the box
python3 /opt/dawarich-custom/restore_custom.py rebase      # after a clean restore on a new upstream version
```

After `capture` or `rebase`: `git diff`, commit, push to OneDev.
New custom file: add its path to `manifest.json` (`custom_files`), then `capture`.

## Migrations

Custom migration versions must never equal an upstream one. `create_gtfs_tables` is
`20261010115959` because upstream 1.16.0 ships `20261010120000_enqueue_achievement_visit_date_backfill`.
On a collision the restore stops; fix by renaming ours to a free version, inserting the new
version into `schema_migrations`, deleting the upstream version row so upstream's migration runs.
