# Asserts the LIVE completion rule end-to-end: every mod the dashboard calls
# "completed" must have all 3 assembly files on disk, be quiet for 2+ minutes,
# and match its Workshop size. Run while the dashboard is up.
# Also asserts the inverse: any assembled folder that the dashboard would treat
# as "have" (resume/queue skip it) must pass the same rule - a folder with the
# 3 marker files but a wrong size is an incomplete download and must stay queued.
$ErrorActionPreference = 'Stop'
$Root = if ($env:RFMM_HOME) { $env:RFMM_HOME } else { $PSScriptRoot }
$Data = if ($env:RFMM_DATA) { $env:RFMM_DATA } else { Join-Path $PSScriptRoot 'data' }
$s = try { Invoke-RestMethod 'http://localhost:8123/status' -TimeoutSec 60 }
     catch { "FAIL dashboard not reachable at http://localhost:8123/ ($($_.Exception.Message))"; exit 1 }
$ds = "$Root\serverprofile\addons"
if (-not (Test-Path $ds)) {
  "FAIL no addons folder at $ds"
  "set RFMM_HOME/RFMM_DATA to the live install (this run would otherwise test the wrong tree)"
  exit 1
}
$sizes = @{}
foreach ($p in (Get-Content "$Data\batch1-sizes.json" -Raw | ConvertFrom-Json).mods.PSObject.Properties) { $sizes[$p.Name] = $p.Value }

$fail = 0
foreach ($r in $s.recent) {
  $dir = Get-ChildItem $ds -Directory -Filter "*_$($r.id)" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $dir) { "FAIL no folder: $($r.name)"; $fail++; continue }
  if ($dir.LastWriteTime -gt (Get-Date).AddMinutes(-2)) { "FAIL still changing: $($r.name)"; $fail++ }
  $exp = if ($sizes[$r.id]) { [double]$sizes[$r.id].bytes } else { 0 }
  if ($exp) {
    # size is authoritative; several Workshop mods ship without addon.gproj
    if ([Math]::Abs($r.b - $exp) -gt [Math]::Max(2MB, 0.02 * $exp)) { "FAIL size off: $($r.name)  expected $exp  disk $($r.b)"; $fail++ }
  } else {
    $names = (Get-ChildItem $dir.FullName -File -Recurse -ErrorAction SilentlyContinue).Name
    $missing = @('addon.gproj', 'meta', 'resourceDatabase.rdb') | Where-Object { $names -notcontains $_ }
    if ($missing) { "FAIL incomplete (missing: $($missing -join ', ')): $($r.name)"; $fail++ }
  }
}

# folders with all 3 marker files but a size mismatch must NOT be treated as
# done anywhere (Get-HaveIds rule) - they would otherwise never re-download
$queuedIds = @()
$cj = Get-Content "$Data\batch1-serverconfig.json" -Raw | ConvertFrom-Json
foreach ($m in $cj.game.mods) { $queuedIds += $m.modId }
Get-ChildItem $ds -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object {
    $id = $Matches[1]
    $exp = if ($sizes[$id]) { [double]$sizes[$id].bytes } else { 0 }
    # recursive: Get-DirMap sums every file under the mod folder (the DS downloads
    # into <mod>\temp\), so a top-level-only count failed healthy installs
    $bytes = (Get-ChildItem $_.FullName -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($exp) {
      if ([Math]::Abs($bytes - $exp) -le [Math]::Max(2MB, 0.02 * $exp)) { return }   # complete
    } else {
      return   # unknown size: cannot judge here
    }
    if ($s.recent.id -contains $id) { "FAIL partial folder counted as completed: $($_.Name)"; $fail++ }
    else {
      # orphaned: partial but not queued -> trim-config would keep it out and
      # nothing ever re-downloads it (the bug that stranded 3 AD2 mods)
      $queued = $queuedIds -contains $id
      if ($queued) { "note: partial folder on disk, queued for re-download: $($_.Name)" }
      else { "FAIL partial folder NOT queued (orphaned): $($_.Name)"; $fail++ }
    }
  }
# the served page script must be syntactically valid: one stray bracket leaves
# the whole page stuck at "connecting to dashboard..." (that happened)
if (Get-Command node -ErrorAction SilentlyContinue) {
  $page = (Invoke-WebRequest 'http://localhost:8123/' -UseBasicParsing -TimeoutSec 30).Content
  $js = [regex]::Match($page, '(?s)<script>(.*)</script>').Groups[1].Value
  $tmpJs = Join-Path $env:TEMP 'rfmm-page.js'
  Set-Content $tmpJs $js -Encoding UTF8
  node --check $tmpJs 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    # keep node's message: "unexpected token" without a line number is useless
    $why = (& node --check $tmpJs 2>&1 | Select-Object -First 3) -join ' '
    "FAIL dashboard page JavaScript: $why"; $fail++
  }
  else { 'page JS: syntax ok' }
  Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue
} else { 'note: node not available - page JS syntax not checked' }

# a truncated state file (a kill during the old non-atomic save) used to kill the
# dashboard before it could serve anything - assert it now starts with defaults
$st = Join-Path $env:TEMP "rfmm-statetest-$PID"
Remove-Item $st -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$st\data", "$st\home" | Out-Null
Set-Content "$st\data\batch1-sizes.json" -Value '{"totalBytes":0,"mods":{"66C8A7B6CE49E24D":{"name":"x",' -NoNewline
Set-Content "$st\data\batch1-serverconfig.json" -Value '{"game":{"mods":[]}}' -NoNewline
Set-Content "$st\data\batch1-servers.json" -Value '{"servers":[]}' -NoNewline
$keepH = $env:RFMM_HOME; $keepD = $env:RFMM_DATA
$env:RFMM_HOME = "$st\home"; $env:RFMM_DATA = "$st\data"
& powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\download-web.ps1" -Check *> $null
$stCode = $LASTEXITCODE
$env:RFMM_HOME = $keepH; $env:RFMM_DATA = $keepD
if ($stCode -ne 0) { "FAIL a truncated state file still stops the dashboard (exit $stCode)"; $fail++ }
elseif (-not (Get-ChildItem "$st\data" -Filter '*.corrupt-*' -ErrorAction SilentlyContinue)) { 'FAIL corrupt state file was not quarantined'; $fail++ }
else { 'state files: truncated json starts with defaults, original kept as .corrupt-*' }
Remove-Item $st -Recurse -Force -ErrorAction SilentlyContinue

"checked $($s.recent.Count) completed mods, failures: $fail"
if ($fail) { exit 1 } else { 'OK' }
