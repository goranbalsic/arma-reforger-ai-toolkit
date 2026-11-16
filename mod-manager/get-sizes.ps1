# Resolve exact Workshop sizes for the mods in the DS config and MERGE them into
# batch1-sizes.json. Merge, never replace: the config is trimmed to un-downloaded
# mods, so replacing would destroy the sizes of everything already downloaded.
$ErrorActionPreference = 'Stop'
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$h = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$j = Get-Content "$Data\batch1-serverconfig.json" -Raw | ConvertFrom-Json
$mods = @($j.game.mods | ForEach-Object { @{ id = $_.modId; name = $_.name } })
"mods in config: $($mods.Count)"

$outPath = "$Data\batch1-sizes.json"
function Save-Json($obj, [string]$Path) {
  # atomic: a kill during Set-Content leaves json the dashboard cannot parse
  $tmp = "$Path.tmp"
  $obj | ConvertTo-Json -Depth 4 | Set-Content $tmp -Encoding UTF8
  if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { Move-Item $tmp $Path -Force }
}
$all = @{}
if (Test-Path $outPath) {
  $raw = Get-Content $outPath -Raw -ErrorAction Stop
  # merge, never replace: with an empty/unreadable file this used to write back
  # only the chunk it just fetched, destroying every size already resolved
  if (-not $raw) { throw "$outPath is empty - restore it instead of overwriting every size" }
  foreach ($p in ($raw | ConvertFrom-Json).mods.PSObject.Properties) { $all[$p.Name] = $p.Value }
}
"existing size entries: $($all.Count)"

$per = 480
for ($i = 0; $i -lt $mods.Count; $i += $per) {
  $chunk = $mods[$i..([Math]::Min($i + $per - 1, $mods.Count - 1))]
  $body = @{ mode = 'replace'; desired = $chunk } | ConvertTo-Json -Depth 5
  $plan = Invoke-RestMethod -Uri 'https://api.reforgermods.net/v2/tools/storage-plan' -Method Post `
    -Body $body -Headers $h -ContentType 'application/json' -TimeoutSec 120
  foreach ($d in $plan.data.downloads) { $all[$d.id] = @{ name = $d.name; bytes = $d.bytes; exact = $d.exact } }
  "chunk: +$($plan.data.downloads.Count)"
}
$total = ($all.Values | ForEach-Object { [double]$_.bytes } | Measure-Object -Sum).Sum
"total: {0:N2} GB across {1} mods ({2} exact)" -f ($total/1GB), $all.Count, @($all.Values | Where-Object exact).Count
Save-Json @{ totalBytes = [double]$total; mods = $all } $outPath
"saved (merged into) $outPath"
