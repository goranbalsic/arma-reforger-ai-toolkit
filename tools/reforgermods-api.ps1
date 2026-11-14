# reforgermods-api.ps1 — thin read-only client for the ReforgerMods V2 API.
# https://reforgermods.net/arma-reforger-mods-api/v2/ — mirrors BI's workshop
# and server-browser backends as JSON. Anonymous access works; the public tier
# is 60 requests/minute — batch scripts must throttle.
#
# Examples:
#   powershell -File reforgermods-api.ps1 -Mod 5965550F24A0C152
#   powershell -File reforgermods-api.ps1 -Search "rhs" -Sort newest
#   powershell -File reforgermods-api.ps1 -Servers -Region frankfurt -Sort players
#   powershell -File reforgermods-api.ps1 -ServerMods <server-uuid>
#   powershell -File reforgermods-api.ps1 -Dependencies 5965550F24A0C152
#
# -Out <file> saves the raw JSON; without it the JSON is printed.
param(
  [string]$Mod,
  [string]$Search,
  [switch]$Servers,
  [string]$Region,
  [string]$ServerMods,
  [string]$Dependencies,
  [string]$Versions,
  [string]$Sort,
  [string]$Out
)

$ErrorActionPreference = 'Stop'
$Base = 'https://api.reforgermods.net/v2'
$Headers = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }

$chosen = @()
if ($Mod) { $chosen += 'mod' }
if ($Search) { $chosen += 'search' }
if ($Servers) { $chosen += 'servers' }
if ($ServerMods) { $chosen += 'servermods' }
if ($Dependencies) { $chosen += 'deps' }
if ($Versions) { $chosen += 'versions' }
if ($chosen.Count -eq 0) {
  throw 'Pick one: -Mod <id> | -Search <text> | -Servers | -ServerMods <serverId> | -Dependencies <id> | -Versions <id>'
}
if ($chosen.Count -gt 1) { throw 'Use exactly one mode.' }

$url = if ($Mod)          { "$Base/mods/$Mod" }
       elseif ($Search)   { "$Base/mods?search=" + [uri]::EscapeDataString($Search) + $(if ($Sort) { "&sort=$Sort" }) }
       elseif ($Servers)  { "$Base/servers?sort=$(if ($Sort) { $Sort } else { 'players' })" + $(if ($Region) { "&region=$Region" }) }
       elseif ($ServerMods)   { "$Base/servers/$ServerMods/mods" }
       elseif ($Dependencies) { "$Base/mods/$Dependencies/dependencies" }
       else                   { "$Base/mods/$Versions/versions" }

$data = Invoke-RestMethod -Uri $url -Headers $Headers -TimeoutSec 60
$json = $data | ConvertTo-Json -Depth 8

if ($Out) {
  $json | Set-Content $Out -Encoding UTF8
  Write-Host "saved -> $Out"
} else {
  $json
}
