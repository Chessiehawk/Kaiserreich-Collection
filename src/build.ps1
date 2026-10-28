# Builds dist\Kaiserreich Collection.exe (everything embedded). Needs only a stock Windows 10 (.NET Framework csc).
$ErrorActionPreference = 'Stop'
$proj = Split-Path $PSScriptRoot -Parent
$out = "$proj\dist"; New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item "$PSScriptRoot\AppInfoParser.cs" "$proj\AppInfoParser.cs" -Force
$exe = "$out\Kaiserreich Collection.exe"
$csc = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
$rsp = @('/nologo', '/target:winexe', '/optimize+', "`"/out:$exe`"", "`"/win32icon:$proj\KaiserreichCollection.ico`"", "`"/win32manifest:$PSScriptRoot\app.manifest`"",'/r:System.Windows.Forms.dll', '/r:System.Drawing.dll')
$count = 0
$skip = @("$proj\src\", "$proj\dist\", "$proj\scenario_saves\", "$proj\.git\", "$proj\docs\")   # ready saves travel as separate save packs (Discord 10 MB limit)
foreach ($f in Get-ChildItem $proj -Recurse -File) {
    if ($skip | Where-Object { $f.FullName.StartsWith($_) }) { continue }
    if ($f.Name -in 'icon_256.png', 'README.md', 'LICENSE', '.gitignore', '.gitattributes') { continue }   # GitHub-only files
    $name = $f.FullName.Substring($proj.Length + 1) -replace '\\', '/'
    $rsp += "`"/resource:$($f.FullName),$name`""; $count++
}
$rsp += "`"$PSScriptRoot\CollectionGui.cs`""; $rsp += "`"$PSScriptRoot\Wasd.cs`""; $rsp += "`"$PSScriptRoot\AssemblyInfo.cs`""
[IO.File]::WriteAllLines("$out\build.rsp", $rsp)
& $csc "@$out\build.rsp"
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item "$out\build.rsp" -Force
Write-Host ("exe: {0} KB, {1} embedded files" -f [math]::Round((Get-Item $exe).Length / 1KB), $count)
