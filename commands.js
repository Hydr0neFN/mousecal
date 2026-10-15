// The one place the page knows its own address. Forks: change SITE_BASE here and
// $SiteBase at the top of tools/setup.src.ps1 (then run `node tools/build-setup.mjs`).
export const SITE_BASE = 'https://mousecal.hydr0negnetwork.de';

// One line that fits the Win+R dialog (limit 259 characters) and runs setup.ps1 from the site.
// Win+R then Ctrl+V then Ctrl+Shift+Enter runs it as administrator.
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

export function uninstallCommand(base = SITE_BASE) {
  return runCommand('-Uninstall', base);
}

// One-click links for people who already ran the install command once: the installer registers the
// mousecal:// URL protocol, and its handler (setup.ps1 -> <ProgramFiles>\RawAccel\mousecal\) accepts exactly
// these two shapes. It asks for confirmation every time. The handler refuses |m| > 20, so we do too.
export const ONE_CLICK_MAX = 20;

export function applyUrl(theta) {
  if (!Number.isFinite(theta)) throw new Error('angle out of range');
  const s = formatRotation(theta); // one decimal, same rounding as the install command
  if (Math.abs(Number(s)) > ONE_CLICK_MAX) throw new Error('angle out of range');
  return 'mousecal://apply?m=' + s;
}

export function uninstallUrl() {
  return 'mousecal://uninstall';
}
