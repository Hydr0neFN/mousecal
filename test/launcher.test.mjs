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

const psBlock = (c) => {
  const m = /-Command "([^"\r\n]*)" & exit \/b\r\n/.exec(c);
  assert.ok(m, 'the one long PowerShell line');
  return m[1];
};
const zhCall = (s) => 'call :zh "' + [...s].map((ch) => ch.charCodeAt(0) < 128 ? ch : '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0')).join('') + '"';
const PSEXE = '%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
const INSTALL = { mode: 'install', measured: 7.5 };

test('launcher: admin check is fltmc (full path, not net session), one marked self-elevation, nothing earlier touches the disk', () => {
  const c = launcherCmd({ mode: 'install', measured: 1 });
  const L = lines(c);
  assert.ok(L.includes('"%SystemRoot%\\System32\\fltmc.exe" >nul 2>&1 || goto :elevate'));
  assert.ok(/fltmc/.test(c) && !/net session/i.test(c));
  assert.equal(L[L.indexOf('setlocal EnableExtensions DisableDelayedExpansion') + 1], 'set "MC_SELF=%~f0"');
  assert.equal(L[L.indexOf('set "MC_SELF=%~f0"') + 1], 'cd /d "%SystemRoot%\\System32"', 'cd away from Downloads right after remembering the path');
  // the marker: present -> never relaunch again, bilingual message, pause, exit
  const marker = 'mousecal-elevated';
  assert.ok(L.includes(`if /i "%~1"=="${marker}" goto :noadmin`));
  assert.equal((c.match(/-Verb RunAs/g) || []).length, 1, 'exactly one elevation');
  const relaunch = L.find((l) => l.includes('-Verb RunAs'));
  assert.ok(relaunch.includes(`-ArgumentList '${marker}'`) && relaunch.includes('-FilePath $env:MC_SELF') && relaunch.includes('-ErrorAction Stop'));
  assert.ok(L.indexOf(relaunch) > L.indexOf(`if /i "%~1"=="${marker}" goto :noadmin`), 'marker check comes before the relaunch');
  const noadmin = c.slice(c.indexOf('\r\n:noadmin\r\n'), c.indexOf('\r\n:end\r\n'));
  assert.ok(noadmin.includes('Still no administrator rights') && !noadmin.includes('RunAs') && /call :zh/.test(noadmin));
  assert.ok(c.slice(c.indexOf('\r\n:end\r\n')).includes('pause >nul'));
  // declined UAC / Start-Process failure: message and pause, not a silent close
  const declined = c.slice(c.indexOf(relaunch), c.indexOf('\r\n:noadmin\r\n'));
  assert.ok(declined.includes('Administrator permission was not granted') && declined.includes('goto :end'));
  assert.ok(declined.includes(zhCall(LAUNCHER_ZH.declined)));
  assert.ok(c.includes(zhCall(LAUNCHER_ZH.noAdmin)));
  assert.ok(relaunch.includes('catch{exit 1}') && relaunch.endsWith('&& exit /b 0'));
  // before the admin check nothing but set/cd runs; the happy path has no goto/label before the long line
  const at = L.indexOf('"%SystemRoot%\\System32\\fltmc.exe" >nul 2>&1 || goto :elevate');
  for (const l of L.slice(0, at)) assert.ok(/^(@echo off|rem |setlocal|set "MC_SELF|cd \/d)/.test(l), l);
  assert.ok(L.findIndex((l) => l.includes('-Command "$ErrorActionPreference')) < L.indexOf(':elevate'));
  assert.ok(!L.slice(at, L.findIndex((l) => l.includes('-Command "$ErrorActionPreference'))).some((l) => /^(:|goto|if|call)/.test(l)));
});

test('launcher: MC_SELF is an env var, %~f0 never appears inside single quotes; powershell/fltmc always by full path', () => {
  for (const o of [INSTALL, { mode: 'uninstall', restoreEpp: true }]) {
    const c = launcherCmd(o);
    assert.equal((c.match(/%~f0/g) || []).length, 1);
    assert.ok(!/'[^'\r\n]*%~f0/.test(c) && !/%~f0[^\r\n]*'/.test(c));
    assert.ok(c.includes('set "MC_SELF=%~f0"'));
    for (const l of lines(c).filter((x) => /powershell(\.exe)?\b/i.test(x) && !/^rem /.test(x))) {
      const cmd = l.replace(/'[^']*'/g, '');
      if (/(^|[ "])powershell(\.exe)?[ "]/i.test(cmd)) assert.ok(cmd.startsWith('"' + PSEXE + '" '), 'bare powershell: ' + l.slice(0, 80));
    }
    assert.ok(!/(^|\r\n)(powershell|fltmc|curl|certutil|icacls)\b/i.test(c), 'a command is looked up through PATH / the Downloads folder');
  }
});

test('launcher: the PowerShell block is one cmd-safe line (no double quote, no percent, no !, no ^), single -Command, short enough', () => {
  const c = launcherCmd(INSTALL);
  const b = psBlock(c);
  assert.ok(!/["%!^\r\n]/.test(b), 'cmd would change this');
  assert.ok(lines(c).every((l) => l.length < 7500), 'cmd line limit is 8191');
  assert.ok(!/-EncodedCommand|-enc\b/i.test(c));
  assert.ok(lines(c).filter((l) => /^"%SystemRoot%.*powershell\.exe" -NoProfile -Command "\$ErrorActionPreference/.test(l)).length === 1);
});

test('launcher: new random folder %ProgramData%\\mousecal-dl-<guid> created with its ACL (protected, owner Administrators, only Administrators + SYSTEM)', () => {
  const b = psBlock(launcherCmd(INSTALL));
  assert.ok(!/icacls|mkdir|ProgramData\\mousecal\b/.test(launcherCmd(INSTALL)), 'no shared root, no icacls sequence');
  assert.ok(b.includes("Join-Path $env:ProgramData ('mousecal-dl-'+[guid]::NewGuid().ToString('N'))"));
  assert.ok(b.includes('[IO.Directory]::CreateDirectory($p,$sec)'));
  assert.ok(b.includes('$sec.SetAccessRuleProtection($true,$false)'), 'no inheritance');
  assert.ok(b.includes('$sec.SetOwner($adm)') && b.includes("SecurityIdentifier('S-1-5-32-544')") && b.includes("SecurityIdentifier('S-1-5-18')"));
  assert.ok(b.includes("'FullControl','ContainerInherit,ObjectInherit','None','Allow'"));
  assert.equal((b.match(/AddAccessRule/g) || []).length, 1, 'one rule per SID through one loop, no other principals');
  assert.ok(b.includes('foreach($s in $adm,$sys)'));
  assert.ok(!/Users|Everyone|S-1-1-0|S-1-5-32-545|S-1-5-11|Authenticated/i.test(b));
  const order = ['$sec.SetAccessRuleProtection', '$sec.SetOwner', 'AddAccessRule', 'NewGuid', 'GetAttributes($p)}catch', 'CreateDirectory($p,$sec)', 'DownloadFile'].map((s) => b.indexOf(s));
  assert.ok(order.every((v, i) => v > 0 && (i === 0 || v > order[i - 1])), 'ACL is built before the folder exists, the folder is created before the download: ' + order);
  // refuses an existing path / a link, and double-checks after creating
  assert.ok(b.includes("if($ex){throw 'the folder already exists'}"));
  assert.ok(b.includes('if([IO.File]::GetAttributes($p) -band 1024){throw') && b.includes('AreAccessRulesProtected'));
  // a path that was not made by this run is never deleted
  assert.ok(b.includes('$mine=$true') && b.includes('finally{if($mine){try{d $p}'));
  assert.ok(b.indexOf('$mine=$true') > b.indexOf('CreateDirectory($p,$sec)'));
  assert.ok(!/%TEMP%|%TMP%|%USERPROFILE%|%LOCALAPPDATA%|%APPDATA%|env:TEMP|env:TMP|env:USERPROFILE|env:LOCALAPPDATA|env:APPDATA/i.test(launcherCmd(INSTALL)), 'a user-writable location is used');
});

test('launcher: cleanup removes links themselves and never follows them', () => {
  const b = psBlock(launcherCmd(INSTALL));
  const fn = [b.slice(b.indexOf('function d('), b.indexOf('$rc=1'))];
  assert.ok(fn, 'delete function');
  assert.ok(/-not \(\$t -band 1024\)/.test(fn[0]), 'only real directories are entered');
  assert.ok(fn[0].includes('[IO.Directory]::Delete($x)') && !/Recurse|\$true\)/.test(fn[0]), 'plain Delete never recurses into a link');
  assert.ok(!/Remove-Item|rmdir|rd /i.test(launcherCmd(INSTALL)));
});

test('launcher: WebClient with the system proxy and TLS 1.2, no curl / Invoke-WebRequest / certutil', () => {
  const c = launcherCmd(INSTALL), b = psBlock(c);
  assert.ok(b.includes('New-Object Net.WebClient') && b.includes('[Net.WebRequest]::GetSystemWebProxy()') && b.includes('DefaultCredentials'));
  assert.ok(b.includes('SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12'));
  assert.ok(b.includes('$w.DownloadFile($env:MC_URL,$f)'));
  assert.ok(!/curl|Invoke-WebRequest|certutil|bitsadmin|DownloadString|irm\b/i.test(c));
  assert.ok(c.includes('set "MC_URL=' + SITE_BASE + '/setup.ps1"'));
  assert.ok(b.includes("$f=Join-Path $p 'setup.ps1'"));
});

test('launcher: SHA256 via .NET, compared with SETUP_SHA256, a mismatch runs nothing and still cleans up', () => {
  const c = launcherCmd(INSTALL), b = psBlock(c);
  assert.ok(c.includes('set "MC_SHA256=' + SETUP_SHA256 + '"') && c.includes('Expected SHA256    : ' + SETUP_SHA256), 'contains SETUP_SHA256');
  assert.ok(!/certutil/i.test(c));
  assert.ok(b.includes('[Security.Cryptography.SHA256]::Create().ComputeHash($s)') && b.includes("Replace('-','')"));
  assert.ok(b.includes('if($g -ne $env:MC_SHA256){$rc=4;'), 'case-insensitive -ne, stops with 4');
  const mismatch = /if\(\$g -ne \$env:MC_SHA256\)\{(.*?)\}else\{/.exec(b)[1];
  assert.ok(!mismatch.includes('-File') && mismatch.includes('does not match the version on the website'));
  assert.ok(b.indexOf('$g -ne $env:MC_SHA256') < b.indexOf('-File $f'), 'the check comes before the run');
  assert.ok(b.indexOf('finally{if($mine)') > b.indexOf('-File $f'), 'cleanup after the run, also reached on a mismatch (finally)');
  // bilingual messages: zh as \\uXXXX, decoding back to the exact sentences
  assert.equal(LAUNCHER_ZH.mismatch, '下載的檔案和網站上的版本不一致，已停止。請重新整理網頁再下載一次。');
  for (const key of ['working', 'noDir', 'noDownload', 'mismatch', 'close']) {
    const re = /m '([^']*)' '([^']*)'/g;
    const found = [...b.matchAll(re)].find((x) => decodeEscapes(x[2]) === LAUNCHER_ZH[key]);
    assert.ok(found, 'zh message ' + key);
    assert.ok(!/[^\x20-\x7e]/.test(found[2]));
  }
  const upper = 'ABCDEF0123456789'.repeat(4);
  assert.ok(launcherCmd({ mode: 'install', measured: 1, sha256: upper }).includes('set "MC_SHA256=' + upper.toLowerCase() + '"'));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, sha256: 'xyz' }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, sha256: SETUP_SHA256 + '"&calc' }));
});

test('launcher: runs setup.ps1 by full powershell path with -File and the right arguments, then one pause with the close message', () => {
  const run = (o) => /& \(\$env:SystemRoot\+'\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'\) (-NoProfile -ExecutionPolicy Bypass -File \$f [^;]*);\$rc=\[int\]\$LASTEXITCODE/.exec(psBlock(launcherCmd(o)));
  assert.equal(run(INSTALL)[1], '-NoProfile -ExecutionPolicy Bypass -File $f -Measured 7.5 -NoPause');
  assert.equal(run({ mode: 'install', measured: -3.14 })[1], '-NoProfile -ExecutionPolicy Bypass -File $f -Measured -3.1 -NoPause');
  assert.ok(run({ mode: 'install', measured: -0.04 })[1].endsWith('-Measured 0.0 -NoPause'));
  const inst = launcherCmd(INSTALL), b = psBlock(inst);
  assert.ok(b.includes('$rc=[int]$LASTEXITCODE') && b.endsWith('exit $rc'));
  assert.equal((b.match(/ReadKey/g) || []).length, 1, 'one pause at the end of the block');
  assert.ok(b.indexOf('ReadKey') > b.indexOf('finally{if($mine)'), 'cleanup before the final pause');
  assert.ok(inst.includes('& exit /b\r\n'), 'cmd leaves right after the block on the same line');
  assert.ok(!/Read-Host/.test(inst));
  assert.equal(LAUNCHER_ZH.close, '按任意鍵關閉');
  assert.ok(inst.includes(zhCall(LAUNCHER_ZH.close)));
  assert.ok(!inst.includes('-Uninstall') && !inst.includes('-Rotation'));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 45.5 }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: NaN }));
  assert.throws(() => launcherCmd({ mode: 'install' }));
  assert.throws(() => launcherCmd({ mode: 'bogus', measured: 1 }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, base: 'http://x.invalid' }));
  assert.throws(() => launcherCmd({ mode: 'install', measured: 1, base: 'https://x.invalid" & calc & "' }));
});

test('launcher: no irm, iex, Invoke-Expression, scriptblock::Create, certutil, net session or Win+R anywhere', () => {
  for (const o of [INSTALL, { mode: 'uninstall' }, { mode: 'uninstall', restoreEpp: true }]) {
    const c = launcherCmd(o);
    assert.ok(!/\birm\b|\biex\b|Invoke-Expression|scriptblock|certutil|net session|Win\+R/i.test(c));
  }
});

test('launcher: uninstall variant (with and without restoring pointer precision)', () => {
  const plain = launcherCmd({ mode: 'uninstall', restoreEpp: false });
  const epp = launcherCmd({ mode: 'uninstall', restoreEpp: true });
  assert.ok(psBlock(plain).includes('-File $f -Uninstall -NoPause;'));
  assert.ok(psBlock(epp).includes('-File $f -Uninstall -RestorePointerPrecision -NoPause;'));
  assert.ok(!plain.includes('RestorePointerPrecision') && !/-Measured/.test(plain + epp));
  assert.equal(launcherCmd({ mode: 'uninstall' }), plain, 'default is not restoring');
  assert.equal(launcherCmd({ mode: 'uninstall', restoreEpp: 'yes' }), plain, 'only a real true restores');
  assert.equal(launcherCmd({ mode: 'uninstall', measured: 12 }), plain, 'the angle is ignored');
  for (const c of [plain, epp]) {
    assert.ok(c.includes(SETUP_SHA256) && c.includes('fltmc.exe'));
    assert.equal((c.match(/^pause\b/gm) || []).length, 1, 'cmd-level error path');
  }
});

test('launcher: the PowerShell block parses (static check only, the block is NEVER executed)', { skip: process.platform !== 'win32' }, () => {
  const script = '$t=$null;$e=$null;$null=[System.Management.Automation.Language.Parser]::ParseInput($env:MC_BLOCK,[ref]$t,[ref]$e);' +
    'if($e.Count){$e|ForEach-Object{[Console]::Error.WriteLine($_.Message+\' @\'+$_.Extent.StartOffset)};exit 1};exit 0';
  for (const o of [INSTALL, { mode: 'install', measured: -45 }, { mode: 'uninstall' }, { mode: 'uninstall', restoreEpp: true }]) {
    const b = psBlock(launcherCmd(o));
    // only ever ParseInput: the text goes in through an environment variable and is never invoked
    execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { env: { ...process.env, MC_BLOCK: b }, stdio: ['ignore', 'pipe', 'pipe'] });
  }
  // the parser really does reject broken text (so the check above means something)
  assert.throws(() => execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { env: { ...process.env, MC_BLOCK: 'if(' }, stdio: ['ignore', 'pipe', 'pipe'] }));
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
  assert.equal(z.dlS1, '打開剛下載的 mousecal-setup 開頭的檔案');
  assert.equal(z.dlStarted, '已經開始下載 {file}（如果瀏覽器問要不要保留，請按「保留」）。檔名可能會多一個 (1)。');
  assert.ok(!/已下載|下載好了/.test(z.dlStarted), 'does not claim the file arrived');
  assert.ok(/has started/.test(STRINGS.en.dlStarted) && !/Downloaded/.test(STRINGS.en.dlStarted));
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
  const r = read('README.md') + read('README.zh-TW.md');   // English + Traditional Chinese docs, linked to each other
  assert.ok(read('README.md').includes('README.zh-TW.md') && read('README.zh-TW.md').includes('README.md'), 'the two READMEs must link to each other');
  for (const needle of ['mousecal-setup-', 'mousecal-uninstall.cmd', 'setup-hash.js', 'SETUP_SHA256', 'fltmc', 'WebClient', 'mousecal-elevated', '%ProgramData%\\mousecal-dl-<guid>', 'ClickFix', 'MOUSECAL_BUILD_OUT', 'launcher.test.mjs', '下載安裝程式']) {
    assert.ok(r.includes(needle), 'README lacks ' + needle);
  }
});

test('git stores setup.ps1 byte for byte (.gitattributes -text), otherwise a checkout would not match SETUP_SHA256', () => {
  assert.match(read('.gitattributes'), /^setup\.ps1 -text\s*$/m);
});
