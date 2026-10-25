# Launch Arma Reforger with a whole launcher preset's addon list, without the
# launcher and without Workshop publishing.
#
#   .\launch-with-preset.ps1 -Preset "AI Test" -DryRun
#   .\launch-with-preset.ps1 -Preset "AI Test"
#
# The launcher resolves preset entries through the Workshop, so an unpublished
# local addon shows "cannot be downloaded". Passing the same GUIDs on the command
# line mounts them directly; the engine already lists them under "Available
# addons" on startup.
param(
    [Parameter(Mandatory = $true)][string]$Preset,
    [string[]]$ExtraGuid = @(),
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skill\arma-reforger-modding\scripts\find-arma.ps1')
$arma = Find-Arma
if (-not $arma.GameAddons) { throw 'Arma Reforger install not found' }
$gameExe = Join-Path (Split-Path $arma.GameAddons -Parent) 'ArmaReforgerSteam.exe'
if (-not (Test-Path $gameExe)) { throw "Game executable not found: $gameExe" }
if (-not $arma.Settings) { throw 'ReforgerGameSettings.conf not found' }

$text = Get-Content $arma.Settings -Raw
$found = $null
foreach ($m in [regex]::Matches($text, 'SCR_WorkshopAddonPreset\s+"\{[0-9A-F]+\}"\s*\{')) {
    $head = $text.Substring($m.Index, [Math]::Min(400, $text.Length - $m.Index))
    if ($head -notmatch ('m_sName\s+"' + [regex]::Escape($Preset) + '"')) { continue }
    $open = $m.Index + $m.Length - 1
    $depth = 0
    for ($i = $open; $i -lt $text.Length; $i++) {
        if ($text[$i] -eq '{') { $depth++ }
        elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { $found = $text.Substring($open, $i - $open + 1); break } }
    }
    break
}
if (-not $found) { throw "Preset '$Preset' not found in $($arma.Settings)" }

$guids = [regex]::Matches($found, 'm_sGuid\s+"([0-9A-Fa-f]{16})"') | ForEach-Object { $_.Groups[1].Value.ToUpper() }
$guids += $ExtraGuid | Where-Object { $_ } | ForEach-Object { $_.ToUpper() }
$guids = $guids | Select-Object -Unique

# every GUID must have a folder on disk, otherwise the engine silently skips it
$onDisk = @{}
Get-ChildItem $arma.UserAddons -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Name -match '_([0-9A-Fa-f]{16})$') { $onDisk[$Matches[1].ToUpper()] = $_.Name }
}
$missing = $guids | Where-Object { -not $onDisk.ContainsKey($_) }

Write-Host "Preset '$Preset': $($guids.Count) addons" -ForegroundColor Cyan
if ($missing) {
    Write-Host "Not installed locally (will be skipped): $($missing -join ', ')" -ForegroundColor Yellow
}

$list = $guids -join ','
$argLine = "-addons `"$list`""
Write-Host "Executable: $gameExe" -ForegroundColor DarkGray
Write-Host "Arguments:  $argLine" -ForegroundColor DarkGray

if ($DryRun) { exit 0 }

$running = Get-Process -Name 'ArmaReforgerSteam' -ErrorAction SilentlyContinue
if ($running) { throw 'Arma Reforger is already running. Close it first.' }

Start-Process -FilePath $gameExe -ArgumentList @('-addons', "`"$list`"") -WorkingDirectory (Split-Path $arma.GameAddons -Parent)
Write-Host 'Launched with the preset addons mounted.' -ForegroundColor Green
Write-Host 'Pick a scenario in game (Conflict for USSR, or Game Master to spawn units).' -ForegroundColor DarkGray
