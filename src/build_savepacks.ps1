# Builds the files to share with friends (each under Discord's 10 MB) in dist\discord\:
#   Kaiserreich Collection.exe                  - the launcher (sets itself up on first start)
#   ACW-saves-1-of-2.7z / ACW-saves-2-of-2.7z   - the custom game's ready saves, as plain data files: leave them in
#                                                 Downloads (or next to the launcher) and the launcher takes them in
#                                                 by itself. (Not wrapped in an exe: a small exe carrying a big blob
#                                                 is what antivirus "dropper" guesses look for.)
# The packs are solid 7z archives of the ready saves (project scenario_saves\acw_macarthur\<branch>\*.hoi4.gz),
# split old / new Kaiserreich so each stays small. Run src\build.ps1 first (the launcher exe).
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
$out = "$proj\dist\discord"; New-Item -ItemType Directory -Force $out | Out-Null
$7z = if (Test-Path "$proj\7zip\7z.exe") { "$proj\7zip\7z.exe" } else { throw '7zip\7z.exe missing' }
$versions = Get-Content "$proj\versions.json" -Raw | ConvertFrom-Json

# unpack the ready saves (gz) into a work folder, in version order
$work = Join-Path $env:TEMP 'krc_savepacks'; if (Test-Path $work) { Remove-Item $work -Recurse -Force }; New-Item -ItemType Directory $work | Out-Null
$saves = @()
foreach ($v in $versions) {
    $gz = Get-ChildItem "$proj\scenario_saves\acw_macarthur\$($v.branch)" -Filter '*.hoi4.gz' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gz) { continue }
    $to = Join-Path $work ($gz.Name -replace '\.gz$', '')
    $in = [IO.File]::OpenRead($gz.FullName); $o = [IO.File]::Create($to)
    try { (New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)).CopyTo($o) } finally { $o.Dispose(); $in.Dispose() }
    $saves += $to
}
$half = [math]::Ceiling($saves.Count / 2)
$parts = @(@($saves[0..($half - 1)]), @($saves[$half..($saves.Count - 1)]))

Get-ChildItem $out -File | Remove-Item -Force
for ($i = 0; $i -lt 2; $i++) {
    $name = "ACW-saves-$($i + 1)-of-2"
    $list = "$work\$name.txt"; $parts[$i] | Set-Content $list -Encoding ASCII
    & $7z a -t7z -mx=9 -m0=lzma2:d=512m:fb=273:mc=1000 -ms=on -mmt=2 "$out\$name.7z" "@$list" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7z failed for $name" }
}
Copy-Item "$proj\dist\Kaiserreich Collection.exe" "$out\Kaiserreich Collection.exe" -Force
Remove-Item $work -Recurse -Force
Get-ChildItem $out -File | ForEach-Object { "{0,-28} {1,5:N1} MB {2}" -f $_.Name, ($_.Length / 1MB), $(if ($_.Length -lt 9.5MB) { '' } else { 'TOO BIG FOR DISCORD' }) }
