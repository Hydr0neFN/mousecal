// mousecal page logic: pointer-lock measurement, result rendering, fix paths.
import * as A from './analysis.js';
import { EXAMPLE } from './example.js';
import { SETTINGS_TEMPLATE } from './settings-template.js';
import { STRINGS } from './i18n.js';
import { installCommand, uninstallCommand, applyUrl, uninstallUrl, formatRotation, ONE_CLICK_MAX } from './commands.js';

const $ = (id) => document.getElementById(id);
const MAX_SECONDS = 30;
const STORE_KEY = 'mousecal.v1';
const SVGNS = 'http://www.w3.org/2000/svg';

// ------------------------------------------------------------------ state
const S = {
  lang: 'zh',
  result: null,            // { res, source: 'example' | 'measured' }
  mode: 'measure',         // 'measure' | 'remeasure'
  path: null,              // 'software' | 'physical' while remeasuring
  before: null,            // { theta } first valid measurement
  measuring: false,
  samples: [],
  trail: [],
  px: 0, py: 0,
  unadjusted: null,        // true / false once a lock was granted
  deadline: 0,
  viewScale: 0,
  live: null
};
let timers = { stop: 0, live: 0, raf: 0 };
let lockPending = false;

// ---------------------------------------------------------------- storage
function load() {
  try {
    const o = JSON.parse(localStorage.getItem(STORE_KEY) || '{}');
    if (o.lang === 'en' || o.lang === 'zh') S.lang = o.lang;
    if (o.before && Number.isFinite(o.before.theta)) S.before = { theta: o.before.theta };
  } catch { /* storage unavailable: run without persistence */ }
}
function save() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify({ lang: S.lang, before: S.before }));
  } catch { /* ignore */ }
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
  $('hudNeed').textContent = t('hudNeed', { n: A.DEFAULTS.minStrokes });
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

function theta() { return S.result && S.result.res.median != null ? S.result.res.median : null; }
function canCopy() {
  return !!S.result && S.result.source !== 'example' && S.result.res.confidence !== 'insufficient';
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
  const r = S.result, res = r.res, ex = r.source === 'example';
  const th = res.median;
  $('exampleStamp').hidden = !ex;
  $('exampleNote').hidden = !ex;
  $('rdTheta').textContent = th == null ? '--' : signed(th) + '°';
  $('rdSe').textContent = th == null || res.n < 2 ? '' : '±' + num(res.se) + '°';
  let sentence;
  if (th == null || res.confidence === 'insufficient' && !ex) sentence = t('sentenceNone');
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
  if (res.warnings.includes('inconsistent')) add(t('warnInconsistent', { s: num(res.std) }));
  if (res.confidence === 'low') add(t('warnLow'));

  renderDial(th, res.n >= 2 ? res.se : null);
  renderStats(res);
  renderHist(res);
  renderVerdict();
}

function renderStats(res) {
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

function renderVerdict() {
  const box = $('verdictBox');
  const r = S.result;
  const show = S.mode === 'remeasure' && S.path && r.remeasured && r.source !== 'example' && r.res.confidence !== 'insufficient' && r.res.median != null;
  box.hidden = !show;
  if (!show) return;
  const th = r.res.median, thr = A.THRESHOLDS[S.path];
  const ok = A.verdict(th, S.path) === 'pass';
  box.dataset.state = ok ? 'pass' : 'fail';
  const icon = $('verdictIcon');
  icon.replaceChildren(ok
    ? svgEl('polyline', { points: '4 12.5 9.5 18 20 6' })
    : svgEl('path', { d: 'M5 5 L19 19 M19 5 L5 19' }));
  $('verdictText').textContent = t(ok ? 'verdictPass' : 'verdictFail', { thr });
  $('beforeAfter').textContent = S.before ? t('beforeAfter', { a: signed(S.before.theta), b: signed(th) }) : '';
  $('beforeAfter').hidden = !S.before;
  const hint = !ok && driverInactive();
  $('driverHint').hidden = !hint;
  const fn = $('failNext');
  fn.hidden = ok || hint;
  if (!ok && !hint) {
    fn.textContent = S.path === 'software'
      ? t('failNextWin', { r: signed(th) })
      : t('failNextPhys', { a: num(Math.abs(th)), dir: t(th > 0 ? 'dirCCW' : 'dirCW') });
  }
}

// ---------------------------------------------------------------- fix paths
function renderFix() {
  const th = theta(), ex = !S.result || S.result.source === 'example';
  const ok = canCopy();
  const rot = measuredForCommand();
  const cmd = $('cmdInstall');
  cmd.textContent = installCommand(rot);
  cmd.classList.toggle('dim', !ok);
  $('btnCopyInstall').disabled = !ok;
  const note = $('cmdNote');
  if (ex) note.textContent = t('cmdNoteExample');
  else if (!ok) note.textContent = t('cmdNoteInsufficient');
  else if (Math.abs(th) < 0.5) note.textContent = t('cmdNoteTiny', { r: signed(th) });
  else note.textContent = t('cmdNoteReady', { r: signed(rot) });
  $('cmdUninstall').textContent = uninstallCommand();

  // one-click links (mousecal:// protocol, registered by an earlier install); only the measured angle is in the link
  const tooBig = ok && Math.abs(Number(formatRotation(rot))) > ONE_CLICK_MAX;
  const ocOk = ok && !tooBig;
  $('ocUrl').textContent = ocOk ? applyUrl(rot) : '';
  $('ocUrl').classList.toggle('dim', !ocOk);
  $('btnOneClick').disabled = !ocOk;
  $('ocState').textContent = ocOk ? '' : tooBig ? t('ocTooBig', { r: signed(rot) }) : t(ex ? 'cmdNoteExample' : 'cmdNoteInsufficient');
  $('unUrl').textContent = uninstallUrl();

  // physical path
  const instr = $('physInstr');
  if (th == null) instr.textContent = t('physInstrNoData');
  else if (ex) instr.textContent = t('physInstrNoData');
  else if (Math.abs(th) < 0.5) instr.textContent = t('physInstrNone');
  else instr.textContent = t(th > 0 ? 'physInstrCCW' : 'physInstrCW', { a: num(Math.abs(th)) });
  renderWedge(th, ex);
  $('btnRemeasureWin').disabled = S.measuring;
  $('btnRemeasurePhys').disabled = S.measuring;

  // advanced
  let json = '';
  try { json = A.rawAccelSettings(SETTINGS_TEMPLATE, rot); } catch { json = ''; }
  $('jsonOut').value = json;
  $('btnCopyJson').disabled = !ok;
  $('btnDownloadJson').disabled = !ok;
}

function renderBanner() {
  const b = $('modeBanner');
  b.replaceChildren();
  if (S.mode !== 'remeasure' || !S.path) { b.hidden = true; return; }
  b.hidden = false;
  const span = document.createElement('span');
  span.textContent = t(S.path === 'software' ? 'modeReWin' : 'modeRePhys', { thr: A.THRESHOLDS[S.path] }) + ' ';
  const back = document.createElement('button');
  back.type = 'button'; back.className = 'btn small ghost'; back.textContent = t('modeBack');
  back.addEventListener('click', () => { if (S.measuring) return; S.mode = 'measure'; S.path = null; renderAll(); });
  b.append(span, back);
}

function renderAll() {
  applyI18n();
  renderBanner();
  renderResult();
  renderFix();
  $('accelWarn').hidden = S.unadjusted !== false;
  if (!S.measuring) {
    const r = S.result;
    $('padStatus').textContent = r && r.source === 'measured'
      ? (r.res.confidence === 'insufficient' ? t('statusNeedMore', { n: r.res.n, need: A.DEFAULTS.minStrokes }) : t('statusDone', { n: r.res.n }))
      : t('statusIdle');
    document.querySelector('.pad-cta').textContent = t(r && r.source === 'measured' ? 'padIdleDone' : 'padIdle');
  }
  drawPad();
}

// ----------------------------------------------------- one-click (mousecal://)
// Opens the protocol link. If the page keeps focus for ~1.5 s (no browser prompt, no app window),
// the protocol is probably not registered: say so. Only the two links from commands.js are ever opened.
const ONE_CLICK_WAIT_MS = 1500;
function openOneClick(url, msgEl, notInstalledKey) {
  clearTimeout(msgEl._t);
  msgEl.textContent = '';
  let left = false;
  const leave = () => { left = true; };
  window.addEventListener('blur', leave, { once: true });
  const vis = () => { if (document.hidden) left = true; };
  document.addEventListener('visibilitychange', vis);
  msgEl._t = setTimeout(() => {
    window.removeEventListener('blur', leave);
    document.removeEventListener('visibilitychange', vis);
    if (!left && !document.hidden) msgEl.textContent = t(notInstalledKey);
  }, ONE_CLICK_WAIT_MS);
  window.location.assign(url);
}

// -------------------------------------------------------------- copy helper
async function copyText(text, node, msgEl) {
  const say = (k) => { msgEl.textContent = t(k); clearTimeout(msgEl._t); msgEl._t = setTimeout(() => { msgEl.textContent = ''; }, 4000); };
  try {
    if (navigator.clipboard && window.isSecureContext) { await navigator.clipboard.writeText(text); say('copied'); return true; }
  } catch { /* fall through to selection */ }
  try {
    if (node.select) { node.focus(); node.select(); }
    else { const rg = document.createRange(); rg.selectNodeContents(node); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(rg); }
    if (document.execCommand && document.execCommand('copy')) { say('copied'); return true; }
  } catch { /* leave it selected */ }
  say('copySelected');
  return false;
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

function beginMeasure() {
  S.measuring = true;
  S.samples = []; S.trail = []; S.px = 0; S.py = 0; S.viewScale = 0;
  S.deadline = performance.now() + MAX_SECONDS * 1000;
  document.querySelector('.pad-frame').classList.add('locked');
  $('hud').hidden = false;
  $('btnDone').disabled = false; $('btnReset').disabled = false;
  $('btnRemeasureWin').disabled = true; $('btnRemeasurePhys').disabled = true;
  setStatus(t('statusMeasuring'));
  document.addEventListener('mousemove', onMove);
  document.addEventListener('keydown', onKey, true);
  timers.stop = setTimeout(() => document.exitPointerLock(), MAX_SECONDS * 1000);
  timers.live = setInterval(liveUpdate, 250);
  liveUpdate();
  rafLoop();
}

function onMove(e) {
  if (document.pointerLockElement !== padCanvas()) return;
  const dx = e.movementX || 0, dy = e.movementY || 0;
  if (!dx && !dy) return;
  const t0 = e.timeStamp || performance.now();
  S.samples.push({ t: t0, dx, dy });
  S.px += dx; S.py += dy;
  const now = performance.now();
  S.trail.push({ x: S.px, y: S.py, t: now });
  while (S.trail.length && now - S.trail[0].t > 2500) S.trail.shift();
}

function onKey(e) {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); document.exitPointerLock(); }
}

function liveUpdate() {
  if (!S.measuring) return;
  const left = Math.max(0, Math.ceil((S.deadline - performance.now()) / 1000));
  $('hudTime').textContent = String(left);
  const r = A.analyze(S.samples);
  $('hudStrokes').textContent = String(r.n);
  $('hudStrokes').style.color = r.n >= A.DEFAULTS.minStrokes ? 'var(--pass)' : '';
  $('hudTheta').textContent = r.n >= 3 ? signed(r.median) + '°' : '--';
  if (S.mode === 'remeasure' && S.path === 'physical' && r.n >= 3) renderWedge(r.median, false);
}

function endMeasure() {
  S.measuring = false;
  clearTimeout(timers.stop); clearInterval(timers.live);
  document.removeEventListener('mousemove', onMove);
  document.removeEventListener('keydown', onKey, true);
  document.querySelector('.pad-frame').classList.remove('locked');
  $('hud').hidden = true;
  $('btnDone').disabled = true; $('btnReset').disabled = true;

  const res = A.analyze(S.samples);
  S.result = { res, source: 'measured', remeasured: S.mode === 'remeasure' };
  if (res.confidence !== 'insufficient') afterValidMeasurement(res);
  save();
  renderAll();
  const target = $('result');
  if (target && target.scrollIntoView) target.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'start' });
}

function afterValidMeasurement(res) {
  const th = res.median;
  if (S.mode === 'measure') S.before = { theta: th };
}

function resetMeasure() {
  if (!S.measuring) return;
  S.samples = []; S.trail = []; S.viewScale = 0;
  setStatus(t('statusReset'));
  liveUpdate();
}

// --------------------------------------------------------------- remeasure
function startRemeasure(path) {
  if (S.measuring) return;
  S.mode = 'remeasure'; S.path = path;
  if (S.result) S.result.remeasured = false; // the next measurement is the one that counts
  renderAll();
  const pad = padCanvas();
  pad.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'center' });
  pad.focus({ preventScroll: true });
}

// -------------------------------------------------------------------- init
function init() {
  load();
  const res = A.summarize(A.strokesFromVectors(EXAMPLE.strokes));
  S.result = { res, source: 'example' };

  const isWin = /Windows/i.test(navigator.userAgent) || (navigator.userAgentData && navigator.userAgentData.platform === 'Windows');
  $('fix').dataset.first = isWin ? 'win' : 'phys';

  const finePointer = !window.matchMedia || window.matchMedia('(any-pointer: fine)').matches;
  $('touchNotice').hidden = finePointer;
  if (!finePointer) padCanvas().setAttribute('aria-disabled', 'true');
  if (typeof padCanvas().requestPointerLock !== 'function') $('noLockNotice').hidden = false;

  const pad = padCanvas();
  pad.addEventListener('click', () => { if (finePointer) startLock(); });
  pad.addEventListener('keydown', (e) => { if ((e.key === 'Enter' || e.key === ' ') && finePointer && !S.measuring) { e.preventDefault(); startLock(); } });
  document.addEventListener('pointerlockchange', onLockChange);
  document.addEventListener('pointerlockerror', () => { if (!lockPending && !S.measuring) setStatus(t('lockErr', { err: 'pointerlockerror' })); });
  $('btnDone').addEventListener('click', () => document.exitPointerLock());
  $('btnReset').addEventListener('click', resetMeasure);
  $('langBtn').addEventListener('click', () => { S.lang = S.lang === 'zh' ? 'en' : 'zh'; save(); renderAll(); });

  $('btnCopyInstall').addEventListener('click', async () => {
    if (!canCopy()) return;
    await copyText(installCommand(measuredForCommand()), $('cmdInstall'), $('copyInstallMsg'));
  });
  $('btnOneClick').addEventListener('click', () => {
    if (!canCopy()) return;
    let url;
    try { url = applyUrl(measuredForCommand()); } catch { return; }
    openOneClick(url, $('oneClickMsg'), 'ocNotInstalled');
  });
  $('btnOneClickUn').addEventListener('click', () => openOneClick(uninstallUrl(), $('oneClickUnMsg'), 'ocUnNotInstalled'));
  $('btnCopyUninstall').addEventListener('click', async () => {
    await copyText(uninstallCommand(), $('cmdUninstall'), $('copyUninstallMsg'));
  });
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

  if (window.ResizeObserver) new ResizeObserver(() => { if (!S.measuring) drawPad(); }).observe(pad);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener?.('change', () => { renderAll(); });
  renderAll();
}

init();
