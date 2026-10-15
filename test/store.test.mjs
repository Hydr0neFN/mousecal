// Pure helpers for the per-browser record. Run: node --test test/store.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeStore, serializeStore, verdictPath, shortDate, installedAfter } from '../store.js';

test('normalizeStore: garbage in, clean record out', () => {
  const empty = { lang: null, last: null, path: null, pendingApply: false, installed: false };
  for (const bad of [null, undefined, 5, 'x', [], {}, { last: 3 }, { last: { theta: 'a' } }, { last: { theta: NaN } }, { last: { theta: 120 } }]) {
    assert.deepEqual(normalizeStore(bad), empty, JSON.stringify(bad));
  }
  const ok = normalizeStore({ lang: 'en', last: { theta: 8.2, se: 0.5, n: 132, at: 1760000000000 }, path: 'physical', pendingApply: true, installed: true, extra: 1 });
  assert.deepEqual(ok, { lang: 'en', last: { theta: 8.2, se: 0.5, n: 132, at: 1760000000000 }, path: 'physical', pendingApply: true, installed: true });
  assert.equal(normalizeStore({ lang: 'fr' }).lang, null);
  assert.equal(normalizeStore({ path: 'hax' }).path, null);
  assert.equal(normalizeStore({ pendingApply: 'yes' }).pendingApply, false);
  assert.deepEqual(normalizeStore({ last: { theta: -1, se: 'x', n: -3 } }).last, { theta: -1, se: null, n: 0, at: null });
  assert.deepEqual(normalizeStore({ before: { theta: 3 } }), empty); // old format is ignored
});

test('serializeStore writes only the allowed fields and round-trips', () => {
  const st = { lang: 'zh', last: { theta: 1.5, se: 0.2, n: 20, at: 5 }, path: 'software', pendingApply: true, installed: false, secret: 'no' };
  const txt = serializeStore(st);
  assert.deepEqual(Object.keys(JSON.parse(txt)).sort(), ['installed', 'lang', 'last', 'path', 'pendingApply']);
  assert.deepEqual(normalizeStore(JSON.parse(txt)), { lang: 'zh', last: st.last, path: 'software', pendingApply: true, installed: false });
});

test('verdictPath: unknown path is held to the stricter software standard', () => {
  assert.equal(verdictPath(null), 'software');
  assert.equal(verdictPath(undefined), 'software');
  assert.equal(verdictPath('software'), 'software');
  assert.equal(verdictPath('physical'), 'physical');
});

test('shortDate gives month/day', () => {
  assert.equal(shortDate(new Date(2026, 9, 15, 12).getTime()), '10/15');
  assert.equal(shortDate(null), '');
  assert.equal(shortDate(NaN), '');
});

test('installedAfter: only a passing software re-measure sets it, and it never un-sets', () => {
  assert.equal(installedAfter(false, { remeasured: true, path: 'software', pass: true }), true);
  assert.equal(installedAfter(false, { remeasured: true, path: 'software', pass: false }), false);
  assert.equal(installedAfter(false, { remeasured: true, path: 'physical', pass: true }), false);
  assert.equal(installedAfter(false, { remeasured: false, path: 'software', pass: true }), false);
  assert.equal(installedAfter(true, { remeasured: true, path: 'software', pass: false }), true);
});
