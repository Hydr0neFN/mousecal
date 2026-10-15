# mousecal

A static website that measures how many degrees your mouse sensor is rotated and helps you fix it.

People swipe the mouse "horizontally" but the pointer drifts up or down by a few degrees. The page
measures that angle in the browser (pointer lock, raw movement where available), then offers two fixes:

- **Windows:** one copied command (Win+R, Ctrl+V, Ctrl+Shift+Enter) that installs
  [Raw Accel](https://github.com/RawAccelOfficial/rawaccel) and sets its "Degrees of rotation".
  Usually no reboot is needed.
- **Mac / no install:** a diagram that shows how many degrees, and in which direction, to rotate the mouse body.

Then it measures again and shows pass / fail (Windows path: |angle| <= 1 deg, physical path: <= 2 deg).
The page is Traditional Chinese (Taiwan) by default with an English toggle.

Raw Accel is **not redistributed** here. `setup.ps1` downloads it from its official GitHub release and
verifies the SHA256 before using it.

[Traditional Chinese section below / 繁體中文說明在下方](#繁體中文)

## Convention

`theta = atan2(-dy, dx)` in degrees (screen y points down), folded to (-90, 90]. Positive theta means a
"horizontal" right swipe drifts **up** (counter-clockwise).

- Raw Accel's `"Degrees of rotation"` is clockwise-positive on screen, so the value to set is `+theta`
  (`setup.ps1` adds the measured angle to the rotation the driver already applies, because the browser measures the already-corrected motion).
- Physically: reading `+theta` means the sensor's x axis sits theta clockwise from the hand's true
  horizontal, so rotate the mouse body **counter-clockwise** by theta seen from above (clockwise when
  theta is negative). Rotating only the mousepad does nothing.

## Files

| File | Purpose |
| --- | --- |
| `index.html`, `style.css` | The page. Self-contained; only Google Fonts are loaded externally. |
| `app.js` | Pointer-lock measurement, live trail, result, re-measure, copy buttons. |
| `analysis.js` | Pure functions (ES module, no DOM): stroke segmentation, statistics, `verdict`, `rawAccelSettings`. |
| `commands.js` | The **one** place the page knows its own address (`SITE_BASE`) and the copied commands. |
| `i18n.js` | All strings (zh-TW and English). |
| `example.js` | Precomputed example result (summed stroke vectors of a real capture), shown labelled "example". |
| `settings-template.js` | Generated: Raw Accel default settings, used by the "Advanced" section. |
| `setup.ps1` | Generated, ASCII-only installer / uninstaller (see below). |
| `_headers`, `.assetsignore` | Cloudflare static-assets config. |
| `tools/setup.src.ps1` | **Source of truth** for `setup.ps1`. |
| `tools/settings.template.json` | Raw Accel default `settings.json` (single source for the template). |
| `tools/zip-files.txt` | SHA256 of every file in `RawAccel_v1.7.1.zip` (embedded into `setup.ps1`). |
| `tools/build-setup.mjs` | Builds `setup.ps1` and `settings-template.js` from the two files above. |
| `tools/make-example.mjs` | Regenerates `example.js` from a capture CSV (`t` seconds, `dx`, `dy`, `device`). |
| `test/` | `analysis.test.mjs`, `site.test.mjs` (node, no dependencies) and `setup.test.ps1`. |

`setup.ps1` is generated so that it stays pure ASCII: Chinese text becomes `\uXXXX` escapes that the script
decodes at run time. That way it works however `irm` decodes the download (no charset header needed).
After editing `tools/setup.src.ps1` or `tools/settings.template.json`, run `node tools/build-setup.mjs`.

## Deploy (Cloudflare Workers static assets)

The directory containing `index.html` is the assets directory. Minimal `wrangler.jsonc`:

```jsonc
{
  "name": "mousecal",
  "compatibility_date": "2026-10-01",
  "assets": { "directory": "." }
}
```

`.assetsignore` keeps `test/`, `tools/`, `README.md` etc. out of the upload; `_headers` serves `setup.ps1`
as `text/plain; charset=utf-8`. Modules are used (`<script type="module">`), so serve over http(s), not `file://`.

### Forking

Change the address in two places, then rebuild:

1. `SITE_BASE` in `commands.js`
2. `$SiteBase` near the top of `tools/setup.src.ps1`, then `node tools/build-setup.mjs`

`node --test test/site.test.mjs` checks that both constants agree and the copied command fits the Win+R
dialog (< 259 characters).

## How setup.ps1 works

The copied command is:

```
powershell -NoProfile -ExecutionPolicy Bypass -Command "try{& ([scriptblock]::Create((irm https://<site>/setup.ps1))) -Measured 8.2}catch{$_;Read-Host 'Press Enter'}"
```

The `try/catch` keeps the Win+R window open with the error visible if the download itself fails; the script
reports its own errors and waits for Enter by itself. The command stays under the 259 character Run-dialog limit.

Parameters: `-Measured <deg>` (the angle the page measured), `-Rotation <deg>` (absolute value, manual use;
exactly one of the two is required), `-Uninstall`, `-DryRun`, `-NoPause` (also `MOUSECAL_NO_PAUSE=1`).
Numbers are parsed with the invariant culture; a comma is rejected. It works in Windows PowerShell 5.1 and
PowerShell 7, needs an administrator terminal, uses TLS 1.2 and has no telemetry.

**New rotation.** The browser measures the already-corrected motion, so with `-Measured` the script reads the
rotation the running driver applies right now (`DriverConfig.GetActive()` from Raw Accel's own `wrapper.dll`)
and sets `new = active + measured` (or just `measured` if no driver runs). It prints
`current X -> new Y` and refuses (exit 3) if `|new| > 45`. The website therefore stores no state.

Install, in this order:

1. Refuses (exit 6) while a listed game / anti-cheat process runs (CS2, Apex, VALORANT/League, Fortnite, Rust,
   Rocket League, EasyAntiCheat, FACEIT, BattlEye, Perfect World Arena; the last three groups are best-effort
   names). `-DryRun` only warns; `vgc` (Riot Vanguard's permanent service) only warns.
2. Checks .NET Framework >= 4.7.2 and the VC++ x64 runtime (Microsoft's installer is downloaded only if
   missing, into the admin-only staging folder, and must carry a valid Microsoft signature before it runs).
3. Downloads `RawAccel_v1.7.1.zip` **into memory**, aborts unless its SHA256 equals
   `770FE3AE0919CA3C4D412F58C985EB27F5434DECAD809F7E8206DE4E8852EEC4`, then extracts it straight from that
   buffer into `C:\Program Files\RawAccel\.staging` (ACL: Administrators + SYSTEM only). **Every one of the 24
   files** is hashed against `tools/zip-files.txt` before it is written; extra, missing or altered files abort
   with exit 4. `driver\rawaccel.sys` must also have a valid Authenticode signature.
4. Computes the new rotation and generates `settings.json` (existing file: only `"Degrees of rotation"`
   changes, everything else stays; otherwise the default template, no acceleration). It is validated with Raw
   Accel's own `DriverConfig.Convert` in a Windows PowerShell 5.1 child, using the staged DLLs.
5. From here on it is transactional. Copies the verified files to `C:\Program Files\RawAccel\RawAccel\`,
   re-checks their hashes, writes the ownership marker `.mousecal-installed`, backs up and writes
   `settings.json` and validates it again with the installed `wrapper.dll`.
6. Runs the verified `installer.exe` (from the staging folder) hidden if the `rawaccel` filter is not yet in
   `UpperFilters`. The installer copies `rawaccel.sys` to `system32\drivers`, creates the service and adds the
   filter last, then waits for a key. The script polls for filter + driver file + service key, then stops it.
7. Re-checks for games, restarts the mouse devices (`pnputil /restart-device`) so the filter attaches without a
   reboot, then health-checks the mouse devices. If a device is in an error state and the driver is not running,
   **everything is rolled back** (driver uninstalled, files and settings restored) and the script exits 8.
8. Registers the task `RawAccel Apply Settings`: runs as SYSTEM, at startup (15 s delay) and at every logon
   (10 s delay), directly `writer.exe "<settings.json>"` (session 0, so no window and no VBS). A task or VBS
   left by an older version is replaced; on failure it is restored.
9. If the driver runs and no game runs, applies immediately with `writer.exe` (exit code must be 0) and reads
   the active rotation back before saying "active now, no reboot". Otherwise it asks for a reboot; the task
   applies the settings by itself afterwards. Exit code is 0 either way. Any failure after step 5 rolls back.

Re-running keeps ownership: an existing valid marker is carried forward (its flags are never downgraded) and a
rollback puts the original marker back byte for byte. Existing files that differ from the official ones are
copied to the admin-only staging folder before being replaced and restored if the run fails; if a rollback step
fails, the message says the rollback was INCOMPLETE. The driver state is decided by CIM and, failing that, by a
successful `GetActive()` read; with `-Measured` and an undeterminable state the script stops with exit 1 and
changes nothing. The task runs as SYSTEM, addressed by its SID (`S-1-5-18`), so it works on any Windows language.

`-Uninstall` removes only what this script installed. With a valid marker it first removes the driver (the
installed `uninstaller.exe` if it matches the pinned hash, otherwise one from a freshly downloaded and fully
verified official zip, staged in the admin-only folder) and only then the scheduled task and legacy VBS, so a
failed driver removal leaves a working setup. Then it restarts the mouse devices and deletes the files it
installed (the pinned list plus `settings.json` and its backups) and the marker. Anything else in the folder is
left and reported. If Raw Accel was already on the PC (no marker), only the task / VBS are removed and you are
told to use Raw Accel's own uninstaller.

`-DryRun` downloads, hashes (zip and every file), extracts to a temp folder, reads the active rotation and
generates and validates the settings, then prints every action it would take. It changes nothing else.

### One-click link (`mousecal://` URL protocol)

The first install is still the copied command. A real install also registers a URL protocol (right after the
startup task and before the immediate apply; a failure there is only a warning, and a later failure rolls it
back) so that later "re-measure, apply" and "uninstall" are one click on the page:

| Link | Does |
| --- | --- |
| `mousecal://apply?m=<deg>` | adds the measured `<deg>` to the active rotation (new = active + m) and applies it |
| `mousecal://uninstall` | runs the normal uninstall |

`mousecal://apply/?m=8.2` and `mousecal:apply?m=8.2` are accepted too (browsers differ). The page's "One-click
apply" button builds the link with `applyUrl(theta)` and the uninstall button with `uninstallUrl()` (both in
`commands.js`). If the page keeps focus for about 1.5 s after the click, it says the tool does not look
installed and points at "First install".

What is installed (all by the elevated install, in an administrators-only place):

- Files in `<ProgramFilesDir>\RawAccel\mousecal\` (administrators + SYSTEM full control, Users read and execute
  only): `handler.vbs`, `handler.ps1`, and `setup.ps1`, a copy of the exact script text that was running (works
  for `-File` and for the pasted script-block command alike). Re-running the install refreshes them.
- Registry `HKLM\SOFTWARE\Classes\mousecal`: default value `URL:mousecal Protocol`, value `URL Protocol` empty,
  and `shell\open\command` = `"<SystemRoot>\System32\wscript.exe" "<dir>\handler.vbs" "%1"`.
- `handler.vbs` receives the raw link and rejects it unless it is at most 64 characters of `[A-Za-z0-9:/?=.&-]`,
  **before** any command line is built (no quote or command injection), then starts `handler.ps1` hidden.
- `handler.ps1` (`ConvertFrom-MousecalUrl`, `Show-Confirm`, `Show-Result`, `Invoke-Elevated`; dot-source it
  with `MOUSECAL_NO_MAIN=1`) runs as the normal user: parse the link, stop if a game / anti-cheat process runs,
  read the active rotation, refuse if the new value would exceed 45 degrees, show a Yes/No dialog (default No)
  with "current -> new", and only on Yes start the **local** `setup.ps1 -Rotation <new absolute value> -NoPause`
  (or `-Uninstall -NoPause`) elevated through UAC, wait, and show a result dialog from the exit code. It uses
  the absolute rotation so a retry cannot add the measurement twice. It logs values only (no personal data) to
  `%LOCALAPPDATA%\mousecal\handler.log` (per user, in the user's own profile, so the elevated uninstall does not
  touch it); delete it by hand if you want.

Security limits of the protocol:

- Every action asks for confirmation each time (dialog, default No) and then UAC; nothing happens on a click alone.
- Only two actions exist (apply a measured angle, uninstall). Any other text, extra parameter, other number
  shape (`^-?\d{1,2}(\.\d{1,2})?$`, invariant culture), or `|m| > 20` is rejected; so is any link longer than 64
  characters or with a character outside the set above. The new absolute rotation is limited to +-45.
- The elevated step runs only the copy of `setup.ps1` in the administrators-only folder (the handler refuses
  any other path or any argument outside `[A-Za-z0-9.-]`), with an absolute `powershell.exe` path; a standard
  user cannot change those files or the registry key. Nothing is downloaded by the handler itself (the elevated
  setup downloads the pinned Raw Accel files as usual). The local copy is the version you installed; to update
  it, run the install command again.
- A web page can only start the handler, never feed it anything but the two link shapes.
- The handler relies on **VBScript** (`wscript.exe` + `handler.vbs`). Microsoft has deprecated VBScript and may
  ship Windows builds without it; if the one-click buttons stop working, use the copy-command method on the
  website, which needs neither the handler nor VBScript. When a 32-bit `wscript.exe` runs the handler, the 64-bit
  PowerShell is started through `Sysnative`.

Concurrency and permissions: a real run takes the named mutex `Global\mousecal-setup`; a second run exits with
code 1 ("another mousecal setup is running"). Each run stages in its own `.staging\<guid>` folder and removes only
that one; stale `.staging\<guid>` folders of crashed runs are deleted at startup (while holding the mutex).
`<ProgramFiles>\RawAccel` (the folder itself), `...\RawAccel\RawAccel` and `...\mousecal` get an exact DACL: a fresh
protected ACL with only SYSTEM full control, Administrators full control and Users read & execute (SIDs; every other
entry, such as Everyone, a single user or a deny, is removed), owner Administrators; everything below the last two is
reset to inherit exactly that. The root is locked before `.staging` is created, the app dir before any file is
copied, and again after `settings.json` is written, even if the folders pre-existed with user write access.
Junctions / symlinks found inside the app or handler folder are deleted (never followed) before any recursive
operation; a link as the folder itself aborts the run. Elevated runs only search the Windows and Program Files module
folders (not `Documents\WindowsPowerShell\Modules`). `writer.exe` is stopped (and the run rolled back) if it takes
longer than 30 s. So
editing `settings.json`, or saving from the Raw Accel GUI, needs an administrator. If the driver profiles have
different rotations, `-Measured` and the one-click button refuse (exit 3); `-Rotation <deg>` still sets them all.
After the mouse devices are restarted, any mouse that was OK before and is not OK now, or is missing and does not
reappear within 10 s, undoes the install (exit 8), even when the driver reports Running. If this run restarted the
mouse devices, a rollback restarts them again.

`-Uninstall` removes the registry key (only if its command still points at this handler), the three files and
the folder (if nothing else is in it). It does this after the driver removal succeeded, so a failed uninstall
keeps the one-click link for a retry. `-DryRun` prints the registry key, the command and the files for install
and uninstall.

Exit codes (when run as a file): 0 ok, 1 other error, 2 not admin, 3 bad arguments, 4 hash mismatch,
5 invalid signature, 6 game / anti-cheat running, 7 prerequisite missing, 8 driver install failed (rolled back).
When pasted as a script block it never calls `exit` (that would close the terminal); it sets `$LASTEXITCODE`.
The window ends with "Press Enter to close" when interactive.

For tests, set `$env:MOUSECAL_NO_MAIN = '1'` and dot-source `setup.ps1` to load only the functions.

### What the upstream installer does (v1.7.1)

`installer.exe` copies `driver\rawaccel.sys` (relative to its working directory) to
`%systemroot%\system32\drivers`, creates or updates the demand-start kernel service `rawaccel`, and adds
`rawaccel` to the mouse class `UpperFilters` **last**, then waits for a key. `uninstaller.exe` removes the
`UpperFilters` entry **first**, renames the `.sys` to `.sys.tmp` (deleted at reboot), does not delete the
service key, and also waits for a key. That is why completion is detected by observing the registry and files.

## Security

- The copied command runs the `setup.ps1` served by the site, so the site is the trust root, as with any
  "paste this in a terminal" installer. Mitigations: HTTPS on the owner's domain, the script is open source on
  GitHub, everything it downloads is pinned by SHA256 (the zip and each file inside it) or must carry a
  Microsoft signature, and you can read it first (the link on the page) or run it with `-DryRun`.
- Nothing is executed from a user-writable location while elevated: the zip is hashed in memory and staged in
  an administrators-only folder; the validator script and DLLs it loads live there or under Program Files.
- Known limit (accepted): the setup mutex `Global\mousecal-setup` is a plain named mutex, so another local process
  can create it first and make real runs report "another mousecal setup is running" (denial of service only; it
  cannot make setup do anything). Reboot or end that process to clear it.
- `-DryRun` is exempt: it never elevates, changes nothing, and stages in `%TEMP%`. Real runs never execute or load anything from `%TEMP%`.
- Uninstall touches only what the ownership marker says this tool installed. The marker is
  `<ProgramFilesDir>\RawAccel\RawAccel\.mousecal-installed`, JSON
  `{"tool":"mousecal","installedDriver":true,"createdAppDir":true,"version":"1"}` (the plain text `mousecal` is
  accepted as a legacy marker meaning both flags true).
- The `mousecal://` URL protocol (see "One-click link") always confirms, supports only apply (|m| <= 20,
  result within +-45) and uninstall, validates the link before building any command line, and its files and
  registry key can only be written by administrators.
- Raw Accel is a third-party kernel driver (Microsoft-signed). Some anti-cheats dislike such drivers; see below.

## Tests

```
node --test test/*.mjs
powershell -NoProfile -ExecutionPolicy Bypass -File test\setup.test.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 -DryRun -NoPause -Measured 2.3
```

Use the glob `node --test test/*.mjs` (a bare `node --test` or `test/` also picks up `setup.test.ps1`, which is not a
node test). `analysis.test.mjs` recovers synthetic +5 / -3 / 0 degree swipes (with noise, 60 / 144 Hz event rates) within
0.3 degrees. Set `MOUSECAL_SAMPLE_CSV` to a capture CSV to also check real data. `setup.test.ps1` is offline and
never installs anything (the system-changing functions are not called). Its `mousecal://` tests redirect the
registry key to a throw-away `HKCU:\Software\mousecal-test-<random>` key (removed at the end), stub the folder
lock (`icacls`), `Start-Process` and every dialog, and run `handler.vbs` under `cscript` with the final `Run`
swapped for a print; the real `HKLM:\SOFTWARE\Classes\mousecal` is never written.

## Notes and limits

- With plain pointer lock (no raw input) the result may include OS mouse acceleration; the page says so and
  tells Windows users to switch off "Enhance pointer precision".
- Some Easy Anti-Cheat games ignore Raw Accel while running (see Raw Accel issues
  [#304](https://github.com/RawAccelOfficial/rawaccel/issues/304),
  [#306](https://github.com/RawAccelOfficial/rawaccel/issues/306),
  [#318](https://github.com/RawAccelOfficial/rawaccel/issues/318)). Those players should use the physical path.
- Windows Defender sometimes flags the Raw Accel zip ([#290](https://github.com/RawAccelOfficial/rawaccel/issues/290));
  the script only proceeds when the official SHA256 matches.
- Rotation corrects the average angle. If right and left strokes differ a lot (wrist arc) the page warns.

MIT licensed, see `LICENSE`. By [Hydr0neFN](https://github.com/Hydr0neFN).

---

## 繁體中文

這是一個靜態網站，量出你的滑鼠感應器偏了幾度，並幫你修正。

橫向揮動滑鼠時，游標常常會往上或往下偏幾度。網頁在瀏覽器裡量出角度（使用指標鎖定，盡量取得未經加速的原始移動），
然後提供兩種修正方式：

- **Windows：** 複製一行指令（Win+R、Ctrl+V、Ctrl+Shift+Enter），安裝
  [Raw Accel](https://github.com/RawAccelOfficial/rawaccel) 並設定「Degrees of rotation」。通常不需要重新開機。
- **Mac／不想安裝：** 圖示會告訴你要把滑鼠本體轉幾度、往哪個方向轉。

修正後可以再量一次，Windows 路徑要求 |角度| <= 1°，轉動滑鼠要求 <= 2°。預設語言是繁體中文（臺灣），可切換成英文。

**Raw Accel 並非由本專案散布。** `setup.ps1` 會從 Raw Accel 官方 GitHub 發行頁下載，並在使用前核對 SHA256。

安裝指令會做的事（沒有隱藏的東西）：下載並驗證 Raw Accel v1.7.1、必要時安裝 Microsoft 的 VC++ 執行階段、
安裝到 `C:\Program Files\RawAccel\` 並安裝它的驅動程式、寫入只含旋轉角度的 `settings.json`（既有檔案會先備份）、
新增登入工作排程 `RawAccel Apply Settings`。有遊戲或反作弊程式在執行時會拒絕執行。不蒐集任何資料。
解除安裝用同樣方式執行帶 `-Uninstall` 的指令。

**一鍵連結（`mousecal://`）：** 第一次安裝之後，安裝程式還會註冊 `mousecal://` 網址通訊協定（登錄在
`HKLM\SOFTWARE\Classes\mousecal`，檔案 `handler.vbs`、`handler.ps1` 和一份 `setup.ps1` 副本放在
`C:\Program Files\RawAccel\mousecal\`，只有系統管理員能修改）。之後重新量測，網頁上的「一鍵套用（已經安裝過）」
（`mousecal://apply?m=<角度>`）和「一鍵解除安裝」（`mousecal://uninstall`）就不用再複製指令。安全限制：每次都會先跳出
確認視窗（預設「否」）再跳 UAC；只接受這兩種動作；連結只能含 `[A-Za-z0-9:/?=.&-]` 且不超過 64 字元，量測值
|m| <= 20，套用後的旋轉不得超過 ±45°；有遊戲在執行時拒絕；提升權限後只會執行資料夾裡那份本機的 `setup.ps1`。
解除安裝時會一併移除這些檔案和登錄機碼（記錄檔 `%LOCALAPPDATA%\mousecal\handler.log` 只含數值，放在各使用者自己的資料夾，可自行刪除）。

部署與修改：見上方英文說明（Deploy、Forking）。fork 時請修改 `commands.js` 的 `SITE_BASE`，以及
`tools/setup.src.ps1` 的 `$SiteBase`，再執行 `node tools/build-setup.mjs`。

已知限制：部分使用 Easy Anti-Cheat 的遊戲（例如 Fortnite、Rust、Rocket League）執行時會忽略 Raw Accel，
這些遊戲請改用「轉動滑鼠」的方式。CS2 是主要使用情境，Apex 也能用。

授權：MIT。作者：[Hydr0neFN](https://github.com/Hydr0neFN)。
