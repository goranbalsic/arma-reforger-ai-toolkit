# One-command build + deploy for a same-path override addon.
#
#   .\build-mod.ps1                 # pack, stamp vanilla GUIDs, install
#   .\build-mod.ps1 -Publish 1.0.5  # ... and upload headlessly
#
# Why stamping: Workbench regenerates resourceDatabase.rdb on every pack/publish
# and writes NULL GUIDs for prefabs that were not registered inside the editor.
# A pak whose GUIDs are null binds to nothing, so the addon loads and does
# nothing. This stamps the vanilla GUIDs back in after packing, which is what
# makes same-path overrides actually take effect.
param(
    [string]$Project,
    [string]$Out,
    [string]$Id,
    [string]$Guid,
    [string]$Title,
    [string]$GuidMap,
    [string[]]$ExtraAddonsDir,
    [string]$Publish,          # version to publish, e.g. 1.0.5 (optional)
    [string]$ChangeNote = 'Rebuild',
    [switch]$SkipPack
)

$ErrorActionPreference = 'Stop'
if (-not $Id -or -not $Guid -or -not $Title) { throw 'Pass -Id, -Guid and -Title' }
$root = Split-Path $PSScriptRoot -Parent
function Res($p, $default) { if ($p) { $p } else { Join-Path $root $default } }

$Project = Res $Project 'work\ussr-mod'
$Out = Res $Out 'build\ussr-modern'
$GuidMap = Res $GuidMap 'context\ussr-guid-map.json'
if (-not $ExtraAddonsDir -or $ExtraAddonsDir.Count -eq 0) {
    $deps = Join-Path $root 'build\deps'
    if (Test-Path $deps) { $ExtraAddonsDir = @($deps) }
}

$python = (Get-Command python -ErrorAction Stop).Source
$packScript = Join-Path $root 'skill\arma-reforger-modding\scripts\pack-addon.ps1'
$patchScript = Join-Path $root 'tools\patch-rdb.py'
$publishScript = Join-Path $root 'tools\publish-addon.ps1'

# 1. metas + pack
if (-not $SkipPack) {
    Write-Host '== write .meta (vanilla GUIDs) ==' -ForegroundColor Cyan
    & $python (Join-Path $root 'tools\gen-metas.py') --project $Project --map $GuidMap
    if ($LASTEXITCODE -ne 0) { throw 'meta generation failed' }

    Write-Host '== pack ==' -ForegroundColor Cyan
    $packArgs = @('-Project', $Project, '-Out', $Out)
    if ($ExtraAddonsDir) { $packArgs += @('-ExtraAddonsDir', ($ExtraAddonsDir -join ',')) }
    & powershell -ExecutionPolicy Bypass -File $packScript @packArgs
    if ($LASTEXITCODE -ne 0) { throw 'pack failed' }
}

$rdb = Join-Path $Out 'resourceDatabase.rdb'
if (-not (Test-Path $rdb)) { throw "No resourceDatabase.rdb in $Out" }

# 2. stamp GUIDs into the build
Write-Host '== stamp build GUIDs ==' -ForegroundColor Cyan
& $python $patchScript --rdb $rdb --map $GuidMap
if ($LASTEXITCODE -ne 0) { throw 'stamping the build failed' }

# 3. install locally (only real addon files - no publish leftovers)
$addons = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\addons'
$dest = Join-Path $addons "${Id}_${Guid}"
New-Item -ItemType Directory -Force $dest | Out-Null
foreach ($f in 'addon.gproj', 'data.pak', 'resourceDatabase.rdb', 'meta') {
    $src = Join-Path $Out $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $dest $f) -Force }
}
Write-Host "== installed -> $dest ==" -ForegroundColor Green

# 4. re-stamp the installed copy (copy is byte-identical, but be explicit)
& $python $patchScript --rdb (Join-Path $dest 'resourceDatabase.rdb') --map $GuidMap
if ($LASTEXITCODE -ne 0) { throw 'stamping the installed copy failed' }

# 5. optional headless publish
if ($Publish) {
    Write-Host "== publish $Publish ==" -ForegroundColor Cyan
    & powershell -ExecutionPolicy Bypass -File $publishScript -Auto -ModId $Id -Project $Project `
        -PublishDir $Out -Version $Publish -ChangeNote $ChangeNote `
        -ExtraAddonsDir ($ExtraAddonsDir -join ',')
    if ($LASTEXITCODE -ne 0) { Write-Host "publish returned $LASTEXITCODE" -ForegroundColor Yellow }
}

Write-Host '== done ==' -ForegroundColor Green
Write-Host 'Launch with Play AI Test.cmd (the launcher preset cannot hold unpublished mods).' -ForegroundColor DarkGray
