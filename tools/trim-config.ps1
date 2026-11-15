# Trim batch1-serverconfig.json to mods not yet assembled in the DS profile.
# the DS fetches a download list for every config mod, and its 1 MB response
# limit chokes once the list gets big - so the config must only hold what's left.
$ErrorActionPreference = 'Stop'
$cfgPath = "$env:USERPROFILE\Documents\Default Project\batch1-serverconfig.json"
$addons  = "$PSScriptRoot\serverprofile\addons"

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

$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$left = @($cfg.game.mods | Where-Object { -not $done.ContainsKey($_.modId) })
"config: $($cfg.game.mods.Count) -> remaining: $($left.Count)"

$cfg.game.mods = $left
$cfg | ConvertTo-Json -Depth 5 | Set-Content $cfgPath -Encoding UTF8
"saved"
