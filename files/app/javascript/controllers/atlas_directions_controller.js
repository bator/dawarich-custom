import { Controller } from "@hotwired/stimulus"

// Directions tab of /map/v2 (docs/atlas.md): by car, bike, on foot (Valhalla)
// or by public transport (MOTIS), through Atlas. Places come from the Atlas
// search (biased to the map centre) or a click on the map; the route is drawn
// on the map and survives a basemap change. Requests go to our API
// (Api::V1::Transit::DirectionsController) with the user's API key, like the
// rest of the map.
const SOURCE = "atlas-directions"
const POINTS = "atlas-directions-points"
const LAYERS = ["atlas-directions-casing", "atlas-directions-line", "atlas-directions-walk", "atlas-directions-points"]
const COLORS = {
  car: "#f97316", bike: "#16a34a", walk: "#64748b", bus: "#2563eb", tram: "#eab308", subway: "#dc2626",
  rail: "#7c3aed", regional_rail: "#7c3aed", regional_fast_rail: "#7c3aed", long_distance: "#7c3aed",
  high_speed_rail: "#7c3aed", night_rail: "#7c3aed", metro: "#dc2626", ferry: "#0891b2", coach: "#2563eb"
}
const OTHER_COLOR = "#0ea5e9"

export default class extends Controller {
  static targets = ["mode", "from", "to", "fromResults", "toResults", "transitOptions", "time", "arriveBy", "status", "results"]
  static values = { searchUrl: String, routeUrl: String, title: String, labels: Object }

  connect() {
    this.mode = "car"
    this.points = { from: null, to: null }
    this.routes = []
    this.routesMode = null // the mode the shown routes were asked for
    this.routeRequest = 0 // a newer number makes an answer still on its way stale
    this.searchTimers = {}
    this.searchAborts = {}
    this.timeEdited = false
    this.timeTarget.value = this.localNow()
    this.renderModes()
    this.onTabChanged = (event) => {
      if (event.detail?.tab !== "directions") return
      const title = document.querySelector("[data-map-panel-target='title']")
      if (title) title.textContent = this.titleValue
      this.refreshTime()
    }
    document.addEventListener("map-panel:tab-changed", this.onTabChanged)
    this.onStyleLoad = () => this.draw()
  }

  disconnect() {
    document.removeEventListener("map-panel:tab-changed", this.onTabChanged)
    this.cancelRoute()
    this.attachMap(null)
    Object.values(this.searchTimers).forEach(clearTimeout)
    Object.values(this.searchAborts).forEach((abort) => abort.abort())
  }

  // The map of /map/v2, once it exists. The panel is Turbo-permanent while the
  // maps--maplibre controller builds a new map after a visit: follow it.
  get mapInstance() {
    const container = document.getElementById("maps-maplibre-container")
    const controller = container && this.application.getControllerForElementAndIdentifier(container, "maps--maplibre")
    const map = controller?.map || null
    if (map !== this.map) this.attachMap(map)
    return this.map
  }

  attachMap(map) {
    this.cancelPick()
    this.stopWaitingForStyle()
    this.map?.off("style.load", this.onStyleLoad)
    this.map = map
    this.map?.on("style.load", this.onStyleLoad)
  }

  get apiKey() {
    return document.getElementById("maps-maplibre-container")?.getAttribute("data-maps--maplibre-api-key-value")
  }

  setMode(event) {
    this.mode = event.currentTarget.dataset.mode
    if (this.mode === "transit") this.refreshTime()
    this.renderModes()
    if (this.points.from && this.points.to) this.route()
  }

  renderModes() {
    this.modeTargets.forEach((button) => button.classList.toggle("btn-active", button.dataset.mode === this.mode))
    this.transitOptionsTarget.classList.toggle("hidden", this.mode !== "transit")
  }

  // --- places -------------------------------------------------------------

  // Typing replaces this end: its marker and the routes to it go. Each field
  // has its own timer, and a newer search aborts the field's previous one.
  search(event) {
    const field = event.target.dataset.field
    this.points[field] = null
    this.dropRoutes()
    clearTimeout(this.searchTimers[field])
    this.searchAborts[field]?.abort()
    const query = event.target.value.trim()
    if (query.length < 2) return this.listResults(field, [])

    this.searchTimers[field] = setTimeout(async () => {
      const abort = (this.searchAborts[field] = new AbortController())
      const center = this.mapInstance?.getCenter()
      const params = new URLSearchParams({ q: query })
      if (center) { params.set("lat", center.lat.toFixed(5)); params.set("lon", center.lng.toFixed(5)) }
      try {
        const data = await this.get(this.searchUrlValue, params, abort.signal)
        if (event.target.value.trim() === query) this.listResults(field, data.results || [])
      } catch (error) {
        if (error.name !== "AbortError") this.setStatus(error.message, true)
      }
    }, 250)
  }

  listResults(field, results) {
    const list = this[`${field}ResultsTarget`]
    list.replaceChildren(...results.map((result) => {
      const item = document.createElement("button")
      item.type = "button"
      item.className = "block w-full text-left px-3 py-2 text-sm hover:bg-base-200"
      item.textContent = result.label
      item.addEventListener("click", () => this.setPoint(field, { lat: result.lat, lon: result.lon, label: result.label }))
      return item
    }))
    list.classList.toggle("hidden", results.length === 0)
  }

  // the next click on the map sets this end (one pick at a time: a second
  // pin button replaces the first one's)
  pick(event) {
    const field = event.currentTarget.dataset.field
    const map = this.mapInstance
    if (!map) return

    this.cancelPick()
    map.getCanvas().style.cursor = "crosshair"
    this.setStatus(this.labelsValue.pick)
    this.pickHandler = (e) => {
      this.cancelPick()
      this.setStatus("")
      const { lat, lng } = e.lngLat
      this.setPoint(field, { lat, lon: lng, label: `${lat.toFixed(5)}, ${lng.toFixed(5)}` })
    }
    map.once("click", this.pickHandler)
  }

  cancelPick() {
    if (!this.pickHandler) return
    this.map?.off("click", this.pickHandler)
    if (this.map) this.map.getCanvas().style.cursor = ""
    this.pickHandler = null
  }

  setPoint(field, point) {
    this.points[field] = point
    this[`${field}Target`].value = point.label
    this.listResults(field, [])
    this.draw()
    if (this.points.from && this.points.to) this.route()
  }

  swap() {
    this.points = { from: this.points.to, to: this.points.from }
    this.fromTarget.value = this.points.from?.label || ""
    this.toTarget.value = this.points.to?.label || ""
    this.dropRoutes()
    if (this.points.from && this.points.to) this.route()
  }

  clear() {
    this.cancelPick()
    this.points = { from: null, to: null }
    this.fromTarget.value = ""
    this.toTarget.value = ""
    this.dropRoutes()
  }

  // the ends changed: the routes shown (or on their way) are no longer theirs
  dropRoutes() {
    this.cancelRoute()
    this.routes = []
    this.resultsTarget.replaceChildren()
    this.setStatus("")
    this.draw()
  }

  timeChanged() {
    this.timeEdited = true
  }

  // the departure follows the clock until the user sets one
  refreshTime() {
    if (!this.timeEdited) this.timeTarget.value = this.localNow()
  }

  // --- routes -------------------------------------------------------------

  // Only the newest request's answer is shown: a new route, new ends or
  // Clear abort the one on its way.
  async route() {
    const { from, to } = this.points
    if (!from || !to) return this.setStatus(this.labelsValue.need_points, true)

    this.cancelRoute()
    const request = this.routeRequest
    const mode = this.mode
    const params = new URLSearchParams({ from: `${from.lat},${from.lon}`, to: `${to.lat},${to.lon}`, mode })
    if (mode === "transit") {
      this.refreshTime()
      if (this.timeTarget.value) params.set("time", new Date(this.timeTarget.value).toISOString())
      if (this.timeTarget.value && this.arriveByTarget.checked) params.set("arrive_by", "true")
    }
    this.setStatus(this.labelsValue.loading)
    this.resultsTarget.replaceChildren()
    this.routeAbort = new AbortController()
    try {
      const data = await this.get(this.routeUrlValue, params, this.routeAbort.signal)
      if (request !== this.routeRequest) return
      this.routes = data.routes || []
      this.routesMode = mode
      this.setStatus(this.routes.length ? "" : this.labelsValue.no_route, !this.routes.length)
      this.renderRoutes()
      this.select(0)
    } catch (error) {
      if (request !== this.routeRequest) return
      this.routes = []
      this.setStatus(error.message, true)
      this.draw()
    }
  }

  cancelRoute() {
    this.routeRequest += 1
    this.routeAbort?.abort()
    this.routeAbort = null
  }

  renderRoutes() {
    this.resultsTarget.replaceChildren(...this.routes.map((route, index) => {
      const card = document.createElement("button")
      card.type = "button"
      card.className = "w-full text-left rounded-lg border border-base-300 p-3 hover:bg-base-200"
      card.dataset.index = index
      card.addEventListener("click", () => this.select(index))

      const head = document.createElement("div")
      head.className = "flex justify-between font-semibold"
      head.append(this.span(this.duration(route.duration_s)), this.span(this.timeRange(route)))
      card.append(head)

      const sub = document.createElement("div")
      sub.className = "text-xs opacity-70 mt-1"
      sub.textContent = this.routesMode === "transit"
        ? `${this.labelsValue.transfers}: ${route.transfers} · ${this.labelsValue.walking} ${this.distance(route.walk_m)}`
        : this.distance(route.distance_m)
      card.append(sub)

      if (route.legs?.length) card.append(this.legList(route.legs))
      return card
    }))
  }

  legList(legs) {
    const list = document.createElement("div")
    list.className = "mt-2 space-y-1 text-xs"
    legs.forEach((leg) => {
      const row = document.createElement("div")
      row.className = "flex items-start gap-2"
      const dot = document.createElement("span")
      dot.className = "mt-1 inline-block w-2 h-2 rounded-full shrink-0"
      dot.style.background = COLORS[leg.mode] || OTHER_COLOR
      const text = document.createElement("span")
      const mode = this.labelsValue.modes?.[leg.mode] || leg.mode
      const what = leg.mode === "walk" ? `${mode} ${this.distance(leg.distance_m)}` : [mode, leg.line, leg.headsign && `→ ${leg.headsign}`].filter(Boolean).join(" ")
      const where = leg.from?.name ? ` · ${this.clock(leg.start)} ${leg.from.name}` : ""
      text.textContent = `${what}${where}`
      row.append(dot, text)
      list.append(row)
    })
    return list
  }

  select(index) {
    this.selected = index
    this.resultsTarget.querySelectorAll("[data-index]").forEach((card) => {
      card.classList.toggle("border-primary", Number(card.dataset.index) === index)
    })
    this.draw()
    this.fit()
  }

  // --- map ----------------------------------------------------------------

  draw() {
    const map = this.mapInstance
    if (!map) return
    if (!map.isStyleLoaded()) return this.drawWhenStyleLoaded(map)

    const route = this.routes[this.selected ?? 0]
    const lines = route?.geojson || { type: "FeatureCollection", features: [] }
    const ends = { type: "FeatureCollection", features: ["from", "to"].filter((f) => this.points[f]).map((f) => ({
      type: "Feature", properties: { end: f },
      geometry: { type: "Point", coordinates: [this.points[f].lon, this.points[f].lat] }
    })) }

    if (!map.getSource(SOURCE)) {
      map.addSource(SOURCE, { type: "geojson", data: lines })
      map.addSource(POINTS, { type: "geojson", data: ends })
      const color = ["match", ["get", "mode"], ...Object.entries(COLORS).flat(), OTHER_COLOR]
      map.addLayer({ id: LAYERS[0], type: "line", source: SOURCE, filter: ["!=", ["get", "mode"], "walk"],
        layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": "#ffffff", "line-width": 8, "line-opacity": 0.9 } })
      map.addLayer({ id: LAYERS[1], type: "line", source: SOURCE, filter: ["!=", ["get", "mode"], "walk"],
        layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": color, "line-width": 5 } })
      map.addLayer({ id: LAYERS[2], type: "line", source: SOURCE, filter: ["==", ["get", "mode"], "walk"],
        layout: { "line-cap": "round" }, paint: { "line-color": COLORS.walk, "line-width": 4, "line-dasharray": [0.1, 2] } })
      map.addLayer({ id: LAYERS[3], type: "circle", source: POINTS,
        paint: { "circle-radius": 7, "circle-stroke-width": 3, "circle-stroke-color": "#ffffff",
                  "circle-color": ["match", ["get", "end"], "from", "#16a34a", "#dc2626"] } })
    } else {
      map.getSource(SOURCE).setData(lines)
      map.getSource(POINTS).setData(ends)
    }
  }

  // Right after a basemap change, and while sources load, the style is not
  // loaded yet: draw once it is. "render" as well as "idle", as
  // map_data_manager waits: an animated layer keeps the map rendering, and
  // "idle" never fires while it runs.
  drawWhenStyleLoaded(map) {
    if (this.styleWait) return
    const onReady = () => {
      if (!map.isStyleLoaded()) return
      this.stopWaitingForStyle()
      if (map === this.map) this.draw()
    }
    this.styleWait = { map, onReady }
    map.on("idle", onReady)
    map.on("render", onReady)
  }

  stopWaitingForStyle() {
    if (!this.styleWait) return
    const { map, onReady } = this.styleWait
    map.off("idle", onReady)
    map.off("render", onReady)
    this.styleWait = null
  }

  fit() {
    const map = this.mapInstance
    const route = this.routes[this.selected ?? 0]
    const coords = route?.geojson?.features.flatMap((f) => f.geometry.coordinates) || []
    if (!map || coords.length < 2) return

    const lons = coords.map((c) => c[0])
    const lats = coords.map((c) => c[1])
    // keep the route clear of the open side panel (unless it covers the screen, on a phone)
    const panel = document.getElementById("map-settings-panel")
    const open = panel?.classList.contains("open") && panel.offsetWidth < window.innerWidth * 0.6
    const left = open ? panel.offsetWidth + 40 : 40
    map.fitBounds([[Math.min(...lons), Math.min(...lats)], [Math.max(...lons), Math.max(...lats)]],
      { padding: { top: 60, bottom: 60, left, right: 80 }, duration: 600 })
  }

  // --- helpers ------------------------------------------------------------

  async get(url, params, signal) {
    const response = await fetch(`${url}?${params}`, { signal, headers: { Authorization: `Bearer ${this.apiKey}`, Accept: "application/json" } })
    const data = await response.json().catch(() => ({}))
    if (!response.ok) {
      const key = { no_route: "no_route", atlas_unavailable: "unavailable", atlas_disabled: "unavailable", atlas_rejected: "rejected" }[data.error]
      throw new Error(key ? this.labelsValue[key] : data.message || response.statusText)
    }
    return data
  }

  setStatus(text, error = false) {
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("text-error", error)
  }

  span(text) {
    const span = document.createElement("span")
    span.textContent = text
    return span
  }

  duration(seconds) {
    const minutes = Math.max(1, Math.round(seconds / 60))
    const h = Math.floor(minutes / 60)
    return h ? `${h} ${this.labelsValue.hour} ${minutes % 60} ${this.labelsValue.minute}` : `${minutes} ${this.labelsValue.minute}`
  }

  distance(metres) {
    return metres >= 1000 ? `${(metres / 1000).toFixed(1)} km` : `${Math.round(metres)} m`
  }

  clock(iso) {
    return iso ? new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : ""
  }

  timeRange(route) {
    return route.start && route.end ? `${this.clock(route.start)}–${this.clock(route.end)}` : ""
  }

  localNow() {
    const now = new Date()
    now.setMinutes(now.getMinutes() - now.getTimezoneOffset())
    return now.toISOString().slice(0, 16)
  }
}
