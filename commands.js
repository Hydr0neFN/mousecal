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
// Flow: self-elevate -> admin-only folder under %ProgramData% -> download setup.ps1 -> check SHA256 against
// SETUP_SHA256 (generated together with setup.ps1) -> run it with -File -> delete the folder -> one pause.
// Nothing is piped into an interpreter: no irm, no iex, no scriptblock::Create, no Win+R.
export const REPO_URL = 'https://github.com/Hydr0neFN/mousecal';

const toEscapes = (s) => s.replace(/[^\x20-\x7e]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));

// zh text printed by the launcher (exported so tests can decode the escapes back and compare).
export const LAUNCHER_ZH = {
  working: 'mousecal：正在下載並檢查檔案，請稍候。',
  noDir: '無法建立安全的暫存資料夾，沒有做任何變更。',
  noDownload: '下載失敗，請檢查網路後再試一次。沒有做任何變更。',
  mismatch: '下載的檔案和網站上的版本不一致，已停止。請重新整理網頁再下載一次。',
  close: '按任意鍵關閉'
};
const LAUNCHER_EN = {
  working: 'mousecal: downloading and checking the file, please wait.',
  noDir: 'Could not create a safe temporary folder. Nothing was changed.',
  noDownload: 'The download failed. Check your internet connection and try again. Nothing was changed.',
  mismatch: 'The downloaded file does not match the version on the website. Stopped. Reload the web page and download the launcher again.',
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
  const zh = (key) => 'call :zh "' + toEscapes(LAUNCHER_ZH[key]) + '"';
  const en = (key) => 'echo ' + LAUNCHER_EN[key];
  const both = (key) => [en(key), zh(key)];
  const ACL = '/inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F';

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
    'rem   1. asks for administrator rights (the Windows UAC window)',
    'rem   2. makes a folder only administrators can write to, under ProgramData',
    'rem   3. downloads setup.ps1 from the address above into that folder',
    'rem   4. checks the SHA256 of the download; if it differs it stops and runs nothing',
    'rem   5. runs setup.ps1 (it installs or removes Raw Accel, a mouse driver)',
    'rem   6. deletes the folder again',
    'rem ======================================================================================',
    'setlocal EnableExtensions',
    // first, so nothing below can pick up a program from the folder this file was saved in
    'cd /d "%SystemRoot%\\System32"',
    'net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath \'%~f0\' -Verb RunAs" & exit /b)',
    'set "MC_URL=' + url + '"',
    'set "MC_SHA256=' + hash + '"',
    'set "MC_ROOT=%ProgramData%\\mousecal"',
    'set "MC_DIR=%MC_ROOT%\\dl-%RANDOM%%RANDOM%%RANDOM%"',
    'set "MC_PS1=%MC_DIR%\\setup.ps1"',
    'set "MC_MADE="',
    'set "MC_RC=1"',
    'echo.',
    'echo ' + LAUNCHER_EN.working,
    zh('working'),
    '',
    'rem --- an administrators-only working folder (a pre-made link is refused)',
    'if exist "%MC_ROOT%" fsutil reparsepoint query "%MC_ROOT%" >nul 2>&1 && goto :fail_dir',
    'if not exist "%MC_ROOT%" mkdir "%MC_ROOT%" >nul 2>&1',
    'if not exist "%MC_ROOT%" goto :fail_dir',
    'icacls "%MC_ROOT%" /setowner *S-1-5-32-544 >nul 2>&1 || goto :fail_dir',
    'icacls "%MC_ROOT%" ' + ACL + ' >nul 2>&1 || goto :fail_dir',
    'if exist "%MC_DIR%" goto :fail_dir',
    'mkdir "%MC_DIR%" >nul 2>&1 || goto :fail_dir',
    'set "MC_MADE=1"',
    'icacls "%MC_DIR%" ' + ACL + ' >nul 2>&1 || goto :fail_dir',
    '',
    'rem --- download (curl.exe is built into Windows 10 1803 and later; otherwise PowerShell)',
    'set "MC_OK="',
    'where curl.exe >nul 2>&1 && curl.exe -fsSL -o "%MC_PS1%" "%MC_URL%" && set "MC_OK=1"',
    'if not defined MC_OK powershell -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri \'%MC_URL%\' -OutFile \'%MC_PS1%\';exit 0}catch{exit 1}" && set "MC_OK=1"',
    'if not defined MC_OK goto :fail_download',
    'if not exist "%MC_PS1%" goto :fail_download',
    '',
    'rem --- check the download against the hash this web page was built with',
    'set "MC_GOT="',
    'for /f "skip=1 delims=" %%H in (\'certutil -hashfile "%MC_PS1%" SHA256 2^>nul\') do if not defined MC_GOT set "MC_GOT=%%H"',
    'if not defined MC_GOT goto :fail_hash',
    'set "MC_GOT=%MC_GOT: =%"',
    'if /i not "%MC_GOT%"=="%MC_SHA256%" goto :fail_hash',
    '',
    'rem --- run it',
    'echo.',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%MC_PS1%" ' + args,
    'set "MC_RC=%errorlevel%"',
    'goto :done',
    '',
    ':fail_dir',
    'echo.',
    ...both('noDir'),
    'goto :done',
    '',
    ':fail_download',
    'echo.',
    ...both('noDownload'),
    'goto :done',
    '',
    ':fail_hash',
    'echo.',
    ...both('mismatch'),
    'set "MC_RC=4"',
    'goto :done',
    '',
    ':done',
    'if defined MC_MADE if exist "%MC_DIR%" rmdir /s /q "%MC_DIR%" >nul 2>&1',
    'echo.',
    ...both('close'),
    'pause >nul',
    'exit /b %MC_RC%',
    '',
    'rem prints a Chinese message given as \\uXXXX escapes (this file stays ASCII)',
    ':zh',
    'powershell -NoProfile -Command "Write-Host ([regex]::Unescape(\'%~1\'))"',
    'exit /b 0',
    ''
  ];
  const text = lines.join('\r\n');
  if (/[^\x00-\x7f]/.test(text)) throw new Error('launcher must be ASCII');
  return text;
}
