// Run: node --test test/analysis.test.mjs   (no dependencies)
// Set MOUSECAL_SAMPLE_CSV to a capture CSV (t seconds, dx, dy, device) to also check real data.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import * as A from '../analysis.js';
import { SETTINGS_TEMPLATE } from '../settings-template.js';

const here = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------- helpers
function rng(seed) { // mulberry32
  return () => {
    seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function gauss(r) { return Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r()); }

/*
 * Back-and-forth swipes along a direction `theta` degrees above horizontal (screen y down,
 * so dy = -sin). Per-stroke angle noise `angSd`, per-sample jitter `jit` counts (it also
 * dithers the integer rounding), bell-shaped velocity. gapMs = pause between strokes
 * (0 = continuous reversal). stepMs = event interval. Samples are {t (ms), dx, dy}.
 */
function synth({ theta, n = 80, len = 2000, angSd = 1, jit = 2, stepMs = 1, strokeMs = 160, gapMs = 0, seed = 1, rightBias = 0 }) {
  const r = rng(seed), out = [];
  let t = 0;
  for (let i = 0; i < n; i++) {
    const right = i % 2 === 0;
    const a = (theta + (right ? rightBias : -rightBias) + gauss(r) * angSd) * Math.PI / 180;
    const L = len * (0.8 + 0.4 * r());
    const k = Math.max(2, Math.round(strokeMs / stepMs));
    let prev = 0;
    for (let j = 1; j <= k; j++) {
      const u = j / k, cum = (1 - Math.cos(Math.PI * u)) / 2;
      const d = (cum - prev) * L; prev = cum;
      const sgn = right ? 1 : -1;
      t += stepMs;
      out.push({ t, dx: sgn * d * Math.cos(a) + gauss(r) * jit, dy: -sgn * d * Math.sin(a) + gauss(r) * jit });
    }
    t += gapMs;
  }
  return out.map((s) => ({ t: s.t, dx: Math.round(s.dx), dy: Math.round(s.dy) })); // device reports integers
}

function frames(s, dt) { // aggregate to display-frame sized events
  const out = []; let cur = null;
  for (const x of s) {
    const k = Math.floor(x.t / dt);
    if (!cur || cur.k !== k) { if (cur) out.push({ t: cur.t, dx: cur.dx, dy: cur.dy }); cur = { k, t: x.t, dx: 0, dy: 0 }; }
    cur.dx += x.dx; cur.dy += x.dy; cur.t = x.t;
  }
  if (cur) out.push({ t: cur.t, dx: cur.dx, dy: cur.dy });
  return out;
}

// ------------------------------------------------------------------ units
test('fold / vecAngle follow the documented convention', () => {
  assert.equal(A.fold(100), -80);
  assert.equal(A.fold(-90), 90);
  assert.equal(A.fold(90), 90);
  assert.ok(Math.abs(A.fold(-175) - 5) < 1e-9);
  assert.ok(Math.abs(A.vecAngle(100, -10) - 5.7106) < 1e-3); // right swipe drifting UP is positive
  assert.ok(Math.abs(A.vecAngle(-100, 10) - 5.7106) < 1e-3); // left swipe folds to the same sign
  assert.ok(A.vecAngle(100, 10) < 0);
});

test('median, weighted median, quantile, pca', () => {
  assert.equal(A.median([3, 1, 2]), 2);
  assert.equal(A.median([4, 1, 2, 3]), 2.5);
  assert.equal(A.weightedMedianOf([1, 2, 3], [1, 1, 10]), 3);
  assert.equal(A.quantile([1, 2, 3, 4, 5], 0.25), 2);
  const t = 7 * Math.PI / 180, v = [];
  for (let i = -5; i <= 5; i++) v.push([i * 10 * Math.cos(t), -i * 10 * Math.sin(t)]);
  assert.ok(Math.abs(A.pcaAngle(v) - 7) < 1e-9);
  assert.equal(A.pcaAngle([]), null);
});

test('confidence labels', () => {
  assert.equal(A.confidenceLabel(0.3, 14), 'insufficient');
  assert.equal(A.confidenceLabel(0.3, 15), 'high');
  assert.equal(A.confidenceLabel(0.59, 40), 'high');
  assert.equal(A.confidenceLabel(0.6, 40), 'medium');
  assert.equal(A.confidenceLabel(1.19, 40), 'medium');
  assert.equal(A.confidenceLabel(1.2, 40), 'low');
});

test('verdict thresholds: software |theta| <= 1, physical |theta| <= 2', () => {
  assert.equal(A.verdict(1, 'software'), 'pass');
  assert.equal(A.verdict(-1, 'software'), 'pass');
  assert.equal(A.verdict(1.01, 'software'), 'fail');
  assert.equal(A.verdict(2, 'physical'), 'pass');
  assert.equal(A.verdict(-2.01, 'physical'), 'fail');
  assert.equal(A.verdict(1.5, 'physical'), 'pass');
  assert.equal(A.verdict(NaN, 'physical'), 'fail');
  assert.throws(() => A.verdict(0, 'other'));
});

test('rawAccelSettings changes only "Degrees of rotation", rounded to 0.1', () => {
  const out = A.rawAccelSettings(SETTINGS_TEMPLATE, 8.24);
  assert.ok(/"Degrees of rotation": 8\.2,/.test(out));
  const a = SETTINGS_TEMPLATE.split('\n'), b = out.split('\n');
  assert.equal(a.length, b.length);
  assert.equal(a.filter((l, i) => l !== b[i]).length, 1);
  assert.equal(JSON.parse(A.rawAccelSettings(SETTINGS_TEMPLATE, -3.06)).profiles[0]['Degrees of rotation'], -3.1);
  assert.equal(JSON.parse(A.rawAccelSettings(SETTINGS_TEMPLATE, -0.04)).profiles[0]['Degrees of rotation'], 0);
  assert.doesNotThrow(() => JSON.parse(out));
  assert.throws(() => A.rawAccelSettings('{"a":1}', 1));
});

// -------------------------------------------------------------- synthetic
for (const theta of [5, -3, 0]) {
  test(`synthetic ${theta >= 0 ? '+' : ''}${theta} deg recovered within 0.3 deg`, () => {
    for (const seed of [1, 2, 3]) {
      const res = A.analyze(synth({ theta, seed }));
      assert.ok(res.n >= 70, `kept ${res.n} strokes`);
      assert.ok(Math.abs(res.median - theta) < 0.3, `seed ${seed}: median ${res.median}`);
      assert.ok(Math.abs(res.weightedMedian - theta) < 0.4, `seed ${seed}: weightedMedian ${res.weightedMedian}`);
      assert.ok(Math.abs(res.se - 1.2533 * res.std / Math.sqrt(res.n)) < 1e-12);
      assert.ok(res.se < 0.6);
      assert.equal(res.confidence, 'high');
      assert.ok(Math.abs(res.pca - theta) < 0.6, `pca ${res.pca}`);
      assert.ok(res.iqr > 0);
    }
  });
}

test('segmentStrokes returns stroke objects', () => {
  const st = A.segmentStrokes(synth({ theta: 5, n: 20 }));
  assert.ok(Array.isArray(st) && st.length >= 18);
  for (const s of st) {
    for (const k of ['t0', 't1', 'dx', 'dy', 'len', 'angle']) assert.equal(typeof s[k], 'number');
    assert.ok(s.dir === 'left' || s.dir === 'right');
    assert.equal(s.dir, s.dx > 0 ? 'right' : 'left');
    assert.ok(s.len >= 150);
  }
  assert.ok(st.some((s) => s.dir === 'left') && st.some((s) => s.dir === 'right'));
});

test('browser-like conditions: 60/144 Hz events, small DPI, pauses between strokes', () => {
  for (const [step, theta] of [[16.67, 5], [6.94, -3], [16.67, 0]]) {
    const raw = synth({ theta, seed: 7, len: 500, stepMs: 1, gapMs: 0, angSd: 1, jit: 0.5 });
    const res = A.analyze(frames(raw, step));
    assert.ok(res.n >= 60, `${step}ms: kept ${res.n}`);
    assert.ok(Math.abs(res.median - theta) < 0.4, `${step}ms: median ${res.median}`);
  }
  // pauses between strokes; averaged over seeds (single-seed noise alone is ~0.2-0.4 deg here)
  let err = 0;
  for (const seed of [9, 10, 11, 12, 13]) {
    const p = A.analyze(synth({ theta: 4, seed, gapMs: 150, len: 800, jit: 0.5 }));
    assert.ok(p.n >= 70, `paused: kept ${p.n}`);
    err += p.median - 4;
  }
  assert.ok(Math.abs(err / 5) < 0.3, `paused: mean error ${err / 5}`);
});

test('adaptive minimum stroke length discards short junk but keeps real strokes', () => {
  const good = synth({ theta: 5, seed: 4, n: 40 });
  const junk = [];
  let t = good[good.length - 1].t + 500;
  for (let i = 0; i < 20; i++) { junk.push({ t, dx: 0, dy: 60 }, { t: t + 5, dx: 0, dy: -20 }); t += 300; }
  const res = A.analyze(good.concat(junk));
  assert.equal(res.n, 40);
  assert.ok(Math.abs(res.median - 5) < 0.4);
  assert.ok(res.minLen >= 150);
});

test('warnings: wrist-arc, inconsistent, few-strokes', () => {
  const arc = A.analyze(synth({ theta: 5, seed: 5, rightBias: 2.5 })); // right 7.5, left 2.5
  assert.ok(arc.warnings.includes('wrist-arc'), `diff ${arc.rightMedian - arc.leftMedian}`);
  const flat = A.analyze(synth({ theta: 5, seed: 5 }));
  assert.ok(!flat.warnings.includes('wrist-arc') && !flat.warnings.includes('few-strokes'));
  const messy = A.analyze(synth({ theta: 5, seed: 5, angSd: 8 }));
  assert.ok(messy.std > 4 && messy.warnings.includes('inconsistent'), `std ${messy.std}`);
  const few = A.analyze(synth({ theta: 5, n: 8 }));
  assert.equal(few.confidence, 'insufficient');
  assert.ok(few.warnings.includes('few-strokes'));
  const none = A.analyze([]);
  assert.equal(none.n, 0);
  assert.equal(none.confidence, 'insufficient');
});

test('histogram counts add up and cover the median', () => {
  const res = A.analyze(synth({ theta: 5, seed: 6 }));
  const h = res.hist;
  assert.equal(h.counts.reduce((a, b) => a + b, 0), res.n);
  assert.ok(h.lo <= res.median && h.lo + h.counts.length * h.binDeg >= res.median);
});

test('samples may also be [t, dx, dy] arrays and unsorted', () => {
  const objs = synth({ theta: 5, seed: 2 });
  const arrs = objs.map((s) => [s.t, s.dx, s.dy]).reverse();
  assert.equal(A.analyze(arrs).median, A.analyze(objs).median);
});

// ------------------------------------------------------------- real data
const csv = process.env.MOUSECAL_SAMPLE_CSV || path.join(here, '..', '..', 'logs', 'capture_20261014_200432.csv');
function loadCsv() {
  const rows = readFileSync(csv, 'utf8').trim().split(/\r?\n/).slice(1).map((l) => l.split(','));
  const c = new Map(); rows.forEach((r) => c.set(r[3], (c.get(r[3]) || 0) + 1));
  const dev = [...c.entries()].sort((a, b) => b[1] - a[1])[0][0];
  return rows.filter((r) => r[3] === dev).map((r) => ({ t: +r[0] * 1000, dx: +r[1], dy: +r[2] })).sort((a, b) => a.t - b.t);
}

test('real capture: median within 0.3 deg of +8.22', { skip: !existsSync(csv) && 'no sample CSV' }, () => {
  const s = loadCsv();
  const res = A.analyze(s);
  assert.ok(Math.abs(res.median - 8.22) < 0.3, `median ${res.median}`);
  assert.equal(res.n, 132);
  for (const dt of [6.94, 16.67]) { // still right when events are aggregated to display-frame rate
    const r = A.analyze(frames(s, dt));
    assert.ok(Math.abs(r.median - 8.22) < 0.4, `${dt}ms: ${r.median}`);
  }
});

test('trimTail drops samples within 300 ms of the end (and anything after it), keeps the input shape', () => {
  const s = [{ t: 0, dx: 1, dy: 0 }, { t: 699, dx: 2, dy: 0 }, { t: 700, dx: 3, dy: 0 }, { t: 701, dx: 4, dy: 0 }, { t: 1000, dx: 5, dy: 0 }, { t: 1200, dx: 6, dy: 0 }];
  assert.deepEqual(A.trimTail(s, 1000).map((x) => x.dx), [1, 2, 3]);   // t <= 700 stays
  assert.deepEqual(A.trimTail(s, 1000, 0).map((x) => x.dx), [1, 2, 3, 4, 5]);
  assert.deepEqual(A.trimTail(s, 1000, 1000).map((x) => x.dx), [1]);
  assert.deepEqual(A.trimTail([[0, 1, 1], [900, 2, 2]], 1000), [[0, 1, 1]]);
  assert.deepEqual(A.trimTail([], 1000), []);
  assert.deepEqual(A.trimTail(null, 1000), []);
  assert.equal(s.length, 6); // input untouched
});

test('dropLast removes exactly the final stroke, even when it is too short to count', () => {
  const s = synth({ theta: 5, n: 20, len: 2000, angSd: 0.5, gapMs: 0, seed: 11 });
  const full = A.analyze(s);
  const dropped = A.analyze(s, { dropLast: true });
  assert.equal(dropped.n, full.n - 1);
  assert.deepEqual(dropped.strokes, full.strokes.slice(0, -1));
  // a tiny unfinished twitch at the very end is the stroke that gets dropped, not a real one
  const t1 = s[s.length - 1].t;
  const twitch = s.concat([1, 2, 3, 4, 5, 6].map((i) => ({ t: t1 + i, dx: 40, dy: 0 })));
  assert.equal(A.analyze(twitch, { dropLast: true }).n, A.analyze(twitch).n);
});

test('analyzeTimed = trimTail + dropLast: the stop-key swing at the end cannot skew the result', () => {
  const good = synth({ theta: 6, n: 30, len: 2000, angSd: 0.8, gapMs: 0, seed: 5 });
  const end = good[good.length - 1].t;
  // the hand swings wildly in the last 250 ms (reaching for the stop key)
  const junk = [];
  for (let i = 1; i <= 25; i++) junk.push({ t: end + i * 10, dx: 400, dy: 300 });
  const all = good.concat(junk), endT = end + 260;
  const timed = A.analyzeTimed(all, endT);
  assert.ok(Math.abs(timed.median - 6) < 1, 'timed median ' + timed.median);
  assert.ok(timed.n >= 25 && timed.n <= 30, 'n ' + timed.n);
  // the unfinished stroke is gone: one fewer than a plain analysis of the trimmed data
  assert.equal(timed.n, A.analyze(A.trimTail(all, endT)).n - 1);
  // options pass through
  assert.equal(A.analyzeTimed(good, end + 300, { minStrokes: 1000 }).confidence, 'insufficient');
});

test('isShaky: se > 1, std > 5, n < 20 or right/left gap > 4 deg flags the result; a steady one does not', () => {
  const ok = { median: 8, n: 30, se: 0.8, std: 3, rightMedian: 8.5, leftMedian: 7.5 };
  assert.equal(A.isShaky(ok), false);
  assert.equal(A.isShaky({ ...ok, se: 1.0 }), false);   // boundaries are inclusive of "fine"
  assert.equal(A.isShaky({ ...ok, se: 1.01 }), true);
  assert.equal(A.isShaky({ ...ok, std: 5 }), false);
  assert.equal(A.isShaky({ ...ok, std: 5.01 }), true);
  assert.equal(A.isShaky({ ...ok, n: 20 }), false);
  assert.equal(A.isShaky({ ...ok, n: 19 }), true);
  assert.equal(A.isShaky({ ...ok, rightMedian: 10, leftMedian: 6 }), false);
  assert.equal(A.isShaky({ ...ok, rightMedian: 10.1, leftMedian: 6 }), true);
  assert.equal(A.isShaky({ ...ok, rightMedian: 5, leftMedian: 10 }), true);
  assert.equal(A.isShaky({ ...ok, rightMedian: null, leftMedian: null }), false);   // one-sided: nothing to compare
  assert.equal(A.isShaky({ ...ok, se: NaN }), true);
  assert.equal(A.isShaky(null), false);
  assert.equal(A.isShaky({ median: null, n: 0, se: 0, std: 0 }), false);            // nothing measured: no note
});

test('capture export: CSV header t,dx,dy,device; seconds relative to the first sample; integer dx/dy', () => {
  const s = [{ t: 1000.5, dx: 3, dy: -1 }, { t: 1008.5, dx: -2.4, dy: 0 }, { t: 2500.5, dx: 1, dy: 7 }];
  const lines = A.capturesToCsv(s, true).trimEnd().split('\n');
  assert.equal(lines[0], 't,dx,dy,device');
  assert.equal(lines.length, 4);
  assert.equal(lines[1], '0.000000,3,-1,browser-unadjusted');
  assert.equal(lines[2], '0.008000,-2,0,browser-unadjusted');
  assert.equal(lines[3], '1.500000,1,7,browser-unadjusted');
  assert.ok(A.capturesToCsv(s, false).includes(',browser-adjusted'));
  assert.ok(A.capturesToCsv(s, null).includes(',browser-adjusted'));
  assert.equal(A.capturesToCsv([], true), 't,dx,dy,device\n');
  assert.equal(A.captureSeconds(s), 1.5);
  assert.equal(A.captureSeconds([]), 0);
  assert.equal(A.captureFilename(new Date(2026, 9, 5, 7, 8, 9)), 'mousecal-capture-20261005-070809.csv');
});
