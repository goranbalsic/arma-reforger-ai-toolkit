# Install a packed addon into the game's addons folder and add it to a launcher preset.
# Refuses to touch the preset while the game or server is running (it would be overwritten).
param(
    [Parameter(Mandatory = $true)][string]$Build,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Guid,
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Preset = 'Preset 1'
)

$ErrorActionPreference = 'Stop'
$Build = (Resolve-Path $Build).Path
if (-not (Test-Path (Join-Path $Build 'data.pak'))) { throw "No data.pak in $Build - pack it first" }

$running = Get-Process -Name 'ArmaReforgerSteam', 'ArmaReforgerServer', 'ArmaReforger_BE' -ErrorAction SilentlyContinue
if ($running) { throw "Arma Reforger is running. Close it first or the preset edit is lost." }

$addons = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\addons'
$dest = Join-Path $addons "${Id}_${Guid}"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $Build '*') $dest -Recurse -Force
Write-Host "Installed -> $dest" -ForegroundColor Green

$conf = Get-ChildItem (Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\profile\.save') `
    -Directory -Filter 'app*_user*' | ForEach-Object {
        Join-Path $_.FullName 'settings\ReforgerGameSettings.conf'
    } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $conf) { throw 'ReforgerGameSettings.conf not found' }
if (-not $Preset) { Write-Host 'No preset requested; addon installed but not enabled.'; exit 0 }

Copy-Item $conf "$conf.bak-$(Get-Date -f yyyyMMdd-HHmmss)" -Force
$text = Get-Content $conf -Raw

if ($text -match [regex]::Escape("m_sGuid `"$Guid`"")) {
    Write-Host "Preset already lists $Guid - nothing to change." -ForegroundColor DarkGray
    exit 0
}

# locate the requested preset block, then the end of its m_aAddonsMeta list
$pm = [regex]::Match($text, 'SCR_WorkshopAddonPreset "\{[0-9A-F]+\}" \{\s*\r?\n\s*m_sName "' + [regex]::Escape($Preset) + '"')
if (-not $pm.Success) { throw "Preset '$Preset' not found in $conf" }
$metaLabel = $text.IndexOf('m_aAddonsMeta {', $pm.Index)
if ($metaLabel -lt 0) { throw "m_aAddonsMeta not found for preset '$Preset'" }

# brace-match the addon list and append at its end: later addons win path overrides
$open = $text.IndexOf('{', $metaLabel)
$depth = 0
$close = -1
for ($i = $open; $i -lt $text.Length; $i++) {
    if ($text[$i] -eq '{') { $depth++ }
    elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { $close = $i; break } }
}
if ($close -lt 0) { throw 'Unbalanced m_aAddonsMeta block' }
$insertAt = $text.LastIndexOf("`n", $close) + 1

# deterministic per-addon meta entry id, so deploying several mods stays unique
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Guid.ToUpper()))
$metaGuid = -join ($hash[0..7] | ForEach-Object { $_.ToString('X2') })

$entry = "     SCR_WorkshopAddonPresetAddonMeta `"{$metaGuid}`" {`r`n" +
         "      m_sGuid `"$Guid`"`r`n" +
         "      m_sName `"$Title`"`r`n" +
         "     }`r`n"
$new = $text.Insert($insertAt, $entry)

# sanity: entry count must grow by one inside that preset
if ($new -notmatch [regex]::Escape("m_sGuid `"$Guid`"")) { throw 'Insertion failed' }
Set-Content -Path $conf -Value $new -NoNewline
Write-Host "Added to preset '$Preset' (backup next to the config)" -ForegroundColor Green
