// The downloaded .cmd launcher, the generated setup-hash.js and how the page uses them.
// These tests only look at TEXT: no launcher is ever run, nothing is elevated.
// Run: node --test test/launcher.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { SITE_BASE, REPO_URL, LAUNCHER_ZH, launcherCmd, launcherFilename, formatRotation } from '../commands.js';
import { SETUP_SHA256 } from '../setup-hash.js';
import { STRINGS } from '../i18n.js';

const web = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (f) => readFileSync(path.join(web, f), 'utf8');
const sha = (buf) => createHash('sha256').update(buf).digest('hex');
const lines = (s) => s.split('\r\n');
const decodeEscapes = (s) => s.replace(/\\u([0-9a-f]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

test('SETUP_SHA256 is the SHA256 of the setup.ps1 shipped next to it', () => {
  assert.match(SETUP_SHA256, /^[0-9a-f]{64}$/);
  assert.equal(SETUP_SHA256, sha(readFileSync(path.join(web, 'setup.ps1'))));
});

test('build script writes setup-hash.js matching the setup.ps1 it wrote (built into a temp folder)', () => {
  const out = mkdtempSync(path.join(tmpdir(), 'mousecal-build-'));
  try {
    const log = execFileSync(process.execPath, [path.join(web, 'tools', 'build-setup.mjs')], { env: { ...process.env, MOUSECAL_BUILD_OUT: out }, encoding: 'utf8' });
    const hashJs = readFileSync(path.join(out, 'setup-hash.js'), 'utf8');
    const m = /^export const SETUP_SHA256 = '([0-9a-f]{64})';$/m.exec(hashJs);
    assert.ok(m, hashJs);
    assert.equal(m[1], sha(readFileSync(path.join(out, 'setup.ps1'))));
    assert.ok(log.includes(m[1]));
    // the committed files are exactly what the build produces now (nobody forgot to rebuild)
    for (const f of ['setup.ps1', 'setup-hash.js', 'settings-template.js']) {
      assert.equal(readFileSync(path.join(out, f)).toString('latin1'), readFileSync(path.join(web, f)).toString('latin1'), f + ' is stale: run node tools/build-setup.mjs');
    }
  } finally { rmSync(out, { recursive: true, force: true }); }
});

test('launcher: CRLF line endings only, ASCII only, ends with a line break', () => {
  for (const o of [{ mode: 'install', measured: 7.5 }, { mode: 'install', measured: -45 }, { mode: 'uninstall' }, { mode: 'uninstall', restoreEpp: true }]) {
    const c = launcherCmd(o);
    assert.ok(!/[^\x00-\x7f]/.test(c), 'non-ASCII character');
    assert.ok(!/(?<!\r)\n/.test(c) && !/\r(?!\n)/.test(c), 'bare LF or CR');
    assert.ok(c.endsWith('\r\n'));
    assert.ok(c.startsWith('@echo off\r\n'));
  }
});

test('launcher: no irm, iex, scriptblock::Create, Invoke-Expression, Win+R, encoded commands or pipes into an interpreter', () => {
  for (const o of [{ mode: 'install', measured: 3.2 }, { mode: 'uninstall', restoreEpp: true }]) {
    const c = launcherCmd(o);
    assert.ok(!/\birm\b|\biex\b|Invoke-Expression|scriptblock|\[scriptblock\]|Win\+R|-EncodedCommand|-enc\b|DownloadString|FromBase64/i.test(c), 'forbidden construct');
    assert.ok(!/\|\s*(powershell|iex|cmd)/i.test(c), 'pipe into an interpreter');
  }
});

test('launcher: header names what it is, the angle, the source URL, the repo and the expected hash', () => {
  const c = launcherCmd({ mode: 'install', measured: 7.5 });
  const header = lines(c).filter((l) => /^rem /.test(l)).join('\n');
  assert.ok(/mousecal setup launcher/.test(header));
  assert.ok(header.includes('7.5 degrees'));
  assert.ok(header.includes(SITE_BASE + '/setup.ps1'));
  assert.ok(header.includes('https://github.com/Hydr0neFN/mousecal') && REPO_URL === 'https://github.com/Hydr0neFN/mousecal');
  assert.ok(header.includes(SETUP_SHA256));
  // the header is the very first thing in the file (right after @echo off)
  assert.ok(/^@echo off\r\nrem =+\r\nrem mousecal setup launcher/.test(c));
  assert.ok(/mousecal uninstall launcher/.test(launcherCmd({ mode: 'uninstall' })));
});

test('launcher: self-elevates with the specified line, before anything touches the disk', () => {
  const c = launcherCmd({ mode: 'install', measured: 1 });
  const elevate = `net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)`;
  assert.ok(lines(c).includes(elevate));
  const at = c.indexOf(elevate);
  for (const later of ['mkdir', 'icacls', 'curl.exe', 'certutil', 'Bypass -File']) assert.ok(c.indexOf(later, at) > at, later);
  assert.ok(!c.slice(0, at).match(/mkdir|icacls|curl|certutil|-File/), 'something runs before the elevation check');
});

test('launcher: admin-only folder under %ProgramData%\\mousecal\\dl-<random>, locked with icacls before the download', () => {
  const c = launcherCmd({ mode: 'install', measured: 1 });
  assert.ok(c.includes('set "MC_ROOT=%ProgramData%\\mousecal"'));
  assert.ok(/set "MC_DIR=%MC_ROOT%\\dl-%RANDOM%/.test(c));
  assert.ok(!/%TEMP%|%TMP%|%USERPROFILE%|%LOCALAPPDATA%|%APPDATA%/i.test(c), 'a user-writable location is used');
  const acl = '/inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F';
  const aclLines = lines(c).filter((l) => l.startsWith('icacls '));
  assert.ok(aclLines.length >= 3);
  assert.ok(aclLines.some((l) => l.includes('/setowner *S-1-5-32-544')), 'a pre-made folder gets an administrators owner');
  assert.ok(lines(c).some((l) => l.startsWith('icacls "%MC_DIR%" ' + acl)), 'download folder is locked');
  assert.ok(c.indexOf('icacls "%MC_DIR%"') < c.indexOf('curl.exe -fsSL'), 'locked before the download');
  assert.ok(c.indexOf('mkdir "%MC_DIR%"') < c.indexOf('icacls "%MC_DIR%"'));
  // deleted at the end, and only a folder this run made
  assert.ok(/if defined MC_MADE if exist "%MC_DIR%" rmdir \/s \/q "%MC_DIR%"/.test(c));
  assert.ok(c.indexOf('rmdir /s /q') > c.indexOf('Bypass -File'));
});

test('launcher: curl.exe -fsSL with an Invoke-WebRequest -UseBasicParsing -OutFile fallback', () => {
  const c = launcherCmd({ mode: 'install', measured: 1 });
  assert.ok(c.includes('curl.exe -fsSL -o "%MC_PS1%" "%MC_URL%"'));
  assert.ok(c.includes('where curl.exe'));
  assert.ok(/Invoke-WebRequest -UseBasicParsing -Uri '%MC_URL%' -OutFile '%MC_PS1%'/.test(c));
  assert.ok(c.includes('set "MC_URL=' + SITE_BASE + '/setup.ps1"'));
  assert.ok(c.includes('set "MC_PS1=%MC_DIR%\\setup.ps1"'));
});

test('launcher: verifies SHA256 with certutil, case-insensitive, spaces stripped, and stops on a mismatch before running anything', () => {
  const c = launcherCmd({ mode: 'install', measured: 1 });
  assert.ok(c.includes('set "MC_SHA256=' + SETUP_SHA256 + '"'), 'contains SETUP_SHA256');
  assert.ok(c.includes('certutil -hashfile "%MC_PS1%" SHA256'));
  assert.ok(c.includes('set "MC_GOT=%MC_GOT: =%"'), 'spaces stripped');
  assert.ok(c.includes('if /i not "%MC_GOT%"=="%MC_SHA256%" goto :fail_hash'), 'case-insensitive compare');
  assert.ok(c.indexOf('goto :fail_hash') < c.indexOf('Bypass -File'), 'the check comes before the run');
  // an empty / unreadable hash also stops
  assert.ok(c.includes('if not defined MC_GOT goto :fail_hash'));
  // the mismatch block: bilingual message, no setup run in it
  const block = c.slice(c.indexOf('\r\n:fail_hash\r\n'), c.indexOf('\r\n:done\r\n'));
  assert.ok(block.length > 20, 'mismatch block found');
  assert.ok(!block.includes('-File'));
  assert.ok(block.includes('does not match the version on the website'));
  assert.equal(LAUNCHER_ZH.mismatch, '下載的檔案和網站上的版本不一致，已停止。請重新整理網頁再下載一次。');
  assert.ok(block.includes(`call :zh "${[...LAUNCHER_ZH.mismatch].map((ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0')).join('')}"`));
  // the \\uXXXX escapes decode back to the exact sentence
  const m = /call :zh "([^"]*)"/.exec(block);
  assert.equal(decodeEscapes(m[1]), LAUNCHER_ZH.mismatch);
  // hash in the file is whatever was passed in (lower-cased), and a bad one is refused
  const upper = 'ABCDEF0123456789'.repeat(4);
  assert.ok(launcherCmd({ mode: 'install', measured: 1, sha256: upper }).includes('set "MC_SHA256=' + upper.toLowerCase() + '"'));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, sha256: 'xyz' }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, sha256: SETUP_SHA256 + '"&calc' }));
});

test('launcher: runs setup.ps1 with -File and the right arguments, one single pause with the close message', () => {
  const inst = launcherCmd({ mode: 'install', measured: 7.5 });
  assert.ok(lines(inst).includes('powershell -NoProfile -ExecutionPolicy Bypass -File "%MC_PS1%" -Measured 7.5 -NoPause'));
  assert.ok(lines(launcherCmd({ mode: 'install', measured: -3.14 })).includes('powershell -NoProfile -ExecutionPolicy Bypass -File "%MC_PS1%" -Measured -3.1 -NoPause'));
  assert.ok(lines(launcherCmd({ mode: 'install', measured: -0.04 })).some((l) => l.endsWith('-Measured 0.0 -NoPause')));
  assert.equal((inst.match(/^pause\b/gm) || []).length, 1, 'exactly one pause');
  assert.ok(!/Read-Host/.test(inst));
  assert.equal(LAUNCHER_ZH.close, '按任意鍵關閉');
  assert.ok(inst.includes('call :zh "' + [...LAUNCHER_ZH.close].map((ch) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0')).join('') + '"'));
  assert.ok(inst.indexOf('rmdir /s /q') < inst.indexOf('\r\npause'), 'cleanup before the final pause');
  assert.ok(!inst.includes('-Uninstall') && !inst.includes('-Rotation'));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 45.5 }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: NaN }));
  assert.throws(() => launcherCmd({ mode: 'install' }));
  assert.throws(() => launcherCmd({ mode: 'bogus', measured: 1 }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, base: 'http://x.invalid' }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, base: 'https://x.invalid" & calc & "' }));
});

test('launcher: uninstall variant (with and without restoring pointer precision)', () => {
  const plain = launcherCmd({ mode: 'uninstall', restoreEpp: false });
  const epp = launcherCmd({ mode: 'uninstall', restoreEpp: true });
  assert.ok(lines(plain).includes('powershell -NoProfile -ExecutionPolicy Bypass -File "%MC_PS1%" -Uninstall -NoPause'));
  assert.ok(lines(epp).includes('powershell -NoProfile -ExecutionPolicy Bypass -File "%MC_PS1%" -Uninstall -RestorePointerPrecision -NoPause'));
  assert.ok(!plain.includes('RestorePointerPrecision') && !/-Measured/.test(plain + epp));
  assert.equal(launcherCmd({ mode: 'uninstall' }), plain, 'default is not restoring');
  assert.equal(launcherCmd({ mode: 'uninstall', restoreEpp: 'yes' }), plain, 'only a real true restores');
  assert.equal(launcherCmd({ mode: 'uninstall', measured: 12 }), plain, 'the angle is ignored');
  for (const c of [plain, epp]) {
    assert.ok(c.includes(SETUP_SHA256) && c.includes('net session >nul 2>&1 || (powershell'));
    assert.equal((c.match(/^pause\b/gm) || []).length, 1);
  }
});

test('file names: mousecal-setup-<angle>.cmd and mousecal-uninstall.cmd', () => {
  assert.equal(launcherFilename('install', 7.5), 'mousecal-setup-7.5.cmd');
  assert.equal(launcherFilename('install', -3.14), 'mousecal-setup--3.1.cmd');
  assert.equal(launcherFilename('uninstall', 7.5), 'mousecal-uninstall.cmd');
  assert.equal(launcherFilename('install', 8.2), `mousecal-setup-${formatRotation(8.2)}.cmd`);
});

test('page: download buttons, steps, fallback button (no auto-download), uninstall pattern, advanced PowerShell box + hash', () => {
  const html = read('index.html'), app = read('app.js');
  for (const id of ['btnDownload', 'dlStep1', 'manualSteps', 'btnRemeasureWin', 'btnApply', 'fallbackBox', 'btnFallbackDownload',
    'btnDownloadUn', 'btnOneClickUn', 'unFallbackBox', 'btnUnFallbackDownload', 'unManual', 'unRestoreEpp', 'psBox', 'setupHash', 'btnCopyInstall', 'btnCopyUninstall', 'cmdInstall', 'cmdUninstall']) {
    assert.ok(html.includes(`id="${id}"`), id);
  }
  assert.equal(STRINGS.zh.btnDownload, '下載安裝程式');
  assert.equal(STRINGS.zh.btnFallbackDownload, '沒有反應？下載安裝程式');
  assert.equal(STRINGS.zh.btnApply, '套用修正');
  assert.equal(STRINGS.zh.psTitle, '進階：用 PowerShell 指令安裝');
  // the Win+R command and its warning live inside the collapsed "advanced PowerShell" details, and that sits inside Advanced
  const ps = /<details class="adv-ps"[^>]*>[\s\S]*?<\/details>/.exec(html)[0];
  assert.ok(!/\sopen[\s>]/.test(ps.split('>')[0] + '>'), 'collapsed by default');
  for (const id of ['cmdInstall', 'cmdUninstall', 'btnCopyInstall', 'btnCopyUninstall']) assert.ok(ps.includes(`id="${id}"`), id + ' inside the PowerShell box');
  assert.ok(ps.includes('data-i18n="psTitle"') && ps.includes('data-i18n="psWarn"'));
  assert.ok(html.indexOf('id="advanced"') < html.indexOf('class="adv-ps"'));
  assert.ok(/antivirus/i.test(STRINGS.en.psWarn) && /防毒/.test(STRINGS.zh.psWarn));
  assert.ok(html.includes('id="setupHash"') && /\$\('setupHash'\)\.textContent = SETUP_SHA256/.test(app));
  assert.ok(html.indexOf('id="setupHash"') > html.indexOf('id="advanced"'));
  // the download is built from launcherCmd + Blob + <a download>; the page never copies a command on its own
  assert.ok(/launcherCmd\(launcherOptions\(mode\)\)/.test(app) && /new Blob\(\[text\]/.test(app) && /a\.download = launcherName\(mode\)/.test(app));
  assert.ok(/\{ mode, restoreEpp: restoreEpp\(\) \}/.test(app), 'uninstall honours the checkbox');
  const run = /function runLinkAction[\s\S]*?\n\}\n/.exec(app)[0];
  assert.ok(!/downloadLauncher|doDownload|copy/i.test(run), 'opening the link never downloads or copies by itself');
  assert.ok(/FALLBACK_DELAY_MS = 3000/.test(app) && /setTimeout\(\(\) => \{ box\.hidden = false; \}, FALLBACK_DELAY_MS\)/.test(run));
  assert.ok(/window\.location\.assign\(url\)/.test(run));
  assert.ok(!/doDownload\([^)]*\)[^;\n]*FALLBACK/.test(app));
  // the only callers of the download are click handlers
  const calls = [...app.matchAll(/doDownload\('(install|uninstall)'\)/g)];
  assert.equal(calls.length, 4);
  for (const m of calls) assert.ok(/addEventListener\('click', \(\) => $/.test(app.slice(Math.max(0, m.index - 40), m.index)), 'doDownload is only called from a click handler');
  // old "copy on every click" is gone
  assert.ok(!/copyQuiet\(command/.test(app));
});

test('page: the four steps say what the owner specified (zh and en), in simple words', () => {
  const z = STRINGS.zh;
  assert.equal(z.dlS1, '打開剛下載的 {file}');
  assert.equal(z.dl2, '如果出現「Windows 已保護您的電腦」，按「其他資訊」→「仍要執行」');
  assert.equal(z.dl3, '出現「是否允許…變更」按「是」');
  assert.equal(z.dl4, '黑色視窗跑完，回到這裡按「再量一次」');
  assert.ok(/More info/.test(STRINGS.en.dl2) && /Run anyway/.test(STRINGS.en.dl2));
  // elder-friendly vocabulary: no jargon words in the main steps
  for (const k of ['dlS1', 'dl1note', 'dl2', 'dl2note', 'dl3', 'dl3note', 'dl4', 'btnDownload', 'dlNote', 'manualTitle']) {
    assert.ok(!/腳本|指令碼|終端|命令列|PowerShell|SHA256|UAC|cmd/i.test(STRINGS.zh[k]), `zh.${k}: ${STRINGS.zh[k]}`);
  }
});

test('disclosure describes the launcher: downloads setup.ps1, checks SHA256 against the value on the page, runs it', () => {
  const zh = [STRINGS.zh.discL1, STRINGS.zh.discL2, STRINGS.zh.discL3].join('');
  assert.ok(/setup\.ps1/.test(zh) && /SHA256/.test(zh) && /進階/.test(zh) && /刪掉/.test(zh));
  const en = [STRINGS.en.discL1, STRINGS.en.discL2, STRINGS.en.discL3].join(' ');
  assert.ok(/setup\.ps1/.test(en) && /SHA256/.test(en) && /Advanced/.test(en) && /deletes/.test(en));
  assert.ok(read('index.html').includes('data-i18n="discL1"'));
  assert.ok(STRINGS.zh.discLinks.includes('https://github.com/Hydr0neFN/mousecal'));
});

test('README documents the launcher, the hash, the folder and the ClickFix reasoning', () => {
  const r = read('README.md');
  for (const needle of ['mousecal-setup-', 'mousecal-uninstall.cmd', 'setup-hash.js', 'SETUP_SHA256', 'certutil', 'curl.exe', '%ProgramData%\\mousecal\\dl-', 'ClickFix', 'MOUSECAL_BUILD_OUT', 'launcher.test.mjs', '下載安裝程式']) {
    assert.ok(r.includes(needle), 'README lacks ' + needle);
  }
});
