# Packs a built launcher (dist\Kaiserreich Collection.exe, from build.ps1) into the release downloads:
#   dist\Kaiserreich-Collection-<ver>.zip            everything in one zip (GitHub)
#   dist\discord\Kaiserreich Collection <ver> - launcher.zip   + the two ACW-saves .7z = each under Discord's 10 MB
# Zip entries use "/" (the .NET Framework's CreateFromDirectory writes "\", which some unzip tools mangle).
$ErrorActionPreference = 'Stop'
$proj = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$exe = "$proj\dist\Kaiserreich Collection.exe"
$v = (Get-Item $exe).VersionInfo; $ver = "$($v.FileMajorPart).$($v.FileMinorPart).$($v.FileBuildPart)"
$packs = "$proj\dist\discord\ACW-saves-1-of-2.7z", "$proj\dist\discord\ACW-saves-2-of-2.7z"
$template = [IO.File]::ReadAllText("$PSScriptRoot\README-zip.txt").Replace('__VERSION__', $ver)
$zipSaves = @"
Its ready saves are the two files "ACW-saves-1-of-2.7z" and
"ACW-saves-2-of-2.7z" in this zip - keep them in the same folder as the
launcher; it finds them itself, no unpacking needed.
"@
$discordSaves = @"
Its ready saves are the two files "ACW-saves-1-of-2.7z" and
"ACW-saves-2-of-2.7z" that came with this zip - leave them in your Downloads
folder (or next to the launcher); it finds them itself, no unpacking needed.
"@
$discordStep0 = "0. Download all 3 files (this zip + the two ACW-saves .7z files) into your`n   Downloads folder.`n"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-Zip([string]$zip, [string]$readme, [string[]]$extra) {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    $fs = [IO.File]::Open($zip, 'CreateNew'); $a = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    $root = "Kaiserreich Collection $ver/"
    $e = $a.CreateEntry($root + 'README.txt'); $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding($false))); $w.Write($readme.Replace("`r`n", "`n").Replace("`n", "`r`n")); $w.Dispose()
    foreach ($f in @($exe) + $extra) { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($a, $f, $root + (Split-Path $f -Leaf), [IO.Compression.CompressionLevel]::Optimal) | Out-Null }
    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($a, "$proj\LICENSE", $root + 'LICENSE.txt', [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    $a.Dispose(); $fs.Dispose()
    '{0,6:N1} MB  {1}' -f ((Get-Item -LiteralPath $zip).Length / 1MB), $zip
}
New-Zip "$proj\dist\Kaiserreich-Collection-$ver.zip" ($template.Replace('__STEP0__', '').Replace('__SAVES__', $zipSaves)) $packs
Copy-Item $exe "$proj\dist\discord\Kaiserreich Collection.exe" -Force
New-Zip "$proj\dist\discord\Kaiserreich Collection $ver - launcher.zip" ($template.Replace('__STEP0__', $discordStep0).Replace('__SAVES__', $discordSaves)) @()
foreach ($p in $packs) { '{0,6:N1} MB  {1}' -f ((Get-Item $p).Length / 1MB), $p }
