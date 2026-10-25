# Publish (or update) an Arma Reforger addon, as headlessly as the platform allows.
#
#   .\publish-addon.ps1 -Project <dir>                  # first publish: opens the GUI once
#   .\publish-addon.ps1 -Auto -PublishDir <dir> -Version 1.0.1 [-ChangeNote "fix"]
#
# Why there is still one GUI step: Workbench authenticates against the Bohemia
# backend with a session tied to your linked Game Identity. Current builds have no
# command-line login (no -wbBackendLogin) and no token file we can seed, so the
# account link must be created once by a human. After that the session is cached
# and every upload runs headless.
#
# This script never asks for, stores or transmits your password.
param(
    [string]$Project = '',
    [string]$PublishDir = '',
    [string]$Version = '',
    [string]$ChangeNote = '',
    [string]$PreviewImage = '',
    [switch]$Auto,
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skill\arma-reforger-modding\scripts\find-arma.ps1')
$arma = Find-Arma
if (-not $arma.Workbench) { throw 'Workbench not found (Arma Reforger Tools)' }
if (-not $arma.GameAddons) { throw 'Game addons folder not found' }

$logsRoot = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforgerWorkbench\logs'

function Get-LatestLog {
    Get-ChildItem $logsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Show-Log($log) {
    if (-not $log) { return }
    Select-String -Path (Join-Path $log.FullName 'console.log') -ErrorAction SilentlyContinue `
        -Pattern 'Publish Addon|BACKEND|Backend|WorkshopApi|login|Login|link|Link' |
        Select-Object -Last 20 | ForEach-Object { Write-Host "  $($_.Line.Trim())" -ForegroundColor Yellow }
}

function Start-WorkbenchGui([string]$gproj) {
    Start-Process -FilePath $arma.Workbench -ArgumentList @('-gproj', "`"$gproj`"") `
        -WorkingDirectory (Split-Path $arma.GameAddons -Parent)
}

# ── first publish: open the GUI once ─────────────────────────────────────────
if (-not $Auto) {
    if (-not $Project) { throw 'Pass -Project <folder with addon.gproj>, or -Auto -PublishDir <packed folder>' }
    $Project = (Resolve-Path $Project).Path
    $gproj = Join-Path $Project 'addon.gproj'
    if (-not (Test-Path $gproj)) { throw "No addon.gproj in $Project" }
    if (Get-Process -Name 'ArmaReforgerWorkbenchSteamDiag', 'ArmaReforgerSteam' -ErrorAction SilentlyContinue) {
        throw 'Close Workbench / Arma Reforger first.'
    }
    Start-WorkbenchGui $gproj
    Write-Host @"
Workbench is opening your project. This is the one-time account link:

  1. Resource Manager -> Publish.
  2. Sign in with your Bohemia Interactive account (Workbench's own dialog).
     Link your Game Identity when asked.
  3. Fill Title / Description / Tags, choose the preview image, publish.

After this succeeds, `-Auto` uploads new builds with no GUI at all.
"@ -ForegroundColor Cyan
    exit 0
}

# ── headless upload ──────────────────────────────────────────────────────────
if (-not $PublishDir -or -not (Test-Path $PublishDir)) { throw 'Pass -PublishDir with a packed addon folder' }
$PublishDir = (Resolve-Path $PublishDir).Path
if (-not (Test-Path (Join-Path $PublishDir 'data.pak'))) { throw "No data.pak in $PublishDir" }
if (-not $Version) { throw 'Pass -Version (e.g. 1.0.1)' }
if ($PreviewImage -and -not (Test-Path $PreviewImage)) { throw "Preview image not found: $PreviewImage" }

if (Get-Process -Name 'ArmaReforgerSteam' -ErrorAction SilentlyContinue) {
    throw 'Arma Reforger is running. Close it: Workbench hangs at startup while the game owns the Steam identity.'
}

$before = Get-LatestLog
$args = @(
    '-wbModule=ResourceManager',
    '-addonsDir', "`"$($arma.GameAddons)`"",
    '-publishAddon',
    '-publishAddonDir', "`"$PublishDir`"",
    '-publishAddonVersion', $Version,
    '-wbSilent', '-noThrow'
)
if ($ChangeNote) { $args += @('-publishAddonChangeNote', "`"$ChangeNote`"") }
if ($PreviewImage) { $args += @('-publishAddonPreviewImage', "`"$((Resolve-Path $PreviewImage).Path)`"") }

Write-Host "Headless publish $Version from $PublishDir" -ForegroundColor Cyan
$p = Start-Process -FilePath $arma.Workbench -PassThru -ArgumentList $args
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    Write-Host "Workbench did not finish in $TimeoutSeconds s - killing it." -ForegroundColor Yellow
    try { $p.Kill() } catch { }
    Start-Sleep -Seconds 2
}
$p.Refresh()
Write-Host "Workbench exit: $($p.ExitCode) (0 is not proof either way)" -ForegroundColor DarkGray

$log = Get-LatestLog
$text = if ($log) { Get-Content (Join-Path $log.FullName 'console.log') -Raw -ErrorAction SilentlyContinue } else { '' }

if ($text -match 'not linked with Bohemia Account') {
    Write-Host 'The account is not linked yet - a human sign-in is required exactly once.' -ForegroundColor Yellow
    Show-Log $log
    if ($Project) {
        Start-WorkbenchGui (Join-Path (Resolve-Path $Project).Path 'addon.gproj')
        Write-Host 'Workbench opened: sign in, then run this command again.' -ForegroundColor Cyan
    }
    else {
        Write-Host 'Run: .\publish-addon.ps1 -Project <dir>   (opens the sign-in)' -ForegroundColor Cyan
    }
    exit 2
}

if ($text -match 'Invalid login credentials') {
    Write-Host 'Backend rejected the cached session. Sign in again with -Project.' -ForegroundColor Red
    Show-Log $log
    exit 3
}

if ($text -match 'Backend is not enabled|authentication timeout|backend initialization') {
    Write-Host 'Backend not ready (is Steam running and online?).' -ForegroundColor Red
    Show-Log $log
    exit 4
}

if ($text -match 'WorkshopApi.*\(E\)|BACKEND.*\(E\)') {
    Write-Host 'Backend reported errors - see below.' -ForegroundColor Red
    Show-Log $log
    exit 1
}

Write-Host 'No backend errors reported. Verify the item on the Workshop page.' -ForegroundColor Green
if ($log) { Show-Log $log }
exit 0
