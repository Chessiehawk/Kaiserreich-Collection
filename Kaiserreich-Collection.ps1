# Kaiserreich Collection - installer + launcher for every old Kaiserreich on its matching HOI4 version.
# A separate program from the Classic HOI4 Collection; it never touches that launcher's files.
#
# How it works
#  - Each Kaiserreich release only runs on the HOI4 version it was made for (versions.json lists 16 pairs).
#  - Every HOI4 version is kept as its own ready-to-run copy under <Store>\games\<branch>. The first time a
#    version is needed, Steam's HOI4 is switched to that beta branch, downloaded, copied out, and at the end
#    Steam is put back on the branch it was on before (so other launchers relying on it are unaffected).
#  - Kaiserreich itself comes from the official GitHub archive and lives in <Store>\mods; only a small
#    KRC_*.mod pointer file goes into Documents\Paradox Interactive\Hearts of Iron IV\mod.
#  - HOI4 always uses the normal Documents folder, so before launching we save dlc_load.json and settings.txt
#    and a hidden watcher restores them (and clears the game cache) once the game closes.
param(
    [string]$Branch = '',                # which version to use (versions.json "branch"); empty = newest
    [switch]$Plpc, [switch]$NoPlpc,      # Player-Led Peace Conferences add-on (only where a build exists)
    [switch]$AllDlcOff,                  # disable every DLC
    [switch]$DlcList, [string]$EnableDlc = '',   # enable only these DLC folders (comma separated)
    [switch]$Install,                    # make sure this version is installed, then stop (no launch)
    [switch]$InstallAll,                 # install every version (long: one Steam download per version)
    [switch]$ClearCache,                 # clear the game cache now and stop
    [switch]$NoLaunch,                   # do everything except starting the game
    [string]$ShortcutTarget = '',        # (re)create the Desktop shortcut pointing at this exe
    [string]$Store = '',                 # where game copies and mods live (default: remembered, else D:\KaiserreichCollection)
    [switch]$Uninstall,                  # remove everything: game copies, Kaiserreich downloads, KRC_* mod files, shortcut, Apps entry, launcher
    [switch]$DryRun,                     # with -Uninstall: only list what would be removed
    [switch]$NoWasd,                     # don't start the WASD map-movement helper with the game
    [string]$Scenario = '',              # custom games to offer in the game (scenarios.json ids, comma separated)
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$AppId  = 394360
$Here   = $PSScriptRoot
$UA     = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
$Curl   = "$env:SystemRoot\System32\curl.exe"
$Home2  = $Here      # the launcher's own folder (<store>\app); store.txt lives here, never in AppData

function Write-Utf8NoBom([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false))) }
function Get-VdfValue([string]$text, [string]$key) { $m = [regex]::Match($text, ('"' + $key + '"\s+"([^"]*)"')); if ($m.Success) { $m.Groups[1].Value } else { '' } }
function Find-Steam {
    $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $p) { $p = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath }
    if (-not $p) { $p = 'C:\Program Files (x86)\Steam' }
    $p = $p -replace '/', '\'
    if (-not (Test-Path "$p\steam.exe")) { throw "Steam not found (looked in $p)." }
    $p
}
function Find-GameLibrary([string]$steam) {
    $libs = @($steam)
    $vdf = "$steam\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) { foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
    foreach ($lib in $libs | Select-Object -Unique) { if (Test-Path "$lib\steamapps\appmanifest_$AppId.acf") { return $lib } }
    throw 'Hearts of Iron IV is not installed in Steam on this PC. Install it from Steam first.'
}
function Get-DirSizeGB([string]$p) { [math]::Round((Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB, 1) }

# ---------- Steam branch switching (only used the first time a version is installed) ----------
function Set-AcfBranch([string]$acfText, [string]$branch) {
    $ucfg = [regex]::Match($acfText, '"UserConfig"\s*\{[^}]*\}')
    $block = $ucfg.Value
    $block = [regex]::Replace($block, '\r?\n\s*"BetaKey"\s+"[^"]*"', '')
    if ($branch -ne 'public') { $block = [regex]::Replace($block, '("UserConfig"\s*\{)', ('${1}' + "`r`n`t`t" + '"BetaKey"' + "`t`t" + '"' + $branch + '"')) }
    $acfText = $acfText.Substring(0, $ucfg.Index) + $block + $acfText.Substring($ucfg.Index + $ucfg.Length)
    [regex]::Replace($acfText, '"StateFlags"\s+"\d+"', ('"StateFlags"' + "`t`t" + '"6"'))
}
function Stop-SteamClient([string]$steam) {
    if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { return }
    Write-Host 'Closing Steam (needed to change the game version)...'
    Start-Process "$steam\steam.exe" -ArgumentList '-shutdown'
    $t = 0; while ((Get-Process steam -ErrorAction SilentlyContinue) -and $t -lt 120) { Start-Sleep 2; $t += 2 }
    if (Get-Process steam -ErrorAction SilentlyContinue) { throw 'Steam did not close. Close it yourself and try again.' }
    Start-Sleep 3
}
function Switch-SteamBranch([string]$steam, [string]$acf, [string]$branch, [string]$buildId, [string]$label) {
    $t0 = Get-Content $acf -Raw
    if ((Get-VdfValue $t0 'buildid') -eq $buildId -and (Get-VdfValue $t0 'StateFlags') -eq '4') { return }
    if (Get-Process hoi4 -ErrorAction SilentlyContinue) { throw 'Close Hearts of Iron IV first - Steam cannot update it while it runs.' }
    Write-Host "Switching Steam's Hearts of Iron IV to $label (beta branch '$branch')..." -ForegroundColor Yellow
    Stop-SteamClient $steam
    Copy-Item $acf "$acf.krc-backup" -Force
    Write-Utf8NoBom $acf (Set-AcfBranch (Get-Content $acf -Raw) $branch)
    Start-Process "$steam\steam.exe"
    Write-Host 'Steam is downloading it now. Do not close this window.'
    Start-Sleep 60
    if ((Get-VdfValue (Get-Content $acf -Raw) 'StateFlags') -eq '6') { Start-Process "steam://validate/$AppId" }
    $waited = 0
    while ($waited -lt 14400) {
        Start-Sleep 10; $waited += 10
        $t = Get-Content $acf -Raw
        $sf = Get-VdfValue $t 'StateFlags'; $bid = Get-VdfValue $t 'buildid'
        if ($sf -eq '4' -and $bid -eq $buildId) { Write-Host "Steam finished: $label is installed." -ForegroundColor Green; return }
        if ($waited % 60 -eq 0) {
            $dl = [int64](Get-VdfValue $t 'BytesDownloaded'); $todo = [int64](Get-VdfValue $t 'BytesToDownload')
            $pct = if ($todo -gt 0) { [math]::Round(100 * $dl / $todo) } else { 0 }
            Write-Host ("   ...Steam download {0}% ({1} of {2} MB), {3} min" -f $pct, [math]::Round($dl/1MB), [math]::Round($todo/1MB), [int]($waited/60))
        }
    }
    throw "Steam did not finish switching to $label within 4 hours. Check Steam's Downloads page, then try again."
}

# ---------- downloads ----------
function Invoke-Download([string]$url, [string]$dest, [string]$label) {
    if (Test-Path $dest) { Remove-Item $dest -Force }
    $p = Start-Process -FilePath $Curl -ArgumentList @('-sL', '-A', "`"$UA`"", '--retry', '3', '-o', "`"$dest`"", "`"$url`"") -PassThru -WindowStyle Hidden
    $last = -1
    while (-not $p.HasExited) { Start-Sleep 5; $mb = if (Test-Path $dest) { [int]((Get-Item $dest).Length / 1MB) } else { 0 }; if ($mb -ne $last) { Write-Host ("   {0}: {1} MB so far..." -f $label, $mb); $last = $mb } }
    ($p.ExitCode -eq 0 -and (Test-Path $dest) -and (Get-Item $dest).Length -gt 1MB)
}
function Expand-ModArchive([string]$zip, [string]$destRoot, [string]$finalName) {
    $staging = Join-Path $destRoot "_staging_$finalName"
    if (Test-Path -LiteralPath $staging) { [IO.Directory]::Delete($staging, $true) }
    New-Item -ItemType Directory -Force $staging | Out-Null
    Write-Host '   Extracting...'
    & "$Here\7zip\7z.exe" x -y -bso0 -bsp0 "-o$staging" $zip | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not extract $zip (7-Zip exit $LASTEXITCODE)" }
    # releases before 0.10 (HOI4 1.5-1.7) ship "Kaiserreich.mod" instead of "descriptor.mod"
    $hasDesc = { param($d) (Test-Path -LiteralPath "$d\descriptor.mod") -or (Test-Path -LiteralPath "$d\Kaiserreich.mod") }
    $src = if (& $hasDesc $staging) { $staging } else { (Get-ChildItem -LiteralPath $staging -Directory | Where-Object { & $hasDesc $_.FullName } | Select-Object -First 1).FullName }
    if (-not $src) { [IO.Directory]::Delete($staging, $true); throw "No descriptor.mod found inside $zip" }
    if (-not (Test-Path -LiteralPath "$src\descriptor.mod")) { Copy-Item -LiteralPath "$src\Kaiserreich.mod" -Destination "$src\descriptor.mod" }
    $final = Join-Path $destRoot $finalName
    if (Test-Path -LiteralPath $final) { [IO.Directory]::Delete($final, $true) }
    Move-Item -LiteralPath $src -Destination $final
    Remove-Item -LiteralPath "$final.zip", "$final.zip.part" -Force -ErrorAction SilentlyContinue   # old-version zip of the previous copy
    if (Test-Path -LiteralPath $staging) { [IO.Directory]::Delete($staging, $true) }
    Remove-Item -LiteralPath $zip -Force
}
function Write-PointerMod([string]$srcDescriptor, [string]$modFile, [string]$name, [string]$contentDir, [string]$archive = '') {
    # descriptor copied from the mod itself, with our name and an absolute path to the content on the store drive
    $d = (Get-Content -LiteralPath $srcDescriptor -Raw -Encoding UTF8) -replace "`r", ''
    $d = [regex]::Replace($d, '(?m)^\s*remote_file_id\s*=.*\n?', '')
    $d = [regex]::Replace($d, '(?m)^\s*(name|path|archive)\s*=.*\n?', '')
    if ($archive) {
        # HOI4 1.8 and older only load a mod from another drive when it is a zip ("archive"), and want UTF-8 with BOM
        $d = 'name="' + $name + "`"`narchive=`"" + ($archive -replace '\\', '/') + "`"`n" + $d
        [IO.File]::WriteAllText($modFile, $d, (New-Object System.Text.UTF8Encoding($true)))
    } else {
        $d = 'name="' + $name + "`"`npath=`"" + ($contentDir -replace '\\', '/') + "`"`n" + $d
        Write-Utf8NoBom $modFile $d
    }
}
# HOI4 1.8 and older: no dlc_load.json, built-in old launcher, mods only as zip archives
function Test-OldGame([string]$gameDir) { -not [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("$gameDir\hoi4.exe")).Contains('dlc_load.json') }
# Old versions (1.5-1.7) have no dependable way to switch DLC off from outside, and two players with different DLC on
# go out of sync in multiplayer the moment one joins. So DLC that is off is moved out of the game copy's dlc folder
# into dlc_off (and back when it is on again): a DLC that isn't there can't load. The game copy is the collection's
# own; a reinstall (robocopy /MIR) deletes dlc_off and puts every DLC back, and the next launch sorts them again.
function Sync-OldGameDlc([string]$gameDir, [string[]]$wanted) {
    $on = "$gameDir\dlc"; $off = "$gameDir\dlc_off"
    foreach ($dir in @(Get-ChildItem -LiteralPath $off -Directory -ErrorAction SilentlyContinue)) {
        if ($wanted -notcontains $dir.Name) { continue }
        if (Test-Path -LiteralPath "$on\$($dir.Name)") { Remove-Item -LiteralPath $dir.FullName -Recurse -Force } else { Move-Item -LiteralPath $dir.FullName -Destination $on }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $on -Directory -ErrorAction SilentlyContinue)) {
        if ($wanted -contains $dir.Name) { continue }
        New-Item -ItemType Directory -Force $off | Out-Null
        if (Test-Path -LiteralPath "$off\$($dir.Name)") { Remove-Item -LiteralPath "$off\$($dir.Name)" -Recurse -Force }
        Move-Item -LiteralPath $dir.FullName -Destination $off
    }
    $n = @(Get-ChildItem -LiteralPath $on -Directory -ErrorAction SilentlyContinue).Count
    Write-Host "DLC on (in the game's dlc folder): $n. Multiplayer: everyone needs the same DLC on."
}

# ---------- the user's own Documents files ----------
# Saved to <store>\state\docs_backup before every game start; put back by the watcher when the game closes.
# restore_pending.txt exists from game start until that restore has happened.
function Restore-DocsFiles([string]$bk, [string]$docs, [string]$presetsDir = '') {
    foreach ($f in 'dlc_load.json', 'settings.txt') {
        $b = Join-Path $bk $f; $d = Join-Path $docs $f
        if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination $d -Force }
        elseif (Test-Path -LiteralPath ($b + '.absent')) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
    }
    Restore-GameRules $docs $presetsDir
}
# Game-rule presets ("Documents\...\game rules"): every game version gets its own set while it runs, because a
# preset saved by a newer HOI4 crashes an older one on Save/Load Preset. The user's normal folder waits as
# "game rules.krc-saved"; the version's own presets are kept in <store>\state\presets\<branch>.
function Use-VersionGameRules([string]$docs, [string]$presetsDir) {
    $gr = Join-Path $docs 'game rules'; $saved = "$gr.krc-saved"
    if (Test-Path -LiteralPath $saved) { Restore-GameRules $docs '' }          # leftover from an interrupted session
    if (Test-Path -LiteralPath $gr) { Rename-Item -LiteralPath $gr -NewName 'game rules.krc-saved' }
    else { New-Item -ItemType Directory -Force $saved | Out-Null }               # (there was none: an empty one goes back)
    New-Item -ItemType Directory -Force $gr | Out-Null
    if ($presetsDir -and (Test-Path -LiteralPath $presetsDir)) { Copy-Item -Path (Join-Path $presetsDir '*') -Destination $gr -Recurse -Force }
}
# Custom games: write each chosen scenario as a game-rule preset ("Load Preset" in the game's Custom Game Rules),
# using only the rules this version has and this version's preset format number. Returns the preset file names.
function Write-ScenarioPresets([string]$grDir, [string]$branch, [string]$ids) {
    $written = @()
    if (-not $ids -or -not (Test-Path -LiteralPath "$Here\scenarios.json")) { return $written }
    foreach ($s in (Get-Content -LiteralPath "$Here\scenarios.json" -Raw | ConvertFrom-Json)) {
        if (($ids -split ',') -notcontains $s.id) { continue }
        $per = $s.versions.$branch
        if (-not $per) { Write-Host "Custom game '$($s.title)' doesn't exist for this version - skipped."; continue }
        if ($per.save_only) {
            # this Kaiserreich has no game rule for it; the scenario exists only as a save made by playing it out
            Write-Host "Custom game '$($s.title)': this Kaiserreich has no game rule for it - start from the ready save below." -ForegroundColor Green
        } else {
            $body = "save_version=$($per.save_version)`ndifficulty_settings={`n}`ngame_rules={`n"
            foreach ($p in $per.rules.PSObject.Properties) { $body += "`t$($p.Name)=`"$($p.Value)`"`n" }
            $body += "}`n"
            $file = "$($s.preset).txt"
            Write-Utf8NoBom (Join-Path $grDir $file) $body
            $written += $file
            Write-Host "Custom game ready: in the game pick Custom Game Rules > Load Preset > '$($s.preset)'." -ForegroundColor Green
        }
        # a ready-made save around the time the war starts, where one was made for this version: shipped next to the
        # engine as <id>\<branch>\*.hoi4.gz, or in a separate save pack (scenario_saves\packs\*.7z, see the window)
        if (-not $per.has_save) { continue }
        $saveDir = Join-Path $Docs 'save games'; New-Item -ItemType Directory -Force $saveDir | Out-Null
        $gzf = Get-ChildItem -LiteralPath "$Here\scenario_saves\$($s.id)\$branch" -Filter '*.hoi4.gz' -ErrorAction SilentlyContinue | Select-Object -First 1
        $name = if ($gzf) { $gzf.Name -replace '\.gz$', '' } elseif ($s.save) {
            $label = ((Get-Content -LiteralPath "$Here\versions.json" -Raw | ConvertFrom-Json) | Where-Object { $_.branch -eq $branch } | Select-Object -First 1).krLabel
            "$($s.save)$label.hoi4"
        }
        if (-not $name) { continue }
        $target = Join-Path $saveDir $name
        if (-not (Test-Path -LiteralPath $target)) {
            if ($gzf) {
                $in = [IO.File]::OpenRead($gzf.FullName); $out = [IO.File]::Create($target)
                try { $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress); $gz.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
            } elseif (Test-Path -LiteralPath "$Here\7zip\7z.exe") {
                foreach ($pack in Get-ChildItem -LiteralPath "$Here\scenario_saves\packs" -Filter '*.7z' -ErrorAction SilentlyContinue) {
                    & "$Here\7zip\7z.exe" e $pack.FullName "-o$saveDir" $name -y 2>&1 | Out-Null
                    if (Test-Path -LiteralPath $target) { break }
                }
            }
        }
        if (Test-Path -LiteralPath $target) {
            (Get-Item -LiteralPath $target).LastWriteTime = Get-Date   # newest = top of the game's save list
            Write-Host ($(if ($per.save_only) { 'Start it: Load Game > ''' } else { 'Or start when the war begins: Load Game > ''' }) + [IO.Path]::GetFileNameWithoutExtension($name) + "' (top of the list).") -ForegroundColor Green
        } else {
            Write-Host "The ready save for this version isn't here yet: download the 'ACW-saves' files as well and leave them in Downloads (or next to the launcher), then click PLAY again." -ForegroundColor Yellow
        }
    }
    $written
}
function Restore-GameRules([string]$docs, [string]$presetsDir) {
    $gr = Join-Path $docs 'game rules'; $saved = "$gr.krc-saved"
    if (-not (Test-Path -LiteralPath $saved)) { return }
    if (Test-Path -LiteralPath $gr) {
        if ($presetsDir) { New-Item -ItemType Directory -Force $presetsDir | Out-Null; Copy-Item -Path (Join-Path $gr '*') -Destination $presetsDir -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $gr -Recurse -Force
    }
    Rename-Item -LiteralPath $saved -NewName 'game rules'
}

# ---------- cache ----------
function Clear-GameCache([string]$docs) {
    if (Get-Process hoi4 -ErrorAction SilentlyContinue) { Write-Host 'Game is running - cache not cleared.' -ForegroundColor Yellow; return }
    $freed = 0; $n = 0
    foreach ($i in 'cache', 'map', 'shadercache', 'naval_dist.cache', 'naval_dist_checksum.cache', 'buildings_nudger_markers.txt') {
        $p = Join-Path $docs $i
        if (Test-Path -LiteralPath $p) { $freed += (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue; $n++ }
    }
    Write-Host ("Game cache cleared: {0} item(s), {1} MB. The game rebuilds it on its next start." -f $n, [math]::Round($freed / 1MB))
}

try {
    # ---------- one job at a time ----------
    # Installing switches Steam's game version and starting a game rewrites the game's settings: two jobs at once
    # would fight over both. A named lock is held for as long as this window runs (Windows drops it on exit).
    $script:jobLock = New-Object System.Threading.Mutex($false, 'Local\KaiserreichCollectionJob')
    $haveLock = $false; try { $haveLock = $script:jobLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveLock = $true }
    if (-not $haveLock) { throw 'The Kaiserreich Collection is already busy installing or starting a game. Wait until that finishes, then try again.' }

    # ---------- setup ----------
    $versions = Get-Content -LiteralPath "$Here\versions.json" -Raw | ConvertFrom-Json
    $storeFile = Join-Path $Home2 'store.txt'
    if (-not $Store) { $Store = if (Test-Path $storeFile) { (Get-Content $storeFile -Raw).Trim() } else { '' } }
    if (-not $Store -and (Split-Path $Here -Leaf) -eq 'app') { $Store = Split-Path $Here -Parent }   # launcher installed in <store>\app
    if (-not $Store) {
        $Store = if ((Test-Path 'D:\') -and ((Get-PSDrive D -ErrorAction SilentlyContinue).Free -gt 150GB)) { 'D:\KaiserreichCollection' }
                 else { $best = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 } | Sort-Object Free -Descending | Select-Object -First 1; "$($best.Root)KaiserreichCollection" }
    }
    New-Item -ItemType Directory -Force "$Store\games", "$Store\mods", "$Store\state" | Out-Null
    Write-Utf8NoBom $storeFile $Store
    $Steam = Find-Steam; $Lib = Find-GameLibrary $Steam
    $Acf   = "$Lib\steamapps\appmanifest_$AppId.acf"
    $SteamGame = "$Lib\steamapps\common\" + $(if ($d = Get-VdfValue (Get-Content $Acf -Raw) 'installdir') { $d } else { 'Hearts of Iron IV' })
    $Docs  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Paradox Interactive\Hearts of Iron IV'
    $ModDir = "$Docs\mod"; New-Item -ItemType Directory -Force $ModDir | Out-Null
    Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath "$Here\AppInfoParser.cs")
    $buildIds = @{}; foreach ($l in ([AppInfoParser]::Branches("$Steam\appcache\appinfo.vdf", $AppId) -split "`r?`n" | Where-Object { $_ })) { $p = $l -split '\|'; $buildIds[$p[0]] = $p[1] }
    if ($ClearCache) { Clear-GameCache $Docs; exit 0 }

    # ---------- uninstall ----------
    if ($Uninstall) {
        if (Get-Process hoi4 -ErrorAction SilentlyContinue) { throw 'Close Hearts of Iron IV first, then uninstall.' }
        $act = if ($DryRun) { 'Would remove' } else { 'Removing' }
        Write-Host ("=== Uninstalling the Kaiserreich Collection{0} ===" -f $(if ($DryRun) { ' (dry run - nothing is deleted)' } else { '' })) -ForegroundColor Yellow
        # Steam: this launcher always puts Steam back after borrowing it; if a switch was interrupted, finish that first
        $origFile = "$Store\state\steam_original_branch.txt"
        if (Test-Path $origFile) {
            $ob = (Get-Content $origFile -Raw).Trim()
            Write-Host ("{0} Steam's HOI4 back on '{1}' first (an earlier version switch was interrupted)" -f $(if ($DryRun) { 'Would put' } else { 'Putting' }), $ob)
            if (-not $DryRun) { Switch-SteamBranch $Steam $Acf $ob $buildIds[$ob] "its previous version ($ob)"; Remove-Item $origFile -Force }
        }
        # the shared game files: if they still hold this launcher's mods (or a restore is still due), put back the saved copies
        $dl = "$Docs\dlc_load.json"; $stf = "$Docs\settings.txt"; $bkDir = "$Store\state\docs_backup"
        $ours = (Test-Path "$Store\state\restore_pending.txt") -or ((Test-Path $dl) -and ((Get-Content $dl -Raw) -match 'KRC_')) -or ((Test-Path $stf) -and ((Get-Content $stf -Raw) -match 'KRC_'))
        if ($ours) {
            Write-Host "$act this launcher's mod list from dlc_load.json / settings.txt (your own saved copies go back)"
            if (-not $DryRun) {
                if ((Test-Path "$bkDir\dlc_load.json") -or (Test-Path "$bkDir\dlc_load.json.absent") -or (Test-Path "$bkDir\settings.txt")) { Restore-DocsFiles $bkDir $Docs }
                elseif ((Test-Path $dl) -and ((Get-Content $dl -Raw) -match 'KRC_')) { Write-Utf8NoBom $dl '{"disabled_dlcs":[],"enabled_mods":[]}' }
            }
        }
        if (Test-Path -LiteralPath "$Docs\game rules.krc-saved") {
            Write-Host "$act this launcher's game-rule presets folder (your own presets go back)"
            if (-not $DryRun) { Restore-GameRules $Docs '' }
        }
        # only this launcher's pointer files in the game's mod folder (named KRC_*); other mods are never touched
        foreach ($f in Get-ChildItem -LiteralPath $ModDir -Filter 'KRC_*.mod' -ErrorAction SilentlyContinue) { Write-Host "$act $($f.FullName)"; if (-not $DryRun) { Remove-Item -LiteralPath $f.FullName -Force } }
        if ($DryRun) { Write-Host 'Would clear the game cache (the game rebuilds it)' } else { Clear-GameCache $Docs }
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Kaiserreich Collection.lnk'
        if (Test-Path -LiteralPath $lnk) { Write-Host "$act Desktop shortcut"; if (-not $DryRun) { Remove-Item -LiteralPath $lnk -Force } }
        $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KaiserreichCollection'
        if (Test-Path $reg) { Write-Host "$act the entry in Windows Apps"; if (-not $DryRun) { Remove-Item $reg -Recurse -Force } }
        # the whole store: game copies, Kaiserreich downloads, launcher. Safety: only a folder that is clearly ours.
        $isOurs = (Test-Path -LiteralPath "$Store\app\Kaiserreich-Collection.ps1") -or ((Test-Path -LiteralPath "$Store\games") -and (Test-Path -LiteralPath "$Store\state"))
        if ($isOurs) {
            $gb = [math]::Round((Get-ChildItem -LiteralPath $Store -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB, 1)
            foreach ($d in Get-ChildItem -LiteralPath "$Store\games" -Directory -ErrorAction SilentlyContinue) { Write-Host "   game copy: HOI4 $($d.Name)" }
            foreach ($d in Get-ChildItem -LiteralPath "$Store\mods" -Directory -ErrorAction SilentlyContinue) { Write-Host "   mod: $($d.Name)" }
            Write-Host "$act everything in $Store ($gb GB), including the launcher (after this window closes)"
            if (-not $DryRun) {
                $cmd = "Start-Sleep 2; `$t=0; while ((Get-Process 'Kaiserreich Collection' -ErrorAction SilentlyContinue) -and `$t -lt 120) { Start-Sleep 1; `$t++ }; Start-Sleep 1; Remove-Item -LiteralPath '" + $Store.Replace("'", "''") + "' -Recurse -Force -ErrorAction SilentlyContinue"
                Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory $env:TEMP -ArgumentList @('-NoProfile', '-Command', $cmd)
            }
        } else { Write-Host "Not deleting $Store - it doesn't look like this launcher's folder." -ForegroundColor Yellow }
        Write-Host ''
        Write-Host $(if ($DryRun) { 'DRY RUN COMPLETE - nothing was removed.' } else { 'UNINSTALL COMPLETE.' }) -ForegroundColor Green
        exit 0
    }

    $sel = if ($Branch) { $versions | Where-Object { $_.branch -eq $Branch } | Select-Object -First 1 } else { $versions[-1] }
    if (-not $sel) { throw "Unknown version '$Branch'." }
    $todo = if ($InstallAll) { @($versions) } else { @($sel) }

    # Steam branch to put back afterwards. Saved to a file the moment we first switch, so that even if this
    # run is interrupted, the next run still knows where Steam was and puts it back.
    $origFile = "$Store\state\steam_original_branch.txt"
    if (Test-Path $origFile) { $origBranch = (Get-Content $origFile -Raw).Trim(); $switched = $true }
    else {
        # MountedConfig = the branch that is actually installed right now (Steam fills it in itself)
        $acfNow = Get-Content $Acf -Raw
        $origBranch = [regex]::Match([regex]::Match($acfNow, '"MountedConfig"\s*\{[^}]*\}').Value, '"BetaKey"\s+"([^"]*)"').Groups[1].Value
        if (-not $origBranch) { $origBranch = [regex]::Match([regex]::Match($acfNow, '"UserConfig"\s*\{[^}]*\}').Value, '"BetaKey"\s+"([^"]*)"').Groups[1].Value }
        if (-not $origBranch) { $origBranch = 'public' }
        $switched = $false
    }

    try {
        foreach ($v in $todo) {
            $label = "HOI4 $($v.game) $($v.codename) + Kaiserreich $($v.krLabel)"
            Write-Host ''; Write-Host "=== $label ===" -ForegroundColor Cyan
            $bid = $buildIds[$v.branch]
            if (-not $bid) { throw "Steam does not list the '$($v.branch)' branch for Hearts of Iron IV any more." }

            # ---- game copy ----
            $gameDir = "$Store\games\$($v.branch)"
            $marker = "$gameDir\krc_build.txt"
            if ((Test-Path "$gameDir\hoi4.exe") -and (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $bid)) {
                Write-Host "Game copy ready: $gameDir" -ForegroundColor Green
            } else {
                if ($v.branch -ne $origBranch -and -not (Test-Path $origFile)) { Write-Utf8NoBom $origFile $origBranch }
                Switch-SteamBranch $Steam $Acf $v.branch $bid "HOI4 $($v.game) ($($v.codename))"
                if ($v.branch -ne $origBranch) { $switched = $true }
                Write-Host "Copying the game to $gameDir ..."
                New-Item -ItemType Directory -Force $gameDir | Out-Null
                robocopy $SteamGame $gameDir /MIR /XF steam_appid.txt krc_build.txt /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Copying the game failed (robocopy $LASTEXITCODE)." }
                Write-Utf8NoBom "$gameDir\steam_appid.txt" "$AppId"
                Write-Utf8NoBom $marker $bid
                Write-Host ("Game copy ready: {0} GB" -f (Get-DirSizeGB $gameDir)) -ForegroundColor Green
            }

            # ---- Kaiserreich ----
            $krName = "Kaiserreich_$($v.krLabel)"; $krDir = "$Store\mods\$krName"
            if (-not (Test-Path -LiteralPath "$krDir\descriptor.mod")) {
                Write-Host "Downloading Kaiserreich $($v.krLabel) from GitHub..." -ForegroundColor Yellow
                $zip = Join-Path $env:TEMP "KRC_$($v.krLabel).zip"
                if (-not (Invoke-Download "https://github.com/Kaiserreich/Kaiserreich-HOI4/archive/refs/tags/$($v.kr).zip" $zip 'Kaiserreich')) { throw 'Kaiserreich download failed. Check your internet connection and try again.' }
                Expand-ModArchive $zip "$Store\mods" $krName
                Write-Host "Kaiserreich $($v.krLabel) installed." -ForegroundColor Green
            } else { Write-Host "Kaiserreich $($v.krLabel) ready." -ForegroundColor Green }
            # unique display name - must never equal another launcher's mod name (the game mixes up same-named mods)
            $krZip = ''
            if (Test-OldGame $gameDir) {
                $krZip = "$Store\mods\$krName.zip"
                if (-not (Test-Path -LiteralPath $krZip)) {
                    Write-Host "Packing Kaiserreich $($v.krLabel) into a zip (old game versions need that)..."
                    Remove-Item -LiteralPath "$krZip.part" -Force -ErrorAction SilentlyContinue   # left over from an interrupted run
                    & "$Here\7zip\7z.exe" a -tzip -mx0 -bso0 -bsp0 "$krZip.part" "$krDir\*" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Could not pack Kaiserreich (7-Zip exit $LASTEXITCODE)" }
                    Move-Item -LiteralPath "$krZip.part" -Destination $krZip -Force
                }
            }
            Write-PointerMod "$krDir\descriptor.mod" "$ModDir\KRC_$krName.mod" "Kaiserreich $($v.krLabel) (HOI4 $($v.game)) [Kaiserreich Collection]" $krDir $krZip

            # ---- Player-Led Peace Conferences, where a build exists for this version ----
            if ($v.plpc) {
                $pName = if ($v.plpc -eq 'legacy') { 'PLPC_Legacy' } else { 'PLPC_Current' }
                $pDir = "$Store\mods\$pName"
                if (-not (Test-Path -LiteralPath "$pDir\descriptor.mod")) { Copy-Item -LiteralPath "$Here\$pName" -Destination $pDir -Recurse -Force }
                Write-PointerMod "$pDir\descriptor.mod" "$ModDir\KRC_$pName.mod" "Player-Led Peace Conferences ($pName) [Kaiserreich Collection]" $pDir
            }
        }
    } finally {
        # put Steam's own copy back exactly where it was, so nothing else on this PC notices
        if ($switched) {
            Write-Host ''; Write-Host "Putting Steam's Hearts of Iron IV back on '$origBranch' (as it was before)..." -ForegroundColor Yellow
            try { Switch-SteamBranch $Steam $Acf $origBranch $buildIds[$origBranch] "its previous version ($origBranch)"; Remove-Item $origFile -Force -ErrorAction SilentlyContinue }
            catch { Write-Host ("WARNING: could not switch Steam back yet: " + $_.Exception.Message + " - it will be retried next run.") -ForegroundColor Red }
        }
    }

    # ---------- Desktop shortcut ----------
    if ($ShortcutTarget -and (Test-Path $ShortcutTarget)) {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Kaiserreich Collection.lnk'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.TargetPath = $ShortcutTarget; $s.WorkingDirectory = Split-Path $ShortcutTarget -Parent
        $ico = Join-Path (Split-Path $ShortcutTarget -Parent) 'KaiserreichCollection.ico'
        $s.IconLocation = if (Test-Path $ico) { "$ico,0" } else { "$ShortcutTarget,0" }
        $s.Description = 'Every old Kaiserreich on its matching Hearts of Iron IV version'
        $s.Save()
        # Windows "Apps" entry so it can be uninstalled like any program (per-user, no admin needed)
        $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KaiserreichCollection'
        $measure = $Install -or $InstallAll -or -not (Test-Path $reg)
        New-Item -Path $reg -Force | Out-Null
        Set-ItemProperty $reg -Name DisplayName -Value 'Kaiserreich Collection'
        Set-ItemProperty $reg -Name DisplayVersion -Value 'Kaiserreich 0.8.4a - 1.7'
        Set-ItemProperty $reg -Name Publisher -Value 'Kaiserreich Collection'
        Set-ItemProperty $reg -Name DisplayIcon -Value $(if (Test-Path $ico) { $ico } else { $ShortcutTarget })
        Set-ItemProperty $reg -Name InstallLocation -Value $Store
        Set-ItemProperty $reg -Name UninstallString -Value ('"' + $ShortcutTarget + '" /uninstall')
        Set-ItemProperty $reg -Name NoModify -Value 1 -Type DWord
        Set-ItemProperty $reg -Name NoRepair -Value 1 -Type DWord
        if ($measure) {
            $kb = [int]((Get-ChildItem -LiteralPath $Store -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB)
            Set-ItemProperty $reg -Name EstimatedSize -Value $kb -Type DWord
        }
    }

    if ($Install -or $InstallAll -or $NoLaunch) { Write-Host ''; Write-Host 'INSTALL COMPLETE.' -ForegroundColor Green; exit 0 }

    # ---------- launch the selected version ----------
    $v = $sel; $gameDir = [IO.Path]::GetFullPath("$Store\games\$($v.branch)")
    if (Get-Process hoi4 -ErrorAction SilentlyContinue) { throw 'Hearts of Iron IV is already running. Close it first.' }
    $mods = @("mod/KRC_Kaiserreich_$($v.krLabel).mod")
    $usePlpc = if ($Plpc) { [bool]$v.plpc } elseif ($NoPlpc) { $false } else { [bool]$v.plpc }
    if ($usePlpc) { $mods += "mod/KRC_" + $(if ($v.plpc -eq 'legacy') { 'PLPC_Legacy' } else { 'PLPC_Current' }) + '.mod' }
    $allowed = @($v.dlc)
    $wanted = if ($AllDlcOff) { @() } elseif ($DlcList) { @($EnableDlc -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $allowed -contains $_ }) } else { $allowed }
    $disabled = @()
    foreach ($dir in Get-ChildItem -LiteralPath "$gameDir\dlc" -Directory -ErrorAction SilentlyContinue) {
        $f = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.dlc' | Select-Object -First 1
        if ($f -and ($wanted -notcontains $dir.Name)) { $disabled += ('dlc/' + $dir.Name + '/' + $f.Name) }
    }

    # save the shared Documents files so they can be restored after the game closes
    $bk = "$Store\state\docs_backup"; New-Item -ItemType Directory -Force $bk | Out-Null
    $pending = "$Store\state\restore_pending.txt"
    if (Test-Path -LiteralPath $pending) {
        # the last game's files were never put back (the game only just closed, or the helper was stopped by a
        # restart): the Documents files are still the modded ones, so put the saved originals back before saving again
        Write-Host 'Putting your own game settings back from the last session first...'
        $lastBranch = (Get-Content -LiteralPath $pending -Raw).Trim()
        $lastPresets = if ($versions | Where-Object { $_.branch -eq $lastBranch }) { "$Store\state\presets\$lastBranch" } else { '' }
        Restore-DocsFiles $bk $Docs $lastPresets
        Remove-Item -LiteralPath $pending -Force
    }
    Get-ChildItem -LiteralPath $bk -File | Remove-Item -Force
    foreach ($f in 'dlc_load.json', 'settings.txt') { if (Test-Path -LiteralPath "$Docs\$f") { Copy-Item -LiteralPath "$Docs\$f" -Destination "$bk\$f" -Force } else { Write-Utf8NoBom "$bk\$f.absent" '' } }
    Clear-GameCache $Docs
    Write-Utf8NoBom $pending $v.branch    # which version's session this is (its presets are saved on restore)
    Use-VersionGameRules $Docs "$Store\state\presets\$($v.branch)"
    $scnFiles = @(Write-ScenarioPresets "$Docs\game rules" $v.branch $Scenario)
    $json = @{ enabled_mods = [string[]]$mods; disabled_dlcs = [string[]]$disabled } | ConvertTo-Json -Compress
    Write-Utf8NoBom "$Docs\dlc_load.json" $json
    # HOI4 1.8 and older don't know dlc_load.json: they read the mods and DLC to use from settings.txt
    # (last_mods = mods on, last_dlcs = DLC on). settings.txt was saved above and is put back after the game.
    $gameArgs = '-gdpr-compliant'
    if (Test-OldGame $gameDir) {
        # these versions also have the old launcher built into hoi4.exe: -nolauncher goes straight into the game
        $gameArgs = '-nolauncher ' + (($mods | ForEach-Object { '"-mod=' + $_ + '"' }) -join ' ')
        Sync-OldGameDlc $gameDir $wanted
        $on = @()
        foreach ($dir in Get-ChildItem -LiteralPath "$gameDir\dlc" -Directory -ErrorAction SilentlyContinue) {
            $f = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.dlc' | Select-Object -First 1
            if ($f -and ($wanted -contains $dir.Name)) { $on += ('dlc/' + $dir.Name + '/' + $f.Name) }
        }
        $st = if (Test-Path -LiteralPath "$Docs\settings.txt") { Get-Content -LiteralPath "$Docs\settings.txt" -Raw -Encoding UTF8 } else { '' }
        $st = [regex]::Replace($st, '(?ms)^\s*last_(mods|dlcs)\s*=\s*\{[^}]*\}\s*', '')
        $st = $st.TrimEnd() + "`nlast_mods={`n" + (($mods | ForEach-Object { "`t`"$_`"" }) -join "`n") + "`n}`nlast_dlcs={`n" + (($on | ForEach-Object { "`t`"$_`"" }) -join "`n") + "`n}`n"
        Write-Utf8NoBom "$Docs\settings.txt" $st
        Write-Host "Older game version: mod and DLC list written to settings.txt."
    }
    Write-Host ("Mods: {0}. DLC on: {1} of {2}." -f ($mods -join ', '), $wanted.Count, $allowed.Count)

    if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { Write-Host 'Starting Steam...'; Start-Process "$Steam\steam.exe"; Start-Sleep 20 }
    Write-Host "Starting Hearts of Iron IV $($v.game) with Kaiserreich $($v.krLabel)..." -ForegroundColor Green
    $game = Start-Process -FilePath "$gameDir\hoi4.exe" -ArgumentList $gameArgs -WorkingDirectory $gameDir -PassThru

    # WASD map movement: the launcher exe itself, in helper mode (ends by itself after the game closes)
    $helperExe = Join-Path $Here 'Kaiserreich Collection.exe'
    if (-not $NoWasd -and (Test-Path -LiteralPath $helperExe)) { Start-Process -FilePath $helperExe -ArgumentList '/wasd'; Write-Host 'WASD moves the map (F11 in the game turns it off/on).' }

    # watcher: once the game exits, put the Documents files back and clear the cache
    $watch = @'
$ErrorActionPreference = 'SilentlyContinue'
$bk = '__BK__'; $docs = '__DOCS__'
Wait-Process -Id __PID__
# some old versions close and reopen themselves once (e.g. from their built-in launcher): wait for that one too
while ($true) {
    Start-Sleep 10
    $again = Get-Process hoi4 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq '__EXE__' }
    if (-not $again) { break }
    $again | Wait-Process
}
# If another Hearts of Iron IV is running by now (started from another launcher or Steam), it owns these
# files - touching them or clearing the cache would break that game while it loads. Do nothing.
if (Get-Process hoi4 -ErrorAction SilentlyContinue) {
    Set-Content -LiteralPath '__STATE__\last_restore.txt' -Value ((Get-Date -Format 's') + ' skipped: another game was running')
    exit
}
foreach ($f in 'dlc_load.json', 'settings.txt') {
    $b = Join-Path $bk $f; $d = Join-Path $docs $f
    if (Test-Path -LiteralPath $b) { Copy-Item -LiteralPath $b -Destination $d -Force }
    elseif (Test-Path -LiteralPath ($b + '.absent')) { Remove-Item -LiteralPath $d -Force }
}
# game-rule presets: keep this version's own, put the user's normal folder back
$gr = Join-Path $docs 'game rules'; $saved = $gr + '.krc-saved'
if (Test-Path -LiteralPath $saved) {
    # the launcher's own custom-game presets are written fresh each time - don't keep them as the user's
    foreach ($n in @(__SCNFILES__)) { Remove-Item -LiteralPath (Join-Path $gr $n) -Force }
    if (Test-Path -LiteralPath $gr) { New-Item -ItemType Directory -Force '__PRESETS__' | Out-Null; Copy-Item -Path (Join-Path $gr '*') -Destination '__PRESETS__' -Recurse -Force; Remove-Item -LiteralPath $gr -Recurse -Force }
    Rename-Item -LiteralPath $saved -NewName 'game rules'
}
foreach ($i in 'cache', 'map', 'shadercache', 'naval_dist.cache', 'naval_dist_checksum.cache', 'buildings_nudger_markers.txt') { Remove-Item -LiteralPath (Join-Path $docs $i) -Recurse -Force }
Remove-Item -LiteralPath '__STATE__\restore_pending.txt' -Force
Set-Content -LiteralPath '__STATE__\last_restore.txt' -Value (Get-Date -Format 's')
'@
    $watch = $watch.Replace('__BK__', $bk.Replace("'", "''")).Replace('__DOCS__', $Docs.Replace("'", "''")).Replace('__PID__', "$($game.Id)").Replace('__EXE__', "$gameDir\hoi4.exe".Replace("'", "''")).Replace('__STATE__', "$Store\state".Replace("'", "''")).Replace('__PRESETS__', "$Store\state\presets\$($v.branch)".Replace("'", "''")).Replace('__SCNFILES__', (($scnFiles | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '))
    # with BOM: Windows PowerShell reads a script without one in the ANSI code page, which garbles non-English paths
    [IO.File]::WriteAllText("$Store\state\restore_after_game.ps1", $watch, (New-Object System.Text.UTF8Encoding($true)))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', "`"$Store\state\restore_after_game.ps1`"")
    Start-Sleep 3
    Write-Host 'GAME STARTED. Your normal Documents settings are restored automatically when it closes.'
}
catch {
    Write-Host ''
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Press Enter to close' }
    exit 1
}
