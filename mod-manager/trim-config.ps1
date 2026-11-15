# Trim batch1-serverconfig.json to mods not yet assembled in the DS profile.
# the DS fetches a download list for every config mod, and its 1 MB response
# limit chokes once the list gets big - so the config must only hold what's left.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$cfgPath = "$Data\batch1-serverconfig.json"
$addons  = "$Root\serverprofile\addons"

$done = @{}
$sizes = @{}
$sp = "$Data\batch1-sizes.json"
if (Test-Path $sp) { foreach ($p in (Get-Content $sp -Raw | ConvertFrom-Json).mods.PSObject.Properties) { $sizes[$p.Name] = [double]$p.Value.bytes } }
# same completion rule as Get-HaveIds: markers alone are NOT done - the DS
# writes them before the paks, so a partial download looks assembled.
# Marker-only folders with a known size would otherwise be trimmed out of the
# config and never re-downloaded.
# same completion rule as Get-HaveIds: size is authoritative when known; markers
# only for mods whose size we never resolved (several Workshop mods ship without
# addon.gproj, so a marker test alone would trim them out and re-download forever)
Get-ChildItem $addons -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object {
    $files = Get-ChildItem $_.FullName -File -ErrorAction SilentlyContinue
    $id = $Matches[1]
    $exp = if ($sizes[$id]) { $sizes[$id] } else { 0 }
    if ($exp) {
      $bytes = ($files | Measure-Object Length -Sum).Sum
      if ([Math]::Abs($bytes - $exp) -le [Math]::Max(2MB, 0.02 * $exp)) { $done[$id] = $true }
    } elseif (($files | Where-Object { $_.Name -in 'addon.gproj','meta','resourceDatabase.rdb' }).Count -eq 3) {
      $done[$id] = $true
    }
  }
"assembled on disk: $($done.Count)"

$j = Get-Content $cfgPath -Raw | ConvertFrom-Json
$left = @($j.game.mods | Where-Object { -not $done.ContainsKey($_.modId) })
"config: $(@($j.game.mods).Count) -> remaining: $($left.Count)"

# A partial download has addon.gproj/meta/rdb on disk, so the DS can believe it
# is installed and never fetch it again. Delete only files that have not been
# touched for 15 minutes: a fresh partial may be resumed by the next run and
# deleting it would throw that progress away.
if (-not (Get-Process ArmaReforgerServer -ErrorAction SilentlyContinue)) {
  foreach ($m in $left) {
    $d = Get-ChildItem $addons -Directory -Filter "*_$($m.modId)" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d) { continue }
    if ($d.LastWriteTime -gt (Get-Date).AddMinutes(-15)) { continue }
    Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    "deleted stale partial download: $($d.Name)"
  }
}

$j.game.mods = $left
$j | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
"saved"
