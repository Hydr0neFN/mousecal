// Static checks of the page: copied commands, translations, no leftovers in shipped files.
// Run: node --test test/site.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { SITE_BASE, installCommand, uninstallCommand, formatRotation, applyUrl, uninstallUrl, ONE_CLICK_MAX } from '../commands.js';
import { STRINGS } from '../i18n.js';

const web = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (f) => readFileSync(path.join(web, f), 'utf8');

test('install / uninstall commands fit the Win+R dialog and match the documented shape', () => {
  for (const r of [8.2, -3.1, 0, 45, -45, 12.34]) {
    const c = installCommand(r);
    assert.ok(c.length < 259, `${c.length} chars`);
    assert.ok(c.startsWith('powershell -NoProfile -ExecutionPolicy Bypass -Command "try{& ([scriptblock]::Create((irm '));
    assert.ok(c.endsWith(` -Measured ${formatRotation(r)}}catch{$_;Read-Host 'Press Enter'}"`));
    assert.ok(c.includes(SITE_BASE + '/setup.ps1'));
  }
  assert.equal(installCommand(8.2), "powershell -NoProfile -ExecutionPolicy Bypass -Command \"try{& ([scriptblock]::Create((irm https://mousecal.hydr0negnetwork.de/setup.ps1))) -Measured 8.2}catch{$_;Read-Host 'Press Enter'}\"");
  assert.ok(uninstallCommand().includes(' -Uninstall}catch{') && uninstallCommand().length < 259);
  assert.equal(formatRotation(-0.04), '0.0');
  assert.throws(() => installCommand(45.5));
  assert.throws(() => installCommand(NaN));
});

test('setup.ps1 site constant matches the page constant', () => {
  const m = /\$SiteBase\s*=\s*'([^']+)'/.exec(read('setup.ps1'));
  assert.ok(m, 'no $SiteBase in setup.ps1');
  assert.equal(m[1], SITE_BASE);
});

test('both languages have the same keys, and every key used in index.html exists', () => {
  const zh = Object.keys(STRINGS.zh).sort(), en = Object.keys(STRINGS.en).sort();
  assert.deepEqual(zh, en);
  const html = read('index.html');
  const used = [...html.matchAll(/data-i18n(?:-html)?="([^"]+)"/g)].map((m) => m[1]);
  assert.ok(used.length > 40);
  for (const k of used) assert.ok(k in STRINGS.zh, `missing key ${k}`);
  const app = read('app.js');
  for (const m of app.matchAll(/\bt\('([A-Za-z0-9]+)'/g)) assert.ok(m[1] in STRINGS.zh, `app.js uses missing key ${m[1]}`);
});

test('Chinese strings are Traditional (no common Simplified-only characters); English has no CJK', () => {
  const simplified = /[这个为们测门来时说对问发开关电线级与专东严两丝丢乐习书买乱争亏亚产亲优儿兴养内决况准凉则刚创别动务区医华单卖却厂历县参双变叶号叹启员响围图场坏块处备头夹夺奋妇孙学宁实宝宽对导将层岁带师帮广庆应开张强录总恶惊户执扩扫扬换损摇数断时显晒晚暂书术机杀杂极构样检楼横欢欧步归残毕气汇汉沟没泽测济浅测浓温湾满滤灭灯灵点热爱状犹猪献现环琐电画异盖盘睁码础确离种积称穷窃笔签简类粮紧纠红纪约级细织终组结绝绞统继续绿维缘编缩网罗罚职联聪肃脑脚脏舰艺节获蓝虑补袜见观规视览觉计订认讨让训议讯记讲许论设访证评识诉词译试话该详语误说请读调谁谈谢谱贝负贡财责贤败货质购贯贴贵贸费资赏赔赖赚赛赞赵趋跃踪车轮软轻载轿较辅辆输边迁过运还这进远违连迟选递逻遗邮邻郑释针钉钟钢钥钱铁铃铜银链锁锅错键锻镜长闭问闲间闷队阳阴阶际陆陈险随隐难雾静颗领频题颜风飞饭饮馆马驱验骑鱼鲜鸟麦黄齐齿龙]/;
  for (const [k, v] of Object.entries(STRINGS.zh)) assert.ok(!simplified.test(v), `zh.${k} has Simplified characters: ${v}`);
  for (const [k, v] of Object.entries(STRINGS.en).filter(([k]) => k !== 'langBtn')) assert.ok(!/[\u3400-\u9fff]/.test(v), `en.${k} contains CJK`);
});

test('windows-path copy stays within the user-approved claims', () => {
  const all = JSON.stringify(STRINGS);
  assert.ok(/CS2/.test(all));
  assert.ok(/Easy Anti-Cheat/.test(all));
  assert.ok(!/Call of Duty|Warzone/i.test(all));
  for (const n of ['issues/304', 'issues/306', 'issues/318', 'issues/290']) assert.ok(all.includes(n), n);
});

test('shipped files contain no personal names/paths or vendor-specific content', () => {
  const bad = [['Ruanyou', 'yi'].join(''), 'C:\\\\Users', 'C:/Users', ['Ra', 'zer'].join(''), ['Syn', 'apse'].join('')];
  const personal = bad;
  const skipDirs = new Set(['test', 'node_modules', '.git']);
  const files = [];
  (function walk(d) {
    for (const n of readdirSync(d)) {
      const p = path.join(d, n);
      if (statSync(p).isDirectory()) { if (!skipDirs.has(n)) walk(p); } else files.push(p);
    }
  })(web);
  assert.ok(files.length > 8);
  for (const f of files) {
    const txt = readFileSync(f, 'utf8');
    for (const b of personal) assert.ok(!txt.includes(b), `${path.relative(web, f)} contains ${b}`);
  }
});

test('page keeps no record of applied rotation and no "applied" editor (F4)', () => {
  const app = read('app.js'), html = read('index.html');
  assert.ok(!/S\.applied|S\.pending|inpApplied|applied:/.test(app), 'app.js still tracks applied rotation');
  assert.ok(!html.includes('inpApplied'));
  const saved = /localStorage\.setItem\([^)]*JSON\.stringify\(\{([^}]*)\}\)/.exec(app);
  assert.ok(saved && !/applied|pending|rotation/i.test(saved[1]), 'storage holds: ' + (saved && saved[1]));
  assert.ok(!installCommand(8.2).includes('-Rotation'));
  assert.ok(installCommand(-45).length < 259 && installCommand(-45).includes('-Measured -45.0}catch{'));
});

test('setup.ps1 is ASCII only and pins every file', () => {
  const s = read('setup.ps1');
  assert.ok(!/[^\x00-\x7F]/.test(s));
  const rows = read('tools/zip-files.txt').trim().split(/\r?\n/);
  assert.equal(rows.length, 24);
  for (const r of rows) assert.ok(s.includes(r), 'setup.ps1 lacks pinned row ' + r);
});

// F6: a failing download must leave the window open with the error visible. The command is
// run exactly as the Win+R dialog would hand it to CreateProcess (verbatim command line), but
// pointed at a host that cannot exist - never at the real site.
test('copied command on a dead host shows the error and waits for Enter (Windows PowerShell 5.1)', { skip: process.platform !== 'win32' }, async () => {
  for (const cmd of [installCommand(-12.3, 'https://mousecal.invalid'), uninstallCommand('https://mousecal.invalid')]) {
    assert.ok(cmd.length < 259);
    const rest = cmd.slice('powershell '.length);
    const child = spawn('powershell.exe', [rest], { windowsVerbatimArguments: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    const exited = new Promise((res) => child.on('exit', res));
    // wait until the error text appears (Read-Host's prompt itself is not echoed to a pipe)
    const t0 = Date.now();
    while (!/could not be resolved|remote name/i.test(out) && Date.now() - t0 < 20000) await new Promise((r) => setTimeout(r, 200));
        assert.ok(/mousecal.invalid|remote name|resolved|ResponseStatus|Unable|無法/i.test(out), 'no download error shown: ' + out);
    await new Promise((r) => setTimeout(r, 1500));
    assert.equal(child.exitCode, null, 'the window would have closed before the user could read the error');
    child.stdin.write(String.fromCharCode(13, 10));
    child.stdin.end();
    await Promise.race([exited, new Promise((r) => setTimeout(r, 10000))]);
    if (child.exitCode === null) child.kill();
    assert.equal(child.exitCode, 0);
  }
});

// ---- mousecal:// one-click links (handler lives in setup.ps1; tested for real in test/setup.test.ps1)
test('one-click links have exactly the shapes the handler accepts', () => {
  const vbsCharset = /^[A-Za-z0-9:/?=.&-]+$/;
  const handlerApply = /^mousecal:(?:\/\/)?apply\/?\?m=(-?[0-9]{1,2}(\.[0-9]{1,2})?)\/?$/;
  for (const th of [8.2, -3.1, 0, 20, -20, 0.04, -0.04, 12.34, 19.96]) {
    const u = applyUrl(th);
    assert.ok(vbsCharset.test(u) && u.length <= 64, u);
    const m = handlerApply.exec(u);
    assert.ok(m, u);
    assert.equal(m[1], formatRotation(th)); // one decimal, same as the install command
    assert.ok(Math.abs(Number(m[1])) <= ONE_CLICK_MAX);
  }
  assert.equal(applyUrl(8.2), 'mousecal://apply?m=8.2');
  assert.equal(applyUrl(-0.04), 'mousecal://apply?m=0.0');
  assert.equal(uninstallUrl(), 'mousecal://uninstall');
  assert.ok(vbsCharset.test(uninstallUrl()));
  // beyond the handler's +-20 limit (also after rounding to one decimal) and non-numbers are refused
  for (const bad of [20.05, -20.06, 21, 45, NaN, Infinity]) assert.throws(() => applyUrl(bad));
});

test('page wiring: one-click apply + uninstall buttons, first-install flow kept, blur fallback', () => {
  const html = read('index.html'), app = read('app.js');
  for (const id of ['btnOneClick', 'oneClickMsg', 'ocUrl', 'btnOneClickUn', 'oneClickUnMsg', 'unUrl', 'btnCopyInstall', 'btnCopyUninstall', 'cmdInstall', 'cmdUninstall']) {
    assert.ok(html.includes(`id="${id}"`), id);
  }
  assert.ok(/applyUrl\(/.test(app) && /uninstallUrl\(/.test(app));
  assert.ok(/addEventListener\('blur'/.test(app) && /1500/.test(app), 'no blur/1.5 s fallback');
  assert.ok(STRINGS.zh.btnOneClick === '一鍵套用（已經安裝過）');
  assert.ok(STRINGS.zh.firstTitle === '第一次安裝');
  assert.ok(STRINGS.zh.ocNotInstalled.includes('好像還沒安裝過') && STRINGS.zh.ocNotInstalled.includes('第一次安裝'));
  assert.ok(STRINGS.zh.btnOneClickUn === '一鍵解除安裝');
  // the copy-command flow is still there and unchanged
  assert.ok(/copyText\(installCommand\(measuredForCommand\(\)\)/.test(app));
});

test('setup.ps1 carries the handler: link validation before any command line, only two actions, confirm, local copy', () => {
  const s = read('setup.ps1');
  assert.ok(s.includes('Register-UrlProtocol') && s.includes('Unregister-UrlProtocol'));
  assert.ok(s.includes('HKLM:\\SOFTWARE\\Classes\\mousecal'));
  // the VBS check precedes the line that builds the command
  const vbs = /\$HandlerVbsText = @'\r?\n([\s\S]*?)\r?\n'@/.exec(s);
  assert.ok(vbs, 'no handler.vbs text');
  const v = vbs[1];
  assert.ok(v.indexOf('re.Test(url)') > 0 && v.indexOf('re.Test(url)') < v.indexOf('cmd ='));
  assert.ok(v.includes('"^[A-Za-z0-9:/?=.&-]+$"') && /Len\(url\) > 64/.test(v));
  assert.ok(v.includes('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'));
  const ps1 = /\$HandlerPs1Text = @'\r?\n([\s\S]*?)\r?\n'@/.exec(s);
  assert.ok(ps1, 'no handler.ps1 text');
  assert.ok(/function ConvertFrom-MousecalUrl/.test(ps1[1]) && /function Show-Confirm/.test(ps1[1]) && /function Show-Result/.test(ps1[1]) && /function Invoke-Elevated/.test(ps1[1]));
  assert.ok(/'YesNo' 'Question' 'Button2'/.test(ps1[1]), 'confirmation must default to No');
  assert.ok(/-Verb RunAs/.test(ps1[1]) && /MOUSECAL_NO_MAIN/.test(ps1[1]));
});

test('README documents the protocol, its limits and how uninstall removes it', () => {
  const r = read('README.md');
  for (const needle of ['mousecal://', 'mousecal://apply?m=', 'mousecal://uninstall', 'handler.vbs', 'handler.ps1', 'HKLM\\SOFTWARE\\Classes\\mousecal', 'handler.log']) {
    assert.ok(r.includes(needle), 'README lacks ' + needle);
  }
});
