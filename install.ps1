# Install or verify the Arma Reforger modding skill for an OpenCode/Claude-style agent.
#   .\install.ps1            copy the skill into ~/.config/opencode/skills
#   .\install.ps1 -Check     print resolved paths and what is missing
param(
    [switch]$Check,
    [string]$SkillDir = (Join-Path $env:USERPROFILE '.config\opencode\skills')
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path $root 'skill\arma-reforger-modding\scripts\find-arma.ps1')

$skillSrc = Join-Path $root 'skill\arma-reforger-modding'
$skillDst = Join-Path $SkillDir 'arma-reforger-modding'

function Row($name, $ok, $detail) {
    $mark = if ($ok) { 'OK  ' } else { 'MISS' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-18} {2}" -f $mark, $name, $detail) -ForegroundColor $color
}

if ($Check) {
    $arma = Find-Arma
    Write-Host 'arma-reforger-ai-toolkit' -ForegroundColor Cyan

    $py = Get-Command python -ErrorAction SilentlyContinue
    $pyVer = if ($py) { (& $py.Source --version 2>&1) } else { 'install Python 3.8+' }
    $wb = if ($arma.Workbench) { $arma.Workbench } else { 'Arma Reforger Tools not found' }
    $game = if ($arma.GameAddons) { $arma.GameAddons } else { 'Arma Reforger not found' }
    $presets = if ($arma.Settings) { $arma.Settings } else { 'ReforgerGameSettings.conf not found' }

    Row 'python' ($null -ne $py) $pyVer
    Row 'workbench' ($null -ne $arma.Workbench) $wb
    Row 'game data' ($null -ne $arma.GameAddons) $game
    Row 'addons folder' (Test-Path $arma.UserAddons) $arma.UserAddons
    Row 'presets' ($null -ne $arma.Settings) $presets
    Row 'skill installed' (Test-Path $skillDst) $skillDst
    exit 0
}

New-Item -ItemType Directory -Force $SkillDir | Out-Null
if (Test-Path $skillDst) { Remove-Item $skillDst -Recurse -Force }
Copy-Item $skillSrc $skillDst -Recurse
Write-Host "Installed skill -> $skillDst" -ForegroundColor Green
Write-Host "Skill id: arma-reforger-modding. Restart or reload your agent if it does not appear." -ForegroundColor DarkGray
