# Add one server's modlist to the batch: fetch, union, subtract what is installed
# or queued, merge into the DS config (which holds only the not-yet-downloaded
# mods) and add placeholder sizes for fix-sizes.ps1 to fill.
#   .\add-server.ps1 -Id <server guid>
#   .\add-server.ps1 -Search 'COLD FRONT' -Match 'COLD FRONT'
# afterwards press Start/Resume (Start-DS trims the config automatically).
param(
  [string]$Id,
  [string]$Search,
  [string]$Match = '.'
)
$ErrorActionPreference = 'Stop'
$h = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$base = 'https://api.reforgermods.net/v2'
$cfgPath = "$env:USERPROFILE\Documents\Default Project\batch1-serverconfig.json"
$sizesPath = "$env:USERPROFILE\Documents\Default Project\batch1-sizes.json"
$dsAddons = "$PSScriptRoot\serverprofile\addons"
$clAddons = "$env:USERPROFILE\Documents\My Games\ArmaReforger\addons"

if ($Id) { $srvId = $Id }
else {
  if (-not $Search) { throw 'pass -Id <server guid> or -Search <text>' }
  $r = Invoke-RestMethod -Uri "$base/servers?search=$([uri]::EscapeDataString($Search))&includeOffline=true" -Headers $h -TimeoutSec 60
  $c = @($r.data | Where-Object { $_.name -match $Match })
  if ($c.Count -eq 0) { throw "no server matched '$Search' / '$Match'" }
  $c | ForEach-Object { "  candidate: [$($_.id)] $($_.name)" }
  $srvId = $c[0].id
}
$d = Invoke-RestMethod -Uri "$base/servers/$srvId" -Headers $h -TimeoutSec 60
"server: $($d.server.name)  mods=$($d.server.mods.Count)"

$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$have = @{}
$cfg.game.mods | ForEach-Object { $have[$_.modId] = $true }
foreach ($root in @($dsAddons, $clAddons)) {
  Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
    ForEach-Object { $have[$Matches[1]] = $true }
}
$new = @($d.server.mods | Where-Object { -not $have.ContainsKey($_.id) })
"covered: $($d.server.mods.Count - $new.Count)   new to download: $($new.Count)"
if (-not $new) { 'nothing to add'; exit 0 }

$cfg.game.mods = @($cfg.game.mods) + @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
$cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
"config now: $($cfg.game.mods.Count) remaining mods"

$sizes = Get-Content $sizesPath -Raw | ConvertFrom-Json
$added = 0
foreach ($m in $new) {
  if (-not $sizes.mods.PSObject.Properties[$m.id]) {
    $sizes.mods | Add-Member -NotePropertyName $m.id -NotePropertyValue ([PSCustomObject]@{ name = $m.name; bytes = 0; exact = $false })
    $added++
  }
}
$sizes | ConvertTo-Json -Depth 4 | Set-Content $sizesPath -Encoding UTF8
"sizes placeholders added: $added (fix-sizes.ps1 fills them; dashboard restart shows the new total)"
