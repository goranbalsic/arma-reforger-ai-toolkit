# Fill in non-exact / zero sizes in batch1-sizes.json via /v2/mods/{id} (60 req/min).
$ErrorActionPreference = 'Stop'
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$h = @{ 'User-Agent' = 'arma-reforger-ai-toolkit/1.0' }
$p = "$Data\batch1-sizes.json"
$j = Get-Content $p -Raw | ConvertFrom-Json
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
@{ totalBytes = [double]$total; mods = $mods } | ConvertTo-Json -Depth 4 | Set-Content $p -Encoding UTF8
"updated $done sizes; new total {0:N2} GB" -f ($total/1GB)
