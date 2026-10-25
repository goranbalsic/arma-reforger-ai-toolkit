# Publish (or update) an Arma Reforger addon on the Workshop.
#
#   .\publish-addon.ps1 -Project <dir>              # first publish: opens Workbench, guides the GUI
#   .\publish-addon.ps1 -Update -PublishDir <dir> -Version 1.0.1 -ChangeNote "fix"
#
# There is no command-line login in current Workbench builds (no -wbBackendLogin,
# and it needs "Game Identity linked with Bohemia Account"). Credentials are only
# ever entered in Workbench's own sign-in dialog; this script never asks for them
# and never stores them.
param(
    [string]$Project = '',
    [string]$PublishDir = '',
    [string]$Version = '',
    [string]$ChangeNote = '',
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skill\arma-reforger-modding\scripts\find-arma.ps1')
$arma = Find-Arma
if (-not $arma.Workbench) { throw 'Workbench not found (Arma Reforger Tools)' }
if (-not $arma.GameAddons) { throw 'Game addons folder not found' }

$logsRoot = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforgerWorkbench\logs'

function Show-LogProblems {
    $log = Get-ChildItem $logsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return }
    $hits = Select-String -Path (Join-Path $log.FullName 'console.log') -ErrorAction SilentlyContinue `
        -Pattern 'Publish Addon|BACKEND.*\(E\)|Backend is not enabled|authentication timeout|not linked with Bohemia|publish' |
        Select-Object -Last 15
    if ($hits) {
        Write-Host "Log ($($log.Name)):" -ForegroundColor DarkGray
        $hits | ForEach-Object { Write-Host "  $($_.Line.Trim())" -ForegroundColor Yellow }
    }
}

if ($Update) {
    if (-not $PublishDir -or -not (Test-Path $PublishDir)) { throw 'Pass -PublishDir with a packed addon folder' }
    $PublishDir = (Resolve-Path $PublishDir).Path
    if (-not (Test-Path (Join-Path $PublishDir 'data.pak'))) { throw "No data.pak in $PublishDir" }
    if (-not $Version) { throw 'Pass -Version (e.g. 1.0.1) for an update' }

    $args = @(
        '-wbModule=ResourceManager',
        '-addonsDir', "`"$($arma.GameAddons)`"",
        '-publishAddon',
        '-publishAddonDir', "`"$PublishDir`"",
        '-publishAddonVersion', $Version,
        '-wbSilent', '-noThrow'
    )
    if ($ChangeNote) { $args += @('-publishAddonChangeNote', "`"$ChangeNote`"") }

    Write-Host "Publishing update $Version from $PublishDir" -ForegroundColor Cyan
    $p = Start-Process -FilePath $arma.Workbench -PassThru -ArgumentList $args
    $null = $p.WaitForExit(600000)
    $p.Refresh()
    Write-Host "Workbench exit: $($p.ExitCode) (0 is not proof of success)" -ForegroundColor DarkGray
    Show-LogProblems
    exit 0
}

# First publish must happen in the GUI: it needs the account sign-in, title,
# description, tags and a preview image. Updates can then use -Update.
if (-not $Project) { throw 'Pass -Project <folder containing addon.gproj> for the first publish' }
$Project = (Resolve-Path $Project).Path
$gproj = Join-Path $Project 'addon.gproj'
if (-not (Test-Path $gproj)) { throw "No addon.gproj in $Project" }

$running = Get-Process -Name 'ArmaReforgerWorkbenchSteamDiag', 'ArmaReforgerSteam' -ErrorAction SilentlyContinue
if ($running) { throw 'Close Workbench / Arma Reforger first.' }

Start-Process -FilePath $arma.Workbench -ArgumentList @('-gproj', "`"$gproj`"") -WorkingDirectory (Split-Path $arma.GameAddons -Parent)
Write-Host @"
Workbench is opening your project.

  1. Resource Manager -> Project -> Publish (or the Publish icon).
  2. Sign in with your Bohemia Interactive account if asked (not Steam, not this script).
     First time: link your game identity to that account when prompted.
  3. Fill Title, Description, Tags, and pick a preview image.
  4. Publish. Wait for the backend to confirm before closing Workbench.

After the item exists, updates can be scripted:
  .\publish-addon.ps1 -Update -PublishDir .\build\<mod> -Version 1.0.1 -ChangeNote "what changed"

The account/session is cached by Workbench, so no password is needed here.
"@ -ForegroundColor Cyan
