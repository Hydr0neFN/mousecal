import { SETUP_SHA256 } from './setup-hash.js';

// The one place the page knows its own address. Forks: change SITE_BASE here and
// $SiteBase at the top of tools/setup.src.ps1 (then run `node tools/build-setup.mjs`).
export const SITE_BASE = 'https://mousecal.hydr0negnetwork.de';

// ADVANCED ONLY (the page keeps this under a collapsed "PowerShell command" section, never copies it on its own):
// one line that fits the Win+R dialog (limit 259 characters) and runs setup.ps1 from the site.
// Win+R then Ctrl+V then Ctrl+Shift+Enter runs it as administrator. Antivirus products treat "paste a command into Win+R"
// as a malware pattern (ClickFix), which is why the main flow is the downloaded launcher below.
// try/catch keeps the window open with the error visible when the download itself fails
// (setup.ps1 reports its own errors and waits for Enter by itself).
function runCommand(args, base) {
  return 'powershell -NoProfile -ExecutionPolicy Bypass -Command "try{& ([scriptblock]::Create((irm ' +
    base + '/setup.ps1))) ' + args + "}catch{$_;Read-Host 'Press Enter'}\"";
}

export function formatRotation(rotation) {
  let v = Math.round(rotation * 10) / 10;
  if (v === 0) v = 0; // no "-0.0"
  return v.toFixed(1);
}

// `measured` is the angle the page measured. setup.ps1 adds it to the rotation the driver
// currently applies (or uses it as is when no driver runs). `-Rotation <abs>` also exists for manual use.
// `base` only exists so tests can point the command at a host that does not exist.
export function installCommand(measured, base = SITE_BASE) {
  if (!Number.isFinite(measured) || Math.abs(measured) > 45) throw new Error('angle out of range');
  return runCommand('-Measured ' + formatRotation(measured), base);
}

// `restore` (true) also puts Windows "Enhance pointer precision" back to the value saved at install time.
export function uninstallCommand(restore = false, base = SITE_BASE) {
  return runCommand('-Uninstall' + (restore === true ? ' -RestorePointerPrecision' : ''), base);
}

// One-click links for people who already ran the install command once: the installer registers the
// mousecal:// URL protocol, and its handler (setup.ps1 -> <ProgramFiles>\RawAccel\mousecal\) accepts exactly
// these shapes (apply?m=<deg>, uninstall, uninstall?epp=1). It asks for confirmation every time. The handler refuses |m| > 20, so we do too.
export const ONE_CLICK_MAX = 20;

export function applyUrl(theta) {
  if (!Number.isFinite(theta)) throw new Error('angle out of range');
  const s = formatRotation(theta); // one decimal, same rounding as the install command
  if (Math.abs(Number(s)) > ONE_CLICK_MAX) throw new Error('angle out of range');
  return 'mousecal://apply?m=' + s;
}

// `restore` (true) -> ?epp=1: the handler passes -RestorePointerPrecision. Without it nothing is restored.
export function uninstallUrl(restore = false) {
  return restore === true ? 'mousecal://uninstall?epp=1' : 'mousecal://uninstall';
}

// ---------------------------------------------------------------------------------------------------------------
// The downloaded launcher: the page builds the text of a small .cmd file in the browser (Blob + <a download>); the
// user opens it. It is plain text on purpose (readable in Notepad), pure ASCII (Chinese messages are printed through
// PowerShell from \uXXXX escapes, so no code page can garble them) and uses CRLF line endings.
// Flow: check for admin rights with fltmc (relaunch itself elevated at most once, marked by an argument) -> ONE
// elevated PowerShell -Command line that makes a brand-new random folder under %ProgramData% (ACL set at creation),
// downloads setup.ps1 into it, checks its SHA256 against SETUP_SHA256 (generated together with setup.ps1), runs it
// with -File, deletes the folder and pauses. All logic is in that one line, so cmd has nothing left to re-read.
// Nothing is piped into an interpreter: no irm, no iex, no scriptblock::Create, no Win+R.
export const REPO_URL = 'https://github.com/Hydr0neFN/mousecal';
export const LAUNCHER_MARKER = 'mousecal-elevated';

const toEscapes = (s) => s.replace(/[^\x20-\x7e]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));

// zh text printed by the launcher (exported so tests can decode the escapes back and compare).
export const LAUNCHER_ZH = {
  working: 'mousecal：正在下載並檢查檔案，請稍候。',
  noDir: '無法建立安全的暫存資料夾，沒有做任何變更。',
  noDownload: '下載失敗，請檢查網路後再試一次。沒有做任何變更。',
  mismatch: '下載的檔案和網站上的版本不一致，已停止。請重新整理網頁再下載一次。',
  declined: '沒有取得系統管理員權限（可能按了「否」）。沒有做任何變更。',
  noAdmin: '仍然沒有系統管理員權限，已停止。沒有做任何變更。',
  close: '按任意鍵關閉'
};
const LAUNCHER_EN = {
  working: 'mousecal: downloading and checking the file, please wait.',
  noDir: 'Could not create a safe temporary folder. Nothing was changed.',
  noDownload: 'The download failed. Check your internet connection and try again. Nothing was changed.',
  mismatch: 'The downloaded file does not match the version on the website. Stopped. Reload the web page and download the launcher again.',
  declined: 'Administrator permission was not granted (or the Windows prompt could not be shown). Nothing was changed.',
  noAdmin: 'Still no administrator rights, so it stopped. Nothing was changed.',
  close: 'Press any key to close.'
};

export function launcherFilename(mode, measured) {
  if (mode === 'uninstall') return 'mousecal-uninstall.cmd';
  return 'mousecal-setup-' + formatRotation(measured) + '.cmd';
}

// mode 'install' needs `measured` (degrees, |x| <= 45, one decimal like the one-click link);
// mode 'uninstall' ignores it and adds -RestorePointerPrecision only when restoreEpp === true.
// `base` / `sha256` exist so tests can use other values; both are validated because they end up in a batch file.
export function launcherCmd({ measured, restoreEpp = false, mode = 'install', base = SITE_BASE, sha256 = SETUP_SHA256 } = {}) {
  if (mode !== 'install' && mode !== 'uninstall') throw new Error('unknown mode');
  if (!/^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._-]+)*$/.test(base)) throw new Error('bad site address');
  if (!/^[0-9a-fA-F]{64}$/.test(sha256)) throw new Error('bad SHA256');
  const hash = sha256.toLowerCase();
  let args, what, actionLine;
  if (mode === 'install') {
    if (!Number.isFinite(measured) || Math.abs(measured) > 45) throw new Error('angle out of range');
    const deg = formatRotation(measured);
    args = '-Measured ' + deg + ' -NoPause';
    what = 'setup';
    actionLine = 'rem Measured angle     : ' + deg + ' degrees (measured by the web page; setup adds it to the rotation already applied)';
  } else {
    args = '-Uninstall' + (restoreEpp === true ? ' -RestorePointerPrecision' : '') + ' -NoPause';
    what = 'uninstall';
    actionLine = 'rem Action               : remove what mousecal installed' + (restoreEpp === true ? ', and put Windows "Enhance pointer precision" back' : '');
  }
  const url = base + '/setup.ps1';
  const PS = '%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  const zh = (key) => 'call :zh "' + toEscapes(LAUNCHER_ZH[key]) + '"';
  const en = (key) => 'echo ' + LAUNCHER_EN[key];
  const both = (key) => [en(key), zh(key)];
  // The PowerShell block lives inside cmd's double quotes: it may not contain " or % (cmd would change them) and uses
  // only single-quoted strings. Messages are 'English' 'zh as \uXXXX' pairs printed by the helper function m.
  const m = (key) => "m '" + LAUNCHER_EN[key] + "' '" + toEscapes(LAUNCHER_ZH[key]) + "';";
  const psExe = "($env:SystemRoot+'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe')";
  const block = [
    "$ErrorActionPreference='Stop';",
    'function m($e,$z){Write-Host $e;Write-Host ([regex]::Unescape($z))}',
    // delete a tree without ever following a link: a reparse point (1024) is removed itself, never entered
    'function d($x){$t=[IO.File]::GetAttributes($x);if(($t -band 16) -and -not ($t -band 1024)){foreach($c in [IO.Directory]::GetFileSystemEntries($x)){d $c}};if($t -band 16){[IO.Directory]::Delete($x)}else{[IO.File]::Delete($x)}}',
    '$rc=1;$k=1;$mine=$false;$p=$null;',
    m('working'),
    'try{',
    '[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12;',
    "$adm=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544');",
    "$sys=New-Object Security.Principal.SecurityIdentifier('S-1-5-18');",
    '$sec=New-Object Security.AccessControl.DirectorySecurity;',
    '$sec.SetAccessRuleProtection($true,$false);',
    '$sec.SetOwner($adm);',
    "foreach($s in $adm,$sys){$sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($s,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))};",
    "$p=Join-Path $env:ProgramData ('mousecal-dl-'+[guid]::NewGuid().ToString('N'));",
    '$ex=$true;try{$null=[IO.File]::GetAttributes($p)}catch{$ex=$false};',
    "if($ex){throw 'the folder already exists'};",
    '$null=[IO.Directory]::CreateDirectory($p,$sec);$mine=$true;',
    "if([IO.File]::GetAttributes($p) -band 1024){throw 'the folder is a link'};",
    "if(-not [IO.Directory]::GetAccessControl($p).AreAccessRulesProtected){throw 'the folder is not locked'};",
    "$f=Join-Path $p 'setup.ps1';$k=2;",
    '$w=New-Object Net.WebClient;$w.Proxy=[Net.WebRequest]::GetSystemWebProxy();$w.Proxy.Credentials=[Net.CredentialCache]::DefaultCredentials;',
    '$w.DownloadFile($env:MC_URL,$f);$w.Dispose();$k=3;',
    "$s=[IO.File]::OpenRead($f);try{$g=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($s)).Replace('-','').ToLower()}finally{$s.Dispose()};",
    'if($g -ne $env:MC_SHA256){$rc=4;' + m('mismatch').slice(0, -1) + '}else{$k=4;Write-Host \'\';' +
      '& ' + psExe + ' -NoProfile -ExecutionPolicy Bypass -File $f ' + args + ';$rc=[int]$LASTEXITCODE}',
    '}catch{if($k -eq 1){' + m('noDir') + '}elseif($k -le 3){' + m('noDownload') + '}else{Write-Host $_.Exception.Message}}',
    "finally{if($mine){try{d $p}catch{Write-Host ('Could not delete '+$p)}}};",
    "Write-Host '';" + m('close'),
    'try{[void][Console]::ReadKey($true)}catch{};exit $rc'
  ].join('');
  if (/["%\r\n]/.test(block)) throw new Error('bad character in the PowerShell block');
  if (block.length > 7000) throw new Error('PowerShell block too long for one cmd line');

  const lines = [
    '@echo off',
    'rem ======================================================================================',
    'rem mousecal ' + what + ' launcher - a small text file made by the mousecal web page in your browser.',
    'rem You can open it in Notepad and read every line. It does not hide anything.',
    actionLine,
    'rem Source of setup.ps1: ' + url,
    'rem Expected SHA256    : ' + hash + ' (also shown in the Advanced section of the page)',
    'rem Project (open source): ' + REPO_URL,
    'rem What it does:',
    'rem   1. asks for administrator rights (the Windows UAC window), once',
    'rem   2. makes a brand-new folder under ProgramData that only administrators can use',
    'rem   3. downloads setup.ps1 from the address above into that folder',
    'rem   4. checks the SHA256 of the download; if it differs it stops and runs nothing',
    'rem   5. runs setup.ps1 (it installs or removes Raw Accel, a mouse driver)',
    'rem   6. deletes the folder again',
    'rem Steps 2-6 are the one long PowerShell line below.',
    'rem ======================================================================================',
    'setlocal EnableExtensions DisableDelayedExpansion',
    'set "MC_SELF=%~f0"',
    // before anything else runs: nothing below can pick up a program from the folder this file was saved in
    'cd /d "%SystemRoot%\\System32"',
    '"%SystemRoot%\\System32\\fltmc.exe" >nul 2>&1 || goto :elevate',
    'set "MC_URL=' + url + '"',
    'set "MC_SHA256=' + hash + '"',
    '"' + PS + '" -NoProfile -Command "' + block + '" & exit /b',
    '',
    ':elevate',
    'if /i "%~1"=="' + LAUNCHER_MARKER + '" goto :noadmin',
    '"' + PS + '" -NoProfile -Command "try{Start-Process -FilePath $env:MC_SELF -ArgumentList \'' + LAUNCHER_MARKER + '\' -Verb RunAs -ErrorAction Stop}catch{exit 1}" && exit /b 0',
    'echo.',
    ...both('declined'),
    'goto :end',
    '',
    ':noadmin',
    'echo.',
    ...both('noAdmin'),
    '',
    ':end',
    'echo.',
    ...both('close'),
    'pause >nul',
    'exit /b 1',
    '',
    'rem prints a Chinese message given as \\uXXXX escapes (this file stays ASCII)',
    ':zh',
    '"' + PS + '" -NoProfile -Command "Write-Host ([regex]::Unescape(\'%~1\'))"',
    'exit /b 0',
    ''
  ];
  const text = lines.join('\r\n');
  if (/[^\x00-\x7f]/.test(text)) throw new Error('launcher must be ASCII');
  return text;
}
