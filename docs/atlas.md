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
shows one line, the snapped one. Everywhere else the raw line stays and joins the drawn ones.

- The map asks for it with `hide=walks,rides` on `/api/v1/tiles/tracks/{z}/{x}/{y}.mvt`
  (`TracksMvtLayer#setHide`, `LayerManager#updateTrackCutouts`).
- **Walks** are cut only where the snap matched the walk: between two consecutive points of the leg
  that both lie on a snapped (`valhalla`) part.
  - The layer draws a recorded part (`raw`) as a faint dotted line, a standing-still cloud
    (`stationary`) as dots, and nothing across a GPS gap. There the raw track line stays to show
    the way. 2026-10-22: one walk had 749 m standing still against 429 m snapped; cutting under
    every drawn part left only dots.
  - `transit_walk_legs.covered` (`int8multirange`) holds the times `[t1, t2)` of those pairs,
    merged.
  - A point counts as not matched when its coordinates are in a `raw` or `stationary` part (within
    2e-6°).
  - A pair is still no gap only in one of two cases:
    - it is at most `GTFS_WALK_RAW_MAX_SEGMENT_M` (60 m) long, with both ends within 50 m of the
      snapped line;
    - or the snapped line runs along all of it (ends, quarters, middle within 25 m).
  - It is filled when a leg is written (`Gtfs::Walk::LegWriter`, `TransitWalkLeg.covered_sql`).
  - Migrations: `20261022120000` added it, `20261022130000` recomputed it with this rule (all legs,
    about 20 s).
- **Joints:** the walking legs layer drew a walk as parts that do not touch. A snapped part ends at its
  matched position and the next part, or the raw track line, starts at the recorded fix: 20–40 m
  apart on 2026-10-22. A GPS gap is not a part at all. `Api::TransitWalkLegSerializer#joints` adds a
  straight `joint` from each part's end to the next part's start (a standing-still cloud by its first
  and last fix). It also adds one from the leg's first fix to a snapped first part, and from a
  snapped last part to the leg's last fix. The layer draws joints like the snapped walk, so the way
  reads as one line.
- **Rides:** the timetable line covers all of the ride, so the ride's times decide.
- What the layers draw for the map's range, and nothing else: the same queries and visibility
  (threshold, feed selection, privacy zones), the same range rule, the same cap of the newest 500.
  - A walk the snap could not match (`raw`) keeps its track line.
  - Rides are cut only when the transit layer shows every mode.
- `Gtfs::TrackCutouts` merges it all into one `int8multirange` (`range_agg`).
- From zoom 8 (`Tracks::VectorTileQuery::HIDE_MIN_ZOOM`), a track under a cut stretch goes the
  clipped-track way. It is rebuilt from its points (`Tracks::PointGeometryQuery`) without the
  segments inside the ranges; the rest stays as separate lines. A track without points keeps its
  line.
- Only for a dated request of at most 93 days (`MAX_DAYS`), without `import_id` and without speed
  colouring, which is what `/map/v2` asks for. Longer ranges are drawn uncut.
- The tile ETag includes the kinds and the cut's epoch: the user's latest walk-leg / ride change and
  their counts, settings, privacy zones. The cut query runs with `jit = off`: JIT compiling took 167
  of 200 ms, the work itself about 30 ms.
- Measured with user 2:
  - On 2026-10-16, a 07:24–17:07 track with 11 walks and 3 rides keeps 5.6 of 88.9 km as raw line.
    That includes 8 GPS gaps (1 km) that now join the walks; all 20.8 km under drawn lines are cut.
  - Slowest cut tile: a day 105 ms, a week 85 ms, a month 309 ms, 93 days 1.0 s.
  - Cutting every tile on the fly with the spatial test instead took 5 s a tile over 93 days, hence
    the stored `covered`.

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
