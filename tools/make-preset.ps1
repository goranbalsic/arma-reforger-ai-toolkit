# Build an Arma Reforger launcher preset from a server's real modlist.
#   .\make-preset.ps1 -ServerId <server guid>     # or no argument for ArmaDudes 1
# The preset block MUST go inside SCR_WorkshopAddonManagerPresetStorage - a block
# appended after it gets dropped by the game (that is what killed the 01:13
# attempt; the 02:41 save wiped it). Only mods already installed locally are
# included: the launcher deletes preset entries it cannot resolve, so uninstalled
# workshop items would poison the whole preset on exit. Re-run when the batch
# finishes to pick up the rest.
param([string]$ServerId)
$ErrorActionPreference = 'Stop'

$conf = Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforger\profile\.save" -Recurse -Filter ReforgerGameSettings.conf |
  Select-Object -First 1
if (-not $conf) { throw 'ReforgerGameSettings.conf not found' }
$conf = $conf.FullName
$srvs = Get-Content "$env:USERPROFILE\Documents\Default Project\batch1-servers.json" -Raw | ConvertFrom-Json
$clAddons = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"

if (Get-Process ArmaReforgerSteam -ErrorAction SilentlyContinue) { throw 'Game is running - close it first (it rewrites this file on exit)' }

$text = [IO.File]::ReadAllText($conf)

$srv = if ($ServerId) { @($srvs.servers | Where-Object { $_.id -eq $ServerId })[0] }
       else { @($srvs.servers | Where-Object { $_.name -match 'ArmaDudes 1\b' })[0] }
if (-not $srv) { throw 'server not found in batch1-servers.json' }
$presetName = if ($srv.PSObject.Properties['key'] -and $srv.key) { [string]$srv.key }
              else { ([string]$srv.name -split '\|')[0].Trim() }
if ($presetName.Length -gt 60) { $presetName = $presetName.Substring(0, 60).Trim() }
$presetName = $presetName -replace '"', "'"
if ($text -match ('m_sName "' + [regex]::Escape($presetName) + '"')) { throw "preset '$presetName' already exists - delete it in the launcher first" }

$installed = @{}
Get-ChildItem $clAddons -Directory |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object { $installed[$Matches[1]] = ($_.Name -replace '_[0-9A-F]{16}$', '') }
$mods = @($srv.mods | Where-Object { $installed.ContainsKey($_.id) })
"server: $($srv.name)  mods=$($srv.mods.Count)  installed here: $($mods.Count)"
if ($mods.Count -lt $srv.mods.Count) {
  "note: $($srv.mods.Count - $mods.Count) mods not installed yet - re-run this after the batch finishes"
}
if (-not $mods) { throw 'no installed mods for this preset yet' }

Copy-Item $conf "$conf.bak-$(Get-Date -f yyyyMMdd-HHmmss)"

function Get-Hash16([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 16)
}
$presetGuid = (Get-Hash16 "preset:$($srv.id)").ToUpper()
$metas = foreach ($m in $mods) {
  $g = (Get-Hash16 "meta:$($m.id)").ToUpper()
  $n = $installed[$m.id] -replace '"', ''
  '   SCR_WorkshopAddonPresetAddonMeta "{' + $g + '}" {' + "`r`n" +
  '    m_sGuid "' + $m.id + '"' + "`r`n" +
  '    m_sName "' + $n + '"' + "`r`n" +
  '   }'
}
$body = '  SCR_WorkshopAddonPreset "{' + $presetGuid + '}" {' + "`r`n" +
        '   m_sName "' + $presetName + '"' + "`r`n" +
        '   m_aAddonsMeta {' + "`r`n" +
        (($metas -join "`r`n") + "`r`n") +
        '   }' + "`r`n" +
        '  }'

$anchor = 'm_iVersion 1'
$i = $text.IndexOf($anchor)
if ($i -lt 0) { throw 'preset storage block not found in conf' }
[IO.File]::WriteAllText($conf, $text.Insert($i + $anchor.Length, "`r`n" + $body), [Text.UTF8Encoding]::new($false))

$check = [IO.File]::ReadAllText($conf)
$open = ([regex]::Matches($check, '\{')).Count
$close = ([regex]::Matches($check, '\}')).Count
$presets = [regex]::Matches($check, 'SCR_WorkshopAddonPreset "\{[0-9A-F]{16}\}"').Count
"verification: presets=$presets meta=$($mods.Count) braces=$open/$close"
if ($presets -ne 1 -or $open -ne $close) { throw 'verification failed - restore from the .bak next to the conf' }
"OK - preset '$presetName' with $($mods.Count) installed mods"
