# Asserts the LIVE completion rule end-to-end: every mod the dashboard calls
# "completed" must have all 3 assembly files on disk, be quiet for 2+ minutes,
# and match its Workshop size. Run while the dashboard is up.
$ErrorActionPreference = 'Stop'
$s = Invoke-RestMethod 'http://localhost:8123/status' -TimeoutSec 60
$ds = "$PSScriptRoot\serverprofile\addons"
$sizes = @{}
foreach ($p in (Get-Content "$env:USERPROFILE\Documents\Default Project\batch1-sizes.json" -Raw | ConvertFrom-Json).mods.PSObject.Properties) { $sizes[$p.Name] = $p.Value }

$fail = 0
foreach ($r in $s.recent) {
  $dir = Get-ChildItem $ds -Directory -Filter "*_$($r.id)" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $dir) { "FAIL no folder: $($r.name)"; $fail++; continue }
  $names = (Get-ChildItem $dir.FullName -File -ErrorAction SilentlyContinue).Name
  $missing = @('addon.gproj', 'meta', 'resourceDatabase.rdb') | Where-Object { $names -notcontains $_ }
  if ($missing) { "FAIL incomplete (missing: $($missing -join ', ')): $($r.name)"; $fail++ }
  if ($dir.LastWriteTime -gt (Get-Date).AddMinutes(-2)) { "FAIL still changing: $($r.name)"; $fail++ }
  $exp = if ($sizes[$r.id]) { [double]$sizes[$r.id].bytes } else { 0 }
  if ($exp -and [Math]::Abs($r.b - $exp) -gt [Math]::Max(2MB, 0.02 * $exp)) {
    "FAIL size off: $($r.name)  expected $exp  disk $($r.b)"; $fail++
  }
}
"checked $($s.recent.Count) completed mods, failures: $fail"
if ($fail) { exit 1 } else { 'OK' }
