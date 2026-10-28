# Dawarich Atlas in the map

[Dawarich Atlas](https://github.com/dawarich-app/atlas) is the self-hostable maps stack of the
Dawarich people (Photon search, Valhalla routing, MOTIS or OTP public transport, PMTiles). The
custom code uses it in four places:

| What | Where | How |
|---|---|---|
| Directions by car, bike, on foot and by public transport | `/map/v2`, the route button of the map-edge cluster | `Api::V1::Transit::DirectionsController` asks Atlas (`/api/v1/route`, `/api/v1/transit`) |
| Place search in the directions panel | same panel | Atlas `/api/v1/search`, biased to the map centre |
| Reverse geocoding and the map's own place search | everywhere Dawarich geocodes | `PHOTON_API_HOST` pointing at Atlas' Photon pass-through, no code of ours |
| A link to the Atlas web UI | navbar | `ATLAS_UI_URL` |

The browser never talks to Atlas: the map calls our API with the user's API key, the Rails server
calls Atlas. Walk snapping (`GTFS_WALK_SNAP_ENABLED`, see `docker/transit.env.example`) and the gap
filling of frequent routes (`docs/corridors.md`) already use the same Atlas for map matching.

## Settings

In `/opt/dawarich/gtfs.env` (LXC) or `transit.env` (Docker):

```bash
# Atlas API base URL. Optional when the walk snap already points at Atlas
# (GTFS_WALK_VALHALLA_URL with GTFS_WALK_VALHALLA_API=atlas): that one is used.
ATLAS_API_URL=http://atlas:8484
# Atlas web UI for the navbar link (unset: no link)
ATLAS_UI_URL=https://atlas.example.com
```

The URL has to be a private address or a host listed in `GTFS_WALK_VALHALLA_ALLOWED_HOSTS`, as
for the walk snap: the places a user looks up never go to a random host. Without a usable URL the
route button and the panel are not shown, and the API answers 503.

Reverse geocoding through Atlas (in Dawarich's own `.env`, then restart web and worker):

```bash
PHOTON_API_HOST=atlas:8484/api/v1/photon   # Geocoder adds /reverse and /api
PHOTON_API_USE_HTTPS=false
```

Atlas answers these with the Photon it runs. A Photon of your own as `PHOTON_API_HOST` gives the
same results; the pass-through only puts one service in front of both.

## What Atlas needs

- **Roads:** a region installed (Settings → Region), Valhalla enabled.
- **Public transport:** MOTIS (Settings → Services → Transit engine) with transport sources
  (Settings → Transport data): GTFS URLs, an auth header where a feed needs one. MOTIS needs the
  region's street data too.
- **Search:** Photon. When Photon runs outside the Atlas compose project, point the app at it
  (`PHOTON_URL`).
- Access: if Atlas sits behind an allowlist, let the Dawarich server reach `GET /api/v1/search`,
  `/api/v1/route`, `/api/v1/transit` and `/api/v1/photon/{api,reverse}` (all with a query string).

## API

```text
GET /api/v1/transit/directions?from=LAT,LON&to=LAT,LON&mode=car|bike|walk|transit[&time=ISO 8601][&arrive_by=true]
GET /api/v1/transit/directions/search?q=TEXT[&lat=..&lon=..]
```

`routes` holds one road route, or the transit itineraries (legs with mode, line, headsign, stops
and times). Each route has a `geojson` FeatureCollection, one LineString per leg. Errors:
- 422 `no_route`: Valhalla or MOTIS answered 4xx (Atlas' 502 `UPSTREAM_ERROR`);
- 422 for invalid parameters;
- 422 `atlas_rejected`: Atlas refused the request (400/422; logged);
- 503 `atlas_unavailable`: no answer, timeout, or an upstream 5xx (logged);
- 503 `atlas_disabled`.

Logged errors name the Atlas path without its query (no addresses or coordinates). A search waits
at most 5 s for Atlas and a route 10 s, retries included.

## Only the snapped line

Walks snapped through Atlas (`Gtfs::Walk`, layer *Walking legs*) and rides matched to a timetable
(layer *Transit*) are drawn over the Tracks layer, which stays below them. While those layers are
on, the Tracks tiles also leave out the raw GPS line where those layers draw over it. A stretch then
shows one line, the walk's or the ride's. Everywhere else the raw line stays and joins the drawn
ones.

- The map asks for it with `hide=walks,rides` on `/api/v1/tiles/tracks/{z}/{x}/{y}.mvt`
  (`TracksMvtLayer#setHide`, `LayerManager#updateTrackCutouts`).
- **Walks** are cut for all of their time, from the leg's first to its last fix: the layer draws all
  of it as one dashed line (Bator, 2026-10-22: the stretches between the snapped parts dashed, not
  as the raw track line).
  - One dashed dark slate line with a white casing: the snapped parts (`valhalla`), the recorded
    parts (`raw`) along their fixes and the straight `joint`s between them, all alike (Bator chose
    it from four styles). A standing-still cloud (`stationary`) stays a grey dot.
  - Earlier rule (`20261022120000`–`20261022130000`, removed by `20261022160100`): cut only between
    two points the snap matched (`transit_walk_legs.covered`), the raw track line stayed under
    recorded parts, standing-still clouds and GPS gaps.
- **Joints:** the parts of a walk do not touch. A snapped part ends at its matched position, the
  next part starts at the recorded fix, 20–40 m apart on 2026-10-22, and a GPS gap is not a part at
  all. `Api::TransitWalkLegSerializer#joints` adds a straight `joint`:
  - from each part's end to the next part's start (a standing-still cloud through its centre, the dot
    the layer draws);
  - from the leg's first fix to its first part, and from its last part to its last fix, where the
    raw track line around the leg ends.
- **Rides:** the timetable line covers all of the ride, so the ride's times decide.
  - Since 2026-10-24 the transit layer draws that timetable line (`Gtfs::SegmentQuery#geometries` via
    `Gtfs::Discord::RideMap`: the trip's shape, else the line through the stops), as the Discord image
    does. Before, it drew the ride's GPS points: a straight line across every stretch without a
    usable fix (G44 of 10-23: 4.4 km straight into Székesfehérvár, up to 611 m off the railway; now
    within 25 m of the S22's 4 m fixes). A ride whose timetable line would only be a straight line
    between its two stops keeps the GPS line. Cached per ride and its last change.
- What the layers draw for the map's range, and nothing else: the same queries and visibility
  (threshold, feed selection, privacy zones), the same range rule, the same cap of the newest 500.
  - A walk without a drawn line keeps its track line.
  - Rides are cut only when the transit layer shows every mode.
- `Gtfs::TrackCutouts` merges it all into one `int8multirange` (`range_agg`).
- From zoom 8 (`Tracks::VectorTileQuery::HIDE_MIN_ZOOM`), a track under a cut stretch goes the
  clipped-track way. It is rebuilt from its points (`Tracks::PointGeometryQuery`) without the
  segments inside the ranges; the rest stays as separate lines. A track without points keeps its
  line.
- Only for a dated request of at most 93 days (`MAX_DAYS`) without `import_id`, which is what
  `/map/v2` asks for. Longer ranges are drawn uncut.
  - Since 2026-10-24 speed-coloured tiles are cut too (`Tracks::SpeedVectorTileQuery` leaves out the
    hidden segments). Before, with speed colouring on, the raw line stayed under the rides, and rough
    fixes showed as red zigzags (Bator).

## Points worse than the accuracy threshold

Since 1.19.0 Dawarich does this itself again: map settings → GPS Noise Filtering → "Hide inaccurate
points" (`gps_accuracy_filter_enabled`, threshold `gps_accuracy_threshold`, 50–1000 m), then "Apply
Settings" and "Re-evaluate past data" for the history (`Points::AnomalyBackfillUserJob` with
`reset: true`, which rebuilds all tracks and stats). Hand-set modes come back through
`TrackModeCorrections`; timetable modes need `gtfs:track_modes DAYS=3650 WRITE=1` afterwards.

`AccuracyGate` (our version for 1.11.0–1.18.x, which ignored the setting) no longer runs on a
schedule. Its log stays, so what it hid can still be shown again:

- Every id it hid is in `/opt/dawarich/accuracy-gate/state/<user_id>/<local day>.jsonl`.
- `bin/rails "accuracy_gate:undo[USER_ID,FROM,TO]"` shows the points of those local days again and
  rebuilds their tracks. With the upstream filter on, the next re-evaluation hides them again.
- `bin/rails accuracy_gate:run` (dry run; `WRITE=1`, `USER_ID=`, `DAYS=`) still works by hand.
- User 2 (threshold 100 m), 2026-10-24: 1882 points on 136 days; the upstream filter is on since
  2026-10-28.

- The tile ETag includes the kinds and the cut's epoch: the user's latest walk-leg / ride change and
  their counts, settings, privacy zones. The cut query runs with `jit = off`: JIT compiling took 167
  of 200 ms, the work itself about 30 ms.
- Measured with user 2 (2026-10-22):
  - 2026-10-16: of the day's 102.6 km of GPS line, 13.5 km stays as raw line (22.3 km with the
    earlier rule).
  - On 2026-10-16 and 2026-10-22, every end of a drawn line lies within 15 m of another drawn line,
    except one track boundary (20 m, already there with the earlier rule).
  - Slowest cut tile of a 5×5 grid at zoom 14 over Budapest: a day 38 ms, a week 62 ms, a month
    298 ms, 93 days 565 ms (earlier rule: 109 ms, 105 ms, 903 ms, 1.3 s).

## Walks the same day

The night's match (`Gtfs::MatchRecentJob`, 03:00) snaps the walks of the days before, so a walk
used to stay raw on the map until the next morning. `Gtfs::WalkTodayJob` snaps today's walks so far
every hour from 06 to 23 (`GTFS_WALK_TODAY_CRON`, default `17 6-23 * * * Europe/Budapest`):

- walks only: rides stay for the night, so no ride is matched while it is still going on, and
  Discord gets no ride message during the day;
- under the user's match lock; a user whose matching is running is skipped until the next hour;
- the night's run replaces today's legs with the whole day.

## Limits

- Atlas has no language parameter for directions, so the panel shows totals and the transit legs,
  not Valhalla's English turn-by-turn text.
- Public transport covers what the configured GTFS feeds cover; times are the timetables'
  (no realtime unless a source has a GTFS-RT URL).
