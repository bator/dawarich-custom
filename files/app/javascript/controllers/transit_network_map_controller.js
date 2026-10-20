import { Controller } from "@hotwired/stimulus"
import * as maplibregl from "maplibre-gl"
import { getMapStyle } from "maps_maplibre/utils/style_manager"

// Overview "Your network" card (/transit/stats): the corridors of the period
// on the Dawarich basemap, the same vector style /map/v2 uses. The page puts
// the GeoJSON (Gtfs::NetworkMap) in a <script type="application/json"> target.
// Scroll zoom needs Ctrl/Cmd (cooperative gestures), so the page still scrolls.
export default class extends Controller {
  static targets = ["map", "data"]
  static values = { bounds: Array, unsupported: String }

  async connect() {
    const dark = (document.documentElement.dataset.theme || "").includes("dark")
    this.dark = dark
    let style
    try {
      style = await getMapStyle(dark ? "dark" : "light")
    } catch (error) {
      console.error("[transit network] basemap style failed", error)
      return
    }
    if (!this.element.isConnected) return

    // stop names sit right of the dot: more room on the right so they are not cut
    const width = this.mapTarget.clientWidth || 600
    const pad = Math.round(Math.min(48, width * 0.08))
    try {
      this.map = new maplibregl.Map({
        container: this.mapTarget,
        style,
        bounds: this.boundsValue,
        fitBoundsOptions: { padding: { top: pad, bottom: pad, left: pad, right: Math.round(Math.min(150, width * 0.3)) }, maxZoom: 13 },
        cooperativeGestures: true,
        attributionControl: { compact: true },
      })
    } catch (error) {
      // no WebGL (MapLibre throws): a note instead of an empty box
      console.error("[transit network] map failed", error)
      const note = document.createElement("p")
      note.className = "h-full flex items-center justify-center p-6 text-center text-sm opacity-70"
      note.textContent = this.unsupportedValue
      this.mapTarget.replaceChildren(note)
      return
    }
    this.map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right")
    this.map.on("load", () => this.addLayers())
  }

  disconnect() {
    this.map?.remove()
    this.map = null
  }

  addLayers() {
    const map = this.map
    const data = JSON.parse(this.dataTarget.textContent)
    const halo = this.dark ? "#0b0f14" : "#ffffff"
    const ink = this.dark ? "#f2f3f5" : "#1f2328"

    map.addSource("transit-network", { type: "geojson", data })
    const paths = ["==", ["get", "kind"], "path"]
    const stops = ["==", ["get", "kind"], "stop"]

    map.addLayer({
      id: "transit-network-casing",
      type: "line",
      source: "transit-network",
      filter: paths,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": halo, "line-width": ["+", ["get", "width"], 4], "line-opacity": 0.9 },
    })
    map.addLayer({
      id: "transit-network-line",
      type: "line",
      source: "transit-network",
      filter: paths,
      layout: { "line-cap": "round", "line-join": "round" },
      paint: { "line-color": ["get", "color"], "line-width": ["get", "width"] },
    })
    map.addLayer({
      id: "transit-network-stops",
      type: "circle",
      source: "transit-network",
      filter: stops,
      paint: {
        "circle-radius": ["get", "radius"],
        "circle-color": halo,
        "circle-stroke-color": ink,
        "circle-stroke-width": 2.2,
      },
    })
    map.addLayer({
      id: "transit-network-labels",
      type: "symbol",
      source: "transit-network",
      filter: ["all", stops, ["==", ["get", "label"], true]],
      layout: {
        "text-field": ["get", "name"],
        "text-font": ["Noto Sans Medium"],
        "text-size": 13,
        "text-anchor": "left",
        "text-offset": [0.9, 0],
        "text-optional": true,
      },
      paint: { "text-color": ink, "text-halo-color": halo, "text-halo-width": 1.6 },
    })

    // the corridor (lines, rides) and the stop name on hover
    const popup = new maplibregl.Popup({ closeButton: false, closeOnClick: false, offset: 10 })
    for (const layer of ["transit-network-line", "transit-network-stops"]) {
      map.on("mousemove", layer, (event) => {
        map.getCanvas().style.cursor = "pointer"
        popup.setLngLat(event.lngLat).setText(event.features[0].properties.title).addTo(map)
      })
      map.on("mouseleave", layer, () => {
        map.getCanvas().style.cursor = ""
        popup.remove()
      })
    }
  }
}
