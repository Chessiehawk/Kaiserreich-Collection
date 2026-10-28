# Test helper: runs the engine with the given arguments and appends timestamped output to a log file.
param([string]$LogFile, [Parameter(ValueFromRemainingArguments = $true)] $EngineArgs)
$engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'Kaiserreich-Collection.ps1'
"$(Get-Date -Format HH:mm:ss) runner started: $($EngineArgs -join ' ')" | Out-File -FilePath $LogFile -Append -Encoding utf8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine @EngineArgs *>&1 | ForEach-Object { "$(Get-Date -Format HH:mm:ss) $_" | Out-File -FilePath $LogFile -Append -Encoding utf8 }
"$(Get-Date -Format HH:mm:ss) runner finished, exit $LASTEXITCODE" | Out-File -FilePath $LogFile -Append -Encoding utf8
