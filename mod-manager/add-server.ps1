# Add one server's modlist to the batch: fetch, union, subtract what is installed
# or queued, merge into the DS config (which holds only the not-yet-downloaded
# mods) and add sizes. The dashboard's "Add server" browser button does the same
# thing live (with a DS restart). This CLI form refuses to run while the DS is up:
# the DS rewrites the config on exit, so the addition would be lost. Afterwards
# press Start/Resume (Start-DS trims the config automatically).
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
$serversPath = "$Data\batch1-servers.json"
function Save-Json($obj, [string]$Path, [int]$Depth = 5) {
  # atomic: a kill during Set-Content leaves json the dashboard cannot parse
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth $Depth | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}
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
$sizes = Get-Content $sizesPath -Raw | ConvertFrom-Json
$sizeMap = @{}
$sizes.mods.PSObject.Properties | ForEach-Object { $sizeMap[$_.Name] = [double]$_.Value.bytes }
$have = @{}
$j.game.mods | ForEach-Object { $have[$_.modId] = $true }
# on disk only when the addon's own file list matches: the DS writes the marker
# files before the data paks, so a folder alone can be a partial download, and a
# mod with no resolved size used to count as installed as soon as ANY folder (even
# a 0-byte stub) existed - so it was never queued.
function Test-AddonComplete([string]$Path) {
  $metaPath = Join-Path $Path 'meta'
  if (-not (Test-Path $metaPath)) { return $false }
  try {
    $mj = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $files = @(@($mj.meta.versions)[0].package.files)
    if (-not $files.Count) { return $false }
    foreach ($f in $files) {
      if (-not $f.name) { continue }
      $p = Join-Path $Path $f.name
      if (-not (Test-Path $p)) { return $false }
      if ((Get-Item $p).Length -ne [long]$f.size) { return $false }
    }
    return $true
  } catch { return $false }
}
foreach ($root in @($dsAddons, $clAddons)) {
  Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
    ForEach-Object {
      if (Test-AddonComplete $_.FullName) { $have[$Matches[1]] = $true }
    }
}
$new = @($d.server.mods | Where-Object { -not $have.ContainsKey($_.id) })
"covered: $(@($d.server.mods).Count - $new.Count)   new to download: $($new.Count)"
if (-not $new) { 'nothing to add'; exit 0 }

if (Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue) {
  # the DS rewrites the config on exit: appending to it now would be discarded
  throw 'downloader is running - press Pause in the dashboard first'
}
$j.game.mods = @($j.game.mods) + @($new | ForEach-Object { [PSCustomObject]@{ modId = $_.id; name = $_.name } })
Save-Json $j $cfgPath
"config now: $(@($j.game.mods).Count) remaining mods"

# real sizes straight from the server detail; zero placeholder when unknown
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
Save-Json $sizes $sizesPath 4
"$added sizes added, $(@($new | Where-Object { -not ($_.sizeKnown -and $_.size) }).Count) still unknown (fix-sizes.ps1 fills them)"

# remember the server so it shows in the dashboard and can get a preset
$doc = Get-Content $serversPath -Raw | ConvertFrom-Json
if (-not @($doc.servers | Where-Object { $_.id -eq $srvId })) {
  $key = ([string]$d.server.name -split '\|')[0].Trim()
  if ($key.Length -gt 60) { $key = $key.Substring(0, 60).Trim() }
  $mods = @($d.server.mods | ForEach-Object {
    $m = $_
    $e = 0
    if ($sizes.mods.PSObject.Properties[$m.id]) { $e = [double]$sizes.mods.($m.id).bytes }
    [PSCustomObject]@{ id = $m.id; name = $m.name; e = $e }
  })
  $doc.servers = @($doc.servers) + @([PSCustomObject]@{ id = $srvId; name = $d.server.name; key = $key; mods = $mods })
  Save-Json $doc $serversPath 6
  "tracked: $($d.server.name)"
}
