# Asserts the LIVE completion rule end-to-end: every mod the dashboard calls
# "completed" must satisfy the addon's own meta file list (exact name + size per
# file) and must not have been written to for 2+ minutes. Run while the dashboard
# is up. Also asserts the inverse: any folder the dashboard would treat as "have"
# (resume/queue skip it) must pass the same rule, and a partial folder must stay
# queued - an unqueued partial is never re-downloaded.
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
$fail = 0
function Test-AddonComplete([string]$Path) {
  # the rule under test: the addon's own meta lists every file with its exact size
  $metaPath = Join-Path $Path 'meta'
  if (-not (Test-Path $metaPath)) { return $false }
  try {
    $j = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $files = @(@($j.meta.versions)[0].package.files)
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
foreach ($r in $s.recent) {
  $dir = Get-ChildItem $ds -Directory -Filter "*_$($r.id)" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $dir) { "FAIL no folder: $($r.name)"; $fail++; continue }
  # newest file, not the folder: the DS appends inside <mod>\temp\ and never
  # touches the directory timestamp, so a directory check proves nothing
  $newest = (Get-ChildItem $dir.FullName -File -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
  if ($newest -and $newest -gt (Get-Date).AddMinutes(-2)) { "FAIL still changing: $($r.name)"; $fail++ }
  if (-not (Test-AddonComplete $dir.FullName)) { "FAIL meta file list does not match: $($r.name)"; $fail++ }
}

# a folder the dashboard calls complete must not still be queued, and a partial
# folder must be queued - otherwise nothing ever re-downloads it
$queuedIds = @()
$cj = Get-Content "$Data\batch1-serverconfig.json" -Raw | ConvertFrom-Json
foreach ($m in $cj.game.mods) { $queuedIds += $m.modId }
# a partial is only recoverable while the dashboard still knows the mod: "Queue
# all missing" enumerates the sizes map plus every tracked server's modlist
$tracked = @{}
foreach ($p in (Get-Content "$Data\batch1-sizes.json" -Raw | ConvertFrom-Json).mods.PSObject.Properties) { $tracked[$p.Name] = $true }
foreach ($sv in (Get-Content "$Data\batch1-servers.json" -Raw | ConvertFrom-Json).servers) { foreach ($m in $sv.mods) { $tracked[$m.id] = $true } }
Get-ChildItem $ds -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '_([0-9A-F]{16})$' } |
  ForEach-Object {
    $id = $Matches[1]
    if (Test-AddonComplete $_.FullName) { return }   # complete, nothing to assert
    if ($s.recent.id -contains $id) { "FAIL partial folder counted as completed: $($_.Name)"; $fail++ }
    else {
      # orphaned: partial and nothing will ever re-fetch it (the bug that
      # stranded 3 AD2 mods). Not being queued right now is fine - Queue all
      # missing picks it up as long as the dashboard tracks the mod.
      if ($queuedIds -contains $id) { "note: partial folder on disk, queued for re-download: $($_.Name)" }
      elseif ($tracked.ContainsKey($id)) { "note: partial folder on disk, 'Queue all missing' re-fetches it: $($_.Name)" }
      else { "FAIL partial folder not tracked by any server or size entry: $($_.Name)"; $fail++ }
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
