# Trim batch1-serverconfig.json to mods not yet assembled in the DS profile.
# the DS fetches a download list for every config mod, and its 1 MB response
# limit chokes once the list gets big - so the config must only hold what's left.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$cfgPath = "$Data\batch1-serverconfig.json"
$addons  = "$Root\serverprofile\addons"

$done = @{}
Get-ChildItem $addons -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object {
    $files = Get-ChildItem $_.FullName -File -ErrorAction SilentlyContinue
    if (($files | Where-Object { $_.Name -in 'addon.gproj','meta','resourceDatabase.rdb' }).Count -eq 3) {
      $done[$Matches[1]] = $true
    }
  }
"assembled on disk: $($done.Count)"

$j = Get-Content $cfgPath -Raw | ConvertFrom-Json
$left = @($j.game.mods | Where-Object { -not $done.ContainsKey($_.modId) })
"config: $(@($j.game.mods).Count) -> remaining: $($left.Count)"

$j.game.mods = $left
$j | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
"saved"
