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

# HARD GUARD (2026-10-15 incident): on a PC with UAC "never notify", one un-stubbed elevation in a test runs the
# REAL installed setup.ps1 silently. These global wrappers refuse every elevation / real system change; a test
# that needs Start-Process defines its own function in its own scope, which takes precedence over these.
function global:Start-Process {
    param($FilePath, $ArgumentList, $Verb, $WorkingDirectory, $WindowStyle, $RedirectStandardOutput, $RedirectStandardError, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow)
    if ($Verb -eq 'RunAs') { throw "TEST GUARD: elevation attempted ($FilePath $ArgumentList)" }
    if ([string]$FilePath -match '(?i)(installer|uninstaller|writer|pnputil|wscript|cscript)\.exe|\\RawAccel\\') { throw "TEST GUARD: real system tool started ($FilePath)" }
    $p = @{ FilePath = $FilePath }
    foreach ($k in 'ArgumentList', 'WorkingDirectory', 'WindowStyle', 'RedirectStandardOutput', 'RedirectStandardError') { if ($PSBoundParameters.ContainsKey($k)) { $p[$k] = $PSBoundParameters[$k] } }
    Microsoft.PowerShell.Management\Start-Process @p -Wait:$Wait -PassThru:$PassThru -NoNewWindow:$NoNewWindow
}
foreach ($n in 'Unregister-ScheduledTask', 'Register-ScheduledTask', 'Start-ScheduledTask') {
    Set-Item "function:global:$n" ([scriptblock]::Create("throw 'TEST GUARD: real $n called'"))
}
function ThrowsCode([scriptblock]$Block) { try { & $Block | Out-Null; return -1 } catch { $c = $_.Exception.Data['ExitCode']; if ($c) { return [int]$c } else { return 0 } } }

$env:MOUSECAL_NO_MAIN = '1'
$env:MOUSECAL_NO_PAUSE = '1'
$setupPath = Join-Path $here '..\setup.ps1'
. $setupPath
$src = [IO.File]::ReadAllText($setupPath)
# Windows PowerShell 5.1 started from PowerShell 7 inherits a PSModulePath it cannot load Microsoft.PowerShell.Security from (Get-Acl);
# setup.ps1 repairs it in Invoke-MainCore, the tests call the functions directly, so repair it here the same way.
$env:PSModulePath = Get-SafeModulePath $env:PSModulePath $false ($PSVersionTable.PSEdition -eq 'Desktop')

# ---- SAFETY: nothing in this file may touch the real HKLM:\SOFTWARE\Classes\mousecal or run icacls on a real
# path. Invoke-Icacls (the only way setup.ps1 runs icacls) only records its arguments here; the one test that
# runs the real tool does so on a throw-away folder under %TEMP% (see the round-3 section).
# The URL-protocol registry key is redirected to a throw-away HKCU key and the folder-lock helper is a
# no-op; this block is re-applied after every re-dot-source of setup.ps1 (which would reset both).
$testKey = 'HKCU:\Software\mousecal-test-' +[guid]::NewGuid().ToString('N')
# SAFETY (pointer precision): the mouse settings key is redirected to a throw-away HKCU key and the SPI_SETMOUSE call is a
# recorder; Invoke-Spi (the raw P/Invoke) refuses everything except the read-only SPI_GETMOUSE. The real
# HKCU:\Control Panel\Mouse values are snapshotted here and compared again at the very end.
$testMouseKey = 'HKCU:\Software\mousecal-test-mouse-' + [guid]::NewGuid().ToString('N')
function Get-RealMouseSnapshot { $k = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Mouse'; return ('{0}|{1}|{2}' -f $k.MouseSpeed, $k.MouseThreshold1, $k.MouseThreshold2) }
$realMouseBefore = Get-RealMouseSnapshot
$script:spiCalls = @()
$script:sameUser = $true
$script:protectCalls = @()
$script:aclCalls = @()
$realInvokeSpi = ${function:Invoke-Spi}             # only ever called with SPI_GETMOUSE (3), see the guard below
$realTestSame = ${function:Test-SameInteractiveUser}   # the stub below answers $script:sameUser; the real one is tested through this
$applySafety = {
    $ProtocolKey = $testKey
    $MouseKey = $testMouseKey
    function Invoke-SpiSetMouse { param([int[]]$Values) $script:spiCalls += , @($Values) }
    function Invoke-Spi { param([uint32]$Action, [int[]]$Values, [uint32]$Flags = 0) if ($Action -ne 3) { throw "SAFETY: the tests may only call the read-only SPI_GETMOUSE (got $Action)" }; & $realInvokeSpi $Action $Values $Flags }
    function Test-SameInteractiveUser { param([string]$CurrentSid = '', [string[]]$ExplorerSids = $null) return [bool]$script:sameUser }
    function Protect-HandlerDir { param($Dir) $script:protectCalls += $Dir }
    function Invoke-Icacls { param([string[]]$IcaclsArgs) $script:aclCalls += , $IcaclsArgs; return @{ Code = 0; Out = '' } }
    function Set-ExactDacl { param([string]$Path) $script:aclCalls += , @($Path, 'EXACT-DACL') }
    function Clear-StaleStaging { $script:staleCalls++ }      # the real one deletes folders: only ever run against the throw-away InstallRoot (L3 test)
}
$realInvokeIcacls = ${function:Invoke-Icacls}   # only ever used on the throw-away folder in the round-3 section
$realSetExactDacl = ${function:Set-ExactDacl}   # ditto (Set-Acl on the throw-away folder only)
$realClearStale = ${function:Clear-StaleStaging}   # ditto (deletes .staging\* of the throw-away InstallRoot only)
$script:staleCalls = 0
. $applySafety
$hklmKeyBefore = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Classes\mousecal'
function Remove-TestKey {
    if (Test-Path -LiteralPath $testKey) { Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $testMouseKey) { Remove-Item -LiteralPath $testMouseKey -Recurse -Force -ErrorAction SilentlyContinue }
}
trap { Remove-TestKey; throw $_ }

# ---- contract: functions exist
foreach ($fn in 'Test-IsAdmin', 'Test-RotationValue', 'Test-ZipHash', 'Get-RunningAntiCheatGames', 'Set-RotationInJson',
                'Backup-Settings', 'Register-ApplyTask', 'Install-RawAccelDriver', 'Invoke-Uninstall', 'Invoke-Main',
                'Restart-MouseDevices', 'Test-DriverActive', 'ConvertTo-Degrees', 'Get-NewRotation', 'Expand-VerifiedZip', 'Get-RawAccelZipBytes', 'Test-ZipEntries',
                'Get-PointerPrecision', 'Set-PointerPrecisionOff', 'Restore-PointerPrecision', 'Test-SameInteractiveUser') {
    Check "function $fn" ([bool](Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue))
}
$params = (Get-Command $setupPath).Parameters
foreach ($p in 'NoPause', 'Measured', 'Rotation', 'Uninstall', 'DryRun', 'RestorePointerPrecision') { Check "parameter -$p" $params.ContainsKey($p) }
Check '-RestorePointerPrecision is a switch' ($params['RestorePointerPrecision'].SwitchParameter)
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
$RestorePointerPrecision = [switch]$true
Check '-RestorePointerPrecision without -Uninstall -> 3' ((Test-Args '' '2' $false) -eq 3)
Check '-RestorePointerPrecision with -Uninstall ok' ((Test-Args '' '' $true).Kind -eq 'Uninstall')
$RestorePointerPrecision = [switch]$false
Check 'no -RestorePointerPrecision: -Measured still parses' ((Test-Args '' '2' $false).Kind -eq 'Measured')
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
    Check 'real run stages under the install root in a per-run .staging\<guid> folder' ($sp -match ('^(?i)' + [regex]::Escape((Join-Path $InstallRoot '.staging')) + '[\x5c][0-9a-f]{32}$') -and (Get-StagePath) -ne $sp -and -not $sp.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase))
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
    foreach ($u in 'mousecal://uninstall?epp=1', 'mousecal://uninstall/?epp=1', 'mousecal:uninstall?epp=1', 'MOUSECAL://UNINSTALL?epp=1', 'mousecal://uninstall?epp=1/') {
        $r = Parse-Url $u
        Check "url ok (restore): $u" ($r -and $r.Action -eq 'uninstall' -and $r.RestorePointerPrecision -eq $true -and -not $r.ContainsKey('Measured'))
    }
    foreach ($u in 'mousecal://uninstall?epp=0', 'mousecal://uninstall/?epp=0', 'mousecal://uninstall', 'mousecal:uninstall/') {
        $r = Parse-Url $u
        Check "url ok (no restore): $u" ($r -and $r.Action -eq 'uninstall' -and $r.RestorePointerPrecision -eq $false)
    }
    $bad = @('mousecal://uninstall?epp=2', 'mousecal://uninstall?epp=', 'mousecal://uninstall?epp', 'mousecal://uninstall?epp=11', 'mousecal://uninstall?epp=01', 'mousecal://uninstall?epp=true',
             'mousecal://uninstall?EPP=1', 'mousecal://uninstall?epp=1&x=1', 'mousecal://uninstall?x=1&epp=1', 'mousecal://uninstall?epp=1&epp=0', 'mousecal://uninstall?epp==1', 'mousecal://uninstall?epp=-1',
             'mousecal://uninstall?epp=1.0', 'mousecal://uninstall?epp=1;calc', 'mousecal://uninstall?epp=1 ', "mousecal://uninstall?epp=1`n", 'mousecal://uninstall?epp=1"', 'mousecal://uninstall?epp=%31',
             'mousecal://uninstall/x?epp=1', 'mousecal://apply?epp=1', 'mousecal://apply?m=8.2&epp=1', 'mousecal://uninstall??epp=1', 'mousecal://uninstall?epp=1?epp=1',
             '', 'mousecal://', 'mousecal://apply', 'mousecal://apply?', 'mousecal://apply?m=', 'mousecal://apply?x=1', 'mousecal://apply?m=8.2&x=1',
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
Check 'rollback unregisters the protocol (unless it existed before this run, then it restores the key)' ($src -match '(?s)function Invoke-Rollback.*?ProtocolRegistered.*?-not \$tx\.PriorProtocol\) \{ Unregister-UrlProtocol( -Owned)? \}.*?Restore-UrlProtocolSnapshot')
Check 'uninstall removes the protocol in both branches (marker / no marker)' ((([regex]::Matches($src, 'Remove-UrlProtocolStep')).Count) -ge 3)
Check 'dry run prints the protocol registration' ($src -match "Dry 'Register the mousecal:// URL protocol")
Check 'handler files are never made user-writable (read & execute only for Users)' ($src -match '\*S-1-5-32-545:\(OI\)\(CI\)RX' -and $src -notmatch "S-1-5-32-545:\(OI\)\(CI\)(F|M|W)")
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
    # a started child: WaitForExit() says whether it finished within the time limit ($script:writerHang = it never does)
    $script:writerHang = $false; $script:waitedMs = $null; $script:killed = 0
    function New-FakeProc([int]$Exit) {
        $o = [pscustomobject]@{ ExitCode = $Exit; Id = 4242 }
        Add-Member -InputObject $o -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $script:waitedMs = $ms; return (-not $script:writerHang) }
        return $o
    }
    function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:killed++ }
    $script:calls = @{ Unregister = 0; Register = 0; Tool = 0; ActiveReads = 0 }
    $script:writerExit = 0; $script:failReadBack = $false; $script:toolOk = $true; $script:probeFails = $false
    function Get-RawAccelZipBytes { return , $fakeZip }
    function New-StageDir { $p = Join-Path $script:InstallRoot '.staging'; New-Item -ItemType Directory $p -Force | Out-Null; return $p }
    function Test-DriverActive { param($a, $b) $script:DriverProbeFailed = $script:probeFails; return (-not $script:probeFails) }
    function Get-ActiveRotation { param($a, $b) $script:calls.ActiveReads++; if ($script:failReadBack -and $script:calls.ActiveReads -gt 1) { throw 'cannot read' }; if ($script:calls.ActiveReads -gt 1) { return 8.5 }; return 8.0 }
    function Test-RawAccelFilter { return $true }
    function Install-RawAccelDriver { param($d) return $false }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = 'x'; Actions = @([pscustomobject]@{ Execute = (Join-Path $AppDir 'writer.exe'); Arguments = '' }) } }
    function Register-ApplyTask { param($s) $script:calls.Register++ }
    function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $script:calls.Unregister++ }
    function Register-ScheduledTask { }
    function Export-ScheduledTask { param($TaskName) return '<task/>' }
    function Restart-MouseDevices { param([switch]$All) return 0 }
    function Get-MouseDeviceStatus { return @{} }
    function Get-RunningAntiCheatGames { return @() }
    function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$Wait, [switch]$PassThru) return (New-FakeProc $script:writerExit) }
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
    function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = 'x'; Actions = @([pscustomobject]@{ Execute = (Join-Path $AppDir 'writer.exe'); Arguments = '' }) } }
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
    # panel: a same-named task that is NOT ours is never removed
    Check 'panel: Test-OwnApplyTask accepts our writer.exe task' (Test-OwnApplyTask ([pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = (Join-Path $AppDir 'writer.exe'); Arguments = '"x"' }) }))
    Check 'panel: Test-OwnApplyTask accepts the legacy wscript + apply-rawaccel.vbs task' (Test-OwnApplyTask ([pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = 'wscript.exe'; Arguments = ('"' + $VbsPath + '"') }) }))
    Check 'panel: Test-OwnApplyTask rejects a foreign task with the same name' (-not (Test-OwnApplyTask ([pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = 'C:\Tools\backup.exe'; Arguments = '' }) })))
    Check 'panel: Test-OwnApplyTask rejects a task with no action' (-not (Test-OwnApplyTask ([pscustomobject]@{ Actions = @() })))
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

    # =====================================================================================
    # Round-3 fixes. Start from the real functions again, then stub every system-changing one.
    # =====================================================================================
    . $setupPath
    . $applySafety
    $ZipFilesText = $rows -join "`n"; $ZipSha256 = Get-BytesSha256 $fakeZip
    $DryRun = [switch]$false
    $realInstallDriver = ${function:Install-RawAccelDriver}
    $realGetActive = ${function:Get-ActiveRotation}
    $realTestDriverActive = ${function:Test-DriverActive}
    $MouseSettleSeconds = 0
    Check 'R3 stub guard: Invoke-Icacls is the recorder, not the real tool' (${function:Invoke-Icacls}.ToString() -match 'aclCalls')

    # ---- F3: differing profile rotations
    Check 'F3 the driver query reports MIXED when profiles disagree' ($ActiveScript -match 'MIXED' -and $ActiveScript -match 'Write-Output \(.ROT ')
    function Invoke-Ps51Script { param($t, $w, $n, $a) return $script:ps51Result }
    $script:ps51Result = @{ Code = 0; Out = 'ROT 8' }
    Check 'F3 equal profiles -> the rotation' ((Get-ActiveRotation 'd' 'w') -eq 8.0)
    $script:ps51Result = @{ Code = 0; Out = 'MIXED 8 0 -3.5' }
    $c = ThrowsCode { Get-ActiveRotation 'd' 'w' }
    Check 'F3 differing profiles -> exit 3' ($c -eq 3) "code=$c"
    try { Get-ActiveRotation 'd' 'w' } catch { $m = $_.Exception.Message }
    Check 'F3 ... with a bilingual message that names the values and -Rotation' ($m -match '8, 0, -3\.5' -and $m -match '-Rotation' -and $m -match '[^\x00-\x7F]')
    $script:ps51Result = @{ Code = 3; Out = 'ERROR: x' }
    Check 'F3 an unreadable driver stays exit 1' ((ThrowsCode { Get-ActiveRotation 'd' 'w' }) -eq 1)
    Remove-Item function:Invoke-Ps51Script
    function Get-CimInstance { throw 'WMI down' }
    function Get-ActiveRotation { param($a, $b) Fail 'mixed' 'mixed' @() 3 }
    Check 'F3 the driver probe counts a MIXED answer as "driver is running"' ((Test-DriverActive 'C:\x' $sbRoot) -eq $true -and $script:DriverProbeFailed -eq $false)
    function Get-ActiveRotation { param($a, $b) Fail 'nope' 'nope' @() 1 }
    Check 'F3 ... but a plain read failure still is not' ((Test-DriverActive 'C:\x' $sbRoot) -eq $false -and $script:DriverProbeFailed -eq $true)
    Remove-Item function:Get-CimInstance
    Set-Item function:Get-ActiveRotation $realGetActive

    # ---- F6: mouse regressions
    $script:statusNow = @{}
    function Get-MouseDeviceStatus { return $script:statusNow }
    $script:statusNow = @{ 'A' = 'OK'; 'B' = 'Error' }
    Check 'F6 nothing changed -> no regression' (@(Get-MouseRegressions @{ 'A' = 'OK'; 'B' = 'Error' }).Count -eq 0)
    $script:statusNow = @{ 'A' = 'Error'; 'B' = 'Error' }
    Check 'F6 OK before, not OK now -> regression (pre-existing broken B ignored)' ((@(Get-MouseRegressions @{ 'A' = 'OK'; 'B' = 'Error' }) -join ',') -eq 'A')
    $script:statusNow = @{ 'B' = 'Error' }
    Check 'S6 a device that was OK and is missing now IS a regression (it gets time to reappear in the install flow)' ((@(Get-MouseRegressions @{ 'A' = 'OK'; 'B' = 'Error' }) -join ',') -eq 'A')
    Check 'S6 a device that was already broken and is missing is ignored' (@(Get-MouseRegressions @{ 'B' = 'Error' }).Count -eq 0)
    Check 'S6 the settle time is 10 seconds' ($src -match '\$MouseSettleSeconds = 10\b')
    $script:statusNow = @{ 'A' = 'Unknown' }
    Check 'F6 any non-OK status counts' ((@(Get-MouseRegressions @{ 'A' = 'OK' }) -join ',') -eq 'A')
    Check 'F6 the install no longer uses the old Error-only baseline' ($src -notmatch 'Get-MouseDevicesInError|baselineBad')

    # ---- M1/F5: Protect-AppDir arguments (recorders: Set-ExactDacl and Invoke-Icacls only record)
    function Show-Calls { return , @($script:aclCalls | ForEach-Object { $_ -join ' ' }) }
    $fakeApp = Join-Path $sbRoot 'fake-app'; New-Item -ItemType Directory -Path $fakeApp | Out-Null
    $script:aclCalls = @(); Protect-AppDir $fakeApp
    $c = Show-Calls
    Check 'M1 empty folder: exact DACL only (nothing below to own or reset)' ($c.Count -eq 1 -and $c[0] -ceq ($fakeApp + ' EXACT-DACL')) ($c -join ' | ')
    [IO.File]::WriteAllText((Join-Path $fakeApp 'writer.exe'), 'x')
    $script:aclCalls = @(); Protect-AppDir $fakeApp
    $c = Show-Calls
    Check 'M1 the folder gets the exact DACL first' ($c[0] -ceq ($fakeApp + ' EXACT-DACL')) ($c -join ' | ')
    Check 'M1 ... then everything below is owned by Administrators (/T)' ($c[1] -ceq ($fakeApp + ' /setowner *S-1-5-32-544 /T /C')) ($c -join ' | ')
    Check 'M1 ... then reset to inherit exactly that (/reset /T)' ($c.Count -eq 3 -and $c[2] -ceq ((Join-Path $fakeApp '*') + ' /reset /T /C')) ($c -join ' | ')
    $script:aclCalls = @(); Protect-AppDir $fakeApp -NoRecurse
    $c = Show-Calls
    Check 'M1 -NoRecurse: only the folder itself (still the exact DACL)' ($c.Count -eq 1 -and $c[0] -ceq ($fakeApp + ' EXACT-DACL')) ($c -join ' | ')
    Check 'M1 Set-ExactDacl builds a fresh protected ACL: purge every rule, then SYSTEM F, Administrators F, Users RX (SIDs), owner Administrators' (
        $src -match '(?s)function Set-ExactDacl.*?/setowner.*?/inheritance:r.*?/grant:r.*?\*S-1-5-18:\(OI\)\(CI\)F.*?\*S-1-5-32-544:\(OI\)\(CI\)F.*?\*S-1-5-32-545:\(OI\)\(CI\)RX.*?Get-Acl -LiteralPath.*?/remove:g.*?/remove:d' -and (($src -split 'function Set-ExactDacl')[1] -split 'function Protect-AppDir')[0] -notmatch 'Set-Acl' -and
        $src -match ([regex]::Escape('$AclOwnerSid = ') + "'S-1-5-32-544'"))
    Check 'M1 no entry ever gives Users more than read & execute' (-not ($src -match "S-1-5-32-545:\(OI\)\(CI\)(F|M|W|RW)"))
    function Invoke-Icacls { param([string[]]$IcaclsArgs) return @{ Code = 5; Out = 'Access is denied.' } }
    Check 'F5 a failing icacls aborts with exit 1' ((ThrowsCode { Protect-AppDir $fakeApp }) -eq 1)
    . $applySafety
    function Set-ExactDacl { param([string]$Path) throw 'Set-Acl failed' }
    Check 'M1 a failing Set-ExactDacl aborts with exit 1' ((ThrowsCode { Protect-AppDir $fakeApp -NoRecurse }) -eq 1)
    . $applySafety

    # ---- S4: links (junctions) inside are deleted, never followed; a link as the folder itself is refused
    $s4 = Join-Path $sbRoot 's4'; $decoy = Join-Path $s4 'decoy'; $s4App = Join-Path $s4 'app'
    New-Item -ItemType Directory -Path $decoy, (Join-Path $s4App 'sub\deep') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $decoy 'precious.txt'), 'keep');  [IO.File]::WriteAllText((Join-Path $s4App 'writer.exe'), 'x')
    $null = & cmd.exe /c mklink /J (Join-Path $s4App 'link1') $decoy
    $null = & cmd.exe /c mklink /J (Join-Path $s4App 'sub\deep\link2') $decoy
    Check 'S4 setup: two junctions exist inside the folder' ((Test-ReparsePoint (Join-Path $s4App 'link1')) -and (Test-ReparsePoint (Join-Path $s4App 'sub\deep\link2')))
    $script:aclCalls = @(); Protect-AppDir $s4App
    Check 'S4 both junctions are gone (also the nested one)' (-not (Test-Path -LiteralPath (Join-Path $s4App 'link1')) -and -not (Test-Path -LiteralPath (Join-Path $s4App 'sub\deep\link2')))
    Check 'S4 ... and their target was NOT touched' ((Test-Path -LiteralPath (Join-Path $decoy 'precious.txt')) -and [IO.File]::ReadAllText((Join-Path $decoy 'precious.txt')) -eq 'keep')
    Check 'S4 ... the real files stayed, and the /T operations ran afterwards' ((Test-Path (Join-Path $s4App 'writer.exe')) -and @(Show-Calls | Where-Object { $_ -match '/reset /T' }).Count -eq 1)
    $null = & cmd.exe /c mklink /J (Join-Path $s4 'applink') $decoy
    $script:aclCalls = @()
    Check 'S4 the folder itself being a junction is refused (exit 1), nothing is changed' ((ThrowsCode { Protect-AppDir (Join-Path $s4 'applink') }) -eq 1 -and $script:aclCalls.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $decoy 'precious.txt')))
    Check 'S4 the uninstall also removes links before it scans / deletes' ($src -match '(?s)if \(\$marker\.createdAppDir\) \{\s*if \(-not \$DryRun.*?Remove-ReparsePoints \$AppDir.*?Get-OwnedFileClassification \$AppDir')
    Check 'S4 Protect-AppDir removes links before the first /T operation' ($src -match '(?s)function Protect-AppDir.*?Remove-ReparsePoints \$Dir.*?/setowner.*?/reset')

    # ---- M1: the REAL Set-ExactDacl + icacls /reset on a throw-away tree (fake files under %TEMP% only; never a real path)
    $aclRoot = Join-Path $sbRoot 'acl-real'
    $realRoot = Join-Path $aclRoot 'RawAccel'
    $realApp = Join-Path $realRoot 'RawAccel'
    $realHnd = Join-Path $realRoot 'mousecal'
    $mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $randSid = 'S-1-5-21-1111111111-2222222222-3333333333-4444'
    $unsafe = [Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteAttributes, WriteExtendedAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    function Assert-InSandbox([string]$p) { if (-not $p.StartsWith($sbRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $p -match '\.\.') { throw "SAFETY: refusing to touch $p (outside $sbRoot)" } }
    function Get-TestAcl([string]$p) { Assert-InSandbox $p; return (Get-Acl -LiteralPath $p) }
    function Invoke-TestIcacls([string[]]$a) { Assert-InSandbox $a[0]; $null = & icacls.exe @a }
    $origOwnerSid = $AclOwnerSid
    try {
        foreach ($d in $realApp, (Join-Path $realApp 'sub'), $realHnd) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        foreach ($f in 'writer.exe', 'settings.json', 'sub\x.dll', 'user-added.txt') { [IO.File]::WriteAllText((Join-Path $realApp $f), 'x') }
        [IO.File]::WriteAllText((Join-Path $realHnd 'handler.vbs'), 'x'); [IO.File]::WriteAllText((Join-Path $realRoot 'apply.vbs'), 'x')
        # the worst case: root, app dir and handler dir all carry Everyone:F and a random explicit SID (and inherit them down), plus per-file extras
        foreach ($d in $realRoot, $realApp, $realHnd) {
            Invoke-TestIcacls @($d, '/inheritance:e', '/grant', '*S-1-1-0:(OI)(CI)F', '/grant', '*S-1-5-32-545:(OI)(CI)F')
            # a SID icacls cannot resolve: added through the ACL object (an orphaned / foreign-domain SID)
            Assert-InSandbox $d
            $seed = Get-Acl -LiteralPath $d
            $seed.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($randSid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
            Set-Acl -LiteralPath $d -AclObject $seed
        }
        Invoke-TestIcacls @((Join-Path $realApp 'settings.json'), '/grant', ('*' + $mySid + ':F'))
        Invoke-TestIcacls @((Join-Path $realApp 'sub\x.dll'), '/grant', '*S-1-1-0:F')
        Invoke-TestIcacls @((Join-Path $realApp 'user-added.txt'), '/deny', '*S-1-5-11:W')
        $before = Get-TestAcl (Join-Path $realApp 'settings.json')
        Check 'M1 setup of the scenario: Users, Everyone and the random SID really had write access first' (@($before.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-32-545' -and ($_.FileSystemRights -band $unsafe) }).Count -gt 0 -and @((Get-TestAcl $realRoot).Access | Where-Object { $_.IdentityReference.Value -eq 'Everyone' }).Count -gt 0 -and @((Get-TestAcl $realHnd).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -eq $randSid }).Count -gt 0)
        # not elevated: the owner of everything is the current user already (nothing to take), and /setowner would need a token we do not have
        $AclOwnerSid = $mySid
        Set-Item function:Set-ExactDacl $realSetExactDacl
        function Invoke-Icacls { param([string[]]$IcaclsArgs) Assert-InSandbox $IcaclsArgs[0].TrimEnd('*').TrimEnd('\'); $script:aclCalls += , $IcaclsArgs; if ($IcaclsArgs -contains '/setowner') { return @{ Code = 0; Out = 'skipped: needs an elevated token' } }; return (& $realInvokeIcacls -IcaclsArgs $IcaclsArgs) }
        $script:aclCalls = @()
        Assert-InSandbox $realRoot; Assert-InSandbox $realApp; Assert-InSandbox $realHnd
        Protect-AppDir $realRoot -NoRecurse
        Protect-AppDir $realApp
        Protect-AppDir $realHnd
        . $applySafety      # back to the recorders
        $AclOwnerSid = $origOwnerSid
        $okAll = $true; $why = @(); $seen = 0
        $items = @($realRoot, (Join-Path $realRoot 'apply.vbs'), $realApp, $realHnd) + @(Get-ChildItem -LiteralPath $realApp -Recurse -Force | ForEach-Object { $_.FullName }) + @(Get-ChildItem -LiteralPath $realHnd -Recurse -Force | ForEach-Object { $_.FullName })
        foreach ($p in $items) {
            $seen++
            $rules = @((Get-TestAcl $p).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            $sids = @($rules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
            $short = $p.Substring($sbRoot.Length)
            if (($sids -join ',') -ne 'S-1-5-18,S-1-5-32-544,S-1-5-32-545') { $okAll = $false; $why += "$short has SIDs [$($sids -join ',')]" }
            if (@($rules | Where-Object { $_.AccessControlType -ne 'Allow' }).Count -gt 0) { $okAll = $false; $why += "$short has a deny entry" }
            if ($rules.Count -ne 3) { $okAll = $false; $why += "$short has $($rules.Count) entries (want exactly 3)" }
            foreach ($rule in $rules) {
                $sid = $rule.IdentityReference.Value
                if ($sid -eq 'S-1-5-32-545' -and (($rule.FileSystemRights -band $unsafe) -or ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne [Security.AccessControl.FileSystemRights]::ReadAndExecute)) { $okAll = $false; $why += "$short Users has $($rule.FileSystemRights)" }
                elseif ($sid -ne 'S-1-5-32-545' -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) { $okAll = $false; $why += "$short $sid is not full control" }
            }
        }
        Check "M1 real ACLs: root, app dir, handler dir and all $seen items below end with EXACTLY SYSTEM F, Administrators F, Users RX (no Everyone, no random SID, no deny, no extra)" ($okAll -and $seen -ge 10) ($why -join '; ')
        Check 'M1 real ACLs: root, app dir and handler dir no longer inherit' ((Get-TestAcl $realRoot).AreAccessRulesProtected -and (Get-TestAcl $realApp).AreAccessRulesProtected -and (Get-TestAcl $realHnd).AreAccessRulesProtected)
        Check 'M1 real ACLs: the children inherit (nothing explicit left)' (-not (Get-TestAcl (Join-Path $realApp 'settings.json')).AreAccessRulesProtected -and @((Get-TestAcl (Join-Path $realApp 'settings.json')).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])).Count -eq 0)
    } finally {
        . $applySafety
        $AclOwnerSid = $origOwnerSid
        if ($aclRoot.StartsWith($sbRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $null = & icacls.exe $aclRoot '/grant:r' ('*' + $mySid + ':(OI)(CI)F') '/T' '/C'   # throw-away folder: give the cleanup access back
            Remove-Item -LiteralPath $aclRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Check 'M1 real ACL test folder cleaned up' (-not (Test-Path -LiteralPath $aclRoot))

    # ---- F1: one real run at a time (named mutex; TEST_MOCK name so the real one is never involved)
    $mxName = 'Global\TEST_MOCK_mousecal-' + [guid]::NewGuid().ToString('N')
    function Start-Holder([string]$name) {
        $ready = New-Object Threading.ManualResetEvent $false
        $release = New-Object Threading.ManualResetEvent $false
        $ps = [powershell]::Create()
        [void]$ps.AddScript({ param($sp, $n, $ready, $release) $env:MOUSECAL_NO_MAIN = '1'; . $sp; $m = Enter-SetupLock $n; [void]$ready.Set(); if ($m) { [void]$release.WaitOne(30000); Exit-SetupLock $m; 'held' } else { 'busy' } }).AddArgument($setupPath).AddArgument($name).AddArgument($ready).AddArgument($release)
        $h = $ps.BeginInvoke()
        [void]$ready.WaitOne(30000)
        return @{ PS = $ps; Handle = $h; Release = $release }
    }
    function Stop-Holder($h) { [void]$h.Release.Set(); $o = @($h.PS.EndInvoke($h.Handle)); $h.PS.Dispose(); return [string]$o[0] }
    Check 'F1 the real name is Global\mousecal-setup' ($SetupMutexName -ceq 'Global\mousecal-setup')
    $m1 = Enter-SetupLock $mxName
    Check 'F1 a free lock is taken' ($null -ne $m1)
    $h = Start-Holder $mxName
    $res = Stop-Holder $h
    Check 'F1 a second run (other thread) cannot take it' ($res -eq 'busy') $res
    Exit-SetupLock $m1
    $h = Start-Holder $mxName
    $res = Stop-Holder $h
    Check 'F1 after release the next run can' ($res -eq 'held') $res
    # Invoke-MainCore: held -> bilingual message, exit 1, nothing run; free -> runs; dry run ignores the lock
    $SetupMutexName = $mxName
    function Test-IsAdmin { return $true }
    function Get-RunningAntiCheatGames { return @() }
    function Get-RunningVanguard { return @() }
    $script:installRan = 0
    function Invoke-Install { param($a) $script:installRan++; return 0 }
    $Rotation = '1'
    $h = Start-Holder $mxName
    $all = @(Invoke-MainCore 6>&1)
    $rc = @($all | Where-Object { $_ -is [int] }); $txt = ($all | Where-Object { $_ -isnot [int] } | Out-String)
    Check 'F1 locked -> exit 1, the install did not run' ($rc.Count -eq 1 -and $rc[0] -eq 1 -and $script:installRan -eq 0) ("rc=$rc ran=$($script:installRan)")
    Check 'F1 locked -> bilingual "another mousecal setup is running"' ($txt -match 'Another mousecal setup is running' -and $txt -match '[^\x00-\x7F]')
    $DryRun = [switch]$true
    $all = @(Invoke-MainCore 6>&1)
    $DryRun = [switch]$false
    Check 'F1 -DryRun does not take or need the lock' ($script:installRan -eq 1)
    $null = Stop-Holder $h
    $all = @(Invoke-MainCore 6>&1)
    $rc = @($all | Where-Object { $_ -is [int] })
    Check 'F1 lock free -> the run happens' ($rc[0] -eq 0 -and $script:installRan -eq 2)
    $h = Start-Holder $mxName
    $res = Stop-Holder $h
    Check 'F1 ... and the run released the lock afterwards' ($res -eq 'held') $res
    Check 'F1 the lock is taken only for real runs and released in finally' ($src -match '(?s)if \(-not \$DryRun\) \{\s*\$script:SetupLock = Enter-SetupLock' -and $src -match '(?s)finally \{.*?Exit-SetupLock \$script:SetupLock')
    $Rotation = ''
    . $setupPath; . $applySafety
    $ZipFilesText = $rows -join "`n"; $ZipSha256 = Get-BytesSha256 $fakeZip

    # ---- F1/L1: per-run staging folder (root locked + owned first, .staging owned before it is ACL'd)
    $script:InstallRoot = Join-Path $sbRoot 'stg\RawAccel'; $script:Tx = $null
    $script:aclCalls = @(); $script:stagingAtRootLock = $null
    function Set-ExactDacl { param([string]$Path) $script:aclCalls += , @($Path, 'EXACT-DACL'); if ($null -eq $script:stagingAtRootLock) { $script:stagingAtRootLock = Test-Path -LiteralPath (Join-Path $script:InstallRoot '.staging') } }
    $sa = New-StageDir
    $c = Show-Calls
    Check 'L1 the root is locked (exact DACL) before .staging exists' ($c[0] -ceq ($script:InstallRoot + ' EXACT-DACL') -and $script:stagingAtRootLock -eq $false) ($c -join ' | ')
    Check 'N1 .staging and the run folder each get the exact DACL (no icacls /grant:r), after the root' ($c.Count -eq 3 -and $c[1] -ceq ((Split-Path -Parent $sa) + ' EXACT-DACL') -and $c[2] -ceq ($sa + ' EXACT-DACL') -and -not (($c -join ' ') -match '/grant')) ($c -join ' | ')
    Check 'N1 New-StageDir clears stale staging only after the root and .staging are locked, and refuses a .staging link' ($src -match '(?s)function New-StageDir \{.*?Protect-AppDir \$InstallRoot -NoRecurse.*?Test-ReparsePoint \$stg.*?Set-ExactDacl \$stg.*?Clear-StaleStaging.*?Set-ExactDacl \$p' -and $script:staleCalls -ge 1)
    Check 'N1 the stage functions use no /grant:r' (-not ((($src -split 'function New-StageDir')[1] -split 'function Save-Download')[0] -match '/grant:r'))
    $sb2 = New-StageDir
    Check 'F1 two runs get two different .staging\<guid> folders' ($sa -ne $sb2 -and (Test-Path $sa) -and (Test-Path $sb2) -and (Split-Path -Leaf (Split-Path -Parent $sa)) -eq '.staging' -and (Split-Path -Leaf $sa) -match '^[0-9a-f]{32}$')
    . $applySafety
    $script:StageDir = $sa; Remove-StageDir
    Check 'F1 cleanup removes only its own folder' (-not (Test-Path $sa) -and (Test-Path $sb2) -and (Test-Path (Split-Path -Parent $sb2)))
    $script:StageDir = $sb2; Remove-StageDir
    Check 'F1 ... and the empty .staging parent at the end' (-not (Test-Path (Split-Path -Parent $sb2)))
    $script:StageDir = $null
    $script:aclCalls = @()
    # L3: stale staging folders of crashed runs are deleted (links inside are not followed)
    Set-Item function:Clear-StaleStaging $realClearStale
    if (-not $script:InstallRoot.StartsWith($sbRoot + '', [StringComparison]::OrdinalIgnoreCase)) { throw 'SAFETY: InstallRoot is not the sandbox' }
    $stg = Join-Path $script:InstallRoot '.staging'; $decoy3 = Join-Path $sbRoot 'stg-decoy'
    New-Item -ItemType Directory -Path $decoy3, (Join-Path $stg 'aaaa\inner'), (Join-Path $stg 'bbbb') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $decoy3 'precious.txt'), 'keep'); [IO.File]::WriteAllText((Join-Path $stg 'aaaa\inner\x.bin'), 'x'); [IO.File]::WriteAllText((Join-Path $stg 'loose.txt'), 'x')
    $null = & cmd.exe /c mklink /J (Join-Path $stg 'bbbb\lnk') $decoy3
    Clear-StaleStaging
    Check 'L3 every stale .staging\* entry is deleted, whatever is inside' ((Test-Path -LiteralPath $stg) -and -not @([IO.Directory]::GetFileSystemEntries($stg)).Count) ((Get-ChildItem -LiteralPath $stg -Force -ErrorAction SilentlyContinue | ForEach-Object Name) -join ',')
    Check 'L3 a junction inside a stale folder was not followed' ((Test-Path -LiteralPath (Join-Path $decoy3 'precious.txt')) -and [IO.File]::ReadAllText((Join-Path $decoy3 'precious.txt')) -eq 'keep')
    Clear-StaleStaging
    Check 'L3 nothing to clean is fine' (-not (Throws { Clear-StaleStaging }))
    # N1: a .staging that is itself a junction is refused (exit 1) and nothing behind it is touched
    Remove-Item -LiteralPath $stg -Force -Recurse
    New-Item -ItemType Directory -Path (Join-Path $decoy3 'victim') -Force | Out-Null
    $null = & cmd.exe /c mklink /J $stg $decoy3
    $script:aclCalls = @(); $script:Tx = $null
    $thrown = $null; try { [void](New-StageDir) } catch { $thrown = $_ }
    Check 'N1 New-StageDir refuses a .staging junction (exit 1), changes no ACL on it and deletes nothing behind it' ($thrown -and $thrown.Exception.Data['ExitCode'] -eq 1 -and (Test-Path -LiteralPath (Join-Path $decoy3 'victim')) -and -not (($script:aclCalls | ForEach-Object { $_ -join ' ' }) -match '\.staging')) "$thrown"
    $thrown = $null; try { Clear-StaleStaging } catch { $thrown = $_ }
    Check 'N1 Clear-StaleStaging refuses a .staging junction too' ($thrown -and (Test-Path -LiteralPath (Join-Path $decoy3 'precious.txt')) -and (Test-Path -LiteralPath (Join-Path $decoy3 'victim')))
    [IO.Directory]::Delete($stg, $false)
    Check 'N1 ... removing the junction left its target alone' ((Test-Path -LiteralPath (Join-Path $decoy3 'precious.txt')) -and -not (Test-Path -LiteralPath $stg))
    # S-a: Remove-StageDir removes links inside the run folder without following them
    $rs = Join-Path $stg 'cccc'; New-Item -ItemType Directory -Path (Join-Path $rs 'sub') -Force | Out-Null
    $null = & cmd.exe /c mklink /J (Join-Path $rs 'sub\lnk') $decoy3
    $script:StageDir = $rs; Remove-StageDir; $script:StageDir = $null
    Check 'S-a Remove-StageDir deletes a junction inside without following it, then the folder and the empty .staging' (-not (Test-Path -LiteralPath $rs) -and -not (Test-Path -LiteralPath $stg) -and (Test-Path -LiteralPath (Join-Path $decoy3 'precious.txt')))
    Check 'S-a the only recursive file delete left is inside Remove-TreeSafe (links removed first)' (([regex]::Matches($src, 'Remove-Item -LiteralPath \$(?!Key)[^\r\n]*-Recurse')).Count -eq 1)
    . $applySafety
    Check 'N1 main no longer calls Clear-StaleStaging itself (New-StageDir does, after the lock; never for -DryRun)' (-not (($src -split 'function Invoke-Main')[1] -match 'Clear-StaleStaging') -and $src -match '(?s)function New-StageDir \{.*?if \(\$DryRun\) \{ New-Item[^\n]*return \$p \}')

    # ---- F4 / F7 / hidden elevation: handler.ps1 and handler.vbs
    $hd = Join-Path $sbRoot 'hnd'; New-Item -ItemType Directory -Path $hd | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $hd 'handler.ps1'), (ConvertTo-HandlerBytes $HandlerPs1Text $true))
    [IO.File]::WriteAllText((Join-Path $hd 'setup.ps1'), '# dummy')
    Check 'F4 handler log is per user (LOCALAPPDATA), not ProgramData' ($HandlerPs1Text -match 'env:LOCALAPPDATA' -and $HandlerPs1Text -notmatch 'ProgramData')
    & {
        $laBefore = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $sbRoot 'localappdata'
        try {
            . (Join-Path $hd 'handler.ps1')
            Check 'F4 $McLog = %LOCALAPPDATA%\mousecal\handler.log' ($McLog -ceq (Join-Path $env:LOCALAPPDATA 'mousecal\handler.log'))
            Write-HandlerLog 'probe'
            Check 'F4 the log is written there' ((Test-Path $McLog) -and ([IO.File]::ReadAllText($McLog) -match 'probe'))
            function Start-Process { param($FilePath, $ArgumentList, $Verb, $WindowStyle, [switch]$Wait, [switch]$PassThru) $script:spArgs = @{ File = $FilePath; Args = $ArgumentList; Verb = $Verb; Style = $WindowStyle }; return [pscustomobject]@{ ExitCode = 0 } }
            $script:spArgs = $null
            $rc = Invoke-Elevated (Join-Path $McDir 'setup.ps1') @('-Rotation', '1', '-NoPause')
            Check 'F2 the elevated Start-Process is RunAs and -WindowStyle Hidden' ($rc -eq 0 -and $script:spArgs.Verb -eq 'RunAs' -and $script:spArgs.Style -eq 'Hidden' -and $script:spArgs.Args -match '-File ".*setup\.ps1" -Rotation 1 -NoPause') ($script:spArgs | Out-String)
            $fr = Join-Path $sbRoot 'fakewin'; New-Item -ItemType Directory -Path (Join-Path $fr 'Sysnative\WindowsPowerShell\v1.0') -Force | Out-Null
            Check 'F7 64-bit host -> System32 powershell' ((Get-HandlerPowerShell $true $fr) -ceq (Join-Path $fr 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            Check '... 32-bit host without Sysnative -> System32' ((Get-HandlerPowerShell $false $fr) -ceq (Join-Path $fr 'System32\WindowsPowerShell\v1.0\powershell.exe'))
            [IO.File]::WriteAllText((Join-Path $fr 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'), 'x')
            Check 'F7 32-bit host with Sysnative -> Sysnative powershell' ((Get-HandlerPowerShell $false $fr) -ceq (Join-Path $fr 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'))
            Check 'F7 Invoke-Elevated uses Get-HandlerPowerShell' ($HandlerPs1Text -match 'Get-HandlerPowerShell' -and $script:spArgs.File -match 'System32')
        } finally { $env:LOCALAPPDATA = $laBefore }
    }
    # handler.vbs: 64-bit and 32-bit cscript (printing instead of running)
    $vt = $HandlerVbsText.Replace('sh.Run cmd, 0, False', 'WScript.StdOut.WriteLine cmd')
    $vp = Join-Path $hd 'handler-r3.vbs'; [IO.File]::WriteAllText($vp, $vt, [Text.Encoding]::ASCII)
    function Run-Cscript([string]$exe) {
        $psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = $exe; $psi.Arguments = '//Nologo "' + $vp + '" "mousecal://uninstall"'
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEnd(); $p.WaitForExit(); return $o.Trim()
    }
    Check 'F7 vbs text: tries Sysnative first, falls back to System32' ($HandlerVbsText -match 'Sysnative' -and $HandlerVbsText -match 'FileExists' -and $HandlerVbsText -match 'System32\\WindowsPowerShell')
    $o64 = Run-Cscript (Join-Path $env:SystemRoot 'System32\cscript.exe')
    Check 'F7 64-bit wscript -> System32 powershell' ($o64 -match '^"[^"]*\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile') $o64
    $c32 = Join-Path $env:SystemRoot 'SysWOW64\cscript.exe'
    if (Test-Path $c32) {
        $o32 = Run-Cscript $c32
        Check 'F7 32-bit wscript -> Sysnative (64-bit) powershell' ($o32 -match '^"[^"]*\\Sysnative\\WindowsPowerShell\\v1\.0\\powershell\.exe" -NoProfile') $o32
    }

    # ---- coordinator P1: rollback restores a pre-existing protocol key exactly
    $snapKey = $testKey + '-snap'
    Remove-Item -LiteralPath $snapKey -Recurse -Force -ErrorAction SilentlyContinue
    Check 'P1 snapshot of a missing key is $null; restoring $null removes a key' ($null -eq (Get-UrlProtocolSnapshot $snapKey))
    New-Item -Path ($snapKey + '\shell\open\command') -Force | Out-Null
    Set-Item -LiteralPath $snapKey -Value 'URL:old'; New-ItemProperty -LiteralPath $snapKey -Name 'URL Protocol' -Value 'x' -PropertyType String -Force | Out-Null
    Set-Item -LiteralPath ($snapKey + '\shell\open\command') -Value '"C:\old\wscript.exe" "C:\old\handler.vbs" "%1"'
    $sn = Get-UrlProtocolSnapshot $snapKey
    Set-Item -LiteralPath $snapKey -Value 'changed'; Remove-ItemProperty -LiteralPath $snapKey -Name 'URL Protocol'
    Set-Item -LiteralPath ($snapKey + '\shell\open\command') -Value 'changed'
    Restore-UrlProtocolSnapshot $sn $snapKey
    $k = Get-Item -LiteralPath $snapKey; $kc = Get-Item -LiteralPath ($snapKey + '\shell\open\command')
    Check 'P1 snapshot/restore round trip: default, URL Protocol, command' ($k.GetValue('') -ceq 'URL:old' -and $k.GetValue('URL Protocol') -ceq 'x' -and $kc.GetValue('') -ceq '"C:\old\wscript.exe" "C:\old\handler.vbs" "%1"')
    Restore-UrlProtocolSnapshot $null $snapKey
    Check 'P1 restoring $null removes the key' (-not (Test-Path -LiteralPath $snapKey))

    # ---- flows with the full stub set
    $r3Stubs = {
        function Get-RawAccelZipBytes { return , $fakeZip }
        function New-StageDir { $p = Join-Path (Join-Path $script:InstallRoot '.staging') 'run'; New-Item -ItemType Directory $p -Force | Out-Null; return $p }
        function Test-DriverActive { param($a, $b) $script:DriverProbeFailed = $false; $script:daCalls++; if ($script:daSeq.Count -ge $script:daCalls) { return [bool]$script:daSeq[$script:daCalls - 1] }; return $true }
        function Get-ActiveRotation { param($a, $b) if ($script:rotMixed) { Fail 'mixed' 'mixed' @() 3 }; return 8.0 }
        function Test-RawAccelFilter { return $true }
        function Install-RawAccelDriver { param($d) return $false }
        function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{ TaskName = 'x'; Actions = @([pscustomobject]@{ Execute = (Join-Path $AppDir 'writer.exe'); Arguments = '' }) } }
        function Register-ApplyTask { param($s) $script:calls.Register++ }
        function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $script:calls.Unregister++ }
        function Register-ScheduledTask { }
        function Export-ScheduledTask { param($TaskName) return '<task/>' }
        function Restart-MouseDevices { param([switch]$All) $script:restarted = $true; return 1 }
        function Get-MouseDeviceStatus { if ($script:restarted) { if ($script:miceAfterSeq.Count -gt 0) { $h = $script:miceAfterSeq[[math]::Min($script:miceIdx, $script:miceAfterSeq.Count - 1)]; $script:miceIdx++; return $h }; return $script:miceAfter }; return $script:miceBefore }
        function Get-RunningAntiCheatGames { return @() }
        function Start-Process { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$Wait, [switch]$PassThru) return (New-FakeProc $script:writerExit) }
        function Get-AuthenticodeSignature { param($LiteralPath) return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=fake, O=Microsoft Corporation' } } }
        function Test-SettingsJson { param($d, $j, $w) }
        function Invoke-DriverTool { param($Exe, $Mode, $TimeoutSec) $script:calls.Tool++; return @{ Ok = $script:toolOk; Output = 'stub' } }
        function Invoke-Icacls { param([string[]]$IcaclsArgs) $script:aclCalls += , $IcaclsArgs; $script:aclState += , @{ Writer = (Test-Path (Join-Path $script:AppDir 'writer.exe')); Settings = (Test-Path $script:SettingsPath) }; return @{ Code = 0; Out = '' } }
        function Set-ExactDacl { param([string]$Path) $script:aclCalls += , @($Path, 'EXACT-DACL'); $script:aclState += , @{ Writer = (Test-Path (Join-Path $script:AppDir 'writer.exe')); Settings = (Test-Path $script:SettingsPath) } }
    }
    . $r3Stubs
    function New-Sandbox3 { New-Sandbox; $script:daSeq = @(); $script:daCalls = 0; $script:rotMixed = $false; $script:restarted = $false; $script:miceBefore = @{}; $script:miceAfter = @{}; $script:aclCalls = @(); $script:aclState = @(); $script:rpt = 0; $script:miceAfterSeq = @(); $script:miceIdx = 0 }
    $script:daSeq = @(); $script:daCalls = 0; $script:rotMixed = $false; $script:restarted = $false; $script:miceBefore = @{}; $script:miceAfter = @{}; $script:aclState = @()

    # F5 in the install flow: locked before the first copy, again after settings.json
    New-Sandbox3
    $r = Run-Install $mm
    Check 'F5 flow: the install succeeds with the stubs' (-not $r.Threw) $r.Out
    $c = Show-Calls
    Check 'F5 flow: the install root is locked non-recursively (exact DACL, no /T)' ($c[0] -ceq ($script:InstallRoot + ' EXACT-DACL') -and @($c | Where-Object { $_ -match ([regex]::Escape($script:InstallRoot + ' ') + '/') }).Count -eq 0) ($c -join ' | ')
    $iApp = @(0..($script:aclCalls.Count - 1) | Where-Object { $script:aclCalls[$_][0] -eq $script:AppDir -and $script:aclCalls[$_] -contains 'EXACT-DACL' })
    Check 'F5 flow: the app dir is locked twice (before the copy, after settings.json)' ($iApp.Count -eq 2) ($c -join ' | ')
    Check 'F5 flow: first lock happens before writer.exe exists' ($script:aclState[$iApp[0]].Writer -eq $false)
    Check 'F5 flow: second lock happens after settings.json was written' ($script:aclState[$iApp[1]].Settings -eq $true)
    Check 'F5 flow: the second lock also resets the files that exist by then (/reset /T)' (@($c | Where-Object { $_ -ceq ((Join-Path $script:AppDir '*') + ' /reset /T /C') }).Count -ge 1)
    Check 'F5 flow: Users never get more than read & execute' (-not (($c -join ' ') -match 'S-1-5-32-545:\(OI\)\(CI\)(F|M|W|RW)'))
    Check 'F5 flow: the handler folder lock is also recursive (via Protect-AppDir)' ($src -match 'function Protect-HandlerDir\(\[string\]\$Dir\) \{ Protect-AppDir \$Dir \}')
    Check 'F5 flow: dry run lists the lock' ($src -match "Dry 'Lock \{0\} \(non-recursive\)")

    # F3 in the install flow
    New-Sandbox3; Seed-Prior $oldMarker; $script:rotMixed = $true
    $r = Run-Install $mm
    Check 'F3 flow: -Measured with differing profile rotations -> exit 3' ($r.Threw -and $r.Code -eq 3) "$($r.Code) $($r.Out)"
    Check 'F3 flow: nothing was changed (no ACL change, files, task, marker)' ($script:aclCalls.Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $script:AppDir 'writer.exe')) -eq 'OLD-WRITER' -and [IO.File]::ReadAllText($script:MarkerPath) -eq $oldMarker -and $script:calls.Register -eq 0)
    $DryRun = [switch]$true
    $r = Run-Install $mm
    $DryRun = [switch]$false
    Check 'F3 flow: -DryRun -Measured refuses too' ($r.Threw -and $r.Code -eq 3) "$($r.Code)"
    $r = Run-Install @{ Kind = 'Rotation'; Value = 3.0 }
    Check 'F3 flow: -Rotation (absolute) is still allowed' ((-not $r.Threw) -and [IO.File]::ReadAllText($script:SettingsPath) -match '"Degrees of rotation": 3.0,') $r.Out

    # F6 in the install flow
    $script:MouseSettleSeconds = 0
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK'; 'HID\B' = 'Error' }; $script:miceAfter = @{ 'HID\A' = 'Error'; 'HID\B' = 'Error' }
    $r = Run-Install $mm
    Check 'F6 flow: a mouse that was OK and is not, with the driver "Running" -> exit 8' ($r.Threw -and $r.Code -eq 8 -and $r.Out -match 'HID\\A') "$($r.Code) $($r.Out)"
    Check 'F6 flow: ... and everything is rolled back' (-not (Test-Path $script:SettingsPath) -and -not (Test-Path $script:MarkerPath) -and $script:calls.Register -eq 0)
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK'; 'HID\B' = 'Error' }; $script:miceAfter = @{ 'HID\A' = 'OK'; 'HID\B' = 'Error' }
    $r = Run-Install $mm
    Check 'F6 flow: a mouse that was already broken is ignored' (-not $r.Threw) "$($r.Code) $($r.Out)"
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfter = @{ 'HID\C' = 'OK' }; $script:MouseMissingSeconds = 0
    $r = Run-Install $mm
    Check 'S6 flow: a mouse that was OK and is missing after the restart (and stays missing) -> regression, exit 8, rolled back' ($r.Threw -and $r.Code -eq 8 -and $r.Out -match 'HID\\A' -and -not (Test-Path $script:MarkerPath)) "$($r.Code) $($r.Out)"
    # ... but one that reappears within the settle time is fine (devices re-enumerate after a restart)
    function Start-Sleep { param($Seconds, $Milliseconds) }
    $script:MouseSettleSeconds = 10; $script:MouseMissingSeconds = 30; $script:miceIdx = 0
    $oth = @{ 'HID\C' = 'OK' }
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = @($oth, $oth, $oth, @{ 'HID\A' = 'OK' })
    $r = Run-Install $mm
    Check 'S6 flow: a mouse missing at first but back within the settle time -> no regression' (-not $r.Threw -and $script:miceIdx -ge 4) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    # N2: a missing (not Error) mouse gets 30 s, longer than the 10 s of an Error one
    $script:miceIdx = 0
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = @((1..24 | ForEach-Object { $oth }) + @(@{ 'HID\A' = 'OK' }))
    $r = Run-Install $mm
    Check 'N2 flow: a mouse missing for ~24 s and then back -> no regression' (-not $r.Threw -and $script:miceIdx -ge 25) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    $script:miceIdx = 0
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = @($oth)
    $r = Run-Install $mm
    Check 'N2 flow: a mouse that stays missing for the whole 30 s -> exit 8 (after ~30 checks)' ($r.Threw -and $r.Code -eq 8 -and $script:miceIdx -ge 30 -and $script:miceIdx -le 33) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    $script:miceIdx = 0
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = @(@{ 'HID\A' = 'Error' })
    $r = Run-Install $mm
    Check 'N2 flow: an Error mouse keeps the 10 s limit -> exit 8 after ~10 checks' ($r.Threw -and $r.Code -eq 8 -and $script:miceIdx -ge 10 -and $script:miceIdx -le 13) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    $script:miceIdx = 0
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = @(@{})
    $r = Run-Install $mm
    Check 'R6-1 flow: a post-restart device list that stays EMPTY (one-mouse PC, mouse gone) -> exit 8 after ~30 checks, rolled back' ($r.Threw -and $r.Code -eq 8 -and $script:miceIdx -ge 30 -and -not (Test-Path $script:MarkerPath)) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    $script:miceIdx = 0
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = @(@{}, @{}, @{}, @{ 'HID\A' = 'OK' })
    $r = Run-Install $mm
    Check 'R6-1 flow: an empty list for a few seconds, then the mouse is back -> no regression' (-not $r.Threw -and $script:miceIdx -ge 4) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    $script:miceIdx = 0
    $late = @((1..15 | ForEach-Object { @{} }) + @(@{ 'HID\A' = 'Error' }, @{ 'HID\A' = 'Error' }, @{ 'HID\A' = 'OK' }))
    New-Sandbox3; $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfterSeq = $late
    $r = Run-Install $mm
    Check 'R6-3 flow: a mouse that reappears after 15 s in a brief Error state gets its own settle window -> no regression' (-not $r.Threw -and $script:miceIdx -ge 18) "$($r.Code) $($r.Out) idx=$($script:miceIdx)"
    $script:miceAfterSeq = @(); $script:miceIdx = 0
    Remove-Item function:Start-Sleep
    $script:MouseSettleSeconds = 0

    # F2: the marker says installedDriver=true BEFORE installer.exe runs
    Set-Item function:Install-RawAccelDriver $realInstallDriver
    function Test-RawAccelFilter { return $false }
    function Assert-PinnedFile { param($Path, $Rel) }
    $script:markerSeen = $null
    function Invoke-DriverTool { param($Exe, $Mode, $TimeoutSec) $script:markerSeen = [IO.File]::ReadAllText($script:MarkerPath); return @{ Ok = $script:toolOk; Output = 'stub' } }
    New-Sandbox3; $script:Tx = New-Tx
    $ran = Install-RawAccelDriver (Join-Path $sbRoot 'stage')
    $mk = $script:markerSeen | ConvertFrom-Json
    Check 'F2 installer.exe starts only after the marker holds installedDriver=true' ($ran -eq $true -and $mk.installedDriver -eq $true -and $mk.tool -eq 'mousecal') $script:markerSeen
    $script:markerSeen = $null; $script:toolOk = $false; $script:Tx = New-Tx
    $c = ThrowsCode { Install-RawAccelDriver (Join-Path $sbRoot 'stage') }
    Check 'F2 a failing installer: exit 8, marker already says installedDriver (rollback undoes it)' ($c -eq 8 -and ([IO.File]::ReadAllText($script:MarkerPath) | ConvertFrom-Json).installedDriver -eq $true -and $script:Tx.DriverInstalled -eq $true)
    $script:toolOk = $true; $script:Tx = $null
    Check 'F2 structure: Write-Marker comes before Invoke-DriverTool in Install-RawAccelDriver' ($src -match '(?s)function Install-RawAccelDriver.*?DriverInstalled = \$true.*?Write-Marker \$script:Tx.*?Invoke-DriverTool \$exe')
    . $r3Stubs   # full stub set again (Install-RawAccelDriver etc.)
    function Invoke-DriverTool { param($Exe, $Mode, $TimeoutSec) $script:calls.Tool++; return @{ Ok = $script:toolOk; Output = 'stub' } }

    # P1: a failed re-run restores a pre-existing protocol key exactly; a fresh failed install removes it
    function Hd { return (Join-Path $script:InstallRoot 'mousecal') }
    Remove-TestKey
    $oldCmd = '"C:\old\wscript.exe" "C:\old\handler.vbs" "%1"'
    New-Item -Path ($testKey + '\shell\open\command') -Force | Out-Null
    Set-Item -LiteralPath $testKey -Value 'URL:old protocol'
    New-ItemProperty -LiteralPath $testKey -Name 'URL Protocol' -Value 'old-marker' -PropertyType String -Force | Out-Null
    Set-Item -LiteralPath ($testKey + '\shell\open\command') -Value $oldCmd
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 1
    $r = Run-Install $mm
    $k = Get-Item -LiteralPath $testKey; $kc = Get-Item -LiteralPath ($testKey + '\shell\open\command')
    Check 'P1 failed re-run: default value restored exactly' ($r.Threw -and $k.GetValue('') -ceq 'URL:old protocol') $r.Out
    Check 'P1 failed re-run: "URL Protocol" restored exactly' ($k.GetValue('URL Protocol') -ceq 'old-marker')
    Check 'P1 failed re-run: shell\open\command restored exactly' ($kc.GetValue('') -ceq $oldCmd) ($kc.GetValue(''))
    Remove-TestKey
    New-Item -Path $testKey -Force | Out-Null; Set-Item -LiteralPath $testKey -Value 'URL:only default'
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 1
    $r = Run-Install $mm
    $k = Get-Item -LiteralPath $testKey
    Check 'P1 failed re-run over a bare key: values the run added are removed again' ($r.Threw -and $k.GetValue('') -ceq 'URL:only default' -and ($k.GetValueNames() -notcontains 'URL Protocol') -and -not (Test-Path -LiteralPath ($testKey + '\shell')))
    Remove-TestKey
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 1
    $r = Run-Install $mm
    Check 'P1 fresh failed install still removes the key' ($r.Threw -and -not (Test-Path -LiteralPath $testKey))
    New-Item -Path ($testKey + '\shell\open\command') -Force | Out-Null; Set-Item -LiteralPath ($testKey + '\shell\open\command') -Value $oldCmd
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 0
    $r = Run-Install $mm
    Check 'P1 a successful re-run over it does replace the command (sanity)' ((-not $r.Threw) -and (Get-Item -LiteralPath ($testKey + '\shell\open\command')).GetValue('') -ceq (Get-ProtocolCommand (Hd)))
    Remove-TestKey
    # ---- L2: rollback restarts the mice whenever this run restarted them (also when the filter pre-existed)
    $script:restartLog = @()
    function Restart-MouseDevices { param([switch]$All) $script:restarted = $true; $script:restartLog += , [bool]$All; return 1 }
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 1
    $script:daSeq = @($false, $false, $true); $script:miceBefore = @{ 'HID\A' = 'OK' }; $script:miceAfter = @{ 'HID\A' = 'OK' }
    $r = Run-Install $mm
    Check 'L2 the filter pre-existed, this run restarted the mice, writer.exe failed -> rolled back' ($r.Threw -and $r.Code -eq 1 -and $script:calls.Tool -eq 0) "$($r.Code) $($r.Out)"
    Check 'L2 ... and the mice were restarted again by the rollback (-All): 2 restarts, the last with -All' ($script:restartLog.Count -eq 2 -and $script:restartLog[0] -eq $false -and $script:restartLog[1] -eq $true) ($script:restartLog -join ',')
    $script:restartLog = @()
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 1     # driver already active: no restart in this run -> none in the rollback
    $r = Run-Install $mm
    Check 'L2 no restart in this run -> the rollback does not restart either' ($r.Threw -and $script:restartLog.Count -eq 0) ($script:restartLog -join ',')
    Check 'L2 structure: New-Tx has DevicesRestarted, set before Restart-MouseDevices in the install' ($src -match 'DevicesRestarted = \$false' -and $src -match '(?s)DevicesRestarted = \$true.*?\[void\]\(Restart-MouseDevices\)')
    . $r3Stubs
    function Invoke-DriverTool { param($Exe, $Mode, $TimeoutSec) $script:calls.Tool++; return @{ Ok = $script:toolOk; Output = 'stub' } }

    # ---- S1: writer.exe waits at most 30 s, then it is killed and the run fails (rollback)
    $script:writerHang = $true; $script:waitedMs = $null; $script:killed = 0
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 0
    $r = Run-Install $mm
    Check 'S1 a writer.exe that never finishes: waited 30000 ms, killed, run fails with exit 1' ($r.Threw -and $r.Code -eq 1 -and $script:waitedMs -eq 30000 -and $script:killed -ge 1 -and $r.Out -match '30') "$($r.Code) $($script:waitedMs) $($script:killed) $($r.Out)"
    Check 'S1 ... and it is rolled back (the registered protocol key and the task are undone)' ($script:calls.Unregister -ge 1 -and -not (Test-Path -LiteralPath $testKey))
    $script:writerHang = $false; $script:killed = 0
    New-Sandbox3; Seed-Prior $oldMarker; $script:writerExit = 0
    $r = Run-Install $mm
    Check 'S1 a writer.exe that finishes in time: no kill, success' (-not $r.Threw -and $script:killed -eq 0) "$($r.Code) $($r.Out)"
    Remove-TestKey
    Check 'S1 every other child we wait on is bounded: VC++ redist 10 min, validator / rotation reader are local helpers run with the call operator, pnputil 30 s' ($src -match 'Wait-ChildProcess \$p 600' -and $src -match '& \$ps51 @a' -and $src -match 'pnputil\.exe.*?\$WriterTimeoutSec' -and (($src -split 'function Invoke-Install\(')[1] -notmatch '-Wait') -and $src -match '\$WriterTimeoutSec = 30')
    Check 'H1 setup.ps1 starts no process through .NET (only Start-Process / the call operator)' (-not ($src -match '(?i)Diagnostics\.Process\]::Start|ProcessStartInfo|ShellExecute'))
    $mockSP = Get-Command Start-Process -CommandType Function -ErrorAction SilentlyContinue
    if ($mockSP) { $mockSPBody = $mockSP.ScriptBlock; Remove-Item function:Start-Process }
    $t0 = Get-Date
    $bp = Invoke-BoundedProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') 2 $sbRoot
    $el = ((Get-Date) - $t0).TotalSeconds
    Check 'S1 Invoke-BoundedProcess kills a hanging child after the limit' ($bp.TimedOut -and $bp.Code -eq 124 -and $el -lt 15) "el=$el"
    $bp = Invoke-BoundedProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-Command', 'Write-Output hello; exit 3') 60 $sbRoot
    Check 'S1 Invoke-BoundedProcess returns exit code and output of a child that finishes' (-not $bp.TimedOut -and $bp.Code -eq 3 -and $bp.Out -eq 'hello') "$($bp.Code) [$($bp.Out)]"

    $argProbe = Join-Path $sbRoot 'argprobe.ps1'; [IO.File]::WriteAllText($argProbe, 'Write-Output $args[0]; Write-Output $args[1]')
    $bp = Invoke-BoundedProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-File', $argProbe, 'C:\some dir\', 'a "q" b') 60 $sbRoot
    Check 'S1 Invoke-BoundedProcess passes arguments with spaces, quotes and a trailing backslash intact' (($bp.Out -split "`r?`n")[0] -ceq 'C:\some dir\' -and ($bp.Out -split "`r?`n")[1] -ceq 'a "q" b') $bp.Out

    Check 'H1 Invoke-BoundedProcess leaves no output files behind' (-not @(Get-ChildItem -LiteralPath $sbRoot -Filter 'bp-*' -Force).Count)
    if ($mockSP) { Set-Item function:Start-Process $mockSPBody }

    # ---- L4: the protocol key restore keeps the original value kinds
    $kindKey = $testKey + '-kind'
    Remove-Item -LiteralPath $kindKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path ($kindKey + '\shell\open\command') -Force | Out-Null
    New-ItemProperty -LiteralPath $kindKey -Name '(default)' -Value '%SystemRoot%\old-default' -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -LiteralPath $kindKey -Name 'URL Protocol' -Value '%TEMP%\x' -PropertyType ExpandString -Force | Out-Null
    $cmdOld = '"%SystemRoot%\System32\wscript.exe" "C:\old\handler.vbs" "%1"'
    New-ItemProperty -LiteralPath ($kindKey + '\shell\open\command') -Name '(default)' -Value $cmdOld -PropertyType ExpandString -Force | Out-Null
    $sn = Get-UrlProtocolSnapshot $kindKey
    Set-Item -LiteralPath $kindKey -Value 'changed'; Set-Item -LiteralPath ($kindKey + '\shell\open\command') -Value 'changed'
    New-ItemProperty -LiteralPath $kindKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    Restore-UrlProtocolSnapshot $sn $kindKey
    $k = Get-Item -LiteralPath $kindKey; $kc = Get-Item -LiteralPath ($kindKey + '\shell\open\command')
    Check 'L4 REG_EXPAND_SZ default / URL Protocol / command stay REG_EXPAND_SZ after a restore' ($k.GetValueKind('') -eq 'ExpandString' -and $k.GetValueKind('URL Protocol') -eq 'ExpandString' -and $kc.GetValueKind('') -eq 'ExpandString') "$($k.GetValueKind('')) $($k.GetValueKind('URL Protocol')) $($kc.GetValueKind(''))"
    Check 'L4 ... with the raw (unexpanded) values' ($k.GetValue('', $null, 'DoNotExpandEnvironmentNames') -ceq '%SystemRoot%\old-default' -and $k.GetValue('URL Protocol', $null, 'DoNotExpandEnvironmentNames') -ceq '%TEMP%\x' -and $kc.GetValue('', $null, 'DoNotExpandEnvironmentNames') -ceq $cmdOld)
    Remove-Item -LiteralPath $kindKey -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $kindKey -Force | Out-Null; Set-Item -LiteralPath $kindKey -Value 'URL:plain'
    $sn = Get-UrlProtocolSnapshot $kindKey; New-ItemProperty -LiteralPath $kindKey -Name '(default)' -Value '%X%' -PropertyType ExpandString -Force | Out-Null
    Restore-UrlProtocolSnapshot $sn $kindKey
    Check 'L4 a plain REG_SZ default stays REG_SZ' ((Get-Item -LiteralPath $kindKey).GetValueKind('') -eq 'String' -and (Get-Item -LiteralPath $kindKey).GetValue('') -ceq 'URL:plain')
    Remove-Item -LiteralPath $kindKey -Recurse -Force -ErrorAction SilentlyContinue

    # ---- S5: elevated runs only search the Windows / Program Files module folders
    $pfx = [Environment]::GetFolderPath('ProgramFiles'); $sysr = $env:SystemRoot
    $mp = @('C:\Users\bob\Documents\WindowsPowerShell\Modules', 'D:\OneDrive\Documents\WindowsPowerShell\Modules', 'C:\Users\bob\Documents\PowerShell\Modules', "$pfx\PowerShell\Modules", "$pfx\WindowsApps\Microsoft.PowerShell_7.4.1_x64__8wekyb3d8bbwe\Modules", "$pfx\WindowsPowerShell\Modules", "$sysr\system32\WindowsPowerShell\v1.0\Modules") -join ';'
    Check 'S5 elevated (5.1): only Program Files\WindowsPowerShell and System32 module folders remain' ((Get-SafeModulePath $mp $true $true) -ceq ("$pfx\WindowsPowerShell\Modules;$sysr\system32\WindowsPowerShell\v1.0\Modules")) (Get-SafeModulePath $mp $true $true)
    Check 'S5 elevated (PowerShell 7): the user Documents folders go, the Program Files ones stay' ((Get-SafeModulePath $mp $true $false) -notmatch 'Documents|OneDrive' -and (Get-SafeModulePath $mp $true $false) -match 'Program Files\\PowerShell\\Modules')
    Check 'S5 not elevated (5.1): only the PowerShell 7 folders are dropped (old behaviour)' ((Get-SafeModulePath $mp $false $true) -ceq ("C:\Users\bob\Documents\WindowsPowerShell\Modules;D:\OneDrive\Documents\WindowsPowerShell\Modules;$pfx\WindowsPowerShell\Modules;$sysr\system32\WindowsPowerShell\v1.0\Modules")) (Get-SafeModulePath $mp $false $true)
    Check 'S5 a path with nothing usable falls back to $PSHOME\Modules' ((Get-SafeModulePath 'C:\Users\bob\Documents\WindowsPowerShell\Modules' $true $true) -ceq (Join-Path $PSHOME 'Modules'))
    $pathBefore = $env:PSModulePath
    try {
        $env:PSModulePath = $mp
        function Test-IsAdmin { return $true }
        $orig = Repair-ModulePath
        Check 'S5 Repair-ModulePath (elevated) sets the safe path and returns the original' ($orig -ceq $mp -and $env:PSModulePath -notmatch 'Documents|OneDrive|bob') $env:PSModulePath
        $env:PSModulePath = $mp
        function Test-IsAdmin { return $false }
        $null = Repair-ModulePath
        Check 'S5 Repair-ModulePath (not elevated) keeps the user folders' ($env:PSModulePath -match 'bob\\Documents\\WindowsPowerShell') $env:PSModulePath
    } finally { $env:PSModulePath = $pathBefore; function Test-IsAdmin { return $true } }
    Check 'S5 Invoke-MainCore repairs the path first and restores it at the end' ($src -match '(?s)function Invoke-MainCore.*?\$origModulePath = Repair-ModulePath.*?if \(\$origModulePath\) \{ \$env:PSModulePath = \$origModulePath \}')

    # =====================================================================================
    # Pointer precision ("Enhance pointer precision"). SAFETY: $MouseKey is a throw-away HKCU key and SPI_SETMOUSE is a
    # recorder (see the block at the top); the real HKCU:\Control Panel\Mouse is compared with its snapshot at the end.
    # =====================================================================================
    . $setupPath
    . $applySafety
    . $r3Stubs
    $ZipFilesText = $rows -join "`n"; $ZipSha256 = Get-BytesSha256 $fakeZip
    $DryRun = [switch]$false; $RestorePointerPrecision = [switch]$false
    $zhEpp = [regex]'指標選項'                  # 指標選項
    function Set-TestMouse($s, $t1, $t2) {
        New-Item -Path $testMouseKey -Force | Out-Null
        foreach ($kv in @(@('MouseSpeed', $s), @('MouseThreshold1', $t1), @('MouseThreshold2', $t2))) {
            if ($null -ne $kv[1]) { New-ItemProperty -LiteralPath $testMouseKey -Name $kv[0] -Value $kv[1] -PropertyType String -Force | Out-Null }
        }
    }
    function Get-TestMouse {
        if (-not (Test-Path -LiteralPath $testMouseKey)) { return 'none' }
        $k = Get-Item -LiteralPath $testMouseKey
        return ('{0}/{1}/{2}' -f $k.GetValue('MouseSpeed'), $k.GetValue('MouseThreshold1'), $k.GetValue('MouseThreshold2'))
    }
    function Get-TestMouseKinds { $k = Get-Item -LiteralPath $testMouseKey; return (('MouseSpeed', 'MouseThreshold1', 'MouseThreshold2' | ForEach-Object { [string]$k.GetValueKind($_) }) -join ',') }
    function Get-LastSpi { if ($script:spiCalls.Count -eq 0) { return 'none' }; return ($script:spiCalls[$script:spiCalls.Count - 1] -join ',') }
    function Clear-TestMouse { if (Test-Path -LiteralPath $testMouseKey) { Remove-Item -LiteralPath $testMouseKey -Recurse -Force }; $script:spiCalls = @() }
    $ppJson = '"pointerPrecision":{"MouseSpeed":"1","MouseThreshold1":"6","MouseThreshold2":"10"}'

    Check 'EPP SAFETY: $MouseKey is the throw-away key, not the real one' ($MouseKey -ceq $testMouseKey -and $MouseKey -ne 'HKCU:\Control Panel\Mouse')
    Check 'EPP SAFETY: the real HKCU:\Control Panel\Mouse key is not under test' (-not $testMouseKey.Contains('Control Panel'))

    # ---- Get-PointerPrecision / Test-PointerPrecisionOn
    Clear-TestMouse
    $g = Get-PointerPrecision
    Check 'EPP Get: a missing key -> all $null, not "on"' ($null -eq $g.MouseSpeed -and $null -eq $g.MouseThreshold1 -and $null -eq $g.MouseThreshold2 -and -not (Test-PointerPrecisionOn $g))
    Set-TestMouse '1' '6' '10'
    $g = Get-PointerPrecision
    Check 'EPP Get: reads the three strings' ($g.MouseSpeed -ceq '1' -and $g.MouseThreshold1 -ceq '6' -and $g.MouseThreshold2 -ceq '10' -and $g.MouseSpeed -is [string])
    Check 'EPP Test-PointerPrecisionOn: 1 and 2 are on' ((Test-PointerPrecisionOn $g) -and (Test-PointerPrecisionOn ([pscustomobject]@{ MouseSpeed = '2' })))
    Set-TestMouse '0' '0' '0'
    Check 'EPP Test-PointerPrecisionOn: 0 is off' (-not (Test-PointerPrecisionOn (Get-PointerPrecision)))

    # ---- Set-PointerPrecisionOff / Restore-PointerPrecision (registry values + the SPI call)
    Clear-TestMouse; Set-TestMouse '1' '6' '10'
    Set-PointerPrecisionOff
    Check 'EPP Set-PointerPrecisionOff: all three values "0" (REG_SZ)' ((Get-TestMouse) -ceq '0/0/0' -and (Get-TestMouseKinds) -ceq 'String,String,String') "$(Get-TestMouse) $(Get-TestMouseKinds)"
    Check 'EPP Set-PointerPrecisionOff: exactly one SPI_SETMOUSE call with int[3]{0,0,0}' ($script:spiCalls.Count -eq 1 -and (Get-LastSpi) -ceq '0,0,0')
    $script:spiCalls = @()
    Restore-PointerPrecision ([pscustomobject]@{ MouseSpeed = '1'; MouseThreshold1 = '6'; MouseThreshold2 = '10' })
    Check 'EPP Restore-PointerPrecision: values written back as strings' ((Get-TestMouse) -ceq '1/6/10' -and (Get-TestMouseKinds) -ceq 'String,String,String')
    Check 'EPP Restore-PointerPrecision: SPI array is { threshold1, threshold2, acceleration } = 6,10,1' ($script:spiCalls.Count -eq 1 -and (Get-LastSpi) -ceq '6,10,1') (Get-LastSpi)
    $script:spiCalls = @(); Set-TestMouse '0' '0' '0'
    foreach ($bad in @([pscustomobject]@{ MouseSpeed = '1;calc'; MouseThreshold1 = '6'; MouseThreshold2 = '10' }, [pscustomobject]@{ MouseSpeed = '1'; MouseThreshold1 = ''; MouseThreshold2 = '10' },
                       [pscustomobject]@{ MouseSpeed = '1'; MouseThreshold1 = '6'; MouseThreshold2 = '-3' }, [pscustomobject]@{ MouseSpeed = '99999'; MouseThreshold1 = '6'; MouseThreshold2 = '10' }, [pscustomobject]@{ MouseSpeed = '1'; MouseThreshold1 = '6' })) {
        Check "EPP Restore-PointerPrecision refuses unexpected values ($($bad.MouseSpeed)/$($bad.MouseThreshold1)/$($bad.MouseThreshold2))" ((Throws { Restore-PointerPrecision $bad }) -and (Get-TestMouse) -ceq '0/0/0' -and $script:spiCalls.Count -eq 0)
    }
    Check 'EPP Restore-PointerPrecision $null throws' (Throws { Restore-PointerPrecision $null })

    # ---- the P/Invoke itself (in memory, no Add-Type); only the READ-ONLY SPI_GETMOUSE is ever called
    $spi = Get-SpiMethod
    Check 'EPP P/Invoke: SystemParametersInfoW(uint, uint, int[], uint) -> bool' ($spi.Name -ceq 'SystemParametersInfoW' -and (($spi.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ',') -ceq 'UInt32,UInt32,Int32[],UInt32' -and $spi.ReturnType -eq [bool])
    Check 'EPP P/Invoke: no Add-Type / no temp compilation in the source' ($src -notmatch '(?m)^\s*Add-Type .*MemberDefinition' -and $src -match 'DefinePInvokeMethod')
    $probe = [int[]](99, 99, 99)
    Invoke-Spi 3 $probe 0
    $live = (Get-RealMouseSnapshot) -split '\|'
    Check 'EPP P/Invoke: SPI_GETMOUSE (read-only) binds and fills { t1, t2, speed } like the real registry' ($probe -notcontains 99 -and $probe[2] -eq [int]$live[0] -and $probe[0] -eq [int]$live[1] -and $probe[1] -eq [int]$live[2]) ($probe -join ',')
    Check 'EPP SAFETY: in the tests Invoke-Spi refuses SPI_SETMOUSE' (Throws { Invoke-Spi 4 ([int[]](0, 0, 0)) 3 })
    Check 'EPP the SPI call uses SPI_SETMOUSE (4) with SPIF_UPDATEINIFILE|SPIF_SENDCHANGE (3)' ($src -match 'Invoke-Spi 4 \$Values 3')

    # ---- Test-SameInteractiveUser (the real function; sids passed in)
    Check 'EPP same user: one explorer, same SID -> true' ((& $realTestSame 'S-1-5-21-1' @('S-1-5-21-1')) -eq $true)
    Check 'EPP same user: several explorers, all the same -> true' ((& $realTestSame 'S-1-5-21-1' @('S-1-5-21-1', 'S-1-5-21-1')) -eq $true)
    Check 'EPP same user: explorer owned by someone else -> false' ((& $realTestSame 'S-1-5-21-1' @('S-1-5-21-2')) -eq $false)
    Check 'EPP same user: one explorer is someone else''s -> false' ((& $realTestSame 'S-1-5-21-1' @('S-1-5-21-1', 'S-1-5-21-2')) -eq $false)
    Check 'EPP same user: no explorer found -> false (cannot tell)' ((& $realTestSame 'S-1-5-21-1' @()) -eq $false)
    Check 'EPP same user: empty strings do not count as explorers' ((& $realTestSame 'S-1-5-21-1' @('', $null)) -eq $false)
    Check 'EPP same user: the current SID is a real SID' ((Get-CurrentUserSid) -match '^S-1-5-')
    Check 'EPP same user: Get-ExplorerOwnerSids (read-only CIM query) returns SIDs of this session only' (@(Get-ExplorerOwnerSids | Where-Object { $_ -notmatch '^S-1-' }).Count -eq 0)
    Check 'EPP same user: the real function answers a boolean from the live system' ((& $realTestSame) -is [bool])
    Check 'EPP same user: uses Win32_Process + GetOwnerSid of explorer.exe in this session' ($src -match 'Win32_Process -Filter "Name = ''explorer\.exe''"' -and $src -match 'GetOwnerSid' -and $src -match 'SessionId')

    # ---- marker: pointerPrecision round trip
    $realMarker2 = $MarkerPath
    $MarkerPath = Join-Path $sbRoot 'marker-epp'
    Write-Marker @{ DriverInstalled = $true; AppDirCreated = $true; PointerPrecision = $null }
    Check 'EPP marker: no saved values -> no pointerPrecision key, Read-Marker gives $null' (([IO.File]::ReadAllText($MarkerPath)) -notmatch 'pointerPrecision' -and $null -eq (Read-Marker).pointerPrecision)
    Write-Marker @{ DriverInstalled = $true; AppDirCreated = $true; PointerPrecision = ([ordered]@{ MouseSpeed = '1'; MouseThreshold1 = '6'; MouseThreshold2 = '10' }) }
    $txt = [IO.File]::ReadAllText($MarkerPath)
    Check 'EPP marker: the JSON holds "pointerPrecision":{"MouseSpeed":"1","MouseThreshold1":"6","MouseThreshold2":"10"}' ($txt.Contains($ppJson)) $txt
    $mk = Read-Marker
    Check 'EPP marker: Read-Marker returns the three strings' ($mk.pointerPrecision.MouseSpeed -ceq '1' -and $mk.pointerPrecision.MouseThreshold1 -ceq '6' -and $mk.pointerPrecision.MouseThreshold2 -ceq '10' -and $mk.installedDriver -eq $true)
    foreach ($badpp in '{"MouseSpeed":"x","MouseThreshold1":"6","MouseThreshold2":"10"}', '{"MouseSpeed":"1","MouseThreshold1":"6"}', '{"MouseSpeed":"1;calc","MouseThreshold1":"6","MouseThreshold2":"10"}', '"1/6/10"', '{"MouseSpeed":"","MouseThreshold1":"6","MouseThreshold2":"10"}') {
        [IO.File]::WriteAllText($MarkerPath, '{"tool":"mousecal","installedDriver":true,"createdAppDir":true,"version":"1","pointerPrecision":' + $badpp + '}')
        $mk = Read-Marker
        Check "EPP marker: a malformed pointerPrecision is ignored ($badpp)" ($mk -and $mk.installedDriver -eq $true -and $null -eq $mk.pointerPrecision)
    }
    [IO.File]::WriteAllText($MarkerPath, '{"tool":"mousecal","installedDriver":true,"createdAppDir":true,"version":"1","pointerPrecision":{"MouseSpeed":1,"MouseThreshold1":6,"MouseThreshold2":10}}')
    Check 'EPP marker: numbers (not strings) are accepted and normalised to strings' ((Read-Marker).pointerPrecision.MouseSpeed -ceq '1')
    [IO.File]::WriteAllText($MarkerPath, 'mousecal')
    Check 'EPP marker: the legacy plain-text marker has none' ($null -eq (Read-Marker).pointerPrecision)
    $MarkerPath = $realMarker2

    # ---- install flow (Invoke-Install with the full stub set): turn it off, save the originals, preserve them on re-runs
    Check 'EPP install: Invoke-Install carries a saved value forward from the prior marker' ($src -match '(?s)function Invoke-Install.*?if \(\$prior -and \$prior\.pointerPrecision\) \{ \$tx\.PointerPrecision = \$prior\.pointerPrecision \}')
    Check 'EPP install: the step runs inside the transaction (after Mutated, before the final apply), so a rollback covers it' ($src -match '(?s)\$tx\.Mutated = \$true.*?Disable-PointerPrecisionStep.*?# ---- 6\. apply now')
    Check 'EPP install: Invoke-Rollback restores the values this run changed' ($src -match '(?s)function Invoke-Rollback.*?\$tx\.PointerChanged -and \$tx\.PointerBefore.*?Restore-PointerPrecision \$tx\.PointerBefore')
    Clear-TestMouse; Set-TestMouse '1' '6' '10'; $script:sameUser = $true
    New-Sandbox3
    $r = Run-Install $mm
    Check 'EPP install: succeeds' (-not $r.Threw) $r.Out
    Check 'EPP install: EPP was on -> now 0/0/0 in the registry, applied live with {0,0,0}' ((Get-TestMouse) -ceq '0/0/0' -and (Get-LastSpi) -ceq '0,0,0' -and $script:spiCalls.Count -eq 1) "$(Get-TestMouse) spi=$($script:spiCalls.Count)"
    $mtxt = [IO.File]::ReadAllText($script:MarkerPath)
    Check 'EPP install: the marker holds the originals' ($mtxt.Contains($ppJson)) $mtxt
    Check 'EPP install: the output says so in both languages' ($r.Out -match 'Enhance pointer precision" is now OFF' -and $r.Out -match [regex]'增強指標的精確度')
    # re-run while it is already off: the saved original stays
    $script:spiCalls = @()
    $r = Run-Install $mm
    Check 'EPP re-run (already off): the saved originals are kept, never overwritten with 0s' ((-not $r.Threw) -and ([IO.File]::ReadAllText($script:MarkerPath)).Contains($ppJson) -and $script:spiCalls.Count -eq 0 -and (Get-TestMouse) -ceq '0/0/0') ([IO.File]::ReadAllText($script:MarkerPath))
    Check 'EPP re-run: says it is left as it is (already installed)' ($r.Out -match 'left as it is now')
    # re-run after the user turned it on again with other values: the true original (first saved) stays
    Set-TestMouse '2' '7' '11'
    $r = Run-Install $mm
    Check 'EPP re-run (user turned it on again as 2/7/11): left ON (the user''s choice), the FIRST saved original is still in the marker' ((-not $r.Threw) -and (Get-TestMouse) -ceq '2/7/11' -and $script:spiCalls.Count -eq 0 -and ([IO.File]::ReadAllText($script:MarkerPath)).Contains($ppJson)) "$(Get-TestMouse) $([IO.File]::ReadAllText($script:MarkerPath))"
    # a rollback of a re-run puts back what that run found (2/7/11), and the old marker bytes
    Set-TestMouse '2' '7' '11'; $script:spiCalls = @()
    $before = [IO.File]::ReadAllText($script:MarkerPath); $script:writerExit = 1
    $r = Run-Install $mm
    Check 'EPP re-run that fails later: rolled back, pointer settings untouched (2/7/11, no SPI call)' ($r.Threw -and (Get-TestMouse) -ceq '2/7/11' -and $script:spiCalls.Count -eq 0) "$($r.Threw) $(Get-TestMouse) spi=$($script:spiCalls.Count)"
    Check 'EPP re-run that fails later: the marker is exactly as before' ([IO.File]::ReadAllText($script:MarkerPath) -ceq $before)
    # first install that fails later: rollback restores the original, marker removed
    Clear-TestMouse; Set-TestMouse '1' '6' '10'; New-Sandbox3; $script:writerExit = 1
    $r = Run-Install $mm
    Check 'EPP first install that fails later: rollback restores 1/6/10 and applies it live as 6,10,1' ($r.Threw -and (Get-TestMouse) -ceq '1/6/10' -and (Get-LastSpi) -ceq '6,10,1') "$($r.Threw) $(Get-TestMouse) $(Get-LastSpi)"
    Check 'EPP first install that fails later: no marker is left behind' (-not (Test-Path -LiteralPath $script:MarkerPath))
    # EPP already off and no earlier record: nothing saved, nothing changed
    Clear-TestMouse; Set-TestMouse '0' '0' '0'; New-Sandbox3
    $r = Run-Install $mm
    Check 'EPP already off (never on): no change, no SPI call, no pointerPrecision in the marker' ((-not $r.Threw) -and $script:spiCalls.Count -eq 0 -and ([IO.File]::ReadAllText($script:MarkerPath)) -notmatch 'pointerPrecision')
    Clear-TestMouse; New-Sandbox3
    $r = Run-Install $mm
    Check 'EPP no mouse key at all: no change, no marker entry' ((-not $r.Threw) -and $script:spiCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $testMouseKey) -and ([IO.File]::ReadAllText($script:MarkerPath)) -notmatch 'pointerPrecision')
    # guard: a different interactive user
    Clear-TestMouse; Set-TestMouse '1' '6' '10'; $script:sameUser = $false; New-Sandbox3
    $r = $null; try { $r = @{ Threw = $false; Out = (Invoke-Install $mm *>&1 | Out-String -Width 5000) } } catch { $r = @{ Threw = $true; Out = $_.Exception.Message } }
    Check 'EPP guard: another desktop user -> not touched, no SPI call, nothing in the marker' ((-not $r.Threw) -and (Get-TestMouse) -ceq '1/6/10' -and $script:spiCalls.Count -eq 0 -and ([IO.File]::ReadAllText($script:MarkerPath)) -notmatch 'pointerPrecision') $r.Out
    Check 'EPP guard: the warning is bilingual and points to the mouse settings' (($r.Out -replace '\s+', ' ') -match 'NOT changed' -and ($r.Out -replace '\s+', '') -match $zhEpp -and ($r.Out -replace '\s+', '') -match [regex]'滑鼠設定')
    $script:sameUser = $true
    # SPI fails: the values go back, the marker does not keep an entry, the install itself still succeeds
    Clear-TestMouse; Set-TestMouse '1' '6' '10'; New-Sandbox3
    function Invoke-SpiSetMouse { param([int[]]$Values) throw 'spi boom' }
    $r = Run-Install $mm
    Check 'EPP SPI failure: install still succeeds, a warning is shown, registry back to 1/6/10, no marker entry' ((-not $r.Threw) -and $r.Out -match 'Could not turn off' -and (Get-TestMouse) -ceq '1/6/10' -and ([IO.File]::ReadAllText($script:MarkerPath)) -notmatch 'pointerPrecision') "$($r.Threw) $($r.Out) $(Get-TestMouse)"
    . $applySafety     # the recorder again
    # dry run: only prints
    Clear-TestMouse; Set-TestMouse '1' '6' '10'; New-Sandbox3
    $DryRun = [switch]$true
    $r = Run-Install @{ Kind = 'Rotation'; Value = 3.0 }
    $DryRun = [switch]$false
    Check 'EPP -DryRun: prints the step, changes nothing' ((-not $r.Threw) -and ($r.Out -replace '\s+', ' ') -match 'Turn off Windows "Enhance pointer precision"' -and (Get-TestMouse) -ceq '1/6/10' -and $script:spiCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $script:MarkerPath)) $r.Out

    # ---- uninstall: restore only with -RestorePointerPrecision AND saved originals AND the same-user guard
    function Run-Uninstall { try { $o = (Invoke-Uninstall *>&1 | Out-String -Width 5000); return @{ Threw = $false; Out = $o } } catch { return @{ Threw = $true; Out = $_.Exception.Message } } }
    $mkPlain = '{"tool":"mousecal","installedDriver":false,"createdAppDir":false,"version":"1"}'
    $mkSaved = '{"tool":"mousecal","installedDriver":false,"createdAppDir":false,"version":"1",' + $ppJson + '}'
    function Reset-Un([string]$marker) { New-Sandbox3; Clear-TestMouse; Set-TestMouse '0' '0' '0'; if ($marker) { [IO.File]::WriteAllText($script:MarkerPath, $marker) } }
    Reset-Un $mkSaved; $RestorePointerPrecision = [switch]$true
    $r = Run-Uninstall
    Check 'EPP uninstall -RestorePointerPrecision + saved: values written back and applied live as 6,10,1' ((-not $r.Threw) -and (Get-TestMouse) -ceq '1/6/10' -and (Get-LastSpi) -ceq '6,10,1' -and $script:spiCalls.Count -eq 1) "$($r.Out) $(Get-TestMouse)"
    Check 'EPP uninstall: says it is back to the earlier setting; the marker is gone' ($r.Out -match 'is back to its earlier setting' -and -not (Test-Path -LiteralPath $script:MarkerPath))
    $RestorePointerPrecision = [switch]$false
    Reset-Un $mkSaved
    $r = Run-Uninstall
    Check 'EPP uninstall WITHOUT the switch: EPP stays as it is (off), no SPI call, and it says so' ((-not $r.Threw) -and (Get-TestMouse) -ceq '0/0/0' -and $script:spiCalls.Count -eq 0 -and ($r.Out -replace '\s+', ' ') -match 'stays off' -and ($r.Out -replace '\s+', '') -match $zhEpp) $r.Out
    $RestorePointerPrecision = [switch]$true
    Reset-Un $mkPlain
    $r = Run-Uninstall
    Check 'EPP uninstall with the switch but nothing saved: left as it is, and it says so' ((-not $r.Threw) -and (Get-TestMouse) -ceq '0/0/0' -and $script:spiCalls.Count -eq 0 -and ($r.Out -replace '\s+', ' ') -match 'left as it is') $r.Out
    Reset-Un $null
    $r = Run-Uninstall
    Check 'EPP uninstall with the switch but no marker at all: left as it is' ((-not $r.Threw) -and (Get-TestMouse) -ceq '0/0/0' -and $script:spiCalls.Count -eq 0 -and ($r.Out -replace '\s+', ' ') -match 'left as it is')
    Reset-Un $mkSaved; $script:sameUser = $false
    $r = Run-Uninstall
    Check 'EPP uninstall with the switch but another desktop user: not restored, warning, uninstall still finishes' ((-not $r.Threw) -and (Get-TestMouse) -ceq '0/0/0' -and $script:spiCalls.Count -eq 0 -and ($r.Out -replace '\s+', ' ') -match 'NOT restored' -and ($r.Out -replace '\s+', '') -match $zhEpp -and -not (Test-Path -LiteralPath $script:MarkerPath)) $r.Out
    $script:sameUser = $true
    Reset-Un $mkSaved; $DryRun = [switch]$true
    $r = Run-Uninstall
    $DryRun = [switch]$false
    Check 'EPP uninstall -DryRun with the switch: only reports (nothing written, marker kept)' ((-not $r.Threw) -and (Get-TestMouse) -ceq '0/0/0' -and $script:spiCalls.Count -eq 0 -and ($r.Out -replace '\s+', ' ') -match 'Put "Enhance pointer precision" back' -and (Test-Path -LiteralPath $script:MarkerPath)) $r.Out
    Reset-Un $mkSaved
    function Invoke-SpiSetMouse { param([int[]]$Values) throw 'spi boom' }
    $r = Run-Uninstall
    Check 'EPP uninstall: a failing SPI call only warns (with the old values), the uninstall still finishes' ((-not $r.Threw) -and $r.Out -match 'Could not restore' -and $r.Out -match '1/6/10' -and -not (Test-Path -LiteralPath $script:MarkerPath)) $r.Out
    . $applySafety
    $RestorePointerPrecision = [switch]$false

    # ---- the handler: ?epp=1 -> -Uninstall -RestorePointerPrecision, otherwise no restore
    Check 'EPP handler: the VBS sanitiser is unchanged (same character class, 64 chars)' ($HandlerVbsText.Contains('re.Pattern = "^[A-Za-z0-9:/?=.&-]+$"') -and $HandlerVbsText.Contains('Len(url) > 64'))
    Check 'EPP handler: the new link fits the VBS sanitiser' ([regex]::IsMatch('mousecal://uninstall?epp=1', '^[A-Za-z0-9:/?=.&-]+$') -and 'mousecal://uninstall?epp=1'.Length -le 64)
    & {
        $laBefore = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $sbRoot 'localappdata-epp'
        try {
            . (Join-Path $hd 'handler.ps1')
            function Get-RunningAntiCheatGames { return @() }
            function Show-Confirm { param($Text, $Title) $script:askText = $Text; return $true }
            function Show-Info { param($Text, $Title, $Icon) }
            function Show-Result { param($Code, $Action) }
            function Invoke-Elevated { param($ScriptPath, $ScriptArgs) $script:elev = (@($ScriptArgs) -join ' '); return 0 }
            foreach ($case in @(@('mousecal://uninstall?epp=1', '-Uninstall -RestorePointerPrecision -NoPause', $true), @('mousecal://uninstall?epp=0', '-Uninstall -NoPause', $false), @('mousecal://uninstall', '-Uninstall -NoPause', $false))) {
                $script:elev = $null; $script:askText = $null
                $rc = Invoke-HandlerMain $case[0]
                Check "EPP handler: $($case[0]) -> elevated args '$($case[1])'" ($rc -eq 0 -and $script:elev -ceq $case[1]) "rc=$rc elev=$($script:elev)"
                Check "EPP handler: $($case[0]) -> the confirmation $(if ($case[2]) { 'mentions' } else { 'does not mention' }) pointer precision" ([bool]($script:askText -match 'Enhance pointer precision') -eq $case[2])
            }
            foreach ($u in 'mousecal://uninstall?epp=2', 'mousecal://uninstall?epp=1&x=1', 'mousecal://apply?epp=1', 'mousecal://uninstall?x=1') {
                $script:elev = $null
                $rc = Invoke-HandlerMain $u
                Check "EPP handler: $u is rejected (exit 3), nothing elevated" ($rc -eq 3 -and $null -eq $script:elev)
            }
        } finally { $env:LOCALAPPDATA = $laBefore }
    }
    Check 'EPP handler: every elevated argument still passes the strict argument check' ('-RestorePointerPrecision' -cmatch '^-?[A-Za-z0-9.]+\z' -and $HandlerPs1Text.Contains("'^-?[A-Za-z0-9.]+\z'"))

    # ---- SAFETY: nothing above touched the real mouse settings
    Remove-TestKey
    Check 'EPP SAFETY: the real HKCU:\Control Panel\Mouse is exactly as before' ((Get-RealMouseSnapshot) -ceq $realMouseBefore) "$realMouseBefore -> $(Get-RealMouseSnapshot)"
    Check 'EPP SAFETY: no test key is left behind' (-not (Test-Path -LiteralPath $testMouseKey))

    # ---- housekeeping
    $gi = [IO.File]::ReadAllText((Join-Path $here '..\.gitignore'))
    Check '.gitignore ignores .claude/' ($gi -split "`r?`n" -contains '.claude/')

    Check 'R3 SAFETY: the real HKLM:\SOFTWARE\Classes\mousecal is still as before' ((Test-Path -LiteralPath 'HKLM:\SOFTWARE\Classes\mousecal') -eq $hklmKeyBefore)
} finally {
    Remove-Item -LiteralPath $sbRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-TestKey
if ($script:fails -gt 0) { Write-Host "$script:fails check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'all setup.ps1 checks passed'
