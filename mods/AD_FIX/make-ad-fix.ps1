# Build AD_FIX - the Creature Melee AI scripts patched for Arma Reforger 1.9.
#
# The 1.9 update added a second parameter to StopLoitering; the Workshop mod still
# overrides the old single-parameter version, so the Game module fails to compile
# and the game crashes at startup. This script extracts the installed mod, applies
# the signature fix, packs a standalone addon and installs it next to the mod.
#
#   powershell -ExecutionPolicy Bypass -File mods\AD_FIX\make-ad-fix.ps1
param(
    [string]$GameAddons = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons",
    [string]$GameData = 'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger\addons',
    [string]$ArmaAi = 'C:\Users\Administrator\Documents\Default Project\arma-ai',
    [string]$Out = '',
    [switch]$NoDeploy
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$refpak = Join-Path $repo 'skill\arma-reforger-modding\scripts\refpak.py'
if (-not $Out) { $Out = Join-Path $ArmaAi 'build\ad-fix' }

$src = Join-Path $GameAddons 'CreatureMeleeAI_4FD4A1BD550793F4'
if (-not (Test-Path (Join-Path $src 'data.pak'))) { throw "Creature Melee AI is not installed: $src" }

$work = Join-Path $ArmaAi 'work\ad-fix'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
python $refpak extract (Join-Path $src 'data.pak') $work .c | Out-Null

# --- the 1.9 fix: StopLoitering(bool, SCR_LoiterCustomAnimData = null) ---
$files = @(
    'Scripts\Game\CreatureMeleeAI\Actions\CMAI_PersonThrow.c',
    'Scripts\Game\CreatureMeleeAI\Actions\CMAI_CarryPresentation.c'
)
$oldSig = 'override void StopLoitering(bool terminateFast)'
$newSig = 'override void StopLoitering(bool terminateFast, SCR_LoiterCustomAnimData customAnimData = null)'
$oldSuper = 'super.StopLoitering(terminateFast);'
$newSuper = 'super.StopLoitering(terminateFast, customAnimData);'

foreach ($rel in $files) {
    $path = Join-Path $work $rel
    $text = [IO.File]::ReadAllText($path)
    foreach ($pair in @(@($oldSig, $newSig), @($oldSuper, $newSuper))) {
        $count = ([regex]::Matches($text, [regex]::Escape($pair[0]))).Count
        if ($count -ne 1) { throw "${rel}: expected 1 occurrence of '$($pair[0])', found $count - upstream file changed" }
        $text = $text.Replace($pair[0], $pair[1])
    }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

Copy-Item (Join-Path $PSScriptRoot 'addon.gproj') $work -Force
Copy-Item (Join-Path $PSScriptRoot 'WORKSHOP.md') $work -Force
Remove-Item (Join-Path $work 'resourceDatabase.rdb') -Force -ErrorAction SilentlyContinue
Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Out | Out-Null

$workbench = 'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger Tools\Workbench\ArmaReforgerWorkbenchSteamDiag.exe'
# The mod is mounted only so the project can declare it as a dependency; AD_FIX's
# own copies of the scripts win the same-path lookup.
$p = Start-Process $workbench -PassThru -ArgumentList @(
    '-wbModule=ResourceManager',
    '-addonsDir', "`"$GameData,$GameAddons`"",
    '-gproj', "`"$(Join-Path $work 'addon.gproj')`"",
    '-packAddon', '-packAddonDir', "`"$Out`"",
    '-wbSilent', '-noThrow'
)
$null = $p.WaitForExit(600000)
if (-not (Test-Path (Join-Path $Out 'data.pak'))) { throw 'Pack failed - see the newest ArmaReforgerWorkbench log' }

# Self-check: the packed script must carry the new signature.
$packed = python $refpak cat (Join-Path $Out 'data.pak') '/Scripts/Game/CreatureMeleeAI/Actions/CMAI_PersonThrow.c' | Out-String
if ($packed -notmatch [regex]::Escape($newSig)) { throw 'Packed CMAI_PersonThrow.c does not contain the 1.9 signature' }
Write-Host "Built $Out" -ForegroundColor Green

if (-not $NoDeploy) {
    & (Join-Path $repo 'tools\deploy-mod.ps1') -Build $Out -Id AD_FIX -Guid ADF1000000000001 -Title 'AD_FIX' -NoPreset
}
