# Custom games ("scenarios"): ready-made game-rule presets the launcher puts into the game for you.
# For every version, only the rules/options that exist in THAT Kaiserreich release are used, and a scenario is
# offered only if all its "must" rules exist - or, without them, if a ready save was made for that version by
# playing it out (scenario_saves\<id>\<branch>, "save only"). Writes ..\scenarios.json (engine) and ..\scenarios.txt (window).
# Needs the Kaiserreich downloads present in the store (D:\KaiserreichCollection\mods) when it runs.
$ErrorActionPreference = 'Stop'
$proj  = Split-Path $PSScriptRoot -Parent
$store = if (Test-Path 'D:\KaiserreichCollection\mods') { 'D:\KaiserreichCollection' } else { throw 'Kaiserreich downloads not found' }
$versions = Get-Content -LiteralPath "$proj\versions.json" -Raw | ConvertFrom-Json

# rule = game rule, option = choice; must = the scenario only exists where this rule/option does
$scenarios = @(
  [ordered]@{
    id = 'acw_macarthur'; title = 'ACW: MacArthur'; preset = 'American Civil War - MacArthur'; picture = 'img/scn_acw_macarthur.jpg'; save = 'ACW_MacArthur_KR_'
    about = 'Second American Civil War with MacArthur. Canada stays out, Mexico (Sinarquistas) can join in, war goals and factions free. Every version also comes with a ready save as MacArthur''s USA around the time the country breaks apart (Load Game > ACW_MacArthur_KR_<version>).'
    rules = @(
      @{ rule = 'USA_civil_war';          option = 'USA_CIVIL_WAR_FOUR_SIDES'; must = $true }   # Civil War with MacArthur
      # Canada stays out of it
      @{ rule = 'CAN_acw_intervene';      option = 'CAN_ACW_INTERVENE_NO' }
      @{ rule = 'CAN_acw_support';        option = 'CAN_ACW_SUPPORT_NONE' }
      @{ rule = 'CAN_acw_alaska';         option = 'CAN_ACW_ALASKA_NO_INTERVENE' }
      @{ rule = 'CAN_acw_new_england';    option = 'CAN_ACW_NEW_ENGLAND_NOT_TAKE' }
      # Mexico can get involved: the Sinarquistas get the Reconquista decisions during the civil war
      @{ rule = 'MEX_path';               option = 'MEX_PATH_NATPOP' }
      @{ rule = 'MEX_post_assassination'; option = 'MEX_POST_ASSASSINATION_NATIONAL_POPULIST_SINARQUISTA' }
      # war goals and factions always free (faction rules only exist in some releases)
      @{ rule = 'allow_wargoals';         option = 'ALWAYS_FREE' }
      @{ rule = 'allow_create_faction';   option = 'FREE' }
      @{ rule = 'allow_join_faction';     option = 'FREE' }
      @{ rule = 'allow_leave_faction';    option = 'ALLOWED' }
      @{ rule = 'faction_button_options'; option = 'BUTTON_PRESENT' }
    )
  }
)

function Get-RuleOptions([string]$modDir) {
    $map = @{}
    foreach ($f in Get-ChildItem "$modDir\common\game_rules" -File -ErrorAction SilentlyContinue) {
        $t = Get-Content -LiteralPath $f.FullName -Raw
        foreach ($m in [regex]::Matches($t, '(?ms)^([A-Za-z0-9_]+)\s*=\s*\{(.*?)^\}')) {
            $map[$m.Groups[1].Value] = @([regex]::Matches($m.Groups[2].Value, '(?ms)(?:option|default)\s*=\s*\{\s*name\s*=\s*"?([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value })
        }
    }
    $map
}
function Get-SaveVersion([string]$modDir, [string]$gameDir) {
    foreach ($d in "$modDir\common\defines", "$gameDir\common\defines") {
        $m = Get-ChildItem $d -Filter *.lua -ErrorAction SilentlyContinue | Select-String -Pattern 'SAVE_VERSION\s*=\s*(\d+)' | Select-Object -First 1
        if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    }
    0
}

$json = @(); $lines = @()
foreach ($s in $scenarios) {
    $per = [ordered]@{}
    foreach ($v in $versions) {
        $modDir = "$store\mods\Kaiserreich_$($v.krLabel)"; $gameDir = "$store\games\$($v.branch)"
        if (-not (Test-Path "$modDir\descriptor.mod")) { Write-Host "  $($v.branch): Kaiserreich $($v.krLabel) not downloaded - skipped"; continue }
        $opts = Get-RuleOptions $modDir
        $ok = $true; $use = [ordered]@{}
        foreach ($r in $s.rules) {
            $has = $opts.ContainsKey($r.rule) -and ($opts[$r.rule] -contains $r.option)
            if ($has) { $use[$r.rule] = $r.option } elseif ($r.must) { $ok = $false }
        }
        # a ready-made save shipped for this version (scenario_saves\<id>\<branch>\*.hoi4.gz)
        $hasSave = [bool](Get-ChildItem "$proj\scenario_saves\$($s.id)\$($v.branch)" -Filter '*.hoi4.gz' -ErrorAction SilentlyContinue)
        if ($ok) { $per[$v.branch] = [ordered]@{ save_version = (Get-SaveVersion $modDir $gameDir); rules = $use; has_save = $hasSave } }
        elseif ($hasSave) { $per[$v.branch] = [ordered]@{ save_version = (Get-SaveVersion $modDir $gameDir); rules = $use; has_save = $true; save_only = $true } }   # no rule for it, but a save made by playing it out
        "{0,-14} {1,-9} KR {2,-7} {3}" -f $s.id, $v.branch, $v.krLabel, $(if ($ok) { "$($use.Count) rules, save_version $($per[$v.branch].save_version)" + $(if ($hasSave) { ', ready save' } else { '' }) } elseif ($hasSave) { 'ready save only (no rule for it)' } else { 'not available' })
    }
    $json += [ordered]@{ id = $s.id; title = $s.title; preset = $s.preset; picture = $s.picture; about = $s.about; save = $s.save; versions = $per }
    # window line: id|title|preset|picture|branch,branch,...|about|save-only branches|save name prefix|branches with a save
    $saveOnly = @($per.Keys | Where-Object { $per[$_].save_only }) -join ','
    $withSave = @($per.Keys | Where-Object { $per[$_].has_save }) -join ','
    $lines += ($s.id, $s.title, $s.preset, $s.picture, (@($per.Keys) -join ','), $s.about, $saveOnly, $s.save, $withSave) -join '|'
}
ConvertTo-Json @($json) -Depth 6 | Set-Content -LiteralPath "$proj\scenarios.json" -Encoding UTF8
[IO.File]::WriteAllLines("$proj\scenarios.txt", [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
