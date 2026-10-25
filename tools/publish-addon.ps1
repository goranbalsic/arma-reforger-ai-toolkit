# Publish a new addon, or push headless updates of an already-published one.
#
#   .\publish-addon.ps1 -Project <dir> [-PublishDir <packed>] [-PreviewImage <png>]
#       First publish. Pre-fills the Workbench publish dialog (bundle dir, preview
#       image) and opens it. Title/Summary/Description are the only fields typed by
#       hand, because the Workshop API requires a summary and no CLI switch sets it.
#
#   .\publish-addon.ps1 -Auto -ModId <id> -PublishDir <packed> -Version 1.0.1 [-ChangeNote "x"] [-ExtraAddonsDir <dir>]
#       Headless update of an existing item. Workbench must be logged in (it is,
#       once the first publish succeeded) and the game must be closed.
#
# Never asks for, stores or transmits a password. The only credential is
# Workbench's own cached session.
param(
    [string]$Project = '',
    [string]$PublishDir = '',
    [string]$PreviewImage = '',
    [string]$ModId = '',
    [string]$Version = '',
    [string]$ChangeNote = '',
    [string[]]$ExtraAddonsDir = @(),
    [switch]$Auto,
    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skill\arma-reforger-modding\scripts\find-arma.ps1')
$arma = Find-Arma
if (-not $arma.Workbench) { throw 'Workbench not found (Arma Reforger Tools)' }
if (-not $arma.GameAddons) { throw 'Game addons folder not found' }

$freeGb = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
if ($freeGb -lt 3) {
    throw ('Only {0:N1} GB RAM free. Workbench needs about 3 GB to publish - close games and browsers first.' -f $freeGb)
}

$logsRoot = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforgerWorkbench\logs'
$regRoot = 'HKCU:\Software\Bohemia Interactive\Arma Reforger Workbench\Workbench\publish'

function Get-LatestLog {
    Get-ChildItem $logsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Write-LogLines($log) {
    if (-not $log) { return }
    Select-String -Path (Join-Path $log.FullName 'console.log') -ErrorAction SilentlyContinue `
        -Pattern 'Publish Addon|BACKEND|WorkshopApi|link|Link|login|Login' |
        Select-Object -Last 15 | ForEach-Object { Write-Host "  $($_.Line.Trim())" -ForegroundColor Yellow }
}

function Get-ProjectId([string]$gproj) {
    $m = [regex]::Match((Get-Content $gproj -Raw), '^\s*ID\s+"([^"]+)"', 'Multiline')
    if (-not $m.Success) { throw "No ID in $gproj" }
    $m.Groups[1].Value
}

# ── first publish: pre-fill the dialog and open it ───────────────────────────
if (-not $Auto) {
    if (-not $Project) { throw 'Pass -Project <folder with addon.gproj>' }
    $Project = (Resolve-Path $Project).Path
    $gproj = Join-Path $Project 'addon.gproj'
    if (-not (Test-Path $gproj)) { throw "No addon.gproj in $Project" }
    if (Get-Process -Name 'ArmaReforgerWorkbenchSteamDiag', 'ArmaReforgerSteam' -ErrorAction SilentlyContinue) {
        throw 'Close Workbench / Arma Reforger first.'
    }

    $modId = if ($ModId) { $ModId } else { Get-ProjectId $gproj }

    # The publish dialog remembers its paths in the registry; seed them so the
    # bundle and preview are already correct when it opens.
    $key = Join-Path $regRoot $modId
    New-Item -Path $key -Force | Out-Null
    if ($PublishDir) {
        $PublishDir = (Resolve-Path $PublishDir).Path
        Set-ItemProperty -Path $key -Name 'dataPath' -Value $PublishDir
    }
    if ($PreviewImage) {
        $PreviewImage = (Resolve-Path $PreviewImage).Path
        Set-ItemProperty -Path $key -Name 'previewImagePath' -Value $PreviewImage
    }
    Write-Host "Pre-filled publish dialog for '$modId'" -ForegroundColor DarkGray

    # Dependencies must be mounted or the project refuses to load and Workbench
    # falls back to the project picker - which looks like "it opened the default project".
    $dirs = @($arma.GameAddons) + @($ExtraAddonsDir | Where-Object { $_ })
    $addonsArg = ($dirs | ForEach-Object { (Resolve-Path $_).Path }) -join ','
    Start-Process -FilePath $arma.Workbench -ArgumentList @(
        '-addonsDir', "`"$addonsArg`"",
        '-gproj', "`"$gproj`""
    ) -WorkingDirectory (Split-Path $arma.GameAddons -Parent)
    Write-Host @"
Workbench is opening. In Resource Manager:

  1. Publish.
  2. Title / Summary / Description are the only fields to type - the bundle dir and
     preview image are already set. Text is in work\<mod>\WORKSHOP.md
     (Summary: one line, max ~200 chars. Description: the body.)
  3. Publish. Wait for the backend to confirm.

Why these fields cannot be automated: the Workshop API rejects CreateAssetUpload
without 'summary', and no -publishAddon* switch sets it. Once the item exists,
updates are fully headless with -Auto.
"@ -ForegroundColor Cyan
    exit 0
}

# ── headless update ──────────────────────────────────────────────────────────
if (-not $ModId) { throw 'Pass -ModId (the project ID used at first publish)' }
if (-not $PublishDir -or -not (Test-Path $PublishDir)) { throw 'Pass -PublishDir with a packed addon folder' }
$PublishDir = (Resolve-Path $PublishDir).Path
if (-not (Test-Path (Join-Path $PublishDir 'data.pak'))) { throw "No data.pak in $PublishDir" }
if (-not $Version) { throw 'Pass -Version (e.g. 1.0.1)' }
if (Get-Process -Name 'ArmaReforgerSteam' -ErrorAction SilentlyContinue) {
    throw 'Arma Reforger is running. Close it: Workbench hangs at startup while the game owns the Steam identity.'
}

$dirs = @($arma.GameAddons) + @($ExtraAddonsDir | Where-Object { $_ })
$addonsArg = ($dirs | ForEach-Object { (Resolve-Path $_).Path }) -join ','

$before = Get-LatestLog
$args = @(
    '-wbModule=ResourceManager',
    '-addonsDir', "`"$addonsArg`"",
    '-publishAddon',
    '-publishAddonDir', "`"$PublishDir`"",
    '-publishAddonVersion', $Version,
    '-wbSilent', '-noThrow'
)
if ($ChangeNote) { $args += @('-publishAddonChangeNote', "`"$ChangeNote`"") }

Write-Host "Headless publish of '$ModId' $Version" -ForegroundColor Cyan
$p = Start-Process -FilePath $arma.Workbench -PassThru -ArgumentList $args
$killed = $false
if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    $killed = $true
    Write-Host "Workbench did not finish in $TimeoutSeconds s - killed." -ForegroundColor Red
    try { $p.Kill() } catch { }
    Start-Sleep -Seconds 2
}
$p.Refresh()
Write-Host "Workbench exit: $($p.ExitCode) (0 is not proof either way)" -ForegroundColor DarkGray

$log = Get-LatestLog
$text = if ($log) { Get-Content (Join-Path $log.FullName 'console.log') -Raw -ErrorAction SilentlyContinue } else { '' }
$newLog = $log -and (!$before -or $log.FullName -ne $before.FullName)

if ($text -match "should have required property 'summary'") {
    Write-Host 'The item does not exist yet - the first publish needs the dialog (see -Project).' -ForegroundColor Yellow
    Write-LogLines $log
    exit 2
}
if ($text -match 'not linked with Bohemia Account') {
    Write-Host 'Account not linked - run without -Auto once and sign in.' -ForegroundColor Yellow
    Write-LogLines $log
    exit 3
}
if ($text -match 'Invalid login credentials') {
    Write-Host 'Cached session rejected - sign in again.' -ForegroundColor Red
    Write-LogLines $log
    exit 4
}
if ($text -match 'Backend is not enabled|authentication timeout|backend initialization') {
    Write-Host 'Backend not ready (Steam online?)' -ForegroundColor Red
    Write-LogLines $log
    exit 5
}
if ($text -match 'WorkshopApi.*\(E\)|BACKEND.*\(E\)') {
    Write-Host 'Backend reported errors.' -ForegroundColor Red
    Write-LogLines $log
    exit 1
}
if ($killed -or -not $newLog -or $text -notmatch 'WorkshopApi|Publish Addon|BACKEND') {
    Write-Host 'No publish activity detected - treating as failure.' -ForegroundColor Red
    Write-LogLines $log
    exit 6
}

Write-Host 'No backend errors reported. Confirm the revision on the Workshop page.' -ForegroundColor Green
Write-LogLines $log

# The CLI publish path uses placeholder metadata ("test...") when the asset was
# first created headlessly. Fixing it once in the Publish dialog is permanent:
# later CLI runs copy the asset's metadata forward.
$manifest = Join-Path $PublishDir 'manifest.json'
if (Test-Path $manifest) {
    try {
        $asset = (Get-Content $manifest -Raw | ConvertFrom-Json).asset
        if ($asset.name -match '^test' -or $asset.summary -eq 'test') {
            Write-Host "Metadata is placeholder ('$($asset.name)' / '$($asset.summary)')." -ForegroundColor Yellow
            Write-Host 'Fix Title/Summary/Description once in the Publish dialog; later uploads keep them.' -ForegroundColor Yellow
        }
    }
    catch { }
}
exit 0
