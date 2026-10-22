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
on, the Tracks tiles also leave out the raw GPS line they cover, so a stretch shows one line: the
snapped one.

- The map asks for it with `hide=walks,rides` on `/api/v1/tiles/tracks/{z}/{x}/{y}.mvt`
  (`TracksMvtLayer#setHide`, `LayerManager#updateTrackCutouts`).
- `Gtfs::TrackCutouts` merges the covered time into one `int8multirange` (`range_agg`).
  - Walks: the legs the layer shows with source `valhalla` or `mixed`.
  - Rides: the rides the layer shows.
  - Both use the layers' own visibility (threshold, feed selection, privacy zones).
  - What a layer does not draw is not cut. A walk the snap could not match (`raw`) keeps its track
    line.
- From zoom 8 (`Tracks::VectorTileQuery::HIDE_MIN_ZOOM`), a track under a covered stretch goes the
  clipped-track way: it is rebuilt from its points (`Tracks::PointGeometryQuery`) without the
  segments whose two ends lie in one covered window. The rest stays as separate lines; a track
  without points keeps its line.
- Rides are cut only when the transit layer shows every mode; with a mode filter the other rides
  would leave a gap.
- Only for a dated request without `import_id` and without speed colouring, which is what
  `/map/v2` asks for.
- The tile ETag includes the kinds and the cut's epoch: the user's latest walk-leg / ride change
  and their counts, settings, privacy zones. The cut query runs with `jit = off`: JIT compiling
  took 167 of 200 ms, the work itself about 30 ms.
- Measured on one day (2026-10-16, a 07:24–17:07 track with 11 walks and 3 rides):
  - the track went from 88.9 km to 5.1 km of raw line;
  - tiles took 20–75 ms (without the cut, 10–60 ms).

## Limits

- Atlas has no language parameter for directions, so the panel shows totals and the transit legs,
  not Valhalla's English turn-by-turn text.
- Public transport covers what the configured GTFS feeds cover; times are the timetables'
  (no realtime unless a source has a GTFS-RT URL).
