# mousecal

[English](README.md) · **繁體中文**

這是一個靜態網站，量出你的滑鼠感應器偏了幾度，並幫你修正。

橫向揮動滑鼠時，游標常常會往上或往下偏幾度。網頁在瀏覽器裡量出角度（使用指標鎖定，盡量取得未經加速的原始移動），
然後提供兩種修正方式：

- **Windows：** 按「下載安裝程式」，下載 `mousecal-setup-<角度>.cmd`（網頁在瀏覽器裡產生的小文字檔），打開它，安裝
  [Raw Accel](https://github.com/RawAccelOfficial/rawaccel) 並設定「Degrees of rotation」。通常不需要重新開機。
- **Mac／不想安裝：** 圖示會告訴你要把滑鼠本體轉幾度、往哪個方向轉。

修正後再量一次：Windows 路徑在 1° 以內、轉動滑鼠在 2° 以內，就會顯示「已經修好了」。預設語言是繁體中文（臺灣），可切換成英文。

**Raw Accel 並非由本專案散布。** `setup.ps1` 會從 Raw Accel 官方 GitHub 發行頁下載，並在使用前核對 SHA256。

**為什麼改成下載檔案：** 以前是請使用者把 PowerShell 指令貼進 Win+R，這跟惡意程式常用的「ClickFix」手法一樣，
Microsoft Defender 有偵測（`Behavior:Win32/ClickFix`、`SuspClickFix`、「Suspicious command in RunMRU」），擋廣告的外掛也會擋。
現在的主要流程是下載 `.cmd` 檔再打開（用記事本就看得到每一行）：它先要求系統管理員權限，在
全新的 `%ProgramData%\mousecal-dl-<guid>`（建立時就只有系統管理員和 SYSTEM 能存取）下載 `setup.ps1`，用 .NET 的 SHA256 核對 SHA256 是否等於網頁
（`setup-hash.js`，「進階」裡也看得到）的值，不同就停止，相同才執行，最後刪掉資料夾。檔案沒有程式碼簽章，所以 Windows 會顯示
「Windows 已保護您的電腦」，請按「其他資訊」→「仍要執行」。舊的 Win+R 指令還在「進階：用 PowerShell 指令安裝」裡（預設收起來，
並提醒有些防毒軟體會覺得可疑）。

安裝程式會做的事：下載並驗證 Raw Accel v1.7.1、必要時安裝 Microsoft 的 VC++ 執行階段、
安裝到 `C:\Program Files\RawAccel\` 並安裝它的驅動程式、寫入只含旋轉角度的 `settings.json`（既有檔案會先備份）、
新增登入工作排程 `RawAccel Apply Settings`。有遊戲或反作弊程式在執行時會拒絕執行。不蒐集任何資料。
解除安裝：頁尾的「下載解除安裝程式」會下載 `mousecal-uninstall.cmd`（會依勾選框決定要不要加 `-RestorePointerPrecision`），打開方式相同。

**先量再修（關掉「增強指標的精確度」）：** 安裝時會把 Windows 的「增強指標的精確度」（滑鼠加速）關掉，這樣不讀原始輸入、
只看游標的遊戲也不會有加速。原本的三個值（`HKCU\Control Panel\Mouse` 的 `MouseSpeed`、`MouseThreshold1`、
`MouseThreshold2`）會記在標記檔裡，安裝失敗會還原。重複執行安裝時，已經記下的原始值不會被覆蓋。只有在執行腳本的使用者
就是目前登入桌面的使用者時才會動（否則顯示警告，請自己到「滑鼠設定 → 指標選項」關掉）。解除安裝加上
`-RestorePointerPrecision`（網頁頁尾的勾選框，預設勾選；一鍵連結是 `mousecal://uninstall?epp=1`）會把原本的設定改回去；
沒有勾選或沒有記錄到原始值，就維持現狀並在畫面上說明。

**一鍵連結（`mousecal://`）：** 第一次安裝之後，安裝程式還會註冊 `mousecal://` 網址通訊協定（登錄在
`HKLM\SOFTWARE\Classes\mousecal`，檔案 `handler.vbs`、`handler.ps1` 和一份 `setup.ps1` 副本放在
`C:\Program Files\RawAccel\mousecal\`，只有系統管理員能修改）。之後重新量測，網頁上的「套用修正」
（`mousecal://apply?m=<角度>`）和頁尾的「解除安裝」（`mousecal://uninstall`）就不用再下載檔案；沒有反應時，3 秒後會出現「沒有反應？下載安裝程式」按鈕（不會自動下載）。安全限制：每次都會先跳出
確認視窗（預設「否」）再跳 UAC；只接受這兩種動作；連結只能含 `[A-Za-z0-9:/?=.&-]` 且不超過 64 字元，量測值
|m| <= 20，套用後的旋轉不得超過 ±45°；有遊戲在執行時拒絕；提升權限後只會執行資料夾裡那份本機的 `setup.ps1`。
解除安裝時會一併移除這些檔案和登錄機碼（記錄檔 `%LOCALAPPDATA%\mousecal\handler.log` 只含數值，放在各使用者自己的資料夾，可自行刪除）。

部署與修改：見[英文說明](README.md)的 Deploy、Forking 段落。fork 時請修改 `commands.js` 的 `SITE_BASE`，以及
`tools/setup.src.ps1` 的 `$SiteBase`，再執行 `node tools/build-setup.mjs`。

已知限制：部分使用 Easy Anti-Cheat 的遊戲（例如 Fortnite、Rust、Rocket League）執行時會忽略 Raw Accel，
這些遊戲請改用「轉動滑鼠」的方式。CS2 是主要使用情境，Apex 也能用。

授權：MIT。作者：[Hydr0neFN](https://github.com/Hydr0neFN)。
