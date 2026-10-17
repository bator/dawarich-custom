import * as maplibregl from "maplibre-gl"
import { translate } from "i18n"
import { escapeHtml } from "../utils/geojson_transformers"
import { BaseLayer } from "./base_layer"

const EMPTY = { type: "FeatureCollection", features: [] }

// English fallbacks for locales that do not translate the transit texts yet.
const FALLBACK = {
  uncertain: "Uncertain",
  confirmed: "Confirmed",
  confidence: "Confidence",
  delay: "Delay",
  direction: "Direction",
  confirm: "Confirm",
  reject: "Reject",
  open_list: "Open in list",
  reload: "This ride was matched again; reloading.",
  done_confirmed: "Ride confirmed",
  done_rejected: "Ride rejected",
  failed: "Could not change the ride",
}

export function tr(key) {
  const full = `transit.${key}`
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
 * Public transport rides detected by the GTFS matcher (spec 12.2): one line
 * per ride in the operator's line colour (Gtfs::RouteColors; dashed below the
 * display threshold, casing dark around light colours), boarding and
 * alighting stops as markers, a popup with confirm / reject. Off by default.
 */
export class TransitLayer extends BaseLayer {
  constructor(map, options = {}) {
    super(map, { id: "transit", ...options })
    this.mode = options.mode || "all"
    this.onReview = options.onReview || null
    this.popup = new maplibregl.Popup({
      closeButton: true,
      closeOnClick: true,
      className: "transit-popup",
      maxWidth: "320px",
    })
    this._onClick = this._onClick.bind(this)
  }

  getSourceConfig() {
    return { type: "geojson", data: this._withStops(this.data || EMPTY) }
  }

  getLayerConfigs() {
    const lines = ["==", ["geometry-type"], "LineString"]
    const stops = ["==", ["geometry-type"], "Point"]
    // dashed below the display threshold (display_uncertain); older payloads
    // only have the matcher's flag
    const uncertain = [
      "==",
      ["coalesce", ["get", "display_uncertain"], ["get", "uncertain"]],
      true,
    ]
    const color = ["coalesce", ["get", "route_color"], "#6B7280"]
    const casing = ["coalesce", ["get", "route_casing_color"], "#FFFFFF"]
    return [
      {
        id: "transit-casing",
        type: "line",
        source: this.sourceId,
        filter: this._modeFilter(lines),
        layout: { "line-join": "round", "line-cap": "round" },
        paint: { "line-color": casing, "line-width": 8, "line-opacity": 0.85 },
      },
      {
        id: "transit",
        type: "line",
        source: this.sourceId,
        filter: this._modeFilter(["all", lines, ["!", uncertain]]),
        layout: { "line-join": "round", "line-cap": "round" },
        paint: { "line-color": color, "line-width": 5 },
      },
      {
        id: "transit-uncertain",
        type: "line",
        source: this.sourceId,
        filter: this._modeFilter(["all", lines, uncertain]),
        layout: { "line-join": "round" },
        paint: {
          "line-color": color,
          "line-width": 5,
          "line-dasharray": [2, 1.5],
        },
      },
      {
        id: "transit-stops",
        type: "circle",
        source: this.sourceId,
        filter: this._modeFilter(stops),
        paint: {
          "circle-radius": 6,
          "circle-color": "#FFFFFF",
          "circle-stroke-color": color,
          "circle-stroke-width": 3,
        },
      },
    ]
  }

  add(data) {
    super.add(data || EMPTY)
    for (const id of ["transit", "transit-uncertain", "transit-stops"]) {
      this.map.on("click", id, this._onClick)
      this.map.on("mouseenter", id, this._setPointer)
      this.map.on("mouseleave", id, this._unsetPointer)
    }
  }

  update(data) {
    this.data = data || EMPTY
    const source = this.map.getSource(this.sourceId)
    if (source?.setData) source.setData(this._withStops(this.data))
  }

  remove() {
    for (const id of ["transit", "transit-uncertain", "transit-stops"]) {
      this.map.off("click", id, this._onClick)
      this.map.off("mouseenter", id, this._setPointer)
      this.map.off("mouseleave", id, this._unsetPointer)
    }
    this.popup.remove()
    super.remove()
  }

  setMode(mode) {
    this.mode = mode || "all"
    for (const config of this.getLayerConfigs()) {
      if (this.map.getLayer(config.id)) {
        this.map.setFilter(config.id, config.filter)
      }
    }
  }

  _modeFilter(base) {
    if (!this.mode || this.mode === "all") return base
    return ["all", base, ["==", ["get", "mode"], this.mode]]
  }

  // Boarding / alighting stop markers derived from the ride properties.
  _withStops(collection) {
    const features = [...(collection.features || [])]
    for (const feature of collection.features || []) {
      const p = feature.properties || {}
      for (const [stop, role] of [
        [p.boarding_stop, "board"],
        [p.alighting_stop, "alight"],
      ]) {
        if (!stop?.coordinates) continue
        features.push({
          type: "Feature",
          geometry: { type: "Point", coordinates: stop.coordinates },
          properties: { ...p, stop_role: role, stop_name: stop.name },
        })
      }
    }
    return { type: "FeatureCollection", features }
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
    const p = this._props(feature.properties || {})
    const delay =
      p.delay_secs === null || p.delay_secs === undefined
        ? ""
        : `<div>${escapeHtml(tr("delay"))}: ${Math.round(p.delay_secs / 60)} min</div>`
    const badge = p.uncertain
      ? `<span class="badge badge-warning badge-sm">⚠ ${escapeHtml(tr("uncertain"))}</span>`
      : p.status === "confirmed"
        ? `<span class="badge badge-success badge-sm">✔ ${escapeHtml(tr("confirmed"))}</span>`
        : ""
    const buttons =
      p.status === "auto"
        ? `<div class="flex gap-2 mt-2">
             <button type="button" class="btn btn-success btn-sm min-h-11" data-transit-action="confirmed">${escapeHtml(tr("confirm"))}</button>
             <button type="button" class="btn btn-error btn-outline btn-sm min-h-11" data-transit-action="rejected">${escapeHtml(tr("reject"))}</button>
           </div>`
        : ""
    const html = `
      <div class="text-sm space-y-1">
        <div class="flex items-center gap-2">
          <span class="badge font-bold" style="background:${escapeHtml(p.route_color || "#6B7280")};color:${escapeHtml(p.route_text_color || "#FFFFFF")}">${escapeHtml(p.route_short_name || p.route_long_name || "")}</span>
          ${badge}
        </div>
        <div><strong>${escapeHtml(p.boarding_stop?.name || "")} → ${escapeHtml(p.alighting_stop?.name || "")}</strong></div>
        ${p.headsign ? `<div>${escapeHtml(tr("direction"))}: ${escapeHtml(p.headsign)}</div>` : ""}
        <div>${clock(p.started_at)}–${clock(p.ended_at)}</div>
        <div>${escapeHtml(tr("confidence"))}: ${Math.round((p.confidence || 0) * 100)}%</div>
        ${delay}
        ${buttons}
        <a class="link text-xs" href="/transit">${escapeHtml(tr("open_list"))}</a>
      </div>`
    this.popup.setLngLat(event.lngLat).setHTML(html).addTo(this.map)
    const element = this.popup.getElement()
    element?.querySelectorAll("[data-transit-action]").forEach((button) => {
      button.addEventListener("click", () =>
        this.onReview?.(p.id, button.dataset.transitAction, this.popup),
      )
    })
  }

  // MapLibre stringifies nested properties of rendered features.
  _props(props) {
    const out = { ...props }
    for (const key of ["boarding_stop", "alighting_stop"]) {
      if (typeof out[key] === "string") {
        try {
          out[key] = JSON.parse(out[key])
        } catch (_e) {
          out[key] = null
        }
      }
    }
    return out
  }
}
