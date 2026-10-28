# Regenerates ..\versions.json: the 16 Kaiserreich / HOI4 pairs plus, for each, the DLC folders
# that exist on that HOI4 branch according to Steam's own depot data (appcache\appinfo.vdf).
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath "$PSScriptRoot\AppInfoParser.cs")
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath -replace '/', '\'
$rows = [AppInfoParser]::Depots("$steam\appcache\appinfo.vdf", 394360) -split "`r?`n" | Where-Object { $_ }
if (-not $rows) { throw 'HOI4 not found in the Steam app cache' }

# DLC steam app id -> dlc folder name, from the .dlc files of any installed HOI4
$vdf = Get-Content "$steam\steamapps\libraryfolders.vdf" -Raw
$libs = @($steam) + ([regex]::Matches($vdf, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
$dlcRoot = $libs | ForEach-Object { "$_\steamapps\common\Hearts of Iron IV\dlc" } | Where-Object { Test-Path $_ } | Select-Object -First 1
$map = @{}
Get-ChildItem $dlcRoot -Directory | ForEach-Object {
    $f = Get-ChildItem $_.FullName -Filter *.dlc | Select-Object -First 1
    if ($f) { $id = [regex]::Match((Get-Content $f.FullName -Raw), 'steam_id\s*=\s*"?(\d+)').Groups[1].Value; if ($id) { $map[$id] = $_.Name } }
}
$dlcBranches = @{}
foreach ($r in $rows) { $p = $r -split '\|'; if ($p[1] -ne '-' -and $map[$p[1]]) { $dlcBranches[$map[$p[1]]] = @($p[2] -split ',' | Where-Object { $_ }) } }

# Kaiserreich tag = last release whose descriptor supports that game version (chosen 2026-09-26)
# Steam has no HOI4 branch older than 1.5.4, so Kaiserreich 0.1-0.5 (HOI4 1.0-1.4) can't be played any more; 1.5-1.7 added 2026-10-17
$versions = @(
  [ordered]@{ branch='1.5.4';    game='1.5';    codename='Cornflakes';        kr='0.8.4a';                  krLabel='0.8.4a'; update='La Bella Antillana'; plpc='' }
  [ordered]@{ branch='1.6.2';    game='1.6';    codename='Ironclad';          kr='0.9.1';                   krLabel='0.9.1'; update='Aurora Borealis'; plpc='' }
  [ordered]@{ branch='1.7.1';    game='1.7';    codename='Hydra';             kr='0.9.3';                   krLabel='0.9.3'; update='Aurora Borealis'; plpc='' }
  [ordered]@{ branch='1.8.2';    game='1.8';    codename='Fork';              kr='0.11_The_Long_Road_Home'; krLabel='0.11'; update='The Long Road Home';   plpc='' }
  [ordered]@{ branch='1.9.x';    game='1.9';    codename='Husky';             kr='0.14.2';                  krLabel='0.14.2'; update='The Duke and the Hertzog'; plpc='' }
  [ordered]@{ branch='1.10.5';   game='1.10';   codename='Collie';            kr='0.19.2';                  krLabel='0.19.2'; update='March on the Drina'; plpc='legacy' }
  [ordered]@{ branch='1.11.13';  game='1.11';   codename='Barbarossa';        kr='0.22.1';                  krLabel='0.22.1'; update='Shattered Crescent'; plpc='legacy' }
  [ordered]@{ branch='1.12.14';  game='1.12';   codename='Avalanche';         kr='0.26.2';                  krLabel='0.26.2'; update='Blue Sky, White Sun'; plpc='' }
  [ordered]@{ branch='1.13.7';   game='1.13';   codename='Stella Polaris';    kr='1.0.3';                   krLabel='1.0.3'; update='The Empire Strikes Back';  plpc='' }
  [ordered]@{ branch='1.14.10';  game='1.14';   codename='Bolivar';           kr='1.3.1';                   krLabel='1.3.1'; update='Amid Blue-Coloured Seas';  plpc='' }
  [ordered]@{ branch='1.15.4';   game='1.15';   codename='Kaiser';            kr='1.4.3b';                  krLabel='1.4.3b'; update='All the Russias'; plpc='' }
  [ordered]@{ branch='1.16.10';  game='1.16';   codename='Countenance';       kr='1.5.3a';                  krLabel='1.5.3a'; update='Brave New World'; plpc='' }
  [ordered]@{ branch='1.17.5.2'; game='1.17';   codename='Musketeer';         kr='1.6.2b';                  krLabel='1.6.2b'; update=''; plpc='' }
  [ordered]@{ branch='1.18.3.0'; game='1.18';   codename='Case Green';        kr='1.6.3d';                  krLabel='1.6.3d'; update=''; plpc='' }
  [ordered]@{ branch='1.19.1.0'; game='1.19.1'; codename='Operation Postern'; kr='1.6.4b';                  krLabel='1.6.4b'; update=''; plpc='current' }
  [ordered]@{ branch='public';   game='1.19.3'; codename='Current';           kr='1.7';                     krLabel='1.7'; update='Crossroads of Civilisation';    plpc='current' }
)
# Steam sometimes gives an old branch the DLC that launched with the NEXT game version (e.g. Battle for
# the Bosporus, a 1.10 DLC, shows up on 1.9.x). Cap each version at the DLC released with it.
$maxDlc = @{ '1.5.4'=22; '1.6.2'=24; '1.7.1'=24; '1.8.2'=25; '1.9.x'=29; '1.10.5'=31; '1.11.13'=34; '1.12.14'=36; '1.13.7'=38; '1.14.10'=40; '1.15.4'=43; '1.16.10'=46; '1.17.5.2'=50; '1.18.3.0'=51; '1.19.1.0'=999; 'public'=999 }
# DLC folders Steam's depot data doesn't list (e.g. dlc005 Heavy Cruisers, wallpapers) are allowed up to the cap.
$allFolders = Get-ChildItem $dlcRoot -Directory | Where-Object { $_.Name -match '^dlc\d+_' -and (Get-ChildItem $_.FullName -Filter *.dlc) } | ForEach-Object Name
foreach ($v in $versions) {
    $cap = $maxDlc[$v.branch]
    $v.dlc = @($allFolders | Where-Object {
        $n = [int]([regex]::Match($_, '^dlc(\d+)').Groups[1].Value)
        $n -le $cap -and ((-not $dlcBranches.ContainsKey($_)) -or ($dlcBranches[$_] -contains $v.branch))
    } | Sort-Object)
}
ConvertTo-Json @($versions | ForEach-Object { [pscustomobject]$_ }) -Depth 4 | Set-Content -LiteralPath "$proj\versions.json" -Encoding UTF8
# simple line format for the launcher window: branch|game|codename|krLabel|update|plpc|dlc,dlc,...
$lines = $versions | ForEach-Object { ($_.branch, $_.game, $_.codename, $_.krLabel, $_.update, $_.plpc, ($_.dlc -join ',')) -join '|' }
[IO.File]::WriteAllLines("$proj\versions.txt", [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
foreach ($v in $versions) { "{0,-9} KR {1,-7} {2,2} DLC allowed, newest {3}" -f $v.branch, $v.krLabel, $v.dlc.Count, ($v.dlc | Select-Object -Last 1) }
