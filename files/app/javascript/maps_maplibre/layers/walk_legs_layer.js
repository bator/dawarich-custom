import { translate } from "i18n"
import * as maplibregl from "maplibre-gl"
import { escapeHtml } from "../utils/geojson_transformers"
import { BaseLayer } from "./base_layer"

const EMPTY = { type: "FeatureCollection", features: [] }

// Walking is drawn in dark slate: GTFS route colours are saturated (and the
// H6 HÉV is brown), so a walk never reads as a ride. What lies between the
// snapped parts looks the same (Bator, 2026-10-22); a standing-still dot is
// light grey.
export const WALK_COLOR = "#334155"
export const WALK_STATIONARY_COLOR = "#9CA3AF"

// English fallbacks for locales that do not translate the texts yet.
const FALLBACK = {
  title: "Walk",
  length: "Length",
  source: "Source",
  source_valhalla: "snapped to footpaths",
  source_mixed: "partly snapped",
  source_raw: "recorded GPS",
  part_valhalla: "this part: snapped",
  part_raw: "this part: recorded GPS",
  part_stationary: "standing still",
  part_joint: "between two parts: straight line",
  accuracy: "95% of the fixes within",
  failed_to_load: "Failed to load walking legs",
}

export function walkTr(key) {
  const full = `walk_legs.${key}`
  const value = translate(full)
  return value === full ? FALLBACK[key] || key : value
}

function clock(unix) {
  return new Date(unix * 1000).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  })
}

/**
 * Walking legs next to the public transport rides (Gtfs::Walk, API
 * /api/v1/transit/walk_legs/map): one feature per drawn part. A walk is one
 * dashed dark slate line from its first fix to its last one: the snapped
 * parts, the recorded GPS parts along their fixes and the joints straight
 * (across a GPS gap, to a snapped part's matched position, through a
 * standing-still cloud's dot). The Tracks tiles leave the raw line out under
 * all of the walk (Gtfs::TrackCutouts). Off by default.
 */
export class WalkLegsLayer extends BaseLayer {
  constructor(map, options = {}) {
    super(map, { id: "walkLegs", ...options })
    this.popup = new maplibregl.Popup({
      closeButton: true,
      closeOnClick: true,
      className: "walk-legs-popup",
      maxWidth: "280px",
    })
    this._onClick = this._onClick.bind(this)
  }

  getSourceConfig() {
    return { type: "geojson", data: this.data || EMPTY }
  }

  getLayerConfigs() {
    const part = (source) => ["==", ["get", "part_source"], source]
    // snapped and recorded parts and the joints between them
    // (Api::TransitWalkLegSerializer#joints)
    const line = ["in", ["get", "part_source"], ["literal", ["valhalla", "raw", "joint"]]]
    return [
      {
        id: "walk-legs-casing",
        type: "line",
        source: this.sourceId,
        filter: line,
        layout: { "line-join": "round", "line-cap": "round" },
        paint: {
          "line-color": "#FFFFFF",
          "line-width": 5,
          "line-opacity": 0.7,
        },
      },
      {
        id: "walk-legs",
        type: "line",
        source: this.sourceId,
        filter: line,
        layout: { "line-join": "round" },
        paint: {
          "line-color": WALK_COLOR,
          "line-width": 3,
          "line-dasharray": [2, 1.2],
        },
      },
      {
        id: "walk-legs-stationary",
        type: "circle",
        source: this.sourceId,
        filter: part("stationary"),
        paint: {
          "circle-radius": 3,
          "circle-color": WALK_STATIONARY_COLOR,
          "circle-stroke-color": "#FFFFFF",
          "circle-stroke-width": 1,
        },
      },
    ]
  }

  _interactiveIds() {
    return ["walk-legs", "walk-legs-stationary"]
  }

  add(data) {
    super.add(data || EMPTY)
    for (const id of this._interactiveIds()) {
      this.map.on("click", id, this._onClick)
      this.map.on("mouseenter", id, this._setPointer)
      this.map.on("mouseleave", id, this._unsetPointer)
    }
  }

  update(data) {
    super.update(data || EMPTY)
  }

  remove() {
    for (const id of this._interactiveIds()) {
      this.map.off("click", id, this._onClick)
      this.map.off("mouseenter", id, this._setPointer)
      this.map.off("mouseleave", id, this._unsetPointer)
    }
    this.popup.remove()
    super.remove()
  }

  _setPointer = () => {
    this.map.getCanvas().style.cursor = "pointer"
  }

  _unsetPointer = () => {
    this.map.getCanvas().style.cursor = ""
  }

  _onClick(event) {
    const feature = event.features?.[0]
    if (!feature) return
    const p = feature.properties || {}
    const length =
      p.distance_m === null || p.distance_m === undefined
        ? ""
        : `<div>${escapeHtml(walkTr("length"))}: ${Math.round(p.distance_m)} m</div>`
    const accuracy =
      p.p95_m === null || p.p95_m === undefined
        ? ""
        : `<div class="text-xs opacity-70">${escapeHtml(walkTr("accuracy"))} ${Math.round(p.p95_m)} m</div>`
    const html = `
      <div class="text-sm space-y-1">
        <div class="flex items-center gap-2">
          <span class="badge font-bold" style="background:${WALK_COLOR};color:#FFFFFF">🚶 ${escapeHtml(walkTr("title"))}</span>
        </div>
        <div>${clock(p.started_at)}–${clock(p.ended_at)}</div>
        ${length}
        <div>${escapeHtml(walkTr("source"))}: ${escapeHtml(walkTr(`source_${p.source}`))}</div>
        <div class="text-xs opacity-70">${escapeHtml(walkTr(`part_${p.part_source}`))}</div>
        ${accuracy}
      </div>`
    this.popup.setLngLat(event.lngLat).setHTML(html).addTo(this.map)
  }
}
