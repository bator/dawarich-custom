import { translate } from "i18n"
import * as maplibregl from "maplibre-gl"
import { escapeHtml } from "../utils/geojson_transformers"
import { BaseLayer } from "./base_layer"

const EMPTY = { type: "FeatureCollection", features: [] }

// Frequent routes are drawn like a heat trail: a wide soft orange glow under
// a thin light core, wider the more trips the route has. Stretches routed
// through a gap (a tunnel without GPS, Corridors::GapFiller) are dashed.
export const CORRIDOR_COLOR = "#F97316"
const CORE_COLOR = "#FDBA74"

// English fallbacks for locales that do not translate the texts yet.
const FALLBACK = {
  title: "Frequent route",
  trips: "Trips",
  length: "Length",
  spread: "Spread of the trips",
  gaps: "Few fixes on",
  filled: "Routed where GPS was missing",
  failed_to_load: "Failed to load frequent routes",
  mode_walking: "walking",
  mode_cycling: "cycling",
  mode_running: "running",
}

export function corridorTr(key) {
  const full = `corridors.${key}`
  const value = translate(full)
  return value === full ? FALLBACK[key] || key : value
}

const width = (base) => [
  "interpolate",
  ["linear"],
  ["get", "trips"],
  5,
  base,
  50,
  base * 2,
]

const FILLED = ["==", ["get", "part"], "filled"]
const CLICKABLE = ["corridors", "corridors-filled"]

/**
 * Frequent routes of the user (Corridors::Builder, API
 * /api/v1/transit/corridors): the median line of a route travelled many
 * times, one feature per piece (`part`: gps or filled). Not tied to the map's
 * date range; loaded once when switched on.
 */
export class CorridorsLayer extends BaseLayer {
  constructor(map, options = {}) {
    super(map, { id: "corridors", ...options })
    this.popup = new maplibregl.Popup({
      closeButton: true,
      closeOnClick: true,
      className: "corridors-popup",
      maxWidth: "260px",
    })
    this._onClick = this._onClick.bind(this)
  }

  getSourceConfig() {
    return { type: "geojson", data: this.data || EMPTY }
  }

  getLayerConfigs() {
    return [
      {
        id: "corridors-glow",
        type: "line",
        source: this.sourceId,
        layout: { "line-join": "round", "line-cap": "round" },
        paint: {
          "line-color": CORRIDOR_COLOR,
          "line-width": width(10),
          "line-blur": 6,
          "line-opacity": ["case", FILLED, 0.2, 0.45],
        },
      },
      {
        id: "corridors",
        type: "line",
        source: this.sourceId,
        filter: ["!", FILLED],
        layout: { "line-join": "round", "line-cap": "round" },
        paint: { "line-color": CORE_COLOR, "line-width": width(2.5) },
      },
      {
        id: "corridors-filled",
        type: "line",
        source: this.sourceId,
        filter: FILLED,
        layout: { "line-join": "round", "line-cap": "butt" },
        paint: {
          "line-color": CORE_COLOR,
          "line-width": width(2.5),
          "line-dasharray": [2, 1.5],
        },
      },
    ]
  }

  add(data) {
    super.add(data || EMPTY)
    CLICKABLE.forEach((id) => {
      this.map.on("click", id, this._onClick)
      this.map.on("mouseenter", id, this._setPointer)
      this.map.on("mouseleave", id, this._unsetPointer)
    })
  }

  update(data) {
    super.update(data || EMPTY)
  }

  remove() {
    CLICKABLE.forEach((id) => {
      this.map.off("click", id, this._onClick)
      this.map.off("mouseenter", id, this._setPointer)
      this.map.off("mouseleave", id, this._unsetPointer)
    })
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
    const km = (Number(p.length_m) / 1000).toFixed(p.length_m < 10000 ? 2 : 1)
    const spread =
      p.spread_p50 === null || p.spread_p50 === undefined
        ? ""
        : `<div class="text-xs opacity-70">${escapeHtml(corridorTr("spread"))}: ~${Math.round(p.spread_p50)} m (90%: ${Math.round(p.spread_p90)} m)</div>`
    const stretch = (key, metres) =>
      Number(metres) > 0
        ? `<div class="text-xs opacity-70">${escapeHtml(corridorTr(key))}: ${Math.round(Number(metres))} m</div>`
        : ""
    const html = `
      <div class="text-sm space-y-1">
        <span class="badge font-bold" style="background:${CORRIDOR_COLOR};color:#FFFFFF">${escapeHtml(corridorTr("title"))}</span>
        <div>${escapeHtml(corridorTr(`mode_${p.mode}`))} · ${escapeHtml(corridorTr("trips"))}: ${Number(p.trips)}× · ${escapeHtml(corridorTr("length"))}: ${km} km</div>
        ${spread}
        ${stretch("filled", p.filled_m)}
        ${stretch("gaps", p.gaps_m)}
      </div>`
    this.popup.setLngLat(event.lngLat).setHTML(html).addTo(this.map)
  }
}
