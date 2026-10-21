# Frequent routes

Routes you walk or cycle many times get one clean middle line, built from your own GPS, and new
recordings of the same route can be snapped onto it. On the map (`/map/v2`, layer panel:
*Frequent routes*) they are drawn as an orange trail, wider the more trips they have; a stretch
where GPS was missing and the way was routed (a tunnel, an underpass) is dashed.

Off by default. In `/opt/dawarich/gtfs.env` (LXC) or `transit.env` (Docker):

```bash
CORRIDORS_ENABLED=true        # build the routes every Monday 04:15, map layer
CORRIDORS_SNAP_ENABLED=true   # also snap new tracks every night at 04:45 (rewrites them, logged, revertible)
CORRIDORS_FILL_GAPS=true      # default: route the gaps of walking routes (see below); false: keep the median
```

## How a route is built (`Corridors::Builder`)

1. **Only real fixes.** The raw points of each track (not its stored geometry), without generated
   points: a `tracker_id` starting with `gpx`, `osrm-`, `track-pick-` or `legacy-import`
   (`CORRIDORS_SYNTHETIC_TRACKERS`). A track needs 80% real fixes. Fixes worse than 50 m, impossible
   jumps and the standing-still clouds at both ends are dropped.
2. **Group.** Trips whose ends are within 200 m of each other (in either direction) and whose shapes
   are close (mean distance at equal shares of the length under 40 m walking, 50 m cycling) form
   one route; identical copies count once. A route needs 5 trips (`CORRIDORS_MIN_TRIPS`). Every
   distance here is measured around the points it is between, so trips far from the others (abroad)
   are grouped by the same rules.
3. **Median.** Each trip is first smoothed along its length (20 m on each side), so GPS zigzag
   does not make it longer than the way. The first course of the route is the median of all
   trips' points at equal shares of their lengths, smoothed and run on straight for 200 m at both
   ends (the line may start before the median trip does); every trip is projected onto it, and
   the median of their sideways offsets (interpolated at every 10 m of the line) moves it, twice.
   Trips that run off the line for much of their way (a detour: on average more than 30% of it,
   counting 10 m off as on the line and 30 m off as fully off, and more than the other trips) are
   left out, and the median is built again from the rest. The line runs from where half of the
   trips have started to where half of them still go (the smoothing keeps the ends where they are);
   loops the line made are cut out, and the line is smoothed over 30 m on each side.
4. **Quality.** A route whose trips spread more than 15 m (90th percentile) or whose line still
   zigzags (over 1000° of turning per km, e.g. inside a station hall) is dropped, and of two routes
   that mostly overlap (70% of one within 25 m of the other, e.g. the two directions of a way on
   two pavements) the one with fewer trips.

The same trips give the same routes: no step depends on one chosen trip, on where the GPS samples
fall, or on the frame of the local metres. Checked on real data with the frame centre moved by
±0.01° and the metre scale by ±0.1%: the same routes from the same trips, within 1.5 m.

Each route is computed in metres around its own trips, stored in `track_corridors`, replaced as a
whole every week. A dry run (`DRY_RUN=1`) sends nothing to the Atlas: gaps stay unrouted.

## How a gap is filled (`Corridors::GapFiller`)

An inner stretch of at least 100 m where fewer than 20% of the trips had a real fix (a tunnel, an
underpass) is a gap: the median there is only a straight chord between the fixes on both sides.
On walking and running routes the gap is routed through the Atlas the walk snap uses
(`GTFS_WALK_VALHALLA_URL`, `GTFS_WALK_VALHALLA_API=atlas`): two points of the
line on each side of the gap go to `POST /api/v1/map-match` (pedestrian, `map_snap`), and the path
Valhalla finds between them replaces the median there. It is used only when it is one continuous
path, it starts and ends within 25 m of the line, and it is no detour: at most 1.5 times the
median's length + 50 m, and nowhere farther from the median than 35% of its length (at least
30 m). Otherwise the median stays and the stretch remains a gap.

Nothing is sent when `CORRIDORS_FILL_GAPS=false`, when the walk snap's own rules refuse the address
or the user (`GTFS_WALK_VALHALLA_ALLOWED_HOSTS`, `GTFS_WALK_SNAP_EXCLUDE_EMAILS`, the user's opt-out),
or with a raw Valhalla (`GTFS_WALK_VALHALLA_API=valhalla`); when the server is unavailable, the rest
of that build keeps the medians. Cycling routes are not filled.

`track_corridors.gaps` holds the gaps left as they were and `filled` the routed stretches, both as
`[[from_m, to_m], ...]` along the stored line. The API returns each route in pieces (`part`: `gps`
or `filled`), so the layer can dash the routed ones.

## How a track is snapped (`Corridors::Snapper`)

A track of a route's mode snaps when 90% of its real fixes (`CORRIDORS_SNAP_SHARE`) lie within
30 m (`CORRIDORS_SNAP_BUFFER_M`) of the route: where its stored geometry runs along the route it
gets the route's line, the stored parts before and after stay. The route's part must be within
75–133% of the length of the real fixes it replaces (not of the stored geometry, whose GPS spikes
the snap removes). Of two routes that hold as many fixes, the one they lie closer to wins. Tracks
the OSRM snap already rewrote are not touched. Distances are measured in metres around each
track's own start, so routes far from home snap the same.

The geometry before the snap is kept in `track_corridor_snaps`, with a digest of the geometry
written. While the track still has that geometry it is not snapped again, whatever else changes
it (e.g. its mode); when Dawarich rebuilds its geometry, the new one becomes the recorded one and
the track is snapped again the next night. `corridors:revert` puts back the geometry of the
tracks that still have the snapped one; their rows stay, marked reverted, so the nightly snap
leaves them alone from then on (to let them be snapped again:
`bin/rails runner 'TrackCorridorSnap.where(user_id: USER_ID).where.not(reverted_at: nil).delete_all'`).

## Commands

```bash
bin/rails "corridors:build[USER_ID]"        # build now; DRY_RUN=1 only prints
bin/rails "corridors:snap[USER_ID,DAYS]"    # snap the tracks of the last DAYS; DRY_RUN=1 only prints
bin/rails "corridors:revert[USER_ID]"       # put back every snapped track's geometry, no snapping them again
```

## Limits

- Only walking, cycling (and running, `CORRIDORS_MODES`) tracks: driving and rail are snapped onto
  the road and rail network by other means, and repeated commutes recorded by GPX imports are
  already clean lines.
- A route appears only after 5 similar real recordings; generated history does not count.
- Gaps are filled only on walking and running routes, and only where OpenStreetMap has a walkable
  way (an unmapped underpass, a station hall or a platform crossing keeps the median).
