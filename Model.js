// daikinsplit — display helpers for the Daikin mini-split bar widget / panel.
//
// All functions are pure: they take the parsed `daikin status` JSON object
// (or primitives) and return display strings/colors, so they can be
// unit-tested outside Qt.

var MODE_LABELS = { auto: "Auto", cool: "Cool", heat: "Heat", dry: "Dry", fan: "Fan" }
var FAN_LABELS = { auto: "Auto", quiet: "Quiet", low: "Low", medium: "Medium", high: "High" }
var SWING_LABELS = { off: "Off", vertical: "Vertical", horizontal: "Horizontal", both: "Both" }
// Taskbar/hero palette: grey = off (handled in QML), red = heating,
// blue = cooling; other on-modes get distinct tints.
var MODE_TINTS = { cool: "#4da3ff", heat: "#ff6b6b", dry: "#9adcf0", fan: "#7fd99a", auto: "#d7dde8" }

// Parse `daikin status` stdout. Offline runs still print JSON
// ({"online": false, ...}); a failed launch prints nothing.
function parseStatus(raw) {
  var text = String(raw == null ? "" : raw).trim()
  if (!text) return { ok: false, error: "no data" }
  try {
    var d = JSON.parse(text)
    if (d && d.online === true) return d
    return { ok: false, error: d && d.error ? String(d.error) : "adapter unreachable" }
  } catch (e) {
    return { ok: false, error: "bad response" }
  }
}

function modeLabel(m) { return MODE_LABELS[m] || String(m == null ? "" : m) }
function fanLabel(f) { return FAN_LABELS[f] || String(f == null ? "" : f) }
function swingLabel(s) { return SWING_LABELS[s] || String(s == null ? "" : s) }
function modeTint(m) {
  // null when the mode has no tint (e.g. "off") so callers can fall
  // back to a neutral grey instead of an arbitrary mode color.
  return MODE_TINTS[m] || null
}

// 22.5 -> "22.5°", 22 -> "22°", null -> "—"
function fmtC(c) {
  if (c == null || isNaN(c)) return "—"
  var r = Math.round(c * 2) / 2
  return (r % 1 === 0 ? String(Math.round(r)) : r.toFixed(1)) + "°"
}

// 71.6 -> "72°", null -> "—"
function fmtF(f) {
  if (f == null || isNaN(f)) return "—"
  return String(Math.round(f)) + "°"
}

function tempLabel(state, units) {
  if (!state || state.online !== true) return "—"
  return units === "c" ? fmtC(state.stemp_c) : fmtF(state.stemp_f)
}

function indoorLabel(state, units) {
  if (!state || state.online !== true) return "—"
  return units === "c" ? fmtC(state.indoor_c) : fmtF(state.indoor_f)
}

function outdoorLabel(state, units) {
  if (!state || state.online !== true) return "—"
  return units === "c" ? fmtC(state.outdoor_c) : fmtF(state.outdoor_f)
}

function compressorLabel(state) {
  if (!state || state.online !== true) return "—"
  if (!state.power) return "off"
  return state.compressor_hz > 0 ? state.compressor_hz + " Hz" : "idle"
}

function errorLabel(state) {
  if (!state || state.online !== true) return "—"
  if (!state.error_code) return "OK"
  var code = String(state.error_code)
  if (code.length === 1) code = "0" + code
  return "E" + code
}

// Bar chip label: "—" offline, "OFF" powered down, setpoint when on.
function chipLabel(state, units) {
  if (!state || state.online !== true) return "—"
  if (!state.power) return "OFF"
  if (units === "c") {
    var r = state.stemp_c == null ? null : Math.round(state.stemp_c * 2) / 2
    return r == null ? "—" : (r % 1 === 0 ? String(Math.round(r)) : r.toFixed(1)) + "°"
  }
  return state.stemp_f == null ? "—" : String(Math.round(state.stemp_f)) + "°"
}

// Hero detail line: "OFFLINE" | "OFF" | "COOL 70°"
function heroDetail(state, units) {
  if (!state || state.online !== true) return "OFFLINE"
  if (!state.power) return "OFF"
  var t = units === "f"
    ? (state.stemp_f == null ? "" : String(Math.round(state.stemp_f)) + "°")
    : (state.stemp_c == null ? "" : (Math.round(state.stemp_c * 2) / 2 % 1 === 0 ? String(Math.round(state.stemp_c)) : (Math.round(state.stemp_c * 2) / 2).toFixed(1)) + "°")
  return modeLabel(state.mode).toUpperCase() + (t ? "  " + t : "")
}

// Hero meta line: "PLAY ROOM  ·  73° IN"
function heroMeta(state, units) {
  var parts = []
  parts.push(state && state.room ? state.room.toUpperCase() : "DAIKIN")
  if (state && state.online === true && state.indoor_f != null) {
    parts.push(units === "f" ? fmtF(state.indoor_f) + " IN" : fmtC(state.indoor_c) + " IN")
  }
  return parts.join("  ·  ")
}

// Multi-line bar tooltip.
function tooltip(state, ip, units) {
  if (!state || state.online !== true) {
    return "Daikin offline" + (ip ? " (" + ip + ")" : "") + "\nClick for details, right-click retries the connection."
  }
  var line1 = (state.room ? state.room + " — " : "") +
    (state.power ? modeLabel(state.mode) + " " + tempLabel(state, units) + " set" : "Off") +
    "  ·  " + indoorLabel(state, units) + " in"
  var line2 = "Compressor " + compressorLabel(state) + "  ·  " + errorLabel(state)
  return line1 + "\n" + line2 + "\nClick for the panel, right-click toggles power."
}