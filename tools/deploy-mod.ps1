# Install a packed addon into the game's addons folder and enable it in a
# launcher preset.
#
#   .\deploy-mod.ps1 -Build build\MyMod -Id MyMod -Guid 0123456789ABCDEF -Title "My Mod" -Preset "My Preset"
#   .\deploy-mod.ps1 ... -Preset "AI Test" -CopyFrom "Preset 1"   # create a new preset from an existing one
#
# A local addon needs a `meta` file or the launcher treats it as an unowned
# Workshop item ("cannot be downloaded"). This writes one unless -CreateMeta:$false.
# Refuses to edit presets while the game is running (it would be overwritten).
param(
    [Parameter(Mandatory = $true)][string]$Build,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Guid,
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Preset = '',
    [string]$CopyFrom = '',
    [switch]$PresetOnly,
    [bool]$CreateMeta = $true,
    [switch]$NoPreset
)

$ErrorActionPreference = 'Stop'
$Build = (Resolve-Path $Build).Path
if (-not (Test-Path (Join-Path $Build 'data.pak'))) { throw "No data.pak in $Build - pack it first" }
if ($Guid -notmatch '^[0-9A-Fa-f]{16}$') { throw "Guid must be 16 hex characters" }

$addons = Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\addons'
$dest = Join-Path $addons "${Id}_${Guid}"
if (-not $PresetOnly) {
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item (Join-Path $Build '*') $dest -Recurse -Force
    Write-Host "Installed -> $dest" -ForegroundColor Green
}

function New-Meta {
    param($AddonDir, $AddonId, $AddonGuid, $Name)
    if (Test-Path (Join-Path $AddonDir 'meta')) { return }
    $deps = @()
    $gproj = Join-Path $AddonDir 'addon.gproj'
    if (Test-Path $gproj) {
        $txt = Get-Content $gproj -Raw
        $m = [regex]::Match($txt, '(?s)Dependencies\s*\{(.*?)\}')
        if ($m.Success) {
            foreach ($d in [regex]::Matches($m.Groups[1].Value, '"([0-9A-Fa-f]{16})"')) {
                $deps += [ordered]@{ assetId = $d.Groups[1].Value.ToUpper(); assetName = 'dependency'; version = '1.0.0' }
            }
        }
    }
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $meta = [ordered]@{
        meta = [ordered]@{
            id          = $AddonGuid.ToUpper()
            name        = $Name
            description = 'Local addon installed by arma-reforger-ai-toolkit'
            type        = 1
            createdAt   = $now
            updatedAt   = $now
            versions    = @([ordered]@{
                    version      = '1.0.0'
                    gameVersion  = '1.0.0.0'
                    changelog    = ''
                    corrupted    = $false
                    dependencies = $deps
                    scenarios    = @()
                    env          = 7
                })
            selectedRev = 0
            previews    = @()
            tags        = @()
            deleted     = $false
        }
    }
    $json = $meta | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $AddonDir 'meta'), $json, (New-Object Text.UTF8Encoding($false)))
    Write-Host "Wrote meta so the launcher sees a local addon" -ForegroundColor DarkGray
}

if ($CreateMeta -and -not $PresetOnly) { New-Meta -AddonDir $dest -AddonId $Id -AddonGuid $Guid -Name $Title }
if ($NoPreset -or -not $Preset) {
    Write-Host 'Addon installed; no preset requested.' -ForegroundColor DarkGray
    exit 0
}

$running = Get-Process -Name 'ArmaReforgerSteam', 'ArmaReforgerServer' -ErrorAction SilentlyContinue
if ($running) { throw 'Arma Reforger is running. Close it first or the preset edit is lost.' }

$conf = Get-ChildItem (Join-Path $env:USERPROFILE 'Documents\My Games\ArmaReforger\profile\.save') `
    -Directory -Filter 'app*_user*' | ForEach-Object {
        Join-Path $_.FullName 'settings\ReforgerGameSettings.conf'
    } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $conf) { throw 'ReforgerGameSettings.conf not found' }

function Get-Hash16([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    -join ($h[0..7] | ForEach-Object { $_.ToString('X2') })
}

function Get-PresetBlock([string]$text, [string]$name) {
    foreach ($m in [regex]::Matches($text, 'SCR_WorkshopAddonPreset\s+"\{[0-9A-F]+\}"\s*\{')) {
        $head = $text.Substring($m.Index, [Math]::Min(400, $text.Length - $m.Index))
        if ($head -notmatch ('m_sName\s+"' + [regex]::Escape($name) + '"')) { continue }
        $open = $m.Index + $m.Length - 1
        $depth = 0
        for ($i = $open; $i -lt $text.Length; $i++) {
            if ($text[$i] -eq '{') { $depth++ }
            elseif ($text[$i] -eq '}') { $depth--; if ($depth -eq 0) { return @{ Start = $m.Index; Open = $open; Close = $i } } }
        }
    }
    return $null
}

Copy-Item $conf "$conf.bak-$(Get-Date -f yyyyMMdd-HHmmss)" -Force
$text = Get-Content $conf -Raw

if ($text -match [regex]::Escape("m_sGuid `"$Guid`"")) {
    # already present somewhere: only make sure it is in the requested preset
    $existing = Get-PresetBlock $text $Preset
    if ($existing -and $text.Substring($existing.Open, $existing.Close - $existing.Open) -match [regex]::Escape("m_sGuid `"$Guid`"")) {
        Write-Host "Preset '$Preset' already lists $Guid - nothing to change." -ForegroundColor DarkGray
        exit 0
    }
}

$block = Get-PresetBlock $text $Preset
$metaGuid = Get-Hash16 "entry:$Guid"

if (-not $block) {
    if (-not $CopyFrom) { throw "Preset '$Preset' not found. Pass -CopyFrom <existing preset> to create it." }
    $src = Get-PresetBlock $text $CopyFrom
    if (-not $src) { throw "Source preset '$CopyFrom' not found" }
    # take the source addon entries verbatim - never rewrite their names
    $metaAt = $text.IndexOf('m_aAddonsMeta {', $src.Open)
    if ($metaAt -lt 0) { throw "Source preset '$CopyFrom' has no addon list" }
    $ob = $text.IndexOf('{', $metaAt)
    $d = 0; $cb = -1
    for ($i = $ob; $i -lt $text.Length; $i++) {
        if ($text[$i] -eq '{') { $d++ } elseif ($text[$i] -eq '}') { $d--; if ($d -eq 0) { $cb = $i; break } }
    }
    if ($cb -lt 0) { throw 'Unbalanced source addon list' }
    $inner = $text.Substring($ob + 1, $cb - $ob - 1).TrimEnd()

    $newGuid = Get-Hash16 "preset:$Preset"
    $myEntry = "     SCR_WorkshopAddonPresetAddonMeta `"{$metaGuid}`" {`r`n      m_sGuid `"$Guid`"`r`n      m_sName `"$Title`"`r`n     }"
    $body = "SCR_WorkshopAddonPreset `"{$newGuid}`" {`r`n" +
            "    m_sName `"$Preset`"`r`n" +
            "    m_aAddonsMeta {`r`n" +
            "$inner`r`n" +
            "$myEntry`r`n" +
            "    }`r`n" +
            "   }"
    $text = $text.TrimEnd() + "`r`n   " + $body + "`r`n"
    $copied = ([regex]::Matches($inner, 'm_sGuid')).Count
    Write-Host "Created preset '$Preset' from '$CopyFrom' with $($copied + 1) addons" -ForegroundColor Green
}
else {
    $metaOpen = $text.IndexOf('m_aAddonsMeta {', $block.Open)
    $ob = $text.IndexOf('{', $metaOpen)
    $d = 0; $cb = -1
    for ($i = $ob; $i -lt $text.Length; $i++) {
        if ($text[$i] -eq '{') { $d++ } elseif ($text[$i] -eq '}') { $d--; if ($d -eq 0) { $cb = $i; break } }
    }
    $entry = "     SCR_WorkshopAddonPresetAddonMeta `"{$metaGuid}`" {`r`n      m_sGuid `"$Guid`"`r`n      m_sName `"$Title`"`r`n     }`r`n"
    $lineStart = $text.LastIndexOf("`n", $cb) + 1
    $text = $text.Insert($lineStart, $entry)
    Write-Host "Added to preset '$Preset' (last, so overrides win)" -ForegroundColor Green
}

Set-Content -Path $conf -Value $text -NoNewline
