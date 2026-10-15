/*
 * Pure helpers for the per-browser convenience record and the link-launch decision. No DOM.
 * The record is NEVER used to compute a rotation: the install / apply command carries only
 * the angle measured in the current visit.
 */

export const PATHS = ['software', 'physical'];

// Anything read from localStorage is untrusted: return a clean { lang, last, path, pendingApply }.
export function normalizeStore(raw) {
  const out = { lang: null, last: null, path: null, pendingApply: false, installed: false };
  if (!raw || typeof raw !== 'object') return out;
  if (raw.lang === 'zh' || raw.lang === 'en') out.lang = raw.lang;
  const l = raw.last;
  if (l && typeof l === 'object' && Number.isFinite(l.theta) && Math.abs(l.theta) <= 90) {
    out.last = {
      theta: l.theta,
      se: Number.isFinite(l.se) ? l.se : null,
      n: Number.isInteger(l.n) && l.n >= 0 ? l.n : 0,
      at: Number.isFinite(l.at) ? l.at : null
    };
  }
  if (PATHS.includes(raw.path)) out.path = raw.path;
  out.pendingApply = raw.pendingApply === true;
  out.installed = raw.installed === true;
  return out;
}

// What gets written back. Exactly these fields.
export function serializeStore(s) {
  return JSON.stringify({ lang: s.lang, last: s.last, path: s.path, pendingApply: !!s.pendingApply, installed: !!s.installed });
}

// Unknown path counts as the stricter (software) standard.
export function verdictPath(path) {
  return path === 'physical' ? 'physical' : 'software';
}

// "10/15" from an epoch-ms timestamp; '' when unknown.
export function shortDate(at) {
  if (!Number.isFinite(at)) return '';
  const d = new Date(at);
  return (d.getMonth() + 1) + '/' + d.getDate();
}

// "installed" is only a hint that softens the manual-steps text (it is never hidden). It becomes true once
// a re-measure on the software path, after the user started an apply, comes out within the pass limit.
export function installedAfter(prev, { remeasured, path, pass }) {
  if (remeasured && path === 'software' && pass) return true;
  return prev === true;
}
