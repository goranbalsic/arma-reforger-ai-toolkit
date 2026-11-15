# Add one server's modlist to the batch: fetch, union, subtract what is installed
# or queued, merge into the DS config (which holds only the not-yet-downloaded
# mods) and add sizes. The dashboard's "Add server" browser button does the same
# thing live (with a DS restart); this CLI form does not touch a running DS -
# afterwards press Start/Resume (Start-DS trims the config automatically).
#   .\add-server.ps1 -Id <server guid>
#   .\add-server.ps1 -Search 'COLD FRONT' -Match 'COLD FRONT'
param(
  [string]$Id,
  [string]$Search,
  [string]$Match = '.'
)
$ErrorActionPreference = 'Stop'
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$h = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$base = 'https://api.reforgermods.net/v2'
$cfgPath = "$Data\batch1-serverconfig.json"
$sizesPath = "$Data\batch1-sizes.json"
$dsAddons = "$Root\serverprofile\addons"
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
"server: $($d.server.name)  mods=$(@($d.server.mods).Count)"

$j = Get-Content $cfgPath -Raw | ConvertFrom-Json
$have = @{}
$j.game.mods | ForEach-Object { $have[$_.modId] = $true }
foreach ($root in @($dsAddons, $clAddons)) {
  Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
    ForEach-Object { $have[$Matches[1]] = $true }
}
$new = @($d.server.mods | Where-Object { -not $have.ContainsKey($_.id) })
"covered: $(@($d.server.mods).Count - $new.Count)   new to download: $($new.Count)"
if (-not $new) { 'nothing to add'; exit 0 }

$j.game.mods = @($j.game.mods) + @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
$j | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
"config now: $(@($j.game.mods).Count) remaining mods"

# real sizes straight from the server detail; zero placeholder when unknown
$sizes = Get-Content $sizesPath -Raw | ConvertFrom-Json
$added = 0
foreach ($m in $new) {
  if (-not $sizes.mods.PSObject.Properties[$m.id]) {
    $bytes = if ($m.sizeKnown -and $m.size) { [double]$m.size } else { 0 }
    $exact = [bool]($m.sizeKnown -and $m.size)
    $sizes.mods | Add-Member -NotePropertyName $m.id -NotePropertyValue ([PSCustomObject]@{ name = $m.name; bytes = $bytes; exact = $exact })
    $added++
  }
}
$total = ($sizes.mods.PSObject.Properties | ForEach-Object { [double]$_.Value.bytes } | Measure-Object -Sum).Sum
$sizes.totalBytes = [double]$total
$sizes | ConvertTo-Json -Depth 4 | Set-Content $sizesPath -Encoding UTF8
"sizes added: $added ($($added - ($new | Where-Object { $_.sizeKnown }).Count) still unknown; fix-sizes.ps1 fills them)"
