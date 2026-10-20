# dawarich-custom

Custom code on top of upstream [Dawarich](https://github.com/Freika/dawarich) 1.16.0.
It matches recorded location history against Hungarian public-transport timetables (GTFS), and
`restore_custom.py` puts it back after every community-script upgrade.


## What it adds

<table>
<tr>
<td width="50%" valign="top"><img src="docs/img/rides.png" width="380" alt="Rides page: totals for the period, then the matched rides as cards with line, stops, times and delay"><br>
<b>Rides</b> (<code>/transit</code>): every matched ride with line, stops, on-time state and the uncertain ones to review. Rides are approved from Discord too (<code>dawarich-gtfs-discord-bot</code>).</td>
<td width="50%" valign="top"><img src="docs/img/overview.png" width="380" alt="Overview page: totals against the period before, the ridden network on the map along the timetable's line, punctuality and savings against the car"><br>
<b>Overview</b> (<code>/transit/stats</code>): totals against the period before, your network on the map along the timetable's line, punctuality, CO₂ and money against the car. The old <code>/transit/savings</code> and <code>/transit/punctuality</code> links redirect here.</td>
</tr>
<tr>
<td valign="top"><img src="docs/img/commute.png" width="380" alt="Commute card: a recurring trip with typical times, departures through the day and delay, then rides by vehicle and operator"><br>
<b>Commutes</b> (on the Overview): recurring trips with typical times, departures through the day and delay, then the breakdown by vehicle, operator and line.</td>
<td valign="top"><img src="docs/img/timetables.png" width="380" alt="Timetables page: status strip with sync, queue and history, cards for the timetables rides came from, compact tiles for the rest"><br>
<b>Timetables</b> (<code>/transit/feeds</code>, admins): a status strip (last sync, <code>gtfs</code> job queue, history matching per user; it opens into the job and per-user lists), <i>Needs attention</i> for a failed or expiring timetable only when rides came from it or someone picked it, <i>In use</i> cards (rides in the last 30 days, weekly bars, top lines, validity left) and <i>Standing by</i> tiles for the other enabled feeds.</td>
</tr>
<tr>
<td colspan="2" valign="top"><img src="docs/img/discord.png" width="560" alt="Discord page: connection, whose rides are posted and who approves, message language, track pick, and a preview of the ride message as Discord shows it"><br>
<b>Discord</b> (<code>/transit/discord</code>, admins): bot status, token, channel, whose rides are posted and who may approve, the message language (Hungarian or English) and the daily track pick, with a live preview of the ride message. Saved values win over <code>gtfs.env</code>.</td>
</tr>
</table>

Also: **Tracking** (coverage and devices), **Settings** (opt-in, feeds, minimum confidence, rematch
the whole history), transit layers on `/map/v2`, and `track_pick`, a daily Discord pick of which user's
track to copy onto the target account.

## How it survives upgrades

<img src="docs/restore-flow.svg" width="560" alt="Restore flow: upgrade, path unit, OSRM overlays, restore_custom.py plan, guards, write and migrate, restart, smoke check">

A community-script upgrade replaces `/opt/dawarich/app` wholesale. The restore merges our edits into the new
upstream files instead of overwriting them, and stops on anything it cannot merge cleanly.
State: `/var/lib/dawarich-custom/` (`state.json`, backups, `conflicts/<version>/`).

## Layout

| Path | What |
|---|---|
| `files/<rel>` | custom-only files, copied verbatim into the app |
| `ours/<rel>` | our version of a modified upstream file |
| `upstream/<base_version>/<rel>` | the pristine upstream file `ours/` was made from (merge base) |
| `patches/<rel>.patch` | `upstream` → `ours` diff, for reading only (generated) |
| `manifest.json` | `base_version`, `custom_files`, `patched_files` |
| `systemd/` | drop-in that chains the restore after the OSRM overlay restore |

Not stored: `tailwind.css` and `sprockets-manifest.json` (rebuilt by `assets:precompile`) and secrets
(`/opt/dawarich/.env`, `/opt/dawarich/gtfs.env`).

## Commands 

```bash
python3 /opt/dawarich-custom/restore_custom.py --dry-run   # plan only
python3 /opt/dawarich-custom/restore_custom.py             # restore now
python3 /opt/dawarich-custom/restore_custom.py capture     # live app -> repo after editing on the box
python3 /opt/dawarich-custom/restore_custom.py rebase      # after a clean restore on a new upstream version
```

After `capture` or `rebase`: `git diff`, commit, push to OneDev.
New custom file: add its path to `manifest.json` (`custom_files`), then `capture`.

## Migrations

A custom migration version must never equal an upstream one: `db:migrate` silently skips the second.
`create_gtfs_tables` is `20261010115959` because upstream 1.16.0 ships `20261010120000`. On a collision
the restore stops. Fix: rename ours to a free version, insert the new version into `schema_migrations`,
and delete the upstream version's row so upstream's migration runs.

<sub>Screenshots: 2026-10-20, dark theme, own account only.</sub>
