# Build the "ArmaDudes 1" launcher preset from the server's real modlist.
# The preset block MUST go inside SCR_WorkshopAddonManagerPresetStorage - a block
# appended after it gets dropped by the game (that is what killed the 01:13
# attempt; the 02:41 save wiped it). Only mods already installed locally are
# included: the launcher deletes preset entries it cannot resolve, so uninstalled
# workshop items would poison the whole preset on exit. Re-run when the batch
# finishes to pick up the rest.
$ErrorActionPreference = 'Stop'

$conf = Get-ChildItem "$env:USERPROFILE\Documents\My Games\ArmaReforger\profile\.save" -Recurse -Filter ReforgerGameSettings.conf |
  Select-Object -First 1
if (-not $conf) { throw 'ReforgerGameSettings.conf not found' }
$conf = $conf.FullName
$srvs = Get-Content "$env:USERPROFILE\Documents\Default Project\batch1-servers.json" -Raw | ConvertFrom-Json
$clAddons = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"

if (Get-Process ArmaReforgerSteam -ErrorAction SilentlyContinue) { throw 'Game is running - close it first (it rewrites this file on exit)' }

$text = [IO.File]::ReadAllText($conf)
if ($text -match 'm_sName "ArmaDudes 1"') { throw 'preset ArmaDudes 1 already exists - delete it in the launcher first' }

$ad1 = @($srvs.servers | Where-Object { $_.name -match 'ArmaDudes 1\b' })[0]
if (-not $ad1) { throw 'ArmaDudes 1 not found in batch1-servers.json (run build-servers first)' }

$installed = @{}
Get-ChildItem $clAddons -Directory |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object { $installed[$Matches[1]] = ($_.Name -replace '_[0-9A-F]{16}$', '') }
$mods = @($ad1.mods | Where-Object { $installed.ContainsKey($_.id) })
"server: $($ad1.name)  mods=$($ad1.mods.Count)  installed here: $($mods.Count)"
if ($mods.Count -lt $ad1.mods.Count) {
  "note: $($ad1.mods.Count - $mods.Count) mods not installed yet - re-run this after the batch finishes"
}
if (-not $mods) { throw 'no installed mods for this preset yet' }

Copy-Item $conf "$conf.bak-$(Get-Date -f yyyyMMdd-HHmmss)"

function Get-Hash16([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '').Substring(0, 16)
}
$presetGuid = (Get-Hash16 "preset:$($ad1.id)").ToUpper()
$metas = foreach ($m in $mods) {
  $g = (Get-Hash16 "meta:$($m.id)").ToUpper()
  $n = $installed[$m.id] -replace '"', ''
  '   SCR_WorkshopAddonPresetAddonMeta "{' + $g + '}" {' + "`r`n" +
  '    m_sGuid "' + $m.id + '"' + "`r`n" +
  '    m_sName "' + $n + '"' + "`r`n" +
  '   }'
}
$body = '  SCR_WorkshopAddonPreset "{' + $presetGuid + '}" {' + "`r`n" +
        '   m_sName "ArmaDudes 1"' + "`r`n" +
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
"OK - preset 'ArmaDudes 1' with $($mods.Count) installed mods"
