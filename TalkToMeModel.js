.pragma library

var ID_RE = /^[A-Za-z0-9_-]{4,40}$/
var DEFAULTS = { countdown: 10, askTimeout: 60, textTimeout: 120, maxMinutes: 20, sayMs: 8000, holdSec: 120, textMax: 500, postponeMax: 240, guardMs: 1500, guardQuietMs: 900, guardCapMs: 6000 }

// Input guard: after a card appears, keys and clicks are ignored for guardMs; every ignored
// event extends it until the person has been quiet for guardQuietMs (at most guardCapMs after opening).
function guardUntil(now, openAt) {
  return Math.min(now + DEFAULTS.guardQuietMs, openAt + DEFAULTS.guardCapMs)
}

function cleanId(value) {
  var s = String(value || "")
  return ID_RE.test(s) ? s : ""
}

function clampInt(value, lo, hi, fallback) {
  var n = parseInt(value, 10)
  if (!isFinite(n)) return fallback
  return Math.max(lo, Math.min(hi, n))
}

// Strips control characters, collapses whitespace and limits length.
function cleanText(value, max) {
  var s = String(value || "").replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim()
  return s.length > max ? s.slice(0, max - 1) + "…" : s
}

// Maps a key press to an action for the current phase.
//   countdown -> "human" | "start" | "postpone" | "end" | ""
//   ask       -> "yes" | "no" | "unsure" | "type" | "postpone" | "end" | ""
function keyAction(phase, text, isEscape) {
  if (isEscape) return "end"
  var t = String(text || "").toLowerCase()
  if (phase === "countdown") return t === "y" ? "human" : t === "s" || t === "\n" ? "start" : t === "p" ? "postpone" : ""
  if (phase === "ask") {
    if (t === "y") return "yes"
    if (t === "n") return "no"
    if (t === "?" || t === "/" || t === "u") return "unsure"
    if (t === "t") return "type"
    if (t === "p") return "postpone"
  }
  return ""
}

function askKind(value) {
  return String(value) === "text" ? "text" : "choice"
}

// Result line for a typed answer; "" when nothing was typed (the card stays open).
function textResult(raw) {
  var s = cleanText(raw, DEFAULTS.textMax)
  return s === "" ? "" : "text:" + s
}

// Result line for a postpone request; "" when the input is not a whole number of minutes.
function postponeResult(raw) {
  var s = String(raw || "").trim()
  if (!/^[0-9]{1,4}$/.test(s)) return ""
  if (parseInt(s, 10) < 1) return ""
  return "postpone:" + clampInt(s, 1, DEFAULTS.postponeMax, 1)
}

function remainingText(seconds) {
  var s = Math.max(0, Math.round(seconds))
  var m = Math.floor(s / 60)
  var r = s % 60
  return m + ":" + (r < 10 ? "0" : "") + r
}

// "about 3 min" / "about 45 s" for the countdown card.
function estimateLabel(seconds) {
  var s = Math.max(0, Math.round(seconds))
  if (s <= 0) return ""
  if (s < 90) return "about " + s + " s"
  return "about " + Math.round(s / 60) + " min"
}

// Banner time text: time left against the agent's estimate, "taking longer" past it, or time so far without one.
function progressText(estimate, elapsed) {
  var e = Math.max(0, Math.round(elapsed))
  var est = Math.max(0, Math.round(estimate))
  if (est <= 0) return remainingText(e) + " so far"
  if (e <= est) return "about " + remainingText(est - e) + " left"
  return "taking longer · +" + remainingText(e - est)
}

// Banner line under the label: the agent's estimate stays visible next to the live count for the whole test.
function timeLine(phase, estimate, elapsed) {
  var est = Math.max(0, Math.round(estimate))
  if (phase === "countdown") return est > 0 ? "Expected duration: " + estimateLabel(est) : ""
  if (phase !== "active") return ""
  if (est <= 0) return progressText(est, elapsed)
  return "Expected " + estimateLabel(est).replace("about ", "") + "  ·  " + progressText(est, elapsed)
}

// Corner badge ring: text in the middle and how full the ring is (1 = whole estimate left).
function badgeRing(estimate, elapsed) {
  var est = Math.max(0, Math.round(estimate))
  var e = Math.max(0, Math.round(elapsed))
  if (est <= 0) return { text: remainingText(e), fraction: 1 }
  if (e <= est) return { text: remainingText(est - e), fraction: (est - e) / est }
  return { text: "+" + remainingText(e - est), fraction: 0 }
}

function statusJson(st) {
  return JSON.stringify({
    phase: st.phase,
    mode: st.mode,
    label: st.label,
    question: st.question,
    remainingSec: st.remainingSec,
    estimateSec: st.estimateSec || 0,
    elapsedSec: st.elapsedSec || 0
  })
}
