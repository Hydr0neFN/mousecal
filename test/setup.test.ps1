# Offline checks for setup.ps1 (no network, no admin, never installs anything).
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File test\setup.test.ps1   (5.1 or pwsh)
# Functions that change the system (Install-RawAccelDriver, Register-ApplyTask, Invoke-Uninstall,
# Restart-MouseDevices, Invoke-Rollback) are deliberately NOT called; Test-IsAdmin is mocked to
# $false so the Invoke-Main checks stop before any change even on an elevated machine.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:fails = 0
function Check([string]$Name, [bool]$Cond, [string]$Info = '') {
    if ($Cond) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name $Info" -ForegroundColor Red; $script:fails++ }
}
function Throws([scriptblock]$Block) { try { & $Block | Out-Null; return $false } catch { return $true } }
function ThrowsCode([scriptblock]$Block) { try { & $Block | Out-Null; return -1 } catch { $c = $_.Exception.Data['ExitCode']; if ($c) { return [int]$c } else { return 0 } } }

$env:MOUSECAL_NO_MAIN = '1'
$env:MOUSECAL_NO_PAUSE = '1'
$setupPath = Join-Path $here '..\setup.ps1'
. $setupPath
$src = [IO.File]::ReadAllText($setupPath)

# ---- SAFETY: nothing in this file may touch the real HKLM:\SOFTWARE\Classes\mousecal or run icacls.
# The URL-protocol registry key is redirected to a throw-away HKCU key and the folder-lock helper is a
# no-op; this block is re-applied after every re-dot-source of setup.ps1 (which would reset both).
$testKey = 'HKCU:\Software\mousecal-test-' +[guid]::NewGuid().ToString('N')
$script:protectCalls = @()
$applySafety = {
    $ProtocolKey = $testKey
    function Protect-HandlerDir { param($Dir) $script:protectCalls += $Dir }
}
. $applySafety
$hklmKeyBefore = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Classes\mousecal'
function Remove-TestKey { if (Test-Path -LiteralPath $testKey) { Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue } }
trap { Remove-TestKey; throw $_ }

# ---- contract: functions exist
foreach ($fn in 'Test-IsAdmin', 'Test-RotationValue', 'Test-ZipHash', 'Get-RunningAntiCheatGames', 'Set-RotationInJson',
                'Backup-Settings', 'Register-ApplyTask', 'Install-RawAccelDriver', 'Invoke-Uninstall', 'Invoke-Main',
                'Restart-MouseDevices', 'Test-DriverActive', 'ConvertTo-Degrees', 'Get-NewRotation', 'Expand-VerifiedZip', 'Get-RawAccelZipBytes', 'Test-ZipEntries') {
    Check "function $fn" ([bool](Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue))
}
$params = (Get-Command $setupPath).Parameters
foreach ($p in 'NoPause', 'Measured', 'Rotation', 'Uninstall', 'DryRun') { Check "parameter -$p" $params.ContainsKey($p) }
Check '-Rotation / -Measured are strings' ($params['Rotation'].ParameterType -eq [string] -and $params['Measured'].ParameterType -eq [string])
Check 'file is ASCII only' (-not ($src -match '[^\x00-\x7F]'))

# ---- Test-RotationValue
Check 'rotation 45 ok' (-not (Throws { Test-RotationValue 45 }))
Check 'rotation -45 ok' (-not (Throws { Test-RotationValue -45 }))
Check 'rotation 45.1 throws' (Throws { Test-RotationValue 45.1 })
Check 'rotation -45.1 throws' (Throws { Test-RotationValue -45.1 })
Check 'rotation NaN throws' (Throws { Test-RotationValue ([double]::NaN) })

# ---- F7: invariant parsing, no commas
Check 'parse "8.2"' ((ConvertTo-Degrees '8.2' 'Measured') -eq 8.2)
Check 'parse "-3.4"' ((ConvertTo-Degrees '-3.4' 'Measured') -eq -3.4)
Check 'parse "1e1"' ((ConvertTo-Degrees '1e1' 'Measured') -eq 10)
Check 'comma rejected with code 3' ((ThrowsCode { ConvertTo-Degrees '8,2' 'Measured' }) -eq 3)
Check 'text rejected with code 3' ((ThrowsCode { ConvertTo-Degrees 'abc' 'Measured' }) -eq 3)
Check 'NaN string rejected with code 3' ((ThrowsCode { ConvertTo-Degrees 'NaN' 'Measured' }) -eq 3)
Check 'Infinity string rejected with code 3' ((ThrowsCode { ConvertTo-Degrees 'Infinity' 'Measured' }) -eq 3)
Check 'out of range rejected with code 3' ((ThrowsCode { ConvertTo-Degrees '46' 'Measured' }) -eq 3)
$oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    Check 'parse "8.2" under de-DE still 8.2' ((ConvertTo-Degrees '8.2' 'Measured') -eq 8.2)
    Check 'Format-Rotation under de-DE uses a dot' ((Format-Rotation 8.2) -eq '8.2')
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }

# ---- F4: new rotation = active + measured
Check 'new = active + measured' ((Get-NewRotation 8.0 2.3) -eq 10.3)
Check 'new with negative measured' ((Get-NewRotation 8.0 -1.5) -eq 6.5)
Check 'driver off: active 0' ((Get-NewRotation 0 8.2) -eq 8.2)
Check '|new| > 45 refused with code 3' ((ThrowsCode { Get-NewRotation 44 2 }) -eq 3)
Check '|new| = 45 allowed' ((Get-NewRotation 40 5) -eq 45)

# ---- Resolve-Arguments: exactly one of -Rotation / -Measured unless -Uninstall
function Test-Args($r, $m, [bool]$u) {
    $script:Rotation = $r; $script:Measured = $m; $script:Uninstall = [switch]$u
    try { return (Resolve-Arguments) } catch { return $_.Exception.Data['ExitCode'] }
}
Check 'neither -> 3' ((Test-Args '' '' $false) -eq 3)
Check 'both -> 3' ((Test-Args '1' '2' $false) -eq 3)
Check 'comma -> 3' ((Test-Args '' '8,2' $false) -eq 3)
Check '-Uninstall with -Measured -> 3' ((Test-Args '' '2' $true) -eq 3)
$a = Test-Args '' '2.5' $false; Check '-Measured parsed' ($a.Kind -eq 'Measured' -and $a.Value -eq 2.5)
$a = Test-Args '7' '' $false; Check '-Rotation parsed' ($a.Kind -eq 'Rotation' -and $a.Value -eq 7)
$a = Test-Args '' '' $true; Check '-Uninstall alone ok' ($a.Kind -eq 'Uninstall')
$Rotation = ''; $Measured = ''; $Uninstall = [switch]$false

# ---- F6: Format-Bi tolerates $null arguments
$m = Format-Bi 'a {x}' 'b' $null
Check 'Format-Bi with $null args' ($m[1] -eq 'a {x}')
$m = Format-Bi 'v={0}' 'z={0}' @(5)
Check 'Format-Bi with args' ($m[1] -eq 'v=5' -and $m[0] -eq 'z=5')

# ---- Set-RotationInJson: only the rotation key changes
$tpl = $SettingsTemplate
$out = Set-RotationInJson $tpl 8.2
Check 'rotation set to 8.2' ($out -match '"Degrees of rotation": 8\.2,')
$aa = $tpl -split "`n"; $bb = $out -split "`n"
$diff = @(0..($aa.Count - 1) | Where-Object { $aa[$_] -ne $bb[$_] })
Check 'exactly one line differs' ($aa.Count -eq $bb.Count -and $diff.Count -eq 1) "diff lines: $($diff.Count)"
Check 'negative value' ((Set-RotationInJson $tpl -3.5) -match '"Degrees of rotation": -3\.5,')
Check 'missing key throws' (Throws { Set-RotationInJson '{"a": 1}' 1 })

# ---- F1: pinned hashes for every file; verified in-memory extraction
$table = Get-ZipFileTable
Check 'pinned table has 24 files' ($table.Count -eq 24)
Check 'table includes the driver and installer' ($table.ContainsKey('driver/rawaccel.sys') -and $table.ContainsKey('installer.exe') -and $table.ContainsKey('uninstaller.exe') -and $table.ContainsKey('writer.exe') -and $table.ContainsKey('wrapper.dll'))
Check 'every pinned hash is 64 hex chars' (@($table.Values | Where-Object { $_ -notmatch '^[0-9A-F]{64}$' }).Count -eq 0)

Add-Type -AssemblyName System.IO.Compression
function New-TestZip($files) {
    $ms = New-Object IO.MemoryStream
    $za = New-Object IO.Compression.ZipArchive ($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($k in $files.Keys) {
        $e = $za.CreateEntry($k); $s = $e.Open(); $b = [Text.Encoding]::ASCII.GetBytes($files[$k]); $s.Write($b, 0, $b.Length); $s.Dispose()
    }
    $za.Dispose()
    return , $ms.ToArray()
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('mousecal-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $content = @{ 'RawAccel/a.txt' = 'alpha'; 'RawAccel/sub/b.txt' = 'beta' }
    $tb = @{ 'a.txt' = (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes('alpha'))); 'sub/b.txt' = (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes('beta'))) }
    $z = New-TestZip $content
    $d1 = Join-Path $tmp 'ok'
    Expand-VerifiedZip $z $d1 $tb
    Check 'verified extract writes files' ((Get-Content -Raw (Join-Path $d1 'sub\b.txt')) -eq 'beta')
    $z2 = New-TestZip @{ 'RawAccel/a.txt' = 'alpha'; 'RawAccel/sub/b.txt' = 'TAMPERED' }
    Check 'tampered file -> code 4' ((ThrowsCode { Expand-VerifiedZip $z2 (Join-Path $tmp 'bad1') $tb }) -eq 4)
    Check 'tampered file is never written' (-not (Test-Path (Join-Path $tmp 'bad1\sub\b.txt')))
    $z3 = New-TestZip @{ 'RawAccel/a.txt' = 'alpha'; 'RawAccel/sub/b.txt' = 'beta'; 'RawAccel/evil.exe' = 'x' }
    Check 'extra file -> code 4' ((ThrowsCode { Expand-VerifiedZip $z3 (Join-Path $tmp 'bad2') $tb }) -eq 4)
    $z4 = New-TestZip @{ 'RawAccel/a.txt' = 'alpha' }
    Check 'missing file -> code 4' ((ThrowsCode { Expand-VerifiedZip $z4 (Join-Path $tmp 'bad3') $tb }) -eq 4)
    $z5 = New-TestZip @{ 'RawAccel/a.txt' = 'alpha'; '../escape.txt' = 'x' }
    Check 'path outside RawAccel/ -> code 4' ((ThrowsCode { Expand-VerifiedZip $z5 (Join-Path $tmp 'bad4') $tb }) -eq 4)
    Check 'traversal target not created' (-not (Test-Path (Join-Path $tmp 'escape.txt')))

    # ---- Test-ZipHash / Test-ZipBytes
    $f = Join-Path $tmp 'x.zip'
    [IO.File]::WriteAllText($f, 'not the real zip')
    Check 'wrong file hash -> false' ((Test-ZipHash $f) -eq $false)
    Check 'missing file hash -> false' ((Test-ZipHash (Join-Path $tmp 'nope.zip')) -eq $false)
    Check 'wrong bytes -> false' ((Test-ZipHash ([byte[]](1, 2, 3))) -eq $false)
    Check 'empty bytes -> false' ((Test-ZipHash ([byte[]]@())) -eq $false)
    Check 'Test-ZipHash accepts bytes and paths' ((Test-ZipHash $f) -eq $false -and (Test-ZipHash ([byte[]](9))) -eq $false)
    # a hookable download: the pinned hash can be satisfied by overriding the hash in a copy of the table
    $savedSha = $ZipSha256
    $ZipSha256 = Get-BytesSha256 $z
    Check 'Test-ZipHash true for matching bytes' ((Test-ZipHash $z) -eq $true)
    $zf = Join-Path $tmp 'good.zip'; [IO.File]::WriteAllBytes($zf, $z)
    Check 'Test-ZipHash true for matching file path' ((Test-ZipHash $zf) -eq $true)
    $ZipSha256 = $savedSha
    # Test-ZipEntries: $true or exit code 4
    Check 'Test-ZipEntries true for a matching zip' ((Test-ZipEntries $z $tb) -eq $true)
    Check 'Test-ZipEntries tampered -> 4' ((ThrowsCode { Test-ZipEntries $z2 $tb }) -eq 4)
    Check 'Test-ZipEntries extra file -> 4' ((ThrowsCode { Test-ZipEntries $z3 $tb }) -eq 4)
    Check 'Test-ZipEntries missing file -> 4' ((ThrowsCode { Test-ZipEntries $z4 $tb }) -eq 4)
    Check 'Test-ZipEntries garbage -> 4' ((ThrowsCode { Test-ZipEntries ([byte[]](1, 2, 3, 4)) $tb }) -eq 4)
    Check 'Test-ZipEntries rejects the real table for a fake zip' ((ThrowsCode { Test-ZipEntries $z }) -eq 4)

    # ---- Backup-Settings
    $s = Join-Path $tmp 'settings.json'
    [IO.File]::WriteAllText($s, '{"k":1}')
    $bak = Backup-Settings $s
    Check 'backup exists with same content' ((Test-Path $bak) -and ([IO.File]::ReadAllText($bak) -eq '{"k":1}') -and $bak -ne $s)

    # ---- F2: ownership classification (what uninstall may delete)
    $own = Join-Path $tmp 'own'
    New-Item -ItemType Directory -Path (Join-Path $own 'doc') -Force | Out-Null
    foreach ($n in 'writer.exe', 'doc\FAQ.md', 'settings.json', 'settings.json.bak-20260101-000000', 'my-notes.txt', 'doc\mine.md') { [IO.File]::WriteAllText((Join-Path $own $n), 'x') }
    $c = Get-OwnedFileClassification $own
    Check 'known files recognised' ((@($c.Known) | Sort-Object) -join ',' -eq ((@('doc/FAQ.md', 'settings.json', 'settings.json.bak-20260101-000000', 'writer.exe') | Sort-Object) -join ','))
    Check 'unknown files are left alone' ((@($c.Unknown) | Sort-Object) -join ',' -eq 'doc/mine.md,my-notes.txt')

    # ---- F2: marker round trip (writes to a temp marker path only)
    $realMarker = $MarkerPath
    $MarkerPath = Join-Path $tmp '.mousecal-installed'
    Check 'no marker -> null' ($null -eq (Read-Marker))
    Write-Marker @{ DriverInstalled = $true; AppDirCreated = $false }
    $mk = Read-Marker
    Check 'marker round trip' ($mk -and $mk.installedDriver -eq $true -and $mk.createdAppDir -eq $false)
    $raw = [IO.File]::ReadAllText($MarkerPath) | ConvertFrom-Json
    Check 'marker JSON has tool/installedDriver/createdAppDir/version "1"' ($raw.tool -eq 'mousecal' -and $raw.installedDriver -eq $true -and $raw.createdAppDir -eq $false -and $raw.version -eq '1')
    [IO.File]::WriteAllText($MarkerPath, '{"tool":"someone-else"}')
    Check 'foreign marker ignored' ($null -eq (Read-Marker))
    [IO.File]::WriteAllText($MarkerPath, 'not json')
    Check 'garbage marker ignored' ($null -eq (Read-Marker))
    [IO.File]::WriteAllText($MarkerPath, 'mousecal')
    $lg = Read-Marker
    Check 'legacy plain-text marker = installedDriver + createdAppDir' ($lg -and $lg.installedDriver -eq $true -and $lg.createdAppDir -eq $true)
    [IO.File]::WriteAllText($MarkerPath, '{"tool":"mousecal","installedDriver":false,"createdAppDir":true,"version":"1"}')
    $m2 = Read-Marker
    Check 'marker JSON from the contract parses' ($m2 -and $m2.installedDriver -eq $false -and $m2.createdAppDir -eq $true)
    $MarkerPath = $realMarker
    Check 'marker lives in <ProgramFilesDir>\RawAccel\RawAccel\.mousecal-installed' ($MarkerPath -eq (Join-Path (Join-Path (Join-Path (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion').ProgramFilesDir 'RawAccel') 'RawAccel') '.mousecal-installed'))

    # ---- F1: staging path is admin-only Program Files in a real run, temp only in -DryRun
    $DryRun = [switch]$false
    $sp = Get-StagePath
    Check 'real run stages under the install root' ($sp -eq (Join-Path $InstallRoot '.staging') -and -not $sp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase))
    $DryRun = [switch]$true
    Check 'dry run stages in temp' ((Get-StagePath).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase))
    $DryRun = [switch]$false
    Check 'real-run code paths never use the temp folder' ($src -notmatch 'GetTempPath\(\)[^\r\n]*(Join|vc_redist|installer)')

    # ---- S6: Program Files from the registry
    $pf = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion').ProgramFilesDir
    Check 'ProgramFilesDir comes from the registry' ($InstallRoot -eq (Join-Path $pf 'RawAccel') -and $src -notmatch '\$env:ProgramW6432|\$env:ProgramFiles')

    # ---- F3: game guard uses Get-Process; extended list
    foreach ($n in 'faceit', 'FACEITClient', 'faceitservice', 'BEService', 'BEService_x64', 'perfectworldarena', 'PWAgent', 'cs2', 'r5apex', 'EasyAntiCheat') {
        Check "blocking list has $n" ($BlockingProcesses -contains $n)
    }
    Check 'vgc only warns' (($WarnOnlyProcesses -contains 'vgc') -and ($BlockingProcesses -notcontains 'vgc'))
    Check 'no game running -> empty' (@(Get-RunningAntiCheatGames).Count -eq 0)
    function Get-Process { param([string]$Name, $ErrorAction) 'systemx', 'BEService', 'FACEITClient', 'notepad' | ForEach-Object { New-Object PSObject -Property @{ ProcessName = $_ } } }
    $games = @(Get-RunningAntiCheatGames)
    Check 'mocked Get-Process: BattlEye + FACEIT detected' (($games -contains 'BEService') -and ($games -contains 'FACEITClient') -and $games.Count -eq 2) "got: $($games -join ',')"
    $Uninstall = [switch]$false; $DryRun = [switch]$false
    Check 'Assert-NoGameRunning throws code 6' ((ThrowsCode { Assert-NoGameRunning }) -eq 6)
    $DryRun = [switch]$true
    Check 'Assert-NoGameRunning only warns in -DryRun' (-not (Throws { Assert-NoGameRunning 6>$null 3>$null }))
    $DryRun = [switch]$false
    Remove-Item function:Get-Process

    # ---- real fake process (copy of ping.exe named cs2.exe) -> Invoke-Main exit 6 for install and uninstall
    $fake = Join-Path $tmp 'cs2.exe'
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') $fake
    $p = Start-Process -FilePath $fake -ArgumentList '-n', '40', '127.0.0.1' -WindowStyle Hidden -PassThru
    try {
        Start-Sleep -Milliseconds 700
        Check 'fake cs2 detected' (@(Get-RunningAntiCheatGames) -contains 'cs2')
        function Test-IsAdmin { return $false }
        $Rotation = ''; $Measured = '8.2'; $DryRun = [switch]$false; $Uninstall = [switch]$false; $NoPause = [switch]$true
        Check 'Invoke-Main with game running -> 6' ((Invoke-Main 6>$null) -eq 6)
        $Measured = ''; $Uninstall = [switch]$true
        Check 'Invoke-Main -Uninstall with game running -> 6' ((Invoke-Main 6>$null) -eq 6)
        $Uninstall = [switch]$false
    } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300

    # ---- exit codes 3 and 2 (admin mocked to $false)
    $Measured = '99'
    Check 'bad measured -> 3' ((Invoke-Main 6>$null) -eq 3)
    $Measured = ''; $Rotation = ''
    Check 'missing both -> 3' ((Invoke-Main 6>$null) -eq 3)
    $Measured = '8,2'
    Check 'comma -> 3' ((Invoke-Main 6>$null) -eq 3)
    $Measured = '8.2'; $Rotation = '1'
    Check 'both given -> 3' ((Invoke-Main 6>$null) -eq 3)
    $Rotation = ''
    Check 'not admin -> 2' ((Invoke-Main 6>$null) -eq 2)
    $Measured = ''
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- S2: task = SYSTEM, startup + logon triggers, runs writer.exe directly
$parts = Get-ApplyTaskParts $SettingsPath
Check 'task principal is SYSTEM, highest' ($parts.Principal.UserId -match 'SYSTEM|S-1-5-18' -and [string]$parts.Principal.RunLevel -eq 'Highest')
Check 'task has startup (15 s) and logon (10 s) triggers' (@($parts.Trigger).Count -eq 2 -and @($parts.Trigger | Where-Object { $_.Delay -eq 'PT15S' }).Count -eq 1 -and @($parts.Trigger | Where-Object { $_.Delay -eq 'PT10S' }).Count -eq 1)
Check 'startup trigger is a boot trigger, logon trigger has no user filter' ((@($parts.Trigger | ForEach-Object { $_.CimClass.CimClassName }) -join ',') -match 'MSFT_TaskBootTrigger' -and (@($parts.Trigger | ForEach-Object { $_.CimClass.CimClassName }) -join ',') -match 'MSFT_TaskLogonTrigger' -and -not (@($parts.Trigger | Where-Object { $_.UserId }).Count))
Check 'task action runs writer.exe directly with the settings path' ($parts.Action.Execute -like '*\writer.exe' -and $parts.Action.Arguments -eq ('"{0}"' -f $SettingsPath) -and $parts.Action.Execute -notmatch 'wscript')
Check 'task time limit is 2 minutes' ($parts.Settings.ExecutionTimeLimit -eq 'PT2M')

# ---- structure checks on the script text
Check 'script has a rollback path' ($src -match 'function Invoke-Rollback' -and $src -match 'Invoke-Rollback')
Check 'writer.exe exit code is checked' ($src -match '\$w\.ExitCode -ne 0')
Check 'driver tool waits for filter + driver file + service key' ($src -match 'Test-Path -LiteralPath \$DriverSysPath' -and $src -match 'Test-Path -LiteralPath \$ServiceKey')
Check 'games re-checked before restart and apply' ((([regex]::Matches($src, 'Get-RunningAntiCheatGames')).Count) -ge 4)
Check 'validator reads the installed copies' ($src -match 'Test-SettingsJson \$AppDir')


# =====================================================================================
# mousecal:// URL protocol: handler files, registry key (redirected to HKCU), the link parser
# and the handler flow. Everything is stubbed; no dialog is shown, nothing is elevated.
# =====================================================================================
foreach ($fn in 'Register-UrlProtocol', 'Unregister-UrlProtocol', 'Get-HandlerDir', 'Get-SelfScriptText', 'Get-ProtocolCommand', 'Remove-UrlProtocolStep', 'Test-UrlProtocolPresent') {
    Check "function $fn" ([bool](Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue))
}
Check 'URL-protocol key defaults to HKLM:\SOFTWARE\Classes\mousecal (before the test redirect)' ($src -match [regex]::Escape("`$ProtocolKey  = 'HKLM:\SOFTWARE\Classes\mousecal'"))
Check 'Get-SelfScriptText returns exactly the running script text' ((Get-SelfScriptText) -ceq $src)

$pt = Join-Path ([IO.Path]::GetTempPath()) ('mousecal-proto-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $pt | Out-Null
try {
    $rd = Join-Path $pt 'RawAccel\mousecal'
    $script:protectCalls = @()
    if (Test-Path -LiteralPath $testKey) { throw 'test key unexpectedly exists' }
    Register-UrlProtocol $rd $testKey
    foreach ($f in 'handler.vbs', 'handler.ps1', 'setup.ps1') { Check "protocol: $f written" (Test-Path -LiteralPath (Join-Path $rd $f) -PathType Leaf) }
    Check 'protocol: folder lock-down helper called for the handler folder' ($script:protectCalls -contains $rd)
    $copy = [IO.File]::ReadAllText((Join-Path $rd 'setup.ps1'))
    Check 'protocol: the local setup.ps1 is a copy of the running script' ($copy.TrimStart([char]0xFEFF) -ceq $src)
    $hp = [IO.File]::ReadAllText((Join-Path $rd 'handler.ps1')); $hv = [IO.File]::ReadAllText((Join-Path $rd 'handler.vbs'))
    Check 'protocol: handler.ps1 / handler.vbs are ASCII-only (when built)' (-not (($hp.TrimStart([char]0xFEFF) + $hv) -match '[^\x00-\x7F]'))
    Check 'protocol: handler.ps1 has the UTF-8 BOM' (([IO.File]::ReadAllBytes((Join-Path $rd 'handler.ps1')))[0] -eq 0xEF)
    $errs = $null; $toks = $null
    [void][Management.Automation.Language.Parser]::ParseInput($hp, [ref]$toks, [ref]$errs)
    Check 'protocol: handler.ps1 parses without errors' (@($errs).Count -eq 0) (($errs | ForEach-Object { $_.Message }) -join '; ')
    $k = Get-Item -LiteralPath $testKey
    Check 'protocol: key default value is "URL:mousecal Protocol"' ($k.GetValue('') -ceq 'URL:mousecal Protocol')
    Check 'protocol: "URL Protocol" value exists and is empty' (($k.GetValueNames() -contains 'URL Protocol') -and $k.GetValue('URL Protocol') -ceq '')
    $cmdWant = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + (Join-Path $rd 'handler.vbs') + '" "%1"'
    Check 'protocol: shell\open\command = wscript.exe handler.vbs "%1" with %SystemRoot% expanded' ((Get-Item -LiteralPath ($testKey + '\shell\open\command')).GetValue('') -ceq $cmdWant) ((Get-Item -LiteralPath ($testKey + '\shell\open\command')).GetValue(''))
    Check 'protocol: Get-ProtocolCommand matches' ((Get-ProtocolCommand $rd) -ceq $cmdWant -and $cmdWant -notmatch '%SystemRoot%')
    $stamp = (Get-Item (Join-Path $rd 'setup.ps1')).LastWriteTimeUtc
    Start-Sleep -Milliseconds 50
    Register-UrlProtocol $rd $testKey
    Check 'protocol: registering again is idempotent and does not rewrite identical files' ((Get-Item (Join-Path $rd 'setup.ps1')).LastWriteTimeUtc -eq $stamp -and (Get-Item -LiteralPath $testKey).GetValue('') -ceq 'URL:mousecal Protocol')
    Check 'protocol: Test-UrlProtocolPresent sees it' (Test-UrlProtocolPresent $rd $testKey)

    # ---- dot-source the handler written to disk (setup.ps1 functions are already loaded, so it does not reload them)
    $env:MOUSECAL_NO_MAIN = '1'
    . (Join-Path $rd 'handler.ps1')
    $McLog = Join-Path $pt 'handler.log'
    foreach ($fn in 'ConvertFrom-MousecalUrl', 'Show-Confirm', 'Show-Result', 'Invoke-Elevated', 'Invoke-HandlerMain', 'Get-CurrentRotation', 'Show-Info') {
        Check "handler: function $fn" ([bool](Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue))
    }

    # ---- ConvertFrom-MousecalUrl
    function Parse-Url($u) { try { return (ConvertFrom-MousecalUrl $u) } catch { return $null } }
    foreach ($u in 'mousecal://apply?m=8.2', 'mousecal://apply/?m=8.2', 'mousecal:apply?m=8.2', 'mousecal://apply?m=8.2/', 'MOUSECAL://APPLY?m=8.2') {
        $r = Parse-Url $u
        Check "url ok: $u" ($r -and $r.Action -eq 'apply' -and $r.Measured -eq 8.2 -and $r.Measured -is [double])
    }
    $r = Parse-Url 'mousecal://apply?m=-3.4'; Check 'url: negative value' ($r -and $r.Measured -eq -3.4)
    $r = Parse-Url 'mousecal://apply?m=20'; Check 'url: |m| = 20 accepted' ($r -and $r.Measured -eq 20)
    $r = Parse-Url 'mousecal://apply?m=-20.0'; Check 'url: m = -20.0 accepted' ($r -and $r.Measured -eq -20)
    $r = Parse-Url 'mousecal://apply?m=0'; Check 'url: m = 0 accepted' ($r -and $r.Measured -eq 0)
    foreach ($u in 'mousecal://uninstall', 'mousecal://uninstall/', 'mousecal:uninstall', 'mousecal:uninstall/') {
        $r = Parse-Url $u
        Check "url ok: $u" ($r -and $r.Action -eq 'uninstall' -and -not $r.ContainsKey('Measured'))
    }
    $bad = @('', 'mousecal://', 'mousecal://apply', 'mousecal://apply?', 'mousecal://apply?m=', 'mousecal://apply?x=1', 'mousecal://apply?m=8.2&x=1',
             'mousecal://apply?m=20.01', 'mousecal://apply?m=21', 'mousecal://apply?m=-21', 'mousecal://apply?m=100', 'mousecal://apply?m=1.234', 'mousecal://apply?m=1e1',
             'mousecal://apply?m=.5', 'mousecal://apply?m=5.', 'mousecal://apply?m=8,2', 'mousecal://apply?m=NaN', 'mousecal://apply?m=--1', 'mousecal://apply?m=+1',
             'mousecal://uninstall?m=1', 'mousecal://uninstall?', 'mousecal://other', 'mousecal://apply/extra?m=1', 'mousecal://applyx?m=1', 'http://apply?m=1', 'mousecal//apply?m=1', 'xmousecal://uninstall',
             'mousecal://apply?m=8.2"', 'mousecal://apply?m=8.2" & calc', 'mousecal://apply?m=8.2 ', ' mousecal://uninstall', "mousecal://uninstall`n", "mousecal://uninstall`r`n", "mousecal://apply?m=1`n",
             'mousecal://apply?m=8.2;calc', 'mousecal://apply?m=%38', ('mousecal://apply?m=' + [string][char]0x0663), 'mousecal://apply?m=$(calc)', 'mousecal://apply?m=`calc',
             ('mousecal://apply?m=' + ('1' * 50)), ('a' * 65), ('mousecal://uninstall' + ('/' * 60)))
    foreach ($u in $bad) {
        $show = ($u -replace "`r", '\r' -replace "`n", '\n'); if ($show.Length -gt 40) { $show = $show.Substring(0, 40) + '...' }
        Check "url rejected: [$show]" ($null -eq (Parse-Url $u)) ("len=$($u.Length) tail=" + (($u.ToCharArray() | Select-Object -Last 3 | ForEach-Object { [int]$_ }) -join ","))
    }
    Check 'url: $null rejected' (Throws { ConvertFrom-MousecalUrl $null })
    $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
        $r = Parse-Url 'mousecal://apply?m=8.2'; Check 'url: 8.2 under de-DE is still 8.2' ($r -and $r.Measured -eq 8.2)
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }

    # ---- handler flow with every side effect stubbed
    $savedFns = @{}
    foreach ($n in 'Invoke-Elevated', 'Get-CurrentRotation', 'Get-RunningAntiCheatGames', 'Show-Confirm', 'Show-Info', 'Show-Result') { $savedFns[$n] = (Get-Command $n -CommandType Function).ScriptBlock }
    $McSetup = Join-Path $rd 'setup.ps1'
    $script:ui = @{ Confirm = $true; ConfirmText = ''; Confirms = 0; Infos = @(); Results = @(); Elev = @(); ElevCode = 0; Games = @(); Cur = 8.0 }
    function Show-Confirm { param($Text, $Title) $script:ui.Confirms++; $script:ui.ConfirmText = $Text; return $script:ui.Confirm }
    function Show-Info { param($Text, $Title, $Icon) $script:ui.Infos += $Text }
    function Show-Result { param($Code, $Action) $script:ui.Results += , @($Code, $Action) }
    function Invoke-Elevated { param($ScriptPath, $ScriptArgs) $script:ui.Elev += , @($ScriptPath, ($ScriptArgs -join ' ')); return $script:ui.ElevCode }
    function Get-RunningAntiCheatGames { return @($script:ui.Games) }
    function Get-CurrentRotation { return [double]$script:ui.Cur }
    function Reset-Ui { $script:ui = @{ Confirm = $true; ConfirmText = ''; Confirms = 0; Infos = @(); Results = @(); Elev = @(); ElevCode = 0; Games = @(); Cur = 8.0 }; if (Test-Path $McLog) { Remove-Item $McLog } }
    $deg = [string][char]0x00B0

    Reset-Ui
    $rc = Invoke-HandlerMain 'mousecal://apply?m=8.2'
    Check 'flow apply: asks once, elevates the local setup.ps1 with the ABSOLUTE rotation (active + measured) and -NoPause' ($rc -eq 0 -and $script:ui.Confirms -eq 1 -and $script:ui.Elev.Count -eq 1 -and $script:ui.Elev[0][0] -eq $McSetup -and $script:ui.Elev[0][1] -ceq '-Rotation 16.2 -NoPause') ($script:ui.Elev | Out-String)
    Check 'flow apply: confirm dialog shows "current -> new" in both languages' ($script:ui.ConfirmText -match 'Current 8\.0 deg -> new 16\.2 deg' -and $script:ui.ConfirmText.Contains(([string][char]0x76EE + [char]0x524D + ' 8.0' + $deg + ' -> ' + [char]0x65B0 + ' 16.2' + $deg)) -and $script:ui.ConfirmText -match 'pressing No changes nothing') $script:ui.ConfirmText
    Check 'flow apply: result dialog gets exit code + action' ($script:ui.Results.Count -eq 1 -and $script:ui.Results[0][0] -eq 0 -and $script:ui.Results[0][1] -eq 'apply')
    $log = [IO.File]::ReadAllText($McLog)
    Check 'flow apply: log has the values and nothing personal' ($log -match 'measured 8\.2' -and $log -match 'current 8\.0 -> new 16\.2' -and $log -match 'exit code 0' -and $log -notmatch [regex]::Escape($env:USERNAME + '\') -and $log -notmatch [regex]::Escape($env:COMPUTERNAME))

    Reset-Ui; $script:ui.Confirm = $false
    $rc = Invoke-HandlerMain 'mousecal://apply?m=8.2'
    Check 'flow apply: answering No elevates nothing' ($rc -eq 0 -and $script:ui.Elev.Count -eq 0 -and $script:ui.Results.Count -eq 0 -and ([IO.File]::ReadAllText($McLog)) -match 'declined')

    Reset-Ui; $script:ui.Games = @('cs2')
    $rc = Invoke-HandlerMain 'mousecal://apply?m=8.2'
    Check 'flow apply: a running game stops it before any question' ($rc -eq 6 -and $script:ui.Confirms -eq 0 -and $script:ui.Elev.Count -eq 0 -and $script:ui.Infos.Count -eq 1 -and $script:ui.Infos[0] -match 'cs2')
    Reset-Ui; $script:ui.Games = @('VALORANT')
    $rc = Invoke-HandlerMain 'mousecal://uninstall'
    Check 'flow uninstall: a running game stops it too' ($rc -eq 6 -and $script:ui.Confirms -eq 0 -and $script:ui.Elev.Count -eq 0)

    Reset-Ui; $script:ui.Cur = 44.0
    $rc = Invoke-HandlerMain 'mousecal://apply?m=2'
    Check 'flow apply: |new| > 45 is refused before the question, nothing elevated' ($rc -eq 3 -and $script:ui.Confirms -eq 0 -and $script:ui.Elev.Count -eq 0 -and $script:ui.Infos.Count -eq 1)
    Reset-Ui; $script:ui.Cur = 40.0
    $rc = Invoke-HandlerMain 'mousecal://apply?m=5'
    Check 'flow apply: |new| = 45 is allowed' ($script:ui.Elev.Count -eq 1 -and $script:ui.Elev[0][1] -ceq '-Rotation 45.0 -NoPause') ($script:ui.Elev | Out-String)
    Reset-Ui; $script:ui.Cur = -2.5
    $rc = Invoke-HandlerMain 'mousecal://apply?m=-3'
    Check 'flow apply: negative absolute rotation is passed as -5.5' ($script:ui.Elev.Count -eq 1 -and $script:ui.Elev[0][1] -ceq '-Rotation -5.5 -NoPause') ($script:ui.Elev | Out-String)
    Reset-Ui; $script:ui.Cur = 0.0
    $rc = Invoke-HandlerMain 'mousecal://apply?m=8.2'
    Check 'flow apply: driver not running (active 0) -> new = measured' ($script:ui.Elev[0][1] -ceq '-Rotation 8.2 -NoPause')

    Reset-Ui
    $rc = Invoke-HandlerMain 'mousecal://uninstall'
    Check 'flow uninstall: asks once, elevates setup.ps1 -Uninstall -NoPause' ($rc -eq 0 -and $script:ui.Confirms -eq 1 -and $script:ui.Elev.Count -eq 1 -and $script:ui.Elev[0][0] -eq $McSetup -and $script:ui.Elev[0][1] -ceq '-Uninstall -NoPause' -and $script:ui.Results[0][1] -eq 'uninstall')
    Reset-Ui; $script:ui.Confirm = $false
    $rc = Invoke-HandlerMain 'mousecal://uninstall'
    Check 'flow uninstall: answering No elevates nothing' ($script:ui.Elev.Count -eq 0)

    Reset-Ui; $script:ui.ElevCode = 6
    $rc = Invoke-HandlerMain 'mousecal://apply?m=1'
    Check 'flow: the elevated exit code is returned and shown' ($rc -eq 6 -and $script:ui.Results[0][0] -eq 6)
    Reset-Ui
    foreach ($u in 'mousecal://evil', 'mousecal://apply?m=99', ('x' * 70), '') {
        Reset-Ui
        $rc = Invoke-HandlerMain $u
        Check "flow: invalid link [$($u.Substring(0, [math]::Min(14, $u.Length)))] -> info only, no question, no elevation" ($rc -eq 3 -and $script:ui.Confirms -eq 0 -and $script:ui.Elev.Count -eq 0 -and $script:ui.Infos.Count -eq 1)
    }
    Check 'flow: rejected links are logged by length only' (([IO.File]::ReadAllText($McLog)) -match 'rejected link \(length 0\)')
    Reset-Ui; $McSetup = Join-Path $pt 'missing-setup.ps1'
    $rc = Invoke-HandlerMain 'mousecal://uninstall'
    Check 'flow: local setup.ps1 missing -> info only' ($rc -eq 1 -and $script:ui.Elev.Count -eq 0 -and $script:ui.Confirms -eq 0)
    $McSetup = Join-Path $rd 'setup.ps1'

    # ---- Get-ResultText
    foreach ($c in 0, 1223, 6, 3, 4, 5, 7, 8, 1, 2) {
        $a = Get-ResultText $c 'apply'; $u = Get-ResultText $c 'uninstall'
        Check "result text for code $c is bilingual" ($a.Text -match '[^\x00-\x7F]' -and $a.Text -match '[A-Za-z]{4}' -and $u.Text.Length -gt 10)
    }
    Check 'result text: success differs for apply and uninstall' ((Get-ResultText 0 'apply').Text -ne (Get-ResultText 0 'uninstall').Text)
    Check 'result text: unknown code mentions the code' ((Get-ResultText 77 'apply').Text -match '77')

    # ---- the real Invoke-Elevated (Start-Process stubbed: nothing is started)
    Set-Item function:Invoke-Elevated $savedFns['Invoke-Elevated']
    $script:sp = @()
    function Start-Process { param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru) $script:sp += , @($FilePath, $ArgumentList, $Verb, [bool]$Wait, [bool]$PassThru); if ($script:spThrow) { throw $script:spThrow }; return [pscustomobject]@{ ExitCode = $script:spExit } }
    $script:spExit = 0; $script:spThrow = $null
    $rc = Invoke-Elevated $McSetup @('-Rotation', '16.2', '-NoPause')
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Check 'Invoke-Elevated: absolute powershell.exe, -Verb RunAs, waits, -File "<dir>\setup.ps1" -Rotation <abs> -NoPause' ($script:sp.Count -eq 1 -and $script:sp[0][0] -eq $psExe -and $script:sp[0][2] -eq 'RunAs' -and $script:sp[0][3] -and $script:sp[0][4] -and $script:sp[0][1] -ceq ('-NoProfile -ExecutionPolicy Bypass -File "' + $McSetup + '" -Rotation 16.2 -NoPause') -and $rc -eq 0) ($script:sp[0] -join ' | ')
    $script:spExit = 6; Check 'Invoke-Elevated returns the child exit code' ((Invoke-Elevated $McSetup @('-Uninstall', '-NoPause')) -eq 6)
    $script:sp = @()
    Check 'Invoke-Elevated refuses a script outside the mousecal folder' (Throws { Invoke-Elevated (Join-Path $pt 'evil.ps1') @('-Uninstall') })
    Check 'Invoke-Elevated refuses a path-traversal variant' (Throws { Invoke-Elevated ($rd + '\..\setup.ps1') @('-Uninstall') })
    Check 'Invoke-Elevated refuses unexpected arguments' ((Throws { Invoke-Elevated $McSetup @('-Rotation', '1; calc') }) -and (Throws { Invoke-Elevated $McSetup @('-Rotation', '1" -Uninstall') }) -and (Throws { Invoke-Elevated $McSetup @('-Rotation', "1`n") }))
    Check 'Invoke-Elevated started nothing for the refused calls' ($script:sp.Count -eq 0)
    $script:spThrow = New-Object ComponentModel.Win32Exception (1223)
    Check 'Invoke-Elevated: UAC declined (1223) -> 1223' ((Invoke-Elevated $McSetup @('-Uninstall', '-NoPause')) -eq 1223)
    $script:spThrow = New-Object InvalidOperationException ('This command cannot be run due to the error: The operation was canceled by the user.')
    Check 'Invoke-Elevated: "canceled by the user" -> 1223' ((Invoke-Elevated $McSetup @('-Uninstall', '-NoPause')) -eq 1223)
    $script:spThrow = New-Object InvalidOperationException ('something else')
    Check 'Invoke-Elevated: other errors propagate' (Throws { Invoke-Elevated $McSetup @('-Uninstall', '-NoPause') })
    $script:spThrow = $null
    Remove-Item function:Start-Process

    # ---- Get-CurrentRotation: refuses to load DLLs that are not the official ones
    $savedApp = $AppDir; $AppDir = Join-Path $pt 'app'; New-Item -ItemType Directory -Path $AppDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $AppDir 'wrapper.dll'), 'tampered'); [IO.File]::WriteAllText((Join-Path $AppDir 'Newtonsoft.Json.dll'), 'tampered')
    Set-Item function:Get-CurrentRotation $savedFns['Get-CurrentRotation']
    Check 'Get-CurrentRotation: tampered DLLs -> exit code 7, nothing loaded' ((ThrowsCode { Get-CurrentRotation }) -eq 7)
    $AppDir = $savedApp
    foreach ($n in $savedFns.Keys) { Set-Item "function:$n" $savedFns[$n] }   # the real functions back (never called with real effects)

    # ---- handler.vbs: the link is validated BEFORE a command line is built (run with cscript; the real
    # Run call is swapped for a print so nothing is started)
    $vbsTest = Join-Path $rd 'handler-test.vbs'
    $vtxt = $hv.Replace('sh.Run cmd, 0, False', 'WScript.StdOut.WriteLine cmd')
    Check 'vbs test harness: the Run call was replaced' ($vtxt -ne $hv -and $vtxt -match 'StdOut\.WriteLine cmd')
    [IO.File]::WriteAllText($vbsTest, $vtxt, [Text.Encoding]::ASCII)
    function Run-Vbs([string]$arg) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\cscript.exe'
        $psi.Arguments = '//Nologo "' + $vbsTest + '" "' + $arg + '"'
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd(); $p.WaitForExit()
        return @{ Out = $o.Trim(); Code = $p.ExitCode }
    }
    foreach ($u in 'mousecal://apply?m=8.2', 'mousecal://apply/?m=-3.4', 'mousecal:apply?m=8.2', 'mousecal://uninstall', 'mousecal://uninstall/') {
        $r = Run-Vbs $u
        $want = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $rd + '\handler.ps1" -Url "' + $u + '"'
        Check "vbs accepts $u and builds the hidden powershell command" ($r.Code -eq 0 -and $r.Out.Contains($want) -and $r.Out -match '^"[^"]*\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile') $r.Out
    }
    $vbad = @('mousecal://apply?m=8.2 & calc', 'mousecal://apply?m=8.2;calc', 'mousecal://apply?m=8.2|calc', 'mousecal://apply?m=8.2^x', 'mousecal://apply?m=%228', 'mousecal://apply?m=8.2<x', 'mousecal://apply?m=8.2>x',
              'mousecal://apply?m=$(calc)', 'mousecal://apply?m=8.2`calc', 'mousecal://apply?m=8,2', 'mousecal://apply?m=8.2#', 'mousecal://apply?m=8.2@x', 'mousecal://apply?m=8.2(x)', ('a' * 65), ('mousecal://apply?m=' + ('1' * 46)))
    foreach ($u in $vbad) {
        $r = Run-Vbs $u
        $show = $u; if ($show.Length -gt 30) { $show = $show.Substring(0, 30) + '...' }
        Check "vbs rejects [$show] (exit 2, no command built)" ($r.Code -eq 2 -and $r.Out -eq '') "$($r.Code) [$($r.Out)]"
    }
    $r = Run-Vbs ('mousecal://apply?m=8.2' + ('/' * 42)); Check 'vbs: exactly 64 chars passes' ($r.Code -eq 0 -and $r.Out -ne '') "$($r.Code) $($r.Out)"
    $r = Run-Vbs ('mousecal://apply?m=8.2' + ('/' * 43)); Check 'vbs: 65 chars is rejected' ($r.Code -eq 2 -and $r.Out -eq '')
    $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = Join-Path $env:SystemRoot 'System32\cscript.exe'; $psi.Arguments = '//Nologo "' + $vbsTest + '"'
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi); [void]$p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    Check 'vbs: no argument -> exit 2' ($p.ExitCode -eq 2)
    Check 'vbs text: validates before building the command line' ($hv.IndexOf('re.Test(url)') -gt 0 -and $hv.IndexOf('re.Test(url)') -lt $hv.IndexOf('cmd =') -and $hv -match '\[A-Za-z0-9:/\?=\.&-\]' -and $hv -match '> 64')
    Check 'vbs text: runs hidden (window style 0), not waiting' ($hv -match 'sh\.Run cmd, 0, False')

    Remove-Item -LiteralPath $vbsTest -Force

    # ---- foreign registry key is left alone; unregister cleans up
    Set-Item -LiteralPath ($testKey + '\shell\open\command') -Value '"C:\other\thing.exe" "%1"'
    $o = (Unregister-UrlProtocol $rd $testKey *>&1 | Out-String)
    Check 'unregister: a key that points somewhere else is left alone (with a note)' ((Test-Path -LiteralPath $testKey) -and $o -match 'left alone|points somewhere else')
    Check 'unregister: our files are removed regardless, empty folder removed' (-not (Test-Path -LiteralPath $rd))
    Register-UrlProtocol $rd $testKey
    Unregister-UrlProtocol $rd $testKey
    Check 'unregister: key and folder gone' (-not (Test-Path -LiteralPath $testKey) -and -not (Test-Path -LiteralPath $rd))
    Check 'unregister: nothing there -> no error' (-not (Throws { Unregister-UrlProtocol $rd $testKey }))
    Register-UrlProtocol $rd $testKey
    [IO.File]::WriteAllText((Join-Path $rd 'user-notes.txt'), 'not ours')
    Unregister-UrlProtocol $rd $testKey
    Check 'unregister: a foreign file keeps the folder, our files and key are gone' ((Test-Path (Join-Path $rd 'user-notes.txt')) -and -not (Test-Path (Join-Path $rd 'handler.vbs')) -and -not (Test-Path -LiteralPath $testKey))
} finally {
    Remove-Item -LiteralPath $pt -Recurse -Force -ErrorAction SilentlyContinue
    Remove-TestKey
}

# ---- structure checks for the install / uninstall wiring
Check 'install registers the protocol inside the transaction, after the startup task, before the final apply' ($src -match '(?s)Register-ApplyTask \$SettingsPath.*?Register-UrlProtocol.*?\$writer = Join-Path')
Check 'install marks the protocol for rollback BEFORE registering it' ($src -match '(?s)\$tx\.ProtocolRegistered = \$true.*?Register-UrlProtocol')
Check 'rollback unregisters the protocol (unless it existed before this run)' ($src -match '(?s)function Invoke-Rollback.*?ProtocolRegistered -and -not \$tx\.PriorProtocol.*?Unregister-UrlProtocol')
Check 'uninstall removes the protocol in both branches (marker / no marker)' ((([regex]::Matches($src, 'Remove-UrlProtocolStep')).Count) -ge 3)
Check 'dry run prints the protocol registration' ($src -match "Dry 'Register the mousecal:// URL protocol")
Check 'handler files are never made user-writable (read & execute only for Users)' ($src -match '\*S-1-5-32-545:\(OI\)\(CI\)RX' -and $src -notmatch '\*S-1-5-32-545:\(OI\)\(CI\)(F|M|W)')
Check 'elevation targets only the local copy with -Rotation / -Uninstall' ($src -match "Invoke-Elevated \`$McSetup \`$elevArgs" -and $src -match "'-Rotation', \(Format-Rotation \`$new\), '-NoPause'" -and $src -match "'-Uninstall', '-NoPause'")

# =====================================================================================
# Sandboxed install / uninstall flows (round-2 fixes). Everything is stubbed: no network, no
# registry/driver/task/device changes; all paths point into a temp sandbox. These stubs stay
# defined for the rest of the file, so this section is last.
# =====================================================================================
Check 'S-a task principal is addressed by SID S-1-5-18' ($src -match "-UserId 'S-1-5-18'" -and $src -notmatch "NT AUTHORITY\\SYSTEM'")

$sbRoot = Join-Path ([IO.Path]::GetTempPath()) ('mousecal-sbx-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sbRoot | Out-Null
try {
    # ---- a fake "official" zip with its own pinned table
    $fakeFiles = [ordered]@{ 'installer.exe' = 'OFFICIAL-INSTALLER'; 'uninstaller.exe' = 'OFFICIAL-UNINSTALLER'; 'writer.exe' = 'OFFICIAL-WRITER'; 'wrapper.dll' = 'OFFICIAL-WRAPPER'; 'Newtonsoft.Json.dll' = 'OFFICIAL-NEWTONSOFT'; 'driver/rawaccel.sys' = 'OFFICIAL-SYS' }
    $zipEntries = @{}; $rows = @()
    foreach ($k in $fakeFiles.Keys) { $zipEntries['RawAccel/' + $k] = $fakeFiles[$k]; $rows += ($k + '|' + (Get-BytesSha256 ([Text.Encoding]::ASCII.GetBytes($fakeFiles[$k])))) }
    $fakeZip = New-TestZip $zipEntries
    $ZipFilesText = $rows -join "`n"
    $ZipSha256 = Get-BytesSha256 $fakeZip

    # ---- stubs
    $script:calls = @{ Unregister = 0; Register = 0; Tool = 0; ActiveReads = 0 }
    $script:writerExit = 0; $script:failReadBack = $false; $script:toolOk = $true; $script:probeFails = $false
    function Get-RawAccelZipBytes { return , $fakeZip }
    function New-StageDir { $p = Join-Path $script:InstallRoot '.staging'; New-Item -ItemType Directory $p -Force | Out-Null; return $p }
    function Test-DriverActive { param($a, $b) $script:DriverProbeFailed = $script:probeFails; return (-not $script:probeFails) }
    function Get-ActiveRotation { param($a, $b) $script:calls.ActiveReads++; if ($script:failReadBack -and $script:calls.ActiveReads -gt 1) { throw 'cannot read' }; if ($script:calls.ActiveReads -gt 1) { return 8.5 }; return 8.0 }
    function Test-RawAccelFilter { return $true }
    function Install-RawAccelDriver { param($d) return $false }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = 'x' } }
    function Register-ApplyTask { param($s) $script:calls.Register++ }
    function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $script:calls.Unregister++ }
    function Register-ScheduledTask { }
    function Export-ScheduledTask { param($TaskName) return '<task/>' }
    function Restart-MouseDevices { param([switch]$All) return 0 }
    function Get-MouseDevicesInError { return @() }
    function Get-RunningAntiCheatGames { return @() }
    function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$Wait, [switch]$PassThru) return [pscustomobject]@{ ExitCode = $script:writerExit } }
    function Get-AuthenticodeSignature { param($LiteralPath) return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=fake, O=Microsoft Corporation' } } }
    function Test-SettingsJson { param($d, $j, $w) }
    function Invoke-DriverTool { param($Exe, $Mode, $TimeoutSec) $script:calls.Tool++; $script:lastTool = $Exe; return @{ Ok = $script:toolOk; Output = 'stub' } }

    $script:n = 0
    function New-Sandbox {
        $script:n++
        $sb = Join-Path $sbRoot ('s' + $script:n)
        $script:InstallRoot = Join-Path $sb 'PF\RawAccel'; $script:AppDir = Join-Path $script:InstallRoot 'RawAccel'
        $script:SettingsPath = Join-Path $script:AppDir 'settings.json'; $script:MarkerPath = Join-Path $script:AppDir '.mousecal-installed'
        $script:VbsPath = Join-Path $script:InstallRoot 'apply-rawaccel.vbs'; $script:DriverSysPath = Join-Path $sb 'rawaccel.sys'
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        $script:calls = @{ Unregister = 0; Register = 0; Tool = 0; ActiveReads = 0 }
        $script:writerExit = 0; $script:failReadBack = $false; $script:toolOk = $true; $script:probeFails = $false
        $script:DriverProbeFailed = $false
    }
    function Run-Install($arg) { try { $o = (Invoke-Install $arg *>&1 | Out-String); return @{ Threw = $false; Out = $o; Code = 0 } } catch { return @{ Threw = $true; Out = $_.Exception.Message; Code = $_.Exception.Data['ExitCode'] } } }
    $oldMarker = '{"tool":"mousecal","installedDriver":true,"createdAppDir":true,"version":"1"}'
    function Seed-Prior([string]$marker) {
        if ($marker) { [IO.File]::WriteAllText($script:MarkerPath, $marker) }
        Write-Utf8NoBom $script:SettingsPath (Set-RotationInJson $SettingsTemplate 8.0)
        [IO.File]::WriteAllText((Join-Path $script:AppDir 'writer.exe'), 'OLD-WRITER')
    }
    $mm = @{ Kind = 'Measured'; Value = 0.5 }

    # F1: a re-run keeps ownership
    New-Sandbox; Seed-Prior $oldMarker
    $r = Run-Install $mm
    $mk = [IO.File]::ReadAllText($script:MarkerPath) | ConvertFrom-Json
    Check 'F1 re-run succeeds' (-not $r.Threw) $r.Out
    Check 'F1 re-run keeps installedDriver/createdAppDir true' ($mk.installedDriver -eq $true -and $mk.createdAppDir -eq $true) ([IO.File]::ReadAllText($script:MarkerPath))
    Check 'F3 differing file replaced by the official one' ([IO.File]::ReadAllText((Join-Path $script:AppDir 'writer.exe')) -eq 'OFFICIAL-WRITER')
    Check 'F4 rotation = active 8.0 + measured 0.5' ([IO.File]::ReadAllText($script:SettingsPath) -match '"Degrees of rotation": 8\.5,')
    Check 'F3 the user is told about replaced files' ($r.Out -match 'differed from the official')
    # the old VBS task alone does NOT confer ownership
    New-Sandbox; Seed-Prior ''
    [IO.File]::WriteAllText($script:VbsPath, 'old vbs')
    $r = Run-Install $mm
    $mk = [IO.File]::ReadAllText($script:MarkerPath) | ConvertFrom-Json
    Check 'F1 no marker (old VBS task only) -> installedDriver=false, createdAppDir=false' ($mk.installedDriver -eq $false -and $mk.createdAppDir -eq $false) ([IO.File]::ReadAllText($script:MarkerPath))

    # F2/F3: rollback restores a pre-existing marker and overwritten files
    New-Sandbox; Seed-Prior $oldMarker; $script:writerExit = 1
    $r = Run-Install $mm
    Check 'F2 failed run throws' $r.Threw
    Check 'F2 rollback restores the original marker byte for byte' ((Test-Path $script:MarkerPath) -and [IO.File]::ReadAllText($script:MarkerPath) -eq $oldMarker)
    Check 'F3 rollback puts the original (differing) writer.exe back' ([IO.File]::ReadAllText((Join-Path $script:AppDir 'writer.exe')) -eq 'OLD-WRITER')
    Check 'F3 rollback restores settings.json' ([IO.File]::ReadAllText($script:SettingsPath) -match '"Degrees of rotation": 8\.0,')
    New-Sandbox; Seed-Prior ''; $script:writerExit = 1
    $r = Run-Install $mm
    Check 'F2 marker created by this failed run is removed' (-not (Test-Path $script:MarkerPath))
    Check 'F2 pre-existing app dir is kept' (Test-Path $script:AppDir)
    New-Sandbox; Seed-Prior 'garbage-not-a-marker'; $script:writerExit = 1
    $r = Run-Install $mm
    Check 'F2 an unreadable pre-existing marker is restored too' ([IO.File]::ReadAllText($script:MarkerPath) -eq 'garbage-not-a-marker')

    # F3: a rollback that cannot restore says so
    New-Sandbox
    $script:Tx = New-Tx; $script:Tx.Mutated = $true; $script:Tx.Overwritten = @(@{ Dest = (Join-Path $script:AppDir 'x.bin'); Backup = (Join-Path $script:AppDir 'does-not-exist.bak') })
    $o = (Invoke-Rollback *>&1 | Out-String)
    Check 'F3 incomplete rollback is reported as INCOMPLETE, not "undone"' ($o -match 'INCOMPLETE' -and $o -notmatch 'Changes undone')
    $script:Tx = $null

    # ---- mousecal:// protocol inside the install transaction (registry redirected to HKCU, folder lock stubbed)
    function Hd { return (Join-Path $script:InstallRoot 'mousecal') }
    Remove-TestKey
    New-Sandbox; Seed-Prior $oldMarker
    $r = Run-Install $mm
    Check 'proto: a real install writes the handler files and registers the protocol' ((-not $r.Threw) -and (Test-Path -LiteralPath $testKey) -and (Test-Path (Join-Path (Hd) 'handler.vbs')) -and (Test-Path (Join-Path (Hd) 'handler.ps1')) -and (Test-Path (Join-Path (Hd) 'setup.ps1'))) $r.Out
    Check 'proto: command points at the installed handler.vbs' ((Get-Item -LiteralPath ($testKey + '\shell\open\command')).GetValue('') -ceq (Get-ProtocolCommand (Hd)))
    Check 'proto: the installed setup.ps1 is the running script' (([IO.File]::ReadAllText((Join-Path (Hd) 'setup.ps1'))).TrimStart([char]0xFEFF) -ceq $src)
    Check 'proto: install output mentions the one-click link and uninstall button' ((($r.Out -replace '\s+', ' ') -match 'Registered the mousecal:// URL protocol') -and (($r.Out -replace '\s+', ' ') -match 'One-click apply'))
    # re-install over an existing registration keeps working and keeps it
    $r = Run-Install $mm
    Check 'proto: a second install over it succeeds and keeps it' ((-not $r.Threw) -and (Test-Path -LiteralPath $testKey))
    Unregister-UrlProtocol (Hd) $testKey

    New-Sandbox; Seed-Prior $oldMarker; $script:writerExit = 1
    $r = Run-Install $mm
    Check 'proto: a failed install rolls the protocol back (key, files, folder)' ($r.Threw -and -not (Test-Path -LiteralPath $testKey) -and -not (Test-Path (Hd))) $r.Out
    New-Sandbox; Seed-Prior $oldMarker; $script:writerExit = 1
    Register-UrlProtocol (Hd) $testKey
    $r = Run-Install $mm
    Check 'proto: a failed re-install does NOT remove a registration that existed before' ($r.Threw -and (Test-Path -LiteralPath $testKey) -and (Test-Path (Join-Path (Hd) 'handler.vbs')))
    Unregister-UrlProtocol (Hd) $testKey

    $realReg = ${function:Register-UrlProtocol}
    function Register-UrlProtocol { param($Dir, $Key) throw 'simulated registry failure' }
    New-Sandbox; Seed-Prior $oldMarker
    $r = Run-Install $mm
    Check 'proto: failing to register is only a warning; the install still succeeds' ((-not $r.Threw) -and (($r.Out -replace '\s+', ' ') -match 'Could not set up the one-click link') -and ($r.Out -match 'simulated registry failure') -and (Test-Path $script:SettingsPath)) $r.Out
    Check 'proto: ... and the final message does not advertise the one-click button' (($r.Out -replace '\s+', ' ') -notmatch 'One-click apply')
    Set-Item function:Register-UrlProtocol $realReg

    # dry run: lists the protocol, creates nothing
    $DryRun = [switch]$true
    New-Sandbox; Seed-Prior $oldMarker
    $r = Run-Install $mm
    $DryRun = [switch]$false
    $flat = ($r.Out -replace '\s+', '')   # the console wraps long lines mid-word: compare without whitespace
    Check 'proto: -DryRun lists the protocol registration (key, command, files)' ((-not $r.Threw) -and $flat.Contains('Registerthemousecal://URLprotocol') -and $flat.Contains($testKey) -and $flat.Contains(((Get-ProtocolCommand (Hd)) -replace '\s+', '')) -and $flat.Contains('handler.vbs,handler.ps1')) $r.Out
    Check 'proto: -DryRun creates nothing' (-not (Test-Path -LiteralPath $testKey) -and -not (Test-Path (Hd)))

    # S-b: "installer ran" counts as DriverInstalled for rollback -> staged uninstaller + device restart
    New-Sandbox
    $script:StageDir = New-StageDir
    [IO.File]::WriteAllText((Join-Path $script:StageDir 'uninstaller.exe'), 'x')
    $script:Tx = New-Tx; $script:Tx.Mutated = $true; $script:Tx.DriverInstalled = $true
    $before = $script:calls.Tool
    $o = (Invoke-Rollback *>&1 | Out-String)
    Check 'S-b rollback runs the staged uninstaller when the installer ran' ($script:calls.Tool -eq $before + 1)
    Check 'S-b Install-RawAccelDriver marks DriverInstalled before the installer runs' ($src -match '(?s)function Install-RawAccelDriver.*?\$script:Tx\.DriverInstalled = \$true.*?Invoke-DriverTool \$exe')
    $script:Tx = $null; $script:StageDir = $null

    # S-c: an unreadable read-back is not reported as verified
    New-Sandbox; Seed-Prior $oldMarker; $script:failReadBack = $true
    $r = Run-Install $mm
    Check 'S-c read-back failure: not claimed as active/verified, asks for a reboot' ((-not $r.Threw) -and $r.Out -match 'could not be read back' -and $r.Out -notmatch 'is active now') $r.Out
    New-Sandbox; Seed-Prior $oldMarker
    $r = Run-Install $mm
    Check 'S-c verified read-back says active now' (($r.Out -replace '\s+', ' ') -match 'is active now') ($r.Out.Substring([math]::Max(0, $r.Out.Length - 700)))

    # F4: -Measured with an undeterminable driver state changes nothing and exits 1
    New-Sandbox; Seed-Prior $oldMarker; $script:probeFails = $true
    $wBefore = [IO.File]::ReadAllText((Join-Path $script:AppDir 'writer.exe'))
    $r = Run-Install $mm
    Check 'F4 -Measured + unknown driver state -> exit 1' ($r.Threw -and $r.Code -eq 1) "$($r.Code) $($r.Out)"
    Check 'F4 nothing was changed' ([IO.File]::ReadAllText((Join-Path $script:AppDir 'writer.exe')) -eq $wBefore -and [IO.File]::ReadAllText($script:MarkerPath) -eq $oldMarker -and $script:calls.Register -eq 0)
    New-Sandbox; Seed-Prior $oldMarker; $script:probeFails = $true
    $r = Run-Install @{ Kind = 'Rotation'; Value = 3.0 }
    Check 'F4 -Rotation (absolute) does not need the driver state' (-not $r.Threw) $r.Out

    # F4: Test-DriverActive itself (real function, mocked CIM)
    Remove-Item function:Test-DriverActive
    . $setupPath
    . $applySafety
    $script:InstallRoot = Join-Path $sbRoot 'none'; $script:AppDir = Join-Path $script:InstallRoot 'RawAccel'; $script:StageDir = $null
    function Get-CimInstance { throw 'WMI: RPC server unavailable' }
    $res = Test-DriverActive
    Check 'F4 CIM exception -> not active AND the probe flag is raised' (($res -eq $false) -and $script:DriverProbeFailed -eq $true)
    function Get-CimInstance { [pscustomobject]@{ State = 'Running' } }
    Check 'F4 CIM Running -> active, no flag' ((Test-DriverActive) -eq $true -and $script:DriverProbeFailed -eq $false)
    function Get-CimInstance { [pscustomobject]@{ State = 'Stopped' } }
    Check 'F4 CIM Stopped -> not active, no flag' ((Test-DriverActive) -eq $false -and $script:DriverProbeFailed -eq $false)
    function Get-ActiveRotation { param($a, $b) return 8.0 }
    function Get-CimInstance { throw 'WMI down' }
    Check 'F4 CIM down but GetActive() reads -> active, no flag' ((Test-DriverActive 'C:\x' $sbRoot) -eq $true -and $script:DriverProbeFailed -eq $false)
    Remove-Item function:Get-CimInstance
    . $setupPath   # restore the real Get-ActiveRotation etc.
    . $applySafety

    # F5: uninstall keeps the task until the driver step succeeded; falls back to a verified uninstaller
    $ZipFilesText = $rows -join "`n"; $ZipSha256 = Get-BytesSha256 $fakeZip
    function Test-RawAccelFilter { return $true }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = 'x' } }
    function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $script:calls.Unregister++ }
    function New-StageDir { $p = Join-Path $script:InstallRoot '.staging'; New-Item -ItemType Directory $p -Force | Out-Null; return $p }
    function Invoke-DriverTool { param($Exe, $Mode, $TimeoutSec) $script:calls.Tool++; $script:lastTool = $Exe; return @{ Ok = $script:toolOk; Output = 'stub' } }
    function Test-DriverActive { param($a, $b) $script:DriverProbeFailed = $false; return $false }
    function Restart-MouseDevices { param([switch]$All) return 0 }
    function Get-RawAccelZipBytes { return , $fakeZip }
    $DryRun = [switch]$false
    New-Sandbox; [IO.File]::WriteAllText($script:MarkerPath, $oldMarker)
    [IO.File]::WriteAllText((Join-Path $script:AppDir 'uninstaller.exe'), 'OFFICIAL-UNINSTALLER')
    $script:toolOk = $false
    $r = $null; try { Invoke-Uninstall *>&1 | Out-Null; $r = 'ok' } catch { $r = $_.Exception.Data['ExitCode'] }
    Check 'F5 driver step fails -> exit 8, task NOT removed, marker kept' ($r -eq 8 -and $script:calls.Unregister -eq 0 -and (Test-Path $script:MarkerPath)) "r=$r unreg=$($script:calls.Unregister)"
    $script:toolOk = $true; $script:calls.Unregister = 0
    $null = Invoke-Uninstall *>&1
    Check 'F5 driver step ok -> task removed afterwards, marker gone' ($script:calls.Unregister -eq 1 -and -not (Test-Path $script:MarkerPath))
    Check 'F5 intact installed uninstaller is used as is' ($script:lastTool -eq (Join-Path $script:AppDir 'uninstaller.exe'))
    New-Sandbox; [IO.File]::WriteAllText($script:MarkerPath, $oldMarker); [IO.File]::WriteAllText((Join-Path $script:AppDir 'uninstaller.exe'), 'TAMPERED')
    $null = Invoke-Uninstall *>&1
    Check 'F5 tampered uninstaller is NOT run; the verified staged copy is' ($script:lastTool -ne (Join-Path $script:AppDir 'uninstaller.exe') -and $script:lastTool -like '*.staging*uninstaller.exe') $script:lastTool
    New-Sandbox; [IO.File]::WriteAllText($script:MarkerPath, $oldMarker)
    $null = Invoke-Uninstall *>&1
    Check 'F5 missing uninstaller falls back to the verified staged copy' ($script:lastTool -like '*.staging*uninstaller.exe') $script:lastTool
    function Get-RawAccelZipBytes { return , ([byte[]](1, 2, 3)) }
    New-Sandbox; [IO.File]::WriteAllText($script:MarkerPath, $oldMarker); $script:calls.Tool = 0; $script:calls.Unregister = 0
    $r = $null; try { Invoke-Uninstall *>&1 | Out-Null; $r = 'ok' } catch { $r = $_.Exception.Data['ExitCode'] }
    Check 'F5 fallback download with a wrong hash -> exit 4, nothing run, task kept' ($r -eq 4 -and $script:calls.Tool -eq 0 -and $script:calls.Unregister -eq 0) "r=$r"
    $h = Get-ErrorHint 8 $true; $h2 = Get-ErrorHint 8 $false
    Check 'F5 uninstall has its own error hints' ($h[1] -ne $h2[1] -and $h[0] -match 'uninstall' -and $h2[0] -notmatch 'uninstall command')
    Check 'F5 main passes the uninstall flag to the hints' ($src -match 'Get-ErrorHint \$code \(\[bool\]\$Uninstall\)')

    # ---- uninstall removes the mousecal:// protocol (both with and without a marker), dry run only reports
    function Hd { return (Join-Path $script:InstallRoot 'mousecal') }
    Remove-TestKey
    New-Sandbox; [IO.File]::WriteAllText($script:MarkerPath, $oldMarker); [IO.File]::WriteAllText((Join-Path $script:AppDir 'uninstaller.exe'), 'OFFICIAL-UNINSTALLER')
    Register-UrlProtocol (Hd) $testKey
    $DryRun = [switch]$true
    $o = (Invoke-Uninstall *>&1 | Out-String)
    $DryRun = [switch]$false
    Check 'proto: uninstall -DryRun reports the removal and keeps everything' (($o -replace '\s+', ' ') -match 'Remove the mousecal:// URL protocol' -and (Test-Path -LiteralPath $testKey) -and (Test-Path (Hd))) $o
    $o = (Invoke-Uninstall *>&1 | Out-String)
    Check 'proto: uninstall (with marker) removes the key, the files and the folder' ((-not (Test-Path -LiteralPath $testKey)) -and -not (Test-Path (Hd)) -and (($o -replace '\s+', ' ') -match 'Removed the mousecal:// URL protocol')) $o
    New-Sandbox
    Register-UrlProtocol (Hd) $testKey
    $o = (Invoke-Uninstall *>&1 | Out-String)
    Check 'proto: uninstall without a marker also removes the key and the folder' ((-not (Test-Path -LiteralPath $testKey)) -and -not (Test-Path (Hd))) $o
    New-Sandbox; [IO.File]::WriteAllText($script:MarkerPath, $oldMarker)
    $script:toolOk = $false
    [IO.File]::WriteAllText((Join-Path $script:AppDir 'uninstaller.exe'), 'OFFICIAL-UNINSTALLER')
    Register-UrlProtocol (Hd) $testKey
    $r = $null; try { Invoke-Uninstall *>&1 | Out-Null; $r = 'ok' } catch { $r = $_.Exception.Data['ExitCode'] }
    Check 'proto: a failed driver uninstall (exit 8) keeps the protocol so the user can retry' ($r -eq 8 -and (Test-Path -LiteralPath $testKey))
    $script:toolOk = $true
    Unregister-UrlProtocol (Hd) $testKey
    New-Sandbox
    $o = (Invoke-Uninstall *>&1 | Out-String)
    Check 'proto: uninstall with nothing registered says nothing about it' (($o -notmatch 'mousecal://') -and -not (Test-Path -LiteralPath $testKey))
    Check 'SAFETY: the real HKLM:\SOFTWARE\Classes\mousecal was not touched by this test run' ((Test-Path -LiteralPath 'HKLM:\SOFTWARE\Classes\mousecal') -eq $hklmKeyBefore)
} finally {
    Remove-Item -LiteralPath $sbRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-TestKey
if ($script:fails -gt 0) { Write-Host "$script:fails check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all setup.ps1 checks passed'
