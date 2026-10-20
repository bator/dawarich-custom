# Frequent routes

Routes you walk or cycle many times get one clean middle line, built from your own GPS, and new
recordings of the same route can be snapped onto it. On the map (`/map/v2`, layer panel:
*Frequent routes*) they are drawn as an orange trail, wider the more trips they have.

Off by default. In `/opt/dawarich/gtfs.env` (LXC) or `transit.env` (Docker):

```bash
CORRIDORS_ENABLED=true        # build the routes every Monday 04:15, map layer
CORRIDORS_SNAP_ENABLED=true   # also snap new tracks every night at 04:45 (rewrites them, logged, revertible)
```

## How a route is built (`Corridors::Builder`)

1. **Only real fixes.** The raw points of each track (not its stored geometry), without generated
   points: a `tracker_id` starting with `gpx`, `osrm-`, `track-pick-` or `legacy-import`
   (`CORRIDORS_SYNTHETIC_TRACKERS`). A track needs 80% real fixes. Fixes worse than 50 m, impossible
   jumps and the standing-still clouds at both ends are dropped.
2. **Group.** Trips whose ends are within 200 m of each other (in either direction) and whose shapes
   are close (mean distance at equal shares of the length under 40 m walking, 50 m cycling) form
   one route; identical copies count once. A route needs 5 trips (`CORRIDORS_MIN_TRIPS`).
3. **Median.** Starting from the longest of the central trips, every trip is projected onto the
   line; every 10 m the median of their sideways offsets moves the line, five times. Trips far off
   the others (a detour) are left out. The ends are cut where fewer than half of the trips reach,
   loops the line made are cut out, and the line is smoothed over 30 m on each side.
4. **Quality.** A route whose trips spread more than 15 m (90th percentile) or whose line still
   zigzags (over 1000° of turning per km, e.g. inside a station hall) is dropped, and of two routes
   that mostly overlap the one with fewer trips.

Stored in `track_corridors`, replaced as a whole every week. Inner stretches where few trips had a
fix (a tunnel, an underpass) are kept as `gaps` for a later filling step.

## How a track is snapped (`Corridors::Snapper`)

A track of a route's mode snaps when 90% of its real fixes (`CORRIDORS_SNAP_SHARE`) lie within
30 m (`CORRIDORS_SNAP_BUFFER_M`) of the route: it gets the route's line between where it joins and
leaves it, the recorded parts before and after stay. The snapped length must be within 75–133% of
the recorded one. Tracks the OSRM snap already rewrote are not touched. The geometry before the
snap is kept in `track_corridor_snaps`; when Dawarich rebuilds a track, it is snapped again the
next night.

## Commands

```bash
bin/rails "corridors:build[USER_ID]"        # build now; DRY_RUN=1 only prints
bin/rails "corridors:snap[USER_ID,DAYS]"    # snap the tracks of the last DAYS; DRY_RUN=1 only prints
bin/rails "corridors:revert[USER_ID]"       # put back every snapped track's geometry
```

## Limits

- Only walking, cycling (and running, `CORRIDORS_MODES`) tracks: driving and rail are snapped onto
  the road and rail network by other means, and repeated commutes recorded by GPX imports are
  already clean lines.
- A route appears only after 5 similar real recordings; generated history does not count.
- Gaps are marked but not yet filled from OpenStreetMap.
