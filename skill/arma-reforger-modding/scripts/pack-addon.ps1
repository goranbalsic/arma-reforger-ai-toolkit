# Pack an Arma Reforger project into a distributable addon.
# Workbench exits 0 even when packing fails, so this validates the output files
# and the freshest log instead of trusting the exit code.
#
#   .\pack-addon.ps1 -Project <dir> -Out <dir> [-ExtraAddonsDir <dir1>,<dir2>]
#
# ExtraAddonsDir is how you mount dependency addons at build time (base game is
# always mounted). Point it at a folder containing only the addons you need.
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Workbench,
    [string]$GameAddons,
    [string[]]$ExtraAddonsDir = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'find-arma.ps1')
if (-not $Workbench -or -not $GameAddons) {
    $arma = Find-Arma
    if (-not $Workbench) { $Workbench = $arma.Workbench }
    if (-not $GameAddons) { $GameAddons = $arma.GameAddons }
}

$Project = (Resolve-Path $Project).Path
$gproj = Join-Path $Project 'addon.gproj'
if (-not (Test-Path $gproj)) { throw "No addon.gproj in $Project" }
if (-not $Workbench -or -not (Test-Path $Workbench)) { throw 'Workbench executable not found. Pass -Workbench.' }
if (-not $GameAddons -or -not (Test-Path $GameAddons)) { throw 'Game addons folder not found. Pass -GameAddons.' }

New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

$addonDirs = @($GameAddons) + @($ExtraAddonsDir | Where-Object { $_ })
$addonsArg = ($addonDirs | ForEach-Object { (Resolve-Path $_).Path }) -join ','

$logsRoot = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforgerWorkbench\logs'
$before = Get-ChildItem $logsRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

Write-Host "Packing $Project -> $Out" -ForegroundColor Cyan
$p = Start-Process -FilePath $Workbench -PassThru -ArgumentList @(
    '-wbModule=ResourceManager',
    '-addonsDir', "`"$addonsArg`"",
    '-gproj', "`"$gproj`"",
    '-packAddon',
    '-packAddonDir', "`"$Out`"",
    '-wbSilent',
    '-noThrow'
)
$null = $p.WaitForExit(600000)
$p.Refresh()
Write-Host "Workbench exit code: $($p.ExitCode) (always 0; not a success signal)" -ForegroundColor DarkGray

$expected = 'data.pak', 'addon.gproj', 'resourceDatabase.rdb'
$missing = $expected | Where-Object { -not (Test-Path (Join-Path $Out $_)) }
if ($missing) {
    Write-Host "FAILED: missing $($missing -join ', ')" -ForegroundColor Red
}
else {
    $pak = Join-Path $Out 'data.pak'
    $len = (Get-Item $pak).Length
    $size = if ($len -ge 1MB) { '{0:N2} MB' -f ($len / 1MB) } else { '{0:N1} KB' -f ($len / 1KB) }
    Write-Host "OK: $pak ($size)" -ForegroundColor Green
}

# compile errors are only in the log
$log = Get-ChildItem $logsRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log -and (!$before -or $log.FullName -ne $before.FullName)) {
    $errors = Select-String -Path (Join-Path $log.FullName 'console.log') `
        -Pattern "Can't compile|COMPILE ERROR|Cannot initialize game project|not found" -ErrorAction SilentlyContinue
    if ($errors) {
        Write-Host "Log reports problems ($($log.FullName)):" -ForegroundColor Yellow
        $errors | Select-Object -First 20 | ForEach-Object { Write-Host "  $($_.Line.Trim())" -ForegroundColor Yellow }
    }
}

if ($missing) { exit 1 }
