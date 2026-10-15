/*
 * Mouse sensor-rotation analysis. Pure functions, no DOM.
 * ES module (node and <script type="module">); in a browser it is also attached to
 * globalThis.MouseCalAnalysis.
 *
 * Port of measure_angle.py (fold, vec_angle, pca_angle, _smooth, _zigzag,
 * segment_strokes, analyze_samples) with two browser-oriented changes:
 *   - samples are {t, dx, dy} with t in milliseconds (performance.now() timebase)
 *   - the minimum stroke length is adaptive (browser counts depend on DPI) and the
 *     smoothing window adapts to the event rate.
 *
 * Convention: theta = atan2(-dy, dx) in degrees (screen y points down), folded to
 * (-90, 90]. Positive theta = a "horizontal" right swipe drifts UP on screen
 * (counter-clockwise).
 */

export const DEFAULTS = {
  pauseMs: 80,          // a pause this long always splits strokes
  hyst: 40,             // counts of retreat needed to call a direction reversal
  floorLen: 50,         // candidates shorter than this never enter the length median
  minLenAbs: 150,       // adaptive minimum = max(minLenAbs, minLenRel * median length)
  minLenRel: 0.25,
  minStrokes: 15,
  wristWarnDeg: 3,
  stdWarnDeg: 4,
  smoothWin: null,      // null = choose from the median event interval
  dropLast: false,      // drop the final (possibly unfinished) stroke before counting
  tailMs: 300           // analyzeTimed: samples this close to the end are discarded
};

function opt(o) {
  const r = {};
  for (const k in DEFAULTS) r[k] = o && o[k] != null ? o[k] : DEFAULTS[k];
  return r;
}

// Accepts {t, dx, dy} (contract) or [t, dx, dy]; returns [[t, dx, dy], ...] sorted by t.
function norm(samples) {
  if (!samples) return [];
  const out = samples.map((s) => (Array.isArray(s) ? [s[0], s[1], s[2]] : [s.t, s.dx, s.dy]));
  for (let i = 1; i < out.length; i++) {
    if (out[i][0] < out[i - 1][0]) return out.sort((a, b) => a[0] - b[0]);
  }
  return out;
}

// ------------------------------------------------------------------ angles
export function fold(deg) {
  deg = deg % 180;
  if (deg > 90) deg -= 180;
  else if (deg <= -90) deg += 180;
  return deg === 0 ? 0 : deg; // no -0
}

export function vecAngle(dx, dy) {
  return fold(Math.atan2(-dy, dx) * 180 / Math.PI);
}

// Principal-axis angle of [dx, dy] vectors, closed form, y flipped so up > 0.
export function pcaAngle(vectors) {
  let sxx = 0, sxy = 0, syy = 0;
  for (const v of vectors) {
    const dx = v[0], y = -v[1];
    sxx += dx * dx; sxy += dx * y; syy += y * y;
  }
  if (sxx + syy === 0) return null;
  return fold(0.5 * Math.atan2(2 * sxy, sxx - syy) * 180 / Math.PI);
}

// -------------------------------------------------------------- statistics
export function median(a) {
  if (!a.length) return null;
  const s = a.slice().sort((x, y) => x - y);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export function mean(a) {
  if (!a.length) return null;
  let t = 0;
  for (const v of a) t += v;
  return t / a.length;
}

export function stdev(a) { // sample standard deviation
  if (a.length < 2) return 0;
  const m = mean(a);
  let t = 0;
  for (const v of a) t += (v - m) * (v - m);
  return Math.sqrt(t / (a.length - 1));
}

// Linear-interpolated quantile (same as statistics.quantiles 'inclusive').
export function quantile(a, p) {
  if (!a.length) return null;
  const s = a.slice().sort((x, y) => x - y);
  const pos = (s.length - 1) * p, lo = Math.floor(pos), hi = Math.ceil(pos);
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}

export function weightedMedianOf(values, weights) {
  if (!values.length) return null;
  const idx = values.map((_, i) => i).sort((i, j) => values[i] - values[j]);
  let total = 0;
  for (const w of weights) total += w;
  let acc = 0;
  for (const i of idx) {
    acc += weights[i];
    if (acc >= total / 2) return values[i];
  }
  return values[idx[idx.length - 1]];
}

// ------------------------------------------------------------ segmentation
export function smooth(vals, win) {
  const n = vals.length;
  if (win <= 1 || n === 0) return vals.slice();
  const half = win >> 1, pref = [0];
  for (let i = 0; i < n; i++) pref.push(pref[i] + vals[i]);
  const out = new Array(n);
  for (let i = 0; i < n; i++) {
    const a = Math.max(0, i - half), b = Math.min(n, i + half + 1);
    out[i] = (pref[b] - pref[a]) / (b - a);
  }
  return out;
}

// [start, end] inclusive index ranges split at direction reversals. A reversal needs
// the position to retreat >= hyst from its running extreme.
export function zigzag(s, hyst) {
  const n = s.length;
  if (n === 0) return [];
  const ranges = [];
  let start = 0, d = 0, lo = 0, hi = 0, ext = 0;
  for (let i = 1; i < n; i++) {
    if (d === 0) {
      if (s[i] < s[lo]) lo = i;
      if (s[i] > s[hi]) hi = i;
      if (s[hi] - s[lo] >= hyst) {
        d = hi > lo ? 1 : -1;
        ext = d > 0 ? hi : lo;
      }
    } else if (d > 0) {
      if (s[i] >= s[ext]) ext = i;
      else if (s[ext] - s[i] >= hyst) {
        ranges.push([start, ext]); start = ext + 1; d = -1; ext = i;
      }
    } else {
      if (s[i] <= s[ext]) ext = i;
      else if (s[i] - s[ext] >= hyst) {
        ranges.push([start, ext]); start = ext + 1; d = 1; ext = i;
      }
    }
  }
  if (start <= n - 1) ranges.push([start, n - 1]);
  return ranges;
}

function medianInterval(samples) {
  const dts = [];
  for (let i = 1; i < samples.length; i++) {
    const d = samples[i][0] - samples[i - 1][0];
    if (d > 0 && d <= 80) dts.push(d);
  }
  return median(dts);
}

function makeStroke(dx, dy, t0, t1) {
  return {
    t0: t0 == null ? 0 : t0, t1: t1 == null ? 0 : t1,
    dx, dy, len: Math.hypot(dx, dy),
    angle: vecAngle(dx, dy), dir: dx > 0 ? 'right' : 'left'
  };
}

// samples (already normalised) -> { strokes, minLen, candidates, axis }
function segment(samples, options) {
  const o = opt(options);
  const empty = { strokes: [], minLen: o.minLenAbs, candidates: 0, axis: null };
  if (!samples.length) return empty;
  const axis = pcaAngle(samples.map((s) => [s[1], s[2]]));
  if (axis === null) return empty;
  const ca = Math.cos(axis * Math.PI / 180), sa = Math.sin(axis * Math.PI / 180);

  let win = o.smoothWin;
  if (win == null) {
    const dt = medianInterval(samples);
    win = dt == null || dt < 3 ? 5 : dt < 8 ? 3 : 1;
  }

  const chunks = [];
  let cur = [samples[0]];
  for (let i = 1; i < samples.length; i++) {
    if (samples[i][0] - samples[i - 1][0] > o.pauseMs) { chunks.push(cur); cur = []; }
    cur.push(samples[i]);
  }
  chunks.push(cur);

  const cand = [];
  for (let ci = 0; ci < chunks.length; ci++) {
    const ch = chunks[ci];
    const pos = [];
    let p = 0;
    for (const s of ch) { p += s[1] * ca + (-s[2]) * sa; pos.push(p); }
    const ranges = zigzag(smooth(pos, win), o.hyst);
    // the last range of the last chunk is the stroke still in progress when recording stopped
    if (o.dropLast && ci === chunks.length - 1) ranges.pop();
    for (const [a, b] of ranges) {
      let sx = 0, sy = 0;
      for (let j = a; j <= b; j++) { sx += ch[j][1]; sy += ch[j][2]; }
      const st = makeStroke(sx, sy, ch[a][0], ch[b][0]);
      if (st.len >= o.floorLen) cand.push(st);
    }
  }

  const med = median(cand.map((s) => s.len));
  const minLen = Math.max(o.minLenAbs, med == null ? 0 : o.minLenRel * med);
  return { strokes: cand.filter((s) => s.len >= minLen), minLen, candidates: cand.length, axis };
}

/*
 * samples: [{t (ms), dx, dy}, ...]. Returns [{t0, t1, dx, dy, len, angle, dir}, ...].
 * Minimum stroke length = max(150, 0.25 x median stroke length).
 */
export function segmentStrokes(samples, options) {
  return segment(norm(samples), options).strokes;
}

// -------------------------------------------------------------- summarising
export function confidenceLabel(se, n, minStrokes) {
  if (n < (minStrokes == null ? DEFAULTS.minStrokes : minStrokes)) return 'insufficient';
  if (se < 0.6) return 'high';
  if (se < 1.2) return 'medium';
  return 'low';
}

// Histogram over a fixed 1-degree grid that always covers centre +- halfSpan.
export function histogram(angles, centre, halfSpan, binDeg) {
  binDeg = binDeg || 1;
  const c = centre == null ? 0 : centre, h = halfSpan || 6;
  const lo = Math.floor(Math.min(...angles, c - h) / binDeg) * binDeg;
  const hi = Math.ceil(Math.max(...angles, c + h) / binDeg) * binDeg;
  const nb = Math.max(1, Math.round((hi - lo) / binDeg));
  const counts = new Array(nb).fill(0);
  for (const a of angles) counts[Math.min(nb - 1, Math.max(0, Math.floor((a - lo) / binDeg)))]++;
  return { lo, binDeg, counts };
}

/*
 * Statistics for a list of strokes. Result:
 *   n, median, weightedMedian, mean, std, se (1.2533*std/sqrt(n)), iqr, pca,
 *   rightMedian, leftMedian, confidence ('high'|'medium'|'low'|'insufficient'),
 *   strokes, warnings (codes: 'few-strokes', 'inconsistent', 'wrist-arc')
 * plus helpers for the UI: rightN, leftN, lrDiff, q1, q3, hist, enough, minStrokes.
 */
export function summarize(strokes, options) {
  const o = opt(options);
  const angles = strokes.map((s) => s.angle);
  const n = angles.length;
  const res = {
    n, median: null, weightedMedian: null, mean: null, std: 0, se: 0, iqr: 0, pca: null,
    rightMedian: null, leftMedian: null, rightN: 0, leftN: 0, lrDiff: null,
    q1: null, q3: null, hist: null,
    confidence: 'insufficient', strokes, warnings: [],
    enough: n >= o.minStrokes, minStrokes: o.minStrokes
  };
  if (n < o.minStrokes) res.warnings.push('few-strokes');
  if (!n) return res;

  res.median = median(angles);
  res.weightedMedian = weightedMedianOf(angles, strokes.map((s) => s.len));
  res.mean = mean(angles);
  res.std = stdev(angles);
  res.se = 1.2533 * res.std / Math.sqrt(n);
  res.q1 = quantile(angles, 0.25);
  res.q3 = quantile(angles, 0.75);
  res.iqr = res.q3 - res.q1;
  res.pca = pcaAngle(strokes.map((s) => [s.dx, s.dy]));
  const r = strokes.filter((s) => s.dir === 'right').map((s) => s.angle);
  const l = strokes.filter((s) => s.dir === 'left').map((s) => s.angle);
  res.rightN = r.length; res.leftN = l.length;
  res.rightMedian = median(r); res.leftMedian = median(l);
  if (r.length && l.length) res.lrDiff = res.rightMedian - res.leftMedian;
  res.confidence = confidenceLabel(res.se, n, o.minStrokes);
  res.hist = histogram(angles, res.median);
  if (res.std > o.stdWarnDeg) res.warnings.push('inconsistent');
  if (res.lrDiff != null && Math.abs(res.lrDiff) > o.wristWarnDeg) res.warnings.push('wrist-arc');
  return res;
}

/*
 * samples: [{t (ms), dx, dy}, ...] -> summarize(segmentStrokes(samples)) with
 * pca = principal axis of ALL samples (cross-check), plus minLen / nSamples.
 */
export function analyze(samples, options) {
  const ns = norm(samples);
  const seg = segment(ns, options);
  const res = summarize(seg.strokes, options);
  res.pca = ns.length ? pcaAngle(ns.map((s) => [s[1], s[2]])) : null;
  res.minLen = seg.minLen;
  res.nSamples = ns.length;
  return res;
}

/*
 * Timed recording: the last moments are unreliable (the hand is already moving to stop).
 * trimTail drops every sample within `ms` of endT (and anything after endT); same shape in/out.
 */
export function trimTail(samples, endT, ms) {
  if (!samples) return [];
  const cut = endT - (ms == null ? DEFAULTS.tailMs : ms);
  return samples.filter((s) => (Array.isArray(s) ? s[0] : s.t) <= cut);
}

// analyze() for a recording that ended at endT: trims the tail and drops the final partial stroke.
export function analyzeTimed(samples, endT, options) {
  const o = Object.assign({}, options, { dropLast: true });
  return analyze(trimTail(samples, endT, o.tailMs), o);
}

// ------------------------------------------------------------------ verdict
// path 'software' (Raw Accel): |theta| <= 1 deg; 'physical' (rotate the mouse): |theta| <= 2 deg.
export const THRESHOLDS = { software: 1, physical: 2 };
export function verdict(theta, path) {
  if (!(path in THRESHOLDS)) throw new Error('unknown path: ' + path);
  return Number.isFinite(theta) && Math.abs(theta) <= THRESHOLDS[path] ? 'pass' : 'fail';
}

// ------------------------------------------------------------ settings.json
const ROTATION_RE = /("Degrees of rotation"\s*:\s*)-?\d+(\.\d+)?([eE][+-]?\d+)?/g;

// Returns the template text with only "Degrees of rotation" set to theta rounded to 0.1.
export function rawAccelSettings(templateJsonString, theta) {
  if (!Number.isFinite(theta)) throw new Error('theta must be a finite number');
  ROTATION_RE.lastIndex = 0;
  if (!ROTATION_RE.test(templateJsonString)) throw new Error('"Degrees of rotation" not found in template');
  let v = Math.round(theta * 10) / 10;
  if (v === 0) v = 0; // no -0
  const text = v.toFixed(1);
  return templateJsonString.replace(ROTATION_RE, (_, key) => key + text);
}

const api = {
  DEFAULTS, THRESHOLDS, fold, vecAngle, pcaAngle, median, mean, stdev, quantile, weightedMedianOf,
  smooth, zigzag, segmentStrokes, confidenceLabel, histogram, summarize, analyze,
  trimTail, analyzeTimed, verdict, rawAccelSettings
};
if (typeof window !== 'undefined') globalThis.MouseCalAnalysis = api;
export default api;
