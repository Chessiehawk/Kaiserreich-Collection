# Stress test for the launcher - run it before every release:
#   powershell -ExecutionPolicy Bypass -File src\stress_test.ps1 -Work <empty temp folder> -OldExe <older launcher>[,...]
# Headless: the window is built via reflection and never shown, no game starts, no key presses reach the real screen.
#  1. every version x every button x rotating PLPC / WASD / DLC (all, none, some) / ACW: the exact engine command line
#     the launcher builds, run through powershell.exe -ExecutionPolicy RemoteSigned into a stub with the engine's own
#     param() block that reports what got bound
#  2. the real engine on the real install: uninstall in dry-run mode (only lists, removes nothing)
#  3. RemoveOldLaunchers on a fake Downloads tree full of traps
#  4. the WASD helper's key handling (console key / Esc / held keys), with SendInput swapped for a recorder
#  5. WASD starts off; an old remembered "wasd=1" doesn't turn it on, a new "wasdOn=1" does
param([string]$Exe = '', [string]$Engine = '', [Parameter(Mandatory)][string]$Work, [Parameter(Mandatory)][string[]]$OldExe)
$ErrorActionPreference = 'Stop'
$proj = Split-Path $MyInvocation.MyCommand.Path -Parent | Split-Path -Parent
if (-not $Exe) { $Exe = "$proj\dist\Kaiserreich Collection.exe" }
if (-not $Engine) { $Engine = "$proj\Kaiserreich-Collection.ps1" }
$OldExe = @($OldExe | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # powershell -File passes a list as one "a,b" string
$Exe = (Resolve-Path $Exe).Path; $Engine = (Resolve-Path $Engine).Path
New-Item -ItemType Directory -Force $Work | Out-Null; $Work = (Resolve-Path $Work).Path
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$asm = [Reflection.Assembly]::LoadFile($Exe)
$t = $asm.GetType('CollectionForm')
$bf = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public'
function F($name) { $t.GetField($name, $bf) }
(F 'args').SetValue($null, [string[]]@())
$form = [Activator]::CreateInstance($t, $true)
$null = $form.Handle
$exePath = 'D:\KaiserreichCollection\app\Kaiserreich Collection.exe'
(F 'exePath').SetValue($form, $exePath)
$fail = 0; $runs = 0
$mine = $asm.GetName().Version
"launcher under test: v$mine"

# ---------- 1. command line matrix ----------
$src = [IO.File]::ReadAllText($Engine)
$m = [regex]::Match($src, '(?ms)^param\(.*?^\)')
if (-not $m.Success) { throw 'no param block in the engine' }
$stubDir = Join-Path $Work 'stub'; New-Item -ItemType Directory -Force $stubDir | Out-Null
$stub = Join-Path $stubDir 'Kaiserreich-Collection.ps1'
[IO.File]::WriteAllText($stub, $m.Value + "`r`n" + '$PSBoundParameters.GetEnumerator() | Sort-Object Key | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }; exit 0', (New-Object Text.UTF8Encoding($false)))
$real = Join-Path ($t.GetMethod('HomeDir', $bf).Invoke($form, $null)) 'Kaiserreich-Collection.ps1'
$tiles = (F 'verTiles').GetValue($form); $scns = (F 'scns').GetValue($form)
$tPlpc = (F 'tPlpc').GetValue($form); $cbWasd = (F 'cbWasd').GetValue($form); $dlcChoice = (F 'dlcChoice').GetValue($form)
$select = $t.GetMethod('Select', $bf, $null, [type[]]@($tiles[0].Tag.GetType()), $null)
$compat = $t.GetMethod('CompatDlc', $bf); $engineArgs = $t.GetMethod('EngineArgs', $bf)
$modes = 'play', 'install', 'installall', 'cache', 'uninstall'
$flag = @{ install = 'Install'; installall = 'InstallAll'; cache = 'ClearCache'; uninstall = 'Uninstall' }
function Run-Ps([string]$argLine, [string]$dir) {
    $p = New-Object Diagnostics.Process
    $p.StartInfo = New-Object Diagnostics.ProcessStartInfo('powershell.exe', $argLine)
    $p.StartInfo.UseShellExecute = $false; $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true; $p.StartInfo.CreateNoWindow = $true
    if ($dir) { $p.StartInfo.WorkingDirectory = $dir }
    $null = $p.Start(); $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    @{ code = $p.ExitCode; out = $o; err = $e }
}
$i = 0
foreach ($tile in $tiles) {
    $v = $tile.Tag
    foreach ($mode in $modes) {
        $i++
        $select.Invoke($form, @($v)) | Out-Null
        $plpc = ($i % 2) -eq 0; $wasd = ($i % 3) -ne 0; $dlcMode = @('all', 'none', 'some')[$i % 3]; $acw = ($i % 4) -lt 2
        $tPlpc.On = $plpc; $cbWasd.Checked = $wasd
        foreach ($sc in $scns) { $sc.Tile.On = $acw }
        $dlcs = @($compat.Invoke($form, @($v)))
        $want = $null
        if ($dlcMode -eq 'all') { $dlcChoice.Remove($v.Branch) | Out-Null }
        elseif ($dlcMode -eq 'none') { $dlcChoice[$v.Branch] = New-Object 'System.Collections.Generic.HashSet[string]' }
        else { $hs = New-Object 'System.Collections.Generic.HashSet[string]'; foreach ($d in ($dlcs | Select-Object -First 2)) { $null = $hs.Add($d[0]) }; $dlcChoice[$v.Branch] = $hs; $want = @($hs) -join ',' }
        $a = $engineArgs.Invoke($form, @($mode))
        $runs++
        $problems = @()
        if (-not $a.Contains("-File `"$real`"")) { $problems += 'engine path missing' }
        $r = Run-Ps $a.Replace($real, $stub) $null
        $b = @{}; foreach ($l in ($r.out -split "`r?`n")) { if ($l -match '^(\w+)=(.*)$') { $b[$matches[1]] = $matches[2] } }
        if ($r.code -ne 0) { $problems += "exit $($r.code)" }
        if ($r.err.Trim()) { $problems += "stderr: $($r.err.Trim())" }
        if ($b['Branch'] -ne $v.Branch) { $problems += "Branch=$($b['Branch'])" }
        if ($b['ShortcutTarget'] -ne $exePath) { $problems += "ShortcutTarget=$($b['ShortcutTarget'])" }
        if (-not $b.ContainsKey('NoPause')) { $problems += 'no NoPause' }
        if ($plpc -ne $b.ContainsKey('Plpc') -or $plpc -eq $b.ContainsKey('NoPlpc')) { $problems += 'PLPC wrong' }
        if ($wasd -eq $b.ContainsKey('NoWasd')) { $problems += 'WASD wrong' }
        if ($dlcMode -eq 'all' -and ($b.ContainsKey('AllDlcOff') -or $b.ContainsKey('DlcList'))) { $problems += 'DLC all wrong' }
        if ($dlcMode -eq 'none' -and -not $b.ContainsKey('AllDlcOff')) { $problems += 'No DLC lost' }
        if ($dlcMode -eq 'some' -and $dlcs.Count -gt 0 -and -not ($b.ContainsKey('DlcList') -and $b['EnableDlc'] -eq $want)) { $problems += "DLC list wrong ($($b['EnableDlc']) vs $want)" }
        $acwHere = $acw -and @($scns | Where-Object { $_.Branches.Contains($v.Branch) }).Count -gt 0
        if ($acwHere -ne $b.ContainsKey('Scenario')) { $problems += 'ACW wrong' }
        foreach ($k in $flag.Keys) { if (($mode -eq $k) -ne $b.ContainsKey($flag[$k])) { $problems += "mode flag $($flag[$k]) wrong" } }
        if ($problems) { $fail++; "   FAIL KR $($v.Kr) $mode : $($problems -join '; ')`n        args: $a" }
    }
}
"1. command lines: $runs runs (all versions x 5 buttons, PLPC/WASD/DLC/ACW rotating), failures so far: $fail"

# ---------- 2. real engine, uninstall dry run ----------
(F 'args').SetValue($null, [string[]]@('/dryrun'))
$select.Invoke($form, @($tiles[0].Tag)) | Out-Null
$r = Run-Ps ($engineArgs.Invoke($form, @('uninstall'))) (Split-Path $real)
(F 'args').SetValue($null, [string[]]@())
$ok = $r.code -eq 0 -and $r.out -match 'DRY RUN COMPLETE' -and -not $r.err.Trim()
if (-not $ok) { $fail++; $r.out; $r.err }
"2. real engine (uninstall dry run): $(if ($ok) { 'PASS' } else { 'FAIL' }), exit $($r.code), $(@($r.out -split "`n" | Where-Object { $_ -match 'game copy:' }).Count) game copies listed"

# ---------- 3. old-launcher cleanup ----------
$top = Join-Path $Work 'FakeDownloads'; $sub = Join-Path $top 'Kaiserreich Collection 1.4'; $deep = Join-Path $sub 'deeper'
New-Item -ItemType Directory -Force $deep | Out-Null
$csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
function Dummy([string]$out, [string]$ver) {   # a tiny .NET exe; the assembly name comes from the file name
    $cs = Join-Path $Work ("d" + [guid]::NewGuid().ToString('N') + '.cs')
    $attr = if ($ver) { "[assembly: System.Reflection.AssemblyVersion(`"$ver`")]" } else { '' }
    [IO.File]::WriteAllText($cs, "$attr class P { static void Main() {} }")
    & $csc /nologo /target:exe "/out:$out" $cs | Out-Null; Remove-Item $cs
}
$expect = [ordered]@{}
function Put([string]$path, [bool]$gone) { $expect[$path] = $gone }
$n = 0
foreach ($o in $OldExe) {
    $n++; Copy-Item $o "$top\Kaiserreich.Collection ($n).exe"; Put "$top\Kaiserreich.Collection ($n).exe" $true   # older releases, browser-renamed
}
Copy-Item $OldExe[0] "$top\Kaiserreich.Collection.exe";            Put "$top\Kaiserreich.Collection.exe" $true          # GitHub single-exe name
Copy-Item $Exe "$top\Kaiserreich Collection (9).exe";              Put "$top\Kaiserreich Collection (9).exe" $false     # the current one
Copy-Item $OldExe[0] "$sub\Kaiserreich Collection.exe";            Put "$sub\Kaiserreich Collection.exe" $true          # extracted old zip
Copy-Item $OldExe[0] "$deep\Kaiserreich Collection.exe";           Put "$deep\Kaiserreich Collection.exe" $false        # two folders down: not looked at
Copy-Item $OldExe[0] "$top\Old Collection.exe";                    Put "$top\Old Collection.exe" $false                 # name doesn't start with Kaiserreich
Dummy "$top\Kaiserreich Collection (3).exe" '';                    Put "$top\Kaiserreich Collection (3).exe" $false     # .NET, but another program
Copy-Item "$env:windir\System32\notepad.exe" "$top\Kaiserreich Tool.exe"; Put "$top\Kaiserreich Tool.exe" $false     # not .NET at all
$nd = Join-Path $Work 'n'; New-Item -ItemType Directory -Force $nd | Out-Null
Dummy "$nd\Kaiserreich Collection.exe" '0.0.0.0'; Copy-Item "$nd\Kaiserreich Collection.exe" "$top\Kaiserreich Collection (4).exe"; Put "$top\Kaiserreich Collection (4).exe" $true    # pre-1.3 (no version)
Dummy "$nd\Kaiserreich Collection.exe" '9.0.0.0'; Copy-Item "$nd\Kaiserreich Collection.exe" "$top\Kaiserreich Collection (5).exe" -Force; Put "$top\Kaiserreich Collection (5).exe" $false   # newer: keep
Copy-Item $OldExe[0] "$top\Kaiserreich Collection (6).exe"; Put "$top\Kaiserreich Collection (6).exe" $false   # old but open (in use)
Copy-Item $OldExe[0] "$top\Kaiserreich Collection (7).exe"; (Get-Item "$top\Kaiserreich Collection (7).exe").IsReadOnly = $true; Put "$top\Kaiserreich Collection (7).exe" $false   # read-only: leave
$cur = "$($mine.Major).$($mine.Minor).$($mine.Build)"
foreach ($z in 'Kaiserreich-Collection-1.4.zip', 'Kaiserreich-Collection-1.4 (1).zip', 'Kaiserreich-Collection-1.3.zip', 'Kaiserreich-Collection-1.4.1.zip',
               'Kaiserreich Collection 1.4.1 - launcher.zip', 'Kaiserreich Collection 1.4.1 - launcher (2).zip') { Set-Content "$top\$z" 'x'; Put "$top\$z" $true }
foreach ($z in "Kaiserreich-Collection-$cur.zip", "Kaiserreich Collection $cur - launcher.zip", 'Kaiserreich-Collection-9.0.zip', 'Kaiserreich-Collection.zip',
               'Kaiserreich-Collection-main.zip', 'Kaiserreich Collection.zip', 'ACW-saves-1-of-2.7z', 'notes.txt') { Set-Content "$top\$z" 'x'; Put "$top\$z" $false }
$lock = [IO.File]::Open("$top\Kaiserreich Collection (6).exe", 'Open', 'Read', 'Read')
$sw = [Diagnostics.Stopwatch]::StartNew()
$t.GetMethod('RemoveOldLaunchers', $bf).Invoke($form, @(, [string[]]@($top, $top, (Join-Path $Work 'does-not-exist'), $null))) | Out-Null
$sw.Stop(); $lock.Close()
(Get-Item "$top\Kaiserreich Collection (7).exe").IsReadOnly = $false
$bad = 0
foreach ($k in $expect.Keys) {
    $gone = -not (Test-Path -LiteralPath $k)
    if ($gone -ne $expect[$k]) { $bad++; $fail++; "   FAIL $($k.Substring($Work.Length)) : expected $(if ($expect[$k]) { 'removed' } else { 'kept' }), was $(if ($gone) { 'removed' } else { 'kept' })" }
}
"3. cleanup: $($expect.Count) files, $(@($expect.Values | Where-Object { $_ }).Count) should go to the Recycle Bin, wrong: $bad, took $($sw.ElapsedMilliseconds) ms"

# ---------- 4. WASD key handling ----------
$wasdType = $asm.GetType('Wasd'); function WF($name) { $wasdType.GetField($name, $bf) }
$script:sent = New-Object Collections.Generic.List[string]
(WF 'send').SetValue($null, [Action[uint16, uint16, bool]] { param($vk, $scan, $up) $script:sent.Add(('{0:X2}{1}' -f $vk, $(if ($up) { '^' } else { 'v' }))) })
$cb = $wasdType.GetMethod('Callback', $bf)
$mem = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
function Key([string]$what, [int]$vk, [int]$scan, [bool]$up, [bool]$injected = $false) {
    [Runtime.InteropServices.Marshal]::WriteInt32($mem, 0, $vk); [Runtime.InteropServices.Marshal]::WriteInt32($mem, 4, $scan)
    [Runtime.InteropServices.Marshal]::WriteInt32($mem, 8, ($(if ($up) { 0x80 } else { 0 }) -bor $(if ($injected) { 0x10 } else { 0 })))
    [Runtime.InteropServices.Marshal]::WriteInt32($mem, 12, 0); [Runtime.InteropServices.Marshal]::WriteIntPtr($mem, 16, [IntPtr]::Zero)
    $script:sent.Clear()
    $r = $cb.Invoke($null, @([int]0, [IntPtr]$(if ($up) { 0x101 } else { 0x100 }), $mem))
    @{ swallowed = ($r -ne [IntPtr]::Zero); sent = ($script:sent -join ' ') }
}
$W = @(0x57, 0x11); $A = @(0x41, 0x1E); $S = @(0x53, 0x1F); $D = @(0x44, 0x20); $C = @(0xC0, 0x29); $E = @(0x1B, 0x01)
(WF 'hoiFront').SetValue($null, $true); (WF 'enabled').SetValue($null, $true); (WF 'typing').SetValue($null, $false)
$steps = @(
    @('W down on the map -> Up arrow',              $W, $false, $true,  '26v', $false),
    @('W held (repeat) -> Up arrow again',          $W, $false, $true,  '26v', $false),
    @('W up -> Up arrow released',                  $W, $true,  $true,  '26^', $false),
    @('console key down -> passes, typing starts',  $C, $false, $false, '',    $true),
    @('console key repeat -> still typing',         $C, $false, $false, '',    $true),
    @('W down in console -> letter W',              $W, $false, $false, '',    $true),
    @('W up in console -> letter W',                $W, $true,  $false, '',    $true),
    @('A down in console -> letter A',              $A, $false, $false, '',    $true),
    @('A up',                                       $A, $true,  $false, '',    $true),
    @('console key up',                             $C, $true,  $false, '',    $true),
    @('console key down -> console closed, map',    $C, $false, $false, '',    $false),
    @('console key up',                             $C, $true,  $false, '',    $false),
    @('D down on the map -> Right arrow',           $D, $false, $true,  '27v', $false),
    @('console key while D held -> Right released', $C, $false, $false, '27^', $true),
    @('D up afterwards -> passes, nothing stuck',   $D, $true,  $false, '',    $true),
    @('console key up',                             $C, $true,  $false, '',    $true),
    @('Esc -> back to the map',                     $E, $false, $false, '',    $false),
    @('S down -> Down arrow',                       $S, $false, $true,  '28v', $false),
    @('S up -> Down arrow released',                $S, $true,  $true,  '28^', $false)
)
$wbad = 0
foreach ($s in $steps) {
    $r = Key $s[0] $s[1][0] $s[1][1] $s[2]
    $typingNow = (WF 'typing').GetValue($null)
    if ($r.swallowed -ne $s[3] -or $r.sent -ne $s[4] -or $typingNow -ne $s[5]) { $wbad++; "   FAIL $($s[0]): swallowed $($r.swallowed) sent '$($r.sent)' typing $typingNow" }
}
# not in front / injected keys are never touched
(WF 'hoiFront').SetValue($null, $false)
$r = Key 'W, game not in front' $W[0] $W[1] $false; if ($r.swallowed -or $r.sent) { $wbad++; '   FAIL W changed while HOI4 not in front' }
$r = Key 'W up' $W[0] $W[1] $true
$r = Key 'console key, game not in front' $C[0] $C[1] $false; if ((WF 'typing').GetValue($null)) { $wbad++; '   FAIL console key counted while HOI4 not in front' }
$r = Key 'console up' $C[0] $C[1] $true
(WF 'hoiFront').SetValue($null, $true)
$r = Key 'injected W' $W[0] $W[1] $false $true; if ($r.swallowed -or $r.sent) { $wbad++; '   FAIL injected W was changed' }
[Runtime.InteropServices.Marshal]::FreeHGlobal($mem)
$fail += $wbad
"4. WASD keys: $($steps.Count + 4) steps (map, console open/close, key repeat, held key, Esc, not in front, injected), wrong: $wbad"

# ---------- 5. WASD default and remembered choice ----------
$f2 = [Activator]::CreateInstance($t, $true); $null = $f2.Handle
$cb2 = $t.GetField('cbWasd', $bf).GetValue($f2)
$d5 = 0
if ($cb2.Checked) { $d5++; '   FAIL WASD is ticked on a fresh start' }
$h = Join-Path $Work 'home'; New-Item -ItemType Directory -Force $h | Out-Null
$t.GetField('homeDir', $bf).SetValue($f2, $h)
Set-Content "$h\last.txt" "wasd=1"; $t.GetMethod('LoadLastChoice', $bf).Invoke($f2, $null) | Out-Null
if ($cb2.Checked) { $d5++; '   FAIL old "wasd=1" turned WASD on' }
Set-Content "$h\last.txt" "wasdOn=1"; $t.GetMethod('LoadLastChoice', $bf).Invoke($f2, $null) | Out-Null
if (-not $cb2.Checked) { $d5++; '   FAIL "wasdOn=1" did not turn WASD on' }
$cb2.Checked = $false; $t.GetMethod('SaveLastChoice', $bf).Invoke($f2, $null) | Out-Null
if (-not ((Get-Content "$h\last.txt") -contains 'wasdOn=0')) { $d5++; '   FAIL WASD choice not saved as wasdOn' }
$fail += $d5
"5. WASD default + remembered choice: 4 checks, wrong: $d5"

"TOTAL FAILURES: $fail"
exit $fail
