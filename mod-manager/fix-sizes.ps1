# Fill in non-exact / zero sizes in batch1-sizes.json via /v2/mods/{id} (60 req/min).
$ErrorActionPreference = 'Stop'
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$h = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$p = "$Data\batch1-sizes.json"
$j = Get-Content $p -Raw | ConvertFrom-Json
# a 0-byte file parses to $null; piping that produced one bogus "need" entry and
# then wrote "mods": null, which every other script reads as "no sizes at all"
if (-not $j -or -not $j.mods) { throw "$p has no mods map - restore it instead of overwriting it" }
$mods = $j.mods
$need = @($mods.PSObject.Properties | Where-Object { -not $_.Value.exact -or -not $_.Value.bytes })
"to fetch: $($need.Count)"
$done = 0
foreach ($e in $need) {
  try {
    $m = Invoke-RestMethod -Uri "https://api.reforgermods.net/v2/mods/$($e.Name)" -Headers $h -TimeoutSec 30
    if ($m.mod -and $m.mod.size) {
      $mods.($e.Name) = @{ name = $m.mod.name; bytes = $m.mod.size; exact = $true }
      $done++
    }
  } catch { "skip $($e.Name): $($_.Exception.Message)" }
  Start-Sleep -Milliseconds 1200   # stay under 60/min
}
$total = ($mods.PSObject.Properties | ForEach-Object { [double]$_.Value.bytes } | Measure-Object -Sum).Sum
# atomic: the dashboard reads this file while it runs
$tmp = "$p.tmp"
@{ totalBytes = [double]$total; mods = $mods } | ConvertTo-Json -Depth 4 | Set-Content $tmp -Encoding UTF8
if (Test-Path $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { Move-Item $tmp $p -Force }
"updated $done sizes; new total {0:N2} GB" -f ($total/1GB)
