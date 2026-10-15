// mousecal page logic: pointer-lock measurement, result rendering, fix paths.
import * as A from './analysis.js';
import { SETTINGS_TEMPLATE } from './settings-template.js';
import { STRINGS } from './i18n.js';
import { normalizeStore, serializeStore, verdictPath, shortDate, installedAfter } from './store.js';
import { installCommand, uninstallCommand, applyUrl, uninstallUrl, formatRotation, ONE_CLICK_MAX, launcherCmd, launcherFilename } from './commands.js';
import { SETUP_SHA256 } from './setup-hash.js';

const $ = (id) => document.getElementById(id);
const BASE_MS = 10000;       // countdown starts on the first movement
const MAX_MS = 20000;        // hard limit after an auto-extension
const STORE_KEY = 'mousecal.v1';
const SVGNS = 'http://www.w3.org/2000/svg';

// ------------------------------------------------------------------ state
const S = {
  lang: 'zh',
  result: null,            // { res, source: 'measured', remeasured } - only real, valid measurements
  mode: 'measure',         // 'measure' | 'remeasure'
  path: null,              // 'software' | 'physical' | null (unknown)
  before: null,            // { theta } what the re-measure is compared with
  last: null,              // { theta, se, n, at } last valid measurement (per-browser convenience only)
  pendingApply: false,     // the user started a fix and has not re-measured yet
  installed: false,        // a re-measure after an apply passed in this browser once (only softens a hint)
  attempt: null,           // { n } latest measurement that was too short to count
  finePointer: true,
  measuring: false,
  phase: 'idle',           // 'ready' (locked, waiting for movement) | 'run' | 'extend'
  firstT: 0, endAt: 0, endT: 0, extended: false,
  samples: [],
  capture: null,           // { samples, events, unadjusted } raw data of the last run; memory only, never stored
  trail: [],
  px: 0, py: 0,
  unadjusted: null,        // true / false once a lock was granted
  viewScale: 0,
  live: null
};
let timers = { stop: 0, live: 0, raf: 0 };
let lockPending = false;
const REMEASURE_BTNS = ['btnRemeasureWin', 'btnRemeasurePhys', 'btnBar', 'btnWelcome', 'btnShaky'];

// ---------------------------------------------------------------- storage
// Per-browser convenience only (welcome-back band, sticky bar). Never used to compute a rotation.
function load() {
  try {
    const o = normalizeStore(JSON.parse(localStorage.getItem(STORE_KEY) || '{}'));
    if (o.lang) S.lang = o.lang;
    S.last = o.last; S.path = o.path; S.pendingApply = o.pendingApply; S.installed = o.installed;
  } catch { /* storage unavailable: run without persistence */ }
}
function save() {
  try {
    localStorage.setItem(STORE_KEY, serializeStore({ lang: S.lang, last: S.last, path: S.path, pendingApply: S.pendingApply, installed: S.installed }));
  } catch { /* ignore */ }
}
function clearStore() {
  try { localStorage.removeItem(STORE_KEY); } catch { /* ignore */ }
}

// ------------------------------------------------------------------- i18n
function t(key, vars) {
  let s = (STRINGS[S.lang] && STRINGS[S.lang][key]) ?? STRINGS.zh[key] ?? key;
  if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? vars[k] : m));
  return s;
}
const DEFAULT_VARS = () => ({ thr: A.THRESHOLDS.physical, need: A.DEFAULTS.minStrokes });
function applyI18n() {
  document.documentElement.lang = S.lang === 'zh' ? 'zh-Hant-TW' : 'en';
  document.title = t('pageTitle') + ' · mousecal';
  for (const el of document.querySelectorAll('[data-i18n]')) el.textContent = t(el.dataset.i18n, DEFAULT_VARS());
  for (const el of document.querySelectorAll('[data-i18n-html]')) el.innerHTML = t(el.dataset.i18nHtml, DEFAULT_VARS());
  $('langBtn').textContent = t('langBtn');
}

// --------------------------------------------------------------- formatting
const num = (v, d = 1) => (v == null || !Number.isFinite(v) ? '--' : v.toFixed(d));
const signed = (v, d = 1) => {
  if (v == null || !Number.isFinite(v)) return '--';
  const s = v.toFixed(d);
  return (v > 0 && Number(s) !== 0 ? '+' : '') + (Number(s) === 0 ? (0).toFixed(d) : s);
};
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;

// After a reload the last valid measurement is shown again (marked "last time's result") so the fix can be applied
// without measuring again. Only theta / se / n were kept; everything else stays empty and is not shown.
function savedResult(l) {
  const se = Number.isFinite(l.se) ? l.se : null;
  const res = {
    median: l.theta, weightedMedian: null, mean: null, std: null, pca: null, n: l.n, se: se == null ? 0 : se,
    rightMedian: null, leftMedian: null, rightN: 0, leftN: 0, lrDiff: null,
    confidence: se == null ? 'low' : A.confidenceLabel(se, l.n), warnings: [], strokes: [], hist: null
  };
  return { res, source: 'saved', remeasured: false };
}
const isSaved = () => !!S.result && S.result.source === 'saved';

function theta() { return S.result && S.result.res.median != null ? S.result.res.median : null; }
function canCopy() {
  return !!S.result && S.result.res.median != null;
}
// The command carries the MEASURED angle only; setup.ps1 adds it to whatever rotation the driver
// already applies (it reads that from the driver), so the page keeps no record of applied rotation.
function measuredForCommand() {
  const th = theta();
  return th == null ? 0 : clamp(th, -45, 45);
}

function svgEl(name, attrs, text) {
  const e = document.createElementNS(SVGNS, name);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (text != null) e.textContent = text;
  return e;
}

// ------------------------------------------------------------- dial (result)
function renderDial(th, se) {
  const svg = $('dial');
  svg.replaceChildren();
  const ox = 26, oy = 150, R = 280, MAXA = 30;
  const rad = (d) => d * Math.PI / 180;
  const pt = (a, r) => [ox + r * Math.cos(rad(a)), oy - r * Math.sin(rad(a))];
  const f = (p) => p[0].toFixed(2) + ' ' + p[1].toFixed(2);

  // wedge for the error band, then the needle's angle wedge
  if (th != null) {
    const tc = clamp(th, -MAXA, MAXA);
    svg.append(svgEl('path', { class: 'svg-fill', d: `M ${ox} ${oy} L ${f(pt(0, R))} A ${R} ${R} 0 0 ${tc > 0 ? 0 : 1} ${f(pt(tc, R))} Z` }));
  }
  // ticks
  for (let d = -MAXA; d <= MAXA; d++) {
    const len = d % 10 === 0 ? 24 : d % 5 === 0 ? 15 : 8;
    const a = pt(d, R), b = pt(d, R - len);
    svg.append(svgEl('line', { x1: a[0], y1: a[1], x2: b[0], y2: b[1], class: 'svg-ink', 'stroke-width': d % 10 === 0 ? 1.6 : 1, opacity: d % 5 === 0 ? 1 : 0.55 }));
    if (d % 10 === 0 && d !== 0) {
      const l = pt(d, R - 40);
      svg.append(svgEl('text', { x: l[0], y: l[1] + 4, class: 'svg-label', 'text-anchor': 'middle' }, Math.abs(d) + '°'));
    }
  }
  svg.append(svgEl('path', { d: `M ${f(pt(-MAXA, R))} A ${R} ${R} 0 0 0 ${f(pt(MAXA, R))}`, fill: 'none', class: 'svg-ink', 'stroke-width': 1, opacity: 0.6 }));
  // true horizontal
  svg.append(svgEl('line', { x1: ox, y1: oy, x2: ox + R + 12, y2: oy, class: 'svg-ink', 'stroke-width': 1.4, 'stroke-dasharray': '5 4' }));
  svg.append(svgEl('text', { x: ox + R + 14, y: oy + 4, class: 'svg-label', 'text-anchor': 'end', dy: -8 }, '0°'));

  if (th != null) {
    const tc = clamp(th, -MAXA, MAXA);
    // error band edges
    if (se != null && Number.isFinite(se) && se > 0) {
      for (const e of [tc - se, tc + se]) {
        const ec = clamp(e, -MAXA, MAXA), p = pt(ec, R);
        svg.append(svgEl('line', { x1: ox, y1: oy, x2: p[0], y2: p[1], class: 'svg-needle', 'stroke-width': 1, opacity: 0.45, 'stroke-dasharray': '2 3' }));
      }
    }
    const tip = pt(tc, R + 6);
    svg.append(svgEl('line', { x1: ox, y1: oy, x2: tip[0], y2: tip[1], class: 'svg-needle', 'stroke-width': 3.2, 'stroke-linecap': 'round' }));
    // small angle arc near the pivot
    if (Math.abs(tc) > 0.3) {
      svg.append(svgEl('path', { d: `M ${f(pt(0, 74))} A 74 74 0 0 ${tc > 0 ? 0 : 1} ${f(pt(tc, 74))}`, fill: 'none', class: 'svg-needle', 'stroke-width': 2 }));
    }
  }
  svg.append(svgEl('circle', { cx: ox, cy: oy, r: 5, fill: 'var(--ink)' }));
  svg.setAttribute('aria-label', th == null ? 'Angle dial' : `Angle dial ${signed(th)} degrees`);
}

// ---------------------------------------------------------- histogram (to scale)
function renderHist(res) {
  const svg = $('hist');
  svg.replaceChildren();
  if (!res || !res.hist) return;
  const h = res.hist, ml = 26, mr = 8, mt = 6, mb = 22, W = 320, H = 120;
  const pw = W - ml - mr, ph = H - mt - mb;
  const span = h.counts.length * h.binDeg;
  const peak = Math.max(...h.counts, 1);
  const xOf = (deg) => ml + (deg - h.lo) / span * pw;
  h.counts.forEach((c, i) => {
    if (!c) return;
    const x = xOf(h.lo + i * h.binDeg), bw = pw / h.counts.length;
    const bh = c / peak * ph;
    svg.append(svgEl('rect', { x: x + 0.5, y: mt + ph - bh, width: Math.max(bw - 1, 1), height: bh, fill: 'var(--scale)', opacity: 0.8 }));
  });
  svg.append(svgEl('line', { x1: ml, y1: mt + ph, x2: ml + pw, y2: mt + ph, class: 'svg-ink', 'stroke-width': 1 }));
  for (let d = Math.ceil(h.lo / 2) * 2; d <= h.lo + span; d += 2) {
    const x = xOf(d);
    svg.append(svgEl('line', { x1: x, y1: mt + ph, x2: x, y2: mt + ph + 4, class: 'svg-ink', 'stroke-width': 1 }));
    if (d % 4 === 0) svg.append(svgEl('text', { x, y: H - 6, class: 'svg-label', 'text-anchor': 'middle' }, String(d)));
  }
  svg.append(svgEl('text', { x: ml - 4, y: mt + 9, class: 'svg-label', 'text-anchor': 'end' }, String(peak)));
  if (res.median != null) {
    const x = xOf(res.median);
    svg.append(svgEl('line', { x1: x, y1: mt, x2: x, y2: mt + ph, class: 'svg-needle', 'stroke-width': 2 }));
  }
}

// ---------------------------------------------------------- mouse diagram
function renderWedge(th, dim) {
  const svg = $('wedge');
  svg.replaceChildren();
  const cx = 130, cy = 150;
  const g = (extra, stroke, dash, fill) => {
    const grp = svgEl('g', extra);
    grp.append(svgEl('rect', { x: cx - 34, y: cy - 56, width: 68, height: 112, rx: 30, fill: fill || 'none', stroke, 'stroke-width': 2, 'stroke-dasharray': dash || '' }));
    grp.append(svgEl('line', { x1: cx - 34, y1: cy - 14, x2: cx + 34, y2: cy - 14, stroke, 'stroke-width': 1.5, 'stroke-dasharray': dash || '' }));
    grp.append(svgEl('line', { x1: cx, y1: cy - 56, x2: cx, y2: cy - 14, stroke, 'stroke-width': 1.5, 'stroke-dasharray': dash || '' }));
    grp.append(svgEl('rect', { x: cx - 4, y: cy - 44, width: 8, height: 18, rx: 4, fill: stroke, opacity: 0.8 }));
    return grp;
  };
  const g0 = svgEl('g', { opacity: dim ? 0.45 : 1 });
  // reference axis + ghost mouse (current position)
  g0.append(svgEl('line', { x1: cx, y1: cy, x2: cx, y2: cy - 124, class: 'svg-ink', 'stroke-width': 1.2, 'stroke-dasharray': '5 4' }));
  g0.append(g({}, 'var(--ink-2)', '5 4'));
  if (th != null && Math.abs(th) >= 0.2) {
    const a = -th; // SVG rotate() is clockwise; a positive theta is rotated counter-clockwise
    const P = (ang, r) => [cx + r * Math.sin(ang * Math.PI / 180), cy - r * Math.cos(ang * Math.PI / 180)];
    const r = 104, p0 = P(0, r), p1 = P(a, r);
    const f = (p) => p[0].toFixed(2) + ' ' + p[1].toFixed(2);
    g0.append(svgEl('path', { d: `M ${cx} ${cy} L ${f(p0)} A ${r} ${r} 0 0 ${a < 0 ? 0 : 1} ${f(p1)} Z`, class: 'svg-fill' }));
    g0.append(svgEl('line', { x1: cx, y1: cy, x2: P(a, 124)[0], y2: P(a, 124)[1], class: 'svg-needle', 'stroke-width': 2.4 }));
    g0.append(g({ transform: `rotate(${a} ${cx} ${cy})` }, 'var(--needle)', '', 'var(--needle-soft)'));
    const mid = P(a / 2, 136), key = th > 0 ? 'wedgeCCW' : 'wedgeCW';
    g0.append(svgEl('text', { x: mid[0], y: mid[1] + 4, 'text-anchor': a < 0 ? 'end' : 'start', fill: 'var(--needle)', 'font-size': 13, 'font-weight': 600, 'font-family': 'var(--font-mono)' }, t(key, { a: num(Math.abs(th)) })));
  }
  svg.append(g0);
}

// ------------------------------------------------------------------ result
function renderResult() {
  const r = S.result, res = r.res;
  const th = res.median;
  const savedTag = $('rdSaved');
  savedTag.hidden = r.source !== 'saved';
  if (!savedTag.hidden) { const d = shortDate(S.last && S.last.at); savedTag.textContent = t(d ? 'savedResult' : 'savedResultNoDate', { date: d }); }
  $('savedCaution').hidden = !(r.source === 'saved' && S.pendingApply);
  $('statsBox').hidden = r.source === 'saved';
  $('rdTheta').textContent = th == null ? '--' : signed(th) + '°';
  $('rdSe').textContent = th == null || res.n < 2 ? '' : '±' + num(res.se) + '°';
  let sentence;
  if (th == null || res.confidence === 'insufficient') sentence = t('sentenceNone');
  else if (Math.abs(th) < 0.05) sentence = t('sentenceFlat');
  else sentence = t(th > 0 ? 'sentenceUp' : 'sentenceDown', { a: num(Math.abs(th)) });
  $('rdSentence').textContent = sentence;
  const conf = $('rdConf');
  conf.dataset.level = res.confidence;
  conf.textContent = res.confidence === 'insufficient'
    ? t('confInsufficient', { n: res.n, need: A.DEFAULTS.minStrokes })
    : t({ high: 'confHigh', medium: 'confMedium', low: 'confLow' }[res.confidence]);

  const w = $('rdWarnings');
  w.replaceChildren();
  const add = (txt) => { const li = document.createElement('li'); li.textContent = txt; w.append(li); };
  if (res.warnings.includes('few-strokes') && res.n > 0) add(t('warnFew'));
  if (res.warnings.includes('wrist-arc')) add(t('warnWrist', { d: num(Math.abs(res.lrDiff)), r: signed(res.rightMedian), l: signed(res.leftMedian) }));

  renderDial(th, res.n >= 2 ? res.se : null);
  renderStats(res);
  renderHist(res);
  renderHints();
}

function renderStats(res) {
  const c = S.capture;
  $('btnDownloadCsv').disabled = !c;
  $('csvInfo').textContent = c ? t('csvInfo', { n: c.events, s: num(A.captureSeconds(c.samples)) }) : t('csvNone');
  const dl = $('statsList');
  dl.replaceChildren();
  const rows = [
    ['stMedian', signed(res.median, 2) + '°'],
    ['stWMedian', signed(res.weightedMedian, 2) + '°'],
    ['stMean', signed(res.mean, 2) + '°'],
    ['stStd', num(res.std, 2) + '°'],
    ['stN', String(res.n)],
    ['stSe', res.n ? '±' + num(res.se, 2) + '°' : '--'],
    ['stRight', signed(res.rightMedian, 2) + '°  (n=' + res.rightN + ')'],
    ['stLeft', signed(res.leftMedian, 2) + '°  (n=' + res.leftN + ')'],
    ['stPca', signed(res.pca, 2) + '°']
  ];
  if (res.minLen) rows.push(['stMinLen', Math.round(res.minLen) + ' counts']);
  for (const [k, v] of rows) {
    const dt = document.createElement('dt'), dd = document.createElement('dd');
    dt.textContent = t(k); dd.textContent = v;
    dl.append(dt, dd);
  }
}

function driverInactive() {
  if (S.path !== 'software' || !S.before) return false;
  const th = theta();
  return th != null && Math.abs(S.before.theta) >= 2 && Math.abs(th - S.before.theta) < 1.5;
}

// A gentle note when the swipes disagree (never blocks anything), the before/after numbers, and the driver hint.
function renderHints() {
  const r = S.result;
  $('shakyBox').hidden = isSaved() || !A.isShaky(r.res);
  $('btnShaky').disabled = S.measuring;
  const show = S.mode === 'remeasure' && r.remeasured && r.res.confidence !== 'insufficient' && r.res.median != null;
  const ba = $('beforeAfter');
  ba.hidden = !(show && S.before);
  if (!ba.hidden) ba.textContent = t('beforeAfter', { a: signed(S.before.theta), b: signed(r.res.median) });
  $('driverHint').hidden = !(show && Math.abs(r.res.median) > A.THRESHOLDS.software && driverInactive());
}

// ---------------------------------------------------------------- fix paths
function renderFix() {
  const th = theta();
  const ok = canCopy();
  const rot = measuredForCommand();
  const cmd = $('cmdInstall');
  cmd.textContent = installCommand(rot);
  cmd.classList.toggle('dim', !ok);
  $('btnDownload').disabled = !ok;
  $('btnFallbackDownload').disabled = !ok;
  $('btnCopyInstall').disabled = !ok;
  const note = $('cmdNote');
  if (!ok) note.textContent = '';
  else if (Math.abs(th) < 0.5) note.textContent = t('cmdNoteTiny', { r: signed(th) });
  else note.textContent = t('cmdNoteReady', { r: signed(rot) });

  // the measured number under the main button; when it is already good, say so and make the buttons secondary
  const again = !!S.result && S.result.remeasured;
  $('applyAmount').textContent = ok ? t(again ? 'applyAmountAgain' : 'applyAmount', { r: signed(rot) + '°' }) : '';
  const goodWin = ok && A.verdict(th, 'software') === 'pass';
  const goodPhys = ok && A.verdict(th, 'physical') === 'pass';
  $('goodWin').hidden = !goodWin;
  $('goodPhys').hidden = !goodPhys;
  for (const [id, good] of [['btnDownload', goodWin], ['btnApply', goodWin], ['btnRemeasurePhys', goodPhys]]) {
    $(id).classList.toggle('accent', !good);
    $(id).classList.toggle('ghost', good);
  }

  // one-click link (mousecal:// protocol, registered by an earlier install); only the measured angle is in the link
  const tooBig = ok && !oneClickOk(rot);
  $('ocUrl').textContent = ok && !tooBig ? applyUrl(rot) : '';
  $('ocUrl').classList.toggle('dim', !ok || tooBig);
  $('ocState').textContent = tooBig ? t('ocTooBig', { r: signed(rot) }) : '';
  $('btnApply').disabled = !ok;

  // physical path
  const instr = $('physInstr');
  if (th == null) instr.textContent = t('physInstrNoData');
  else if (Math.abs(th) < 0.5) instr.textContent = t('physInstrNone');
  else instr.textContent = t(th > 0 ? 'physInstrCCW' : 'physInstrCW', { a: num(Math.abs(th)) });
  renderWedge(th, false);
  for (const id of REMEASURE_BTNS) $(id).disabled = S.measuring;

  // advanced
  let json = '';
  try { json = A.rawAccelSettings(SETTINGS_TEMPLATE, rot); } catch { json = ''; }
  $('jsonOut').value = json;
  $('btnCopyJson').disabled = !ok;
  $('btnDownloadJson').disabled = !ok;
}

function oneClickOk(rot) {
  return Math.abs(Number(formatRotation(rot))) <= ONE_CLICK_MAX;
}

function renderBanner() {
  const b = $('modeBanner');
  b.replaceChildren();
  if (S.mode !== 'remeasure') { b.hidden = true; return; }
  b.hidden = false;
  const span = document.createElement('span');
  span.textContent = t(S.path === 'software' ? 'modeReWin' : S.path === 'physical' ? 'modeRePhys' : 'modeReAny');
  b.append(span);   // starting over lives in one place only: the welcome band's reset link
}

function renderWelcome() {
  const l = S.last, show = !!l && (!S.result || isSaved()) && !S.measuring;
  $('welcome').hidden = !show;
  if (!show) return;
  const date = shortDate(l.at);
  $('welcomeText').textContent = t(date ? 'welcomeBack' : 'welcomeBackNoDate', { theta: signed(l.theta), date });
}

function renderAll() {
  applyI18n();
  const has = !!S.result;
  for (const id of ['result', 'fix', 'advanced']) $(id).hidden = !has;
  renderWelcome();
  renderBar();
  renderSteps();
  renderBanner();
  if (has) { renderResult(); renderFix(); }
  else for (const id of REMEASURE_BTNS) $(id).disabled = S.measuring;
  $('accelWarn').hidden = S.unadjusted !== false;
  if (!S.measuring) {
    const r = S.result;
    $('padStatus').textContent = S.attempt
      ? t('statusNeedMore', { n: S.attempt.n, need: A.DEFAULTS.minStrokes })
      : r && !isSaved() ? t('statusDone', { n: r.res.n }) : t('statusIdle');
    document.querySelector('.pad-cta').textContent = t(r && !isSaved() ? 'padIdleDone' : 'padIdle');
  }
  drawPad();
}

// ----------------------------------------------------- mousecal:// links
// Blur / visibility detection of protocol handlers is unreliable, so nothing branches on it. One click on
// "Apply the fix" / "Uninstall" does: (1) open the link, (2) show the "press Open / Yes" hint at once,
// (3) after FALLBACK_DELAY_MS show, and keep showing, a "No reaction? Download the installer" button for the case
// where nothing happened (not installed yet). Nothing is ever downloaded or copied without a click on that button.
// Only the two links from commands.js are ever opened.
const FALLBACK_DELAY_MS = 3000;

function say(msgEl, key, vars) {
  clearTimeout(msgEl._t);
  msgEl.textContent = t(key, vars);
}

// The user started a fix: remember it (per-browser) so the sticky "measure again" bar can show.
function markPending(path) {
  S.path = path;
  S.pendingApply = true;
  save();
  renderBar();
}
function renderBar() {
  // one "measure again" entry at a time: the welcome band already has the big button at the top
  const bar = S.pendingApply && !S.measuring && $('welcome').hidden;
  $('remeasureBar').hidden = !bar;
  document.body.classList.toggle('has-bar', bar);
}

// ---------------------------------------------------- downloaded launcher (.cmd)
// The launcher is built here from commands.js (so it always carries the SHA256 of the setup.ps1 deployed with this
// page) and handed to the browser as a file. The page never runs it.
function launcherOptions(mode) {
  return mode === 'uninstall' ? { mode, restoreEpp: restoreEpp() } : { mode, measured: measuredForCommand() };
}
function launcherName(mode) {
  return launcherFilename(mode, measuredForCommand());
}
function downloadLauncher(mode) {
  if (S.measuring || (mode === 'install' && !canCopy())) return false;
  const text = launcherCmd(launcherOptions(mode));
  const blob = new Blob([text], { type: 'application/octet-stream' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = launcherName(mode);
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  return true;
}
function showSteps(boxId) {
  const box = $(boxId);
  box.hidden = false;
  box.classList.toggle('compact', boxId === 'unManual' || S.installed);   // known to work before: smaller, but never hidden
  renderSteps();
  if (box.scrollIntoView) box.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'nearest' });
}
function doDownload(mode) {
  if (!downloadLauncher(mode)) return;
  if (mode === 'install') {
    markPending('software');
    say($('dlMsg'), 'dlStarted', { file: launcherName('install') });
    showSteps('manualSteps');
  } else {
    say($('oneClickUnMsg'), 'dlStarted', { file: launcherName('uninstall') });
    showSteps('unManual');
  }
}
// The file name inside step 1 depends on the measured angle (and on the language of the sentence).
function renderSteps() {
  $('dlStep1').textContent = t('dlS1', { file: launcherName('install') });
  $('unStep1').textContent = t('unS1', { file: launcherName('uninstall') });
}

// Opens a mousecal:// link and, if nothing seems to happen, offers the download. url null = no link possible.
function runLinkAction({ url, msgEl, fallbackId }) {
  const box = $(fallbackId);
  clearTimeout(box._t);
  box.hidden = true;
  if (!url) {            // no link possible (angle beyond the one-click limit): the download is the way
    msgEl.textContent = '';
    box.hidden = false;
    return;
  }
  say(msgEl, 'applyPrompt');
  box._t = setTimeout(() => { box.hidden = false; }, FALLBACK_DELAY_MS);
  window.location.assign(url);
}

function doApply() {
  if (!canCopy() || S.measuring) return;
  const rot = measuredForCommand();
  let url = null;
  if (oneClickOk(rot)) { try { url = applyUrl(rot); } catch { url = null; } }
  markPending('software');
  runLinkAction({ url, msgEl: $('oneClickMsg'), fallbackId: 'fallbackBox' });
}

// The footer checkbox: also put Windows "Enhance pointer precision" back (checked by default).
const restoreEpp = () => $('unRestoreEpp').checked;
function refreshUninstall() {
  $('cmdUninstall').textContent = uninstallCommand(restoreEpp());
  $('unUrl').textContent = uninstallUrl(restoreEpp());
}

function doUninstall() {
  if (S.measuring) return;
  refreshUninstall();
  runLinkAction({ url: uninstallUrl(restoreEpp()), msgEl: $('oneClickUnMsg'), fallbackId: 'unFallbackBox' });
}

// -------------------------------------------------------------- copy helper
function selectNode(node) {
  try {
    if (node.select) { node.focus(); node.select(); }
    else { const rg = document.createRange(); rg.selectNodeContents(node); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(rg); }
    return true;
  } catch { return false; }
}
// true ONLY when the text really was written: the promise is awaited, a rejection / exception / no answer in time
// (a blocker such as uBlock Origin's clipboard protection, a denied permission) counts as "not copied".
const CLIPBOARD_TIMEOUT_MS = 1500;
async function copyQuiet(text, node) {
  let timer = 0;
  try {
    if (navigator.clipboard && window.isSecureContext) {
      const slow = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('clipboard timeout')), CLIPBOARD_TIMEOUT_MS); });
      await Promise.race([navigator.clipboard.writeText(text), slow]);
      return true;
    }
  } catch { /* fall through to selection */ }
  finally { clearTimeout(timer); }
  try {
    // execCommand needs a visible, selected node; a hidden one proves nothing
    if (node && node.offsetParent !== null && selectNode(node) && document.execCommand && document.execCommand('copy')) return true;
  } catch { /* leave it selected */ }
  return false;
}
async function copyText(text, node, msgEl) {
  const ok = await copyQuiet(text, node);
  say(msgEl, ok ? 'copied' : 'copySelected');
  if (ok) msgEl._t = setTimeout(() => { msgEl.textContent = ''; }, 4000);
  return ok;
}

// ---------------------------------------------------------------- pad drawing
const padCanvas = () => $('pad');
function cssVar(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

function drawPad() {
  const cv = padCanvas(), ctx = cv.getContext('2d');
  const dpr = window.devicePixelRatio || 1, w = cv.clientWidth, h = cv.clientHeight;
  if (!w || !h) return;
  if (cv.width !== Math.round(w * dpr) || cv.height !== Math.round(h * dpr)) { cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr); }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  const ink = cssVar('--ink'), ink2 = cssVar('--ink-2'), rule = cssVar('--rule'), needle = cssVar('--needle');
  const cx = w / 2, cy = S.measuring ? h * 0.56 : h * 0.5;

  // reference: true horizontal, +-5 / +-10 deg guides, ticks
  ctx.lineWidth = 1;
  for (const d of [-10, -5, 5, 10]) {
    const a = d * Math.PI / 180, L = w * 0.46;
    ctx.strokeStyle = rule; ctx.globalAlpha = 0.9;
    ctx.beginPath(); ctx.moveTo(cx - Math.cos(a) * L, cy + Math.sin(a) * L); ctx.lineTo(cx + Math.cos(a) * L, cy - Math.sin(a) * L); ctx.stroke();
    ctx.globalAlpha = 1; ctx.fillStyle = ink2; ctx.font = '10px ' + cssVar('--font-mono');
    ctx.fillText(Math.abs(d) + '°', cx + Math.cos(a) * L - 22, cy - Math.sin(a) * L + (d > 0 ? -4 : 12));
  }
  ctx.strokeStyle = ink; ctx.setLineDash([6, 5]); ctx.beginPath(); ctx.moveTo(w * 0.04, cy); ctx.lineTo(w * 0.96, cy); ctx.stroke(); ctx.setLineDash([]);
  for (let x = w * 0.04; x <= w * 0.96; x += w * 0.92 / 40) { ctx.beginPath(); ctx.moveTo(x, cy - 3); ctx.lineTo(x, cy + 3); ctx.stroke(); }

  if (S.measuring) {
    const now = performance.now();
    const pts = S.trail;
    if (pts.length > 1) {
      let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
      for (const p of pts) { x0 = Math.min(x0, p.x); x1 = Math.max(x1, p.x); y0 = Math.min(y0, p.y); y1 = Math.max(y1, p.y); }
      const target = Math.min((w * 0.84) / Math.max(x1 - x0, 80), (h * 0.5) / Math.max(y1 - y0, 40));
      S.viewScale = S.viewScale ? S.viewScale + (target - S.viewScale) * 0.15 : target;
      const mx = (x0 + x1) / 2, my = (y0 + y1) / 2, k = S.viewScale;
      ctx.lineCap = 'round'; ctx.lineWidth = 2;
      ctx.strokeStyle = needle;
      for (let i = 1; i < pts.length; i++) {
        ctx.globalAlpha = clamp(1 - (now - pts[i].t) / 2500, 0.06, 1);
        ctx.beginPath();
        ctx.moveTo(cx + (pts[i - 1].x - mx) * k, cy + (pts[i - 1].y - my) * k);
        ctx.lineTo(cx + (pts[i].x - mx) * k, cy + (pts[i].y - my) * k);
        ctx.stroke();
      }
      ctx.globalAlpha = 1; ctx.fillStyle = ink;
      const last = pts[pts.length - 1];
      ctx.beginPath(); ctx.arc(cx + (last.x - mx) * k, cy + (last.y - my) * k, 4, 0, 7); ctx.fill();
    }
    drawTimer(ctx, w, h, now, { ink, ink2, rule, needle });
  } else if (S.result && S.result.res.strokes.length) {
    // fan of every stroke (flipped to point right so the angle is what you see) + the median line
    const strokes = S.result.res.strokes;
    const maxLen = Math.max(...strokes.map((s) => s.len));
    const k = (w * 0.8) / maxLen;
    ctx.lineWidth = 1.5; ctx.strokeStyle = needle; ctx.globalAlpha = 0.22;
    for (const s of strokes) {
      const sx = s.dx * k / 2, sy = s.dy * k / 2;
      ctx.beginPath(); ctx.moveTo(cx - sx, cy - sy); ctx.lineTo(cx + sx, cy + sy); ctx.stroke();
    }
    ctx.globalAlpha = 1; ctx.lineWidth = 3;
    const m = S.result.res.median * Math.PI / 180, L = w * 0.4;
    ctx.beginPath(); ctx.moveTo(cx - Math.cos(m) * L, cy + Math.sin(m) * L); ctx.lineTo(cx + Math.cos(m) * L, cy - Math.sin(m) * L); ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

// Big countdown + progress bar + live stroke count, drawn inside the canvas while measuring.
function drawTimer(ctx, w, h, now, c) {
  const mono = cssVar('--font-mono'), sans = cssVar('--font-sans');
  const hud = $('hud').offsetHeight || 0;
  ctx.textAlign = 'center';
  if (S.phase === 'ready') {
    ctx.fillStyle = c.ink; ctx.font = `700 ${Math.round(clamp(w * 0.09, 26, 44))}px ${sans}`;
    ctx.fillText(t('padReady'), w / 2, h * 0.3);
    ctx.fillStyle = c.ink2; ctx.font = `400 ${Math.round(clamp(w * 0.034, 12, 16))}px ${sans}`;
    ctx.fillText(t('padReadySub'), w / 2, h * 0.3 + 26);
    ctx.textAlign = 'start';
    return;
  }
  const left = Math.max(0, S.endAt - now);
  const winStart = S.extended ? S.firstT + BASE_MS : S.firstT;
  const frac = clamp((now - winStart) / (S.endAt - winStart), 0, 1);
  const secs = Math.ceil(left / 1000);
  const top = hud + 8, fs = Math.round(clamp(w * 0.12, 36, 64));
  ctx.fillStyle = S.phase === 'extend' ? c.needle : c.ink;
  ctx.font = `600 ${fs}px ${mono}`;
  ctx.textBaseline = 'top';
  ctx.fillText(String(secs), w / 2, top);
  const bw = w * 0.6, bx = (w - bw) / 2, by = top + fs + 6;
  ctx.fillStyle = c.rule; ctx.fillRect(bx, by, bw, 6);
  ctx.fillStyle = c.needle; ctx.fillRect(bx, by, bw * frac, 6);
  ctx.fillStyle = S.phase === 'extend' ? c.needle : c.ink2;
  ctx.font = `${S.phase === 'extend' ? 700 : 500} ${Math.round(clamp(w * 0.034, 12, 16))}px ${sans}`;
  const line = S.phase === 'extend' ? t('padMore') + ' · ' : '';
  ctx.fillText(line + t('padStrokes', { n: S.liveN || 0, need: A.DEFAULTS.minStrokes }), w / 2, by + 14);
  ctx.textAlign = 'start'; ctx.textBaseline = 'alphabetic';
}

function rafLoop() {
  drawPad();
  timers.raf = S.measuring ? requestAnimationFrame(rafLoop) : 0;
}

// -------------------------------------------------------------- measuring
function setStatus(msg) { $('padStatus').textContent = msg; }

async function startLock() {
  if (S.measuring || lockPending) return;
  const pad = padCanvas();
  if (typeof pad.requestPointerLock !== 'function') { $('noLockNotice').hidden = false; return; }
  lockPending = true;
  S.unadjusted = null;
  try {
    let p;
    try {
      p = pad.requestPointerLock({ unadjustedMovement: true });
      if (p && typeof p.then === 'function') { await p; S.unadjusted = true; }
      else S.unadjusted = false; // old browser: option ignored, cannot confirm raw input
    } catch (err) {
      if (err && err.name === 'NotSupportedError') {
        // platform cannot give raw movement: plain lock, results may include OS acceleration
        const p2 = pad.requestPointerLock();
        if (p2 && typeof p2.then === 'function') await p2;
        S.unadjusted = false;
      } else throw err;
    }
  } catch (err) {
    setStatus(t('lockErr', { err: (err && err.name) || 'error' }));
  } finally {
    lockPending = false;
  }
}

function onLockChange() {
  const locked = document.pointerLockElement === padCanvas();
  if (locked && !S.measuring) beginMeasure();
  else if (!locked && S.measuring) endMeasure();
}

// Locked: show "get ready"; the countdown starts on the FIRST movement (see onMove).
function beginMeasure() {
  S.measuring = true;
  S.phase = 'ready'; S.extended = false; S.firstT = 0; S.endAt = 0; S.endT = 0; S.liveN = 0;
  S.samples = []; S.events = 0; S.trail = []; S.px = 0; S.py = 0; S.viewScale = 0;
  S.attempt = null;
  document.querySelector('.pad-frame').classList.add('locked');
  $('hud').hidden = false;
  $('hudTheta').textContent = '--';
  for (const id of REMEASURE_BTNS) $(id).disabled = true;
  renderBar(); renderWelcome();
  setStatus(t('statusReady'));
  document.addEventListener('mousemove', onMove);
  timers.live = setInterval(tick, 100);
  rafLoop();
}

function onMove(e) {
  if (document.pointerLockElement !== padCanvas()) return;
  const dx = e.movementX || 0, dy = e.movementY || 0;
  S.events++;
  if (!dx && !dy) return;
  const t0 = e.timeStamp || performance.now();
  const now = performance.now();
  if (S.phase === 'ready') {
    S.phase = 'run'; S.firstT = t0; S.endAt = t0 + BASE_MS;
    setStatus(t('statusMeasuring'));
  }
  S.samples.push({ t: t0, dx, dy });
  S.px += dx; S.py += dy;
  S.trail.push({ x: S.px, y: S.py, t: now });
  while (S.trail.length && now - S.trail[0].t > 2500) S.trail.shift();
}

// The recording as it would be scored if it ended at endT (tail trimmed, last partial stroke dropped).
function scoreAt(endT) {
  return A.analyzeTimed(S.samples, endT);
}

function tick() {
  if (!S.measuring || S.phase === 'ready') return;
  const now = performance.now();
  const r = scoreAt(now);
  S.liveN = r.n;
  $('hudTheta').textContent = r.n >= 3 ? signed(r.median) + '°' : '--';
  if (S.mode === 'remeasure' && S.path === 'physical' && r.n >= 3) renderWedge(r.median, false);
  if (now < S.endAt) return;
  if (!S.extended && r.n < A.DEFAULTS.minStrokes) {
    // fewer than 15 valid strokes at 10 s: a few more seconds (20 s in total), then stop
    S.extended = true; S.phase = 'extend'; S.endAt = S.firstT + MAX_MS;
    setStatus(t('statusExtended'));
  } else {
    S.endT = now;
    document.exitPointerLock();
  }
}

function endMeasure() {
  S.measuring = false;
  clearInterval(timers.live);
  document.removeEventListener('mousemove', onMove);
  document.querySelector('.pad-frame').classList.remove('locked');
  $('hud').hidden = true;
  const endT = S.endT || performance.now();
  S.phase = 'idle';

  S.capture = { samples: S.samples.slice(), events: S.events, unadjusted: S.unadjusted === true };
  const res = scoreAt(endT);
  if (res.confidence !== 'insufficient') {
    const prev = S.last;
    if (S.mode === 'remeasure' && !S.before && prev) S.before = { theta: prev.theta };
    const remeasured = S.mode === 'remeasure';
    S.result = { res, source: 'measured', remeasured };
    S.attempt = null;
    S.last = { theta: res.median, se: res.se, n: res.n, at: Date.now() };
    S.pendingApply = false;
    S.installed = installedAfter(S.installed, { remeasured, path: S.path, pass: A.verdict(res.median, verdictPath(S.path)) === 'pass' });
    if (!remeasured) S.before = { theta: res.median };
  } else {
    S.attempt = { n: res.n };
  }
  save();
  renderAll();
  if (S.attempt) return;
  const target = $('result');
  if (target && target.scrollIntoView) target.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'start' });
}

// --------------------------------------------------------------- remeasure
// Every "measure again" entry point starts straight away: the click is the user gesture pointer lock needs,
// and the "get ready" phase waits for the first movement before any clock runs.
function startRemeasure(path) {
  if (S.measuring) return;
  S.mode = 'remeasure';
  if (path) S.path = path;
  if (S.result) S.result.remeasured = false; // the next measurement is the one that counts
  if (!S.before) {
    if (S.result) S.before = { theta: S.result.res.median };
    else if (S.last) S.before = { theta: S.last.theta };
  }
  const pad = padCanvas();
  if (S.finePointer) startLock();
  renderAll();
  pad.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'center' });
  pad.focus({ preventScroll: true });
}

function restartFresh() {
  if (S.measuring) return;
  clearStore();
  S.last = null; S.path = null; S.pendingApply = false; S.installed = false;
  S.before = null; S.result = null; S.attempt = null; S.mode = 'measure';
  renderAll();
}

// -------------------------------------------------------------------- init
function init() {
  load();
  // a returning visitor goes straight to re-measuring, compared with the last result
  // and sees that result again (marked as last time's), so the fix works without measuring first
  if (S.last) { S.mode = 'remeasure'; S.before = { theta: S.last.theta }; S.result = savedResult(S.last); }

  const isWin = /Windows/i.test(navigator.userAgent) || (navigator.userAgentData && navigator.userAgentData.platform === 'Windows');
  $('fix').dataset.first = isWin ? 'win' : 'phys';

  const finePointer = !window.matchMedia || window.matchMedia('(any-pointer: fine)').matches;
  S.finePointer = finePointer;
  $('touchNotice').hidden = finePointer;
  if (!finePointer) padCanvas().setAttribute('aria-disabled', 'true');
  if (typeof padCanvas().requestPointerLock !== 'function') $('noLockNotice').hidden = false;

  const pad = padCanvas();
  pad.addEventListener('click', () => { if (finePointer) startLock(); });
  pad.addEventListener('keydown', (e) => { if ((e.key === 'Enter' || e.key === ' ') && finePointer && !S.measuring) { e.preventDefault(); startLock(); } });
  document.addEventListener('pointerlockchange', onLockChange);
  document.addEventListener('pointerlockerror', () => { if (!lockPending && !S.measuring) setStatus(t('lockErr', { err: 'pointerlockerror' })); });
  $('langBtn').addEventListener('click', () => { S.lang = S.lang === 'zh' ? 'en' : 'zh'; save(); renderAll(); });

  $('btnWelcome').addEventListener('click', () => startRemeasure(S.path));
  $('btnWelcomeReset').addEventListener('click', restartFresh);
  $('btnBar').addEventListener('click', () => startRemeasure(S.path));

  $('btnApply').addEventListener('click', doApply);
  $('btnDownload').addEventListener('click', () => doDownload('install'));
  $('btnFallbackDownload').addEventListener('click', () => doDownload('install'));
  $('btnDownloadUn').addEventListener('click', () => doDownload('uninstall'));
  $('btnUnFallbackDownload').addEventListener('click', () => doDownload('uninstall'));
  $('setupHash').textContent = SETUP_SHA256;
  $('btnShaky').addEventListener('click', () => startRemeasure(S.path));
  $('btnOneClickUn').addEventListener('click', doUninstall);
  // Advanced: the old Win+R command, copy only (never done automatically)
  $('btnCopyInstall').addEventListener('click', async () => {
    if (!canCopy()) return;
    const ok = await copyText(installCommand(measuredForCommand()), $('cmdInstall'), $('copyInstallMsg'));
    $('psBox').querySelector('.copy-hint').hidden = ok;
    if (ok) markPending('software');
  });
  $('btnCopyUninstall').addEventListener('click', async () => {
    refreshUninstall();
    const ok = await copyText(uninstallCommand(restoreEpp()), $('cmdUninstall'), $('copyUninstallMsg'));
    $('psBox').querySelector('.copy-hint').hidden = ok;
    if (ok) markPending('software');
  });
  $('btnPickPhys').addEventListener('click', () => { markPending('physical'); say($('physPickMsg'), 'physPicked'); });
  $('btnRemeasureWin').addEventListener('click', () => startRemeasure('software'));
  $('btnRemeasurePhys').addEventListener('click', () => startRemeasure('physical'));
  $('btnCopyJson').addEventListener('click', () => copyText($('jsonOut').value, $('jsonOut'), $('copyJsonMsg')));
  $('btnDownloadJson').addEventListener('click', () => {
    const blob = new Blob([$('jsonOut').value], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = 'settings.json';
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  });

  $('btnDownloadCsv').addEventListener('click', () => {
    const c = S.capture;
    if (!c) return;
    const blob = new Blob([A.capturesToCsv(c.samples, c.unadjusted)], { type: 'text/csv' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob); a.download = A.captureFilename(new Date());
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  });

  if (window.ResizeObserver) new ResizeObserver(() => { if (!S.measuring) drawPad(); }).observe(pad);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener?.('change', () => { renderAll(); });
  // uninstall lives in the footer and never depends on a measurement
  $('unRestoreEpp').addEventListener('change', () => { refreshUninstall(); renderSteps(); });
  refreshUninstall();
  renderAll();
}

init();
