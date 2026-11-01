# Restore the vanilla resource GUIDs in the installed addon's resourceDatabase.rdb.
#
# Workbench regenerates that file on every publish and writes null GUIDs for
# prefabs authored outside the editor, which makes the pak inert in game. This
# stamps the correct GUIDs back in. Run it after the Workshop updates the mod.
param(
    [string]$AddonGuid,
    [string]$MapPath = (Join-Path $PSScriptRoot '..\context\ussr-guid-map.json'),
    [string]$AddonsRoot = (Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\addons')
)

$ErrorActionPreference = 'Stop'
if (-not $AddonGuid) { throw 'Pass -AddonGuid (the 16-hex suffix of the addon folder)' }
if (Get-Process -Name 'ArmaReforgerSteam' -ErrorAction SilentlyContinue) {
    throw 'Close Arma Reforger first.'
}

$addon = Get-ChildItem $AddonsRoot -Directory | Where-Object { $_.Name -like "*_$AddonGuid" } | Select-Object -First 1
if (-not $addon) { throw "Addon folder not found in $AddonsRoot" }
$rdb = Join-Path $addon.FullName 'resourceDatabase.rdb'
if (-not (Test-Path $rdb)) { throw "No resourceDatabase.rdb in $($addon.FullName)" }
if (-not (Test-Path $MapPath)) { throw "GUID map not found: $MapPath" }

$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) { throw 'python not found' }

$patch = Join-Path $PSScriptRoot 'patch-rdb.py'
& $py $patch --rdb $rdb --map $MapPath
if ($LASTEXITCODE -ne 0) { throw 'patching failed' }
Write-Host "Stamped GUIDs into $rdb" -ForegroundColor Green
