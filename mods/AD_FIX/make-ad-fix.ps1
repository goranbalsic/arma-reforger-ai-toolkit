# Build AD_FIX - the Arma Reforger 1.9 compatibility patch for RHS - Status Quo.
#
# 1.9 changed two APIs RHS still overrides/reads: SetAuthor gained a bool, and
# SCR_WheelSlotInfo's protected field became a getter. The Game module fails to
# compile until they are updated. This extracts the files, patches them, packs
# AD_FIX and installs it. The build dependency on RHS is stripped from the
# published addon.gproj so the Workshop item carries no dependency entry.
#
#   powershell -ExecutionPolicy Bypass -File mods\AD_FIX\make-ad-fix.ps1
param(
    [string]$GameAddons = 'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger\addons',
    [string]$UserAddons = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons",
    [string]$ArmaAi = 'C:\Users\Administrator\Documents\Default Project\arma-ai',
    [string]$Out = '',
    [switch]$NoDeploy
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$refpak = Join-Path $repo 'skill\arma-reforger-modding\scripts\refpak.py'
$rhsPak = Join-Path $UserAddons 'RHS-StatusQuo_595F2BF2F44836FB\data.pak'
if (-not (Test-Path $rhsPak)) { throw "RHS - Status Quo is not installed: $rhsPak" }
if (-not $Out) { $Out = Join-Path $ArmaAi 'build\ad-fix' }

# One entry per 1.9 break; each must match exactly once in the installed file.
$patches = @(
    @{
        rel = 'Scripts/Game/Editor/Components/EditableEntity/RHS_CAS_EditableEntityComponent.c'
        old = "override void SetAuthor(int playerID)`r`n`t{`r`n`t`tsuper.SetAuthor(playerID);"
        new = "override void SetAuthor(int playerID, bool isGM = false)`r`n`t{`r`n`t`tsuper.SetAuthor(playerID, isGM);"
    },
    @{
        rel = 'Scripts/Game/Vehicle/RHS_DestructionTireComponent.c'
        old = 'return m_iWheelIndex;'
        new = 'return GetWheelIndex();'
    }
)

$work = Join-Path $ArmaAi 'work\ad-fix'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
foreach ($patch in $patches) {
    $dst = Join-Path $work $patch.rel.Replace('/', '\')
    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
    $raw = (python $refpak cat $rhsPak "/$($patch.rel)") -join "`r`n"
    [IO.File]::WriteAllText($dst, $raw, (New-Object Text.UTF8Encoding($false)))

    $text = [IO.File]::ReadAllText($dst)
    $old = $patch.old
    $new = $patch.new
    if ($text -notmatch "`r`n") { $old = $old -replace "`r`n", "`n"; $new = $new -replace "`r`n", "`n" }
    $count = ([regex]::Matches($text, [regex]::Escape($old))).Count
    if ($count -ne 1) { throw "$($patch.rel): expected 1 match, found $count - upstream may already be fixed" }
    [IO.File]::WriteAllText($dst, $text.Replace($old, $new), (New-Object Text.UTF8Encoding($false)))
}

Copy-Item (Join-Path $PSScriptRoot 'addon.gproj') $work -Force
Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $Out | Out-Null

$workbench = 'C:\Program Files (x86)\Steam\steamapps\common\Arma Reforger Tools\Workbench\ArmaReforgerWorkbenchSteamDiag.exe'
$p = Start-Process $workbench -PassThru -ArgumentList @(
    '-wbModule=ResourceManager',
    '-addonsDir', "`"$GameAddons,$UserAddons`"",
    '-gproj', "`"$(Join-Path $work 'addon.gproj')`"",
    '-packAddon', '-packAddonDir', "`"$Out`"",
    '-wbSilent', '-noThrow'
)
$null = $p.WaitForExit(600000)
if (-not (Test-Path (Join-Path $Out 'data.pak'))) { throw 'Pack failed - see the newest ArmaReforgerWorkbench log' }

# Self-check: every patched line is in the pak.
foreach ($patch in $patches) {
    $packed = python $refpak cat (Join-Path $Out 'data.pak') "/$($patch.rel)" | Out-String
    $marker = ($patch.new -split "`r?`n")[0]
    if ($packed -notmatch [regex]::Escape($marker)) { throw "Packed $($patch.rel) is missing: $marker" }
}

# The build needs RHS mounted, but the published item must not declare a
# dependency (1.9's Workshop download UI throws on our dependency entries).
$gproj = Join-Path $Out 'addon.gproj'
$g = [IO.File]::ReadAllText($gproj) -replace '\s*"595F2BF2F44836FB"', ''
[IO.File]::WriteAllText($gproj, $g, (New-Object Text.UTF8Encoding($false)))
Write-Host "Built $Out" -ForegroundColor Green

if (-not $NoDeploy) {
    & (Join-Path $repo 'tools\deploy-mod.ps1') -Build $Out -Id AD_FIX -Guid ADF1000000000001 -Title 'AD_FIX' -NoPreset
}
